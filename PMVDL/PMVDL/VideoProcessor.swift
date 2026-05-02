import Foundation

/// Wraps ffmpeg CLI for video processing operations.
struct VideoProcessor {
    static let shared = VideoProcessor()

    static var isAvailable: Bool { findFFmpeg() != nil }

    static func findFFmpeg() -> URL? {
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    static func findFFprobe() -> URL? {
        for path in ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"] {
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    static func verifyForUpload(_ file: URL) async throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw VideoValidationError.invalidFile("Downloaded output is not a regular file.")
        }
        let size = Int64(values.fileSize ?? 0)
        guard size >= 16 * 1024 else {
            throw VideoValidationError.invalidFile("Downloaded file is too short (\(MegaManager.fmt(size))).")
        }
        if let handle = try? FileHandle(forReadingFrom: file) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 512), data.count > 0 {
                let prefix = String(decoding: data.prefix(512), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html") {
                    throw VideoValidationError.invalidFile("Downloaded output is HTML, not a video file.")
                }
            }
        }

        if let ffprobe = findFFprobe() {
            let result = try await runTool(
                ffprobe,
                arguments: [
                    "-v", "error",
                    "-select_streams", "v:0",
                    "-show_entries", "stream=codec_type,codec_name,width,height",
                    "-of", "default=noprint_wrappers=1",
                    file.path
                ],
                timeout: 30
            )
            guard result.status == 0 else {
                throw VideoValidationError.invalidFile(cleanValidationMessage(result.stderr))
            }
            guard result.stdout.contains("codec_type=video") else {
                throw VideoValidationError.invalidFile("Downloaded file does not contain a video stream.")
            }
        }

        guard let ffmpeg = findFFmpeg() else { return }
        let result = try await runTool(
            ffmpeg,
            arguments: [
                "-v", "error",
                "-xerror",
                "-i", file.path,
                "-map", "0:v:0",
                "-frames:v", "1",
                "-f", "null",
                "-"
            ],
            timeout: 45
        )
        guard result.status == 0 else {
            throw VideoValidationError.invalidFile(cleanValidationMessage(result.stderr))
        }
    }

    private static func runTool(_ executable: URL, arguments: [String], timeout: TimeInterval) async throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()

        let started = Date()
        while process.isRunning {
            if Date().timeIntervalSince(started) > timeout {
                process.terminate()
                process.waitUntilExit()
                throw VideoValidationError.invalidFile("Video verification timed out.")
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private static func cleanValidationMessage(_ message: String) -> String {
        let cleaned = message
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if cleaned.isEmpty {
            return "Downloaded video failed verification."
        }
        return String(cleaned.prefix(300))
    }

    enum ProcessOp {
        case downscale(targetHeight: Int)    // 1080, 720, 480
        case convert(format: OutputFormat)    // mp4, webm, mkv
        case optimize                        // H.265 re-encode
        case trim(startTime: Double, endTime: Double)
        case thumbnail                       // extract first frame as JPEG

        var ffmpegArgs: [String] {
            switch self {
            case .downscale(let h):
                return ["-vf", "scale=-2:\(h)", "-c:a", "copy"]
            case .convert(let fmt):
                return fmt == .mp4 ? ["-c:v", "libx264", "-c:a", "aac"]
                   : fmt == .webm ? ["-c:v", "libvpx-vp9", "-c:a", "libopus"]
                   : ["-c", "copy"]
            case .optimize:
                return ["-c:v", "libx265", "-crf", "28", "-c:a", "copy"]
            case .trim(let s, let e):
                return ["-ss", "\(s)", "-to", "\(e)", "-c", "copy"]
            case .thumbnail:
                return ["-vf", "select=eq(n\\,0)", "-vframes", "1", "-q:v", "2"]
            }
        }

        var outputExtension: String {
            switch self {
            case .downscale: return "mp4"
            case .convert(let f): return f.rawValue
            case .optimize: return "mp4"
            case .trim: return "mp4"
            case .thumbnail: return "jpg"
            }
        }
    }

    enum OutputFormat: String { case mp4, webm, mkv }

    /// Process a video file. Returns the output file URL.
    func process(input: URL, operation: ProcessOp, onProgress: @escaping (String) -> Void) async throws -> URL {
        guard let ffmpeg = Self.findFFmpeg() else {
            throw ProcessorError.ffmpegNotFound
        }

        let shortUUID = UUID().uuidString.prefix(8).lowercased()
        let outputName = "viddl_\(shortUUID)_processed.\(operation.outputExtension)"
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(outputName)
        try? FileManager.default.removeItem(at: output)

        var args = ["-y", "-i", input.path]
        args.append(contentsOf: operation.ffmpegArgs)
        args.append(output.path)

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = args
        process.standardOutput = Pipe()

        let errPipe = Pipe()
        process.standardError = errPipe

        // Parse progress from stderr
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { errPipe.fileHandleForReading.readabilityHandler = nil; return }
            if let str = String(data: data, encoding: .utf8) {
                // ffmpeg time=00:01:23.45 → extract progress
                if let timeMatch = try? NSRegularExpression(
                    pattern: "time=(\\d+):(\\d+):(\\d+\\.\\d+)"
                ).firstMatch(in: str, range: NSRange(str.startIndex..<str.endIndex, in: str)),
                   let timeRange = Range(timeMatch.range, in: str) {
                    let timeStr = str[timeRange].dropFirst(5)
                    onProgress("Processing… \(timeStr)")
                }
            }
        }

        try process.run()

        let start = Date()
        while process.isRunning {
            if Date().timeIntervalSince(start) > 7200 {
                process.terminate()
                throw ProcessorError.timedOut
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        errPipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: output.path) else {
            throw ProcessorError.processFailed("Exit code \(process.terminationStatus)")
        }

        onProgress("Processing complete")
        return output
    }
}

enum ProcessorError: LocalizedError {
    case ffmpegNotFound
    case timedOut
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound: return "ffmpeg not found. Run: brew install ffmpeg"
        case .timedOut: return "Processing timed out (2 hours)"
        case .processFailed(let m): return "Processing failed: \(m)"
        }
    }
}

enum VideoValidationError: LocalizedError {
    case invalidFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile(let message): return "Downloaded file failed verification: \(message)"
        }
    }
}
