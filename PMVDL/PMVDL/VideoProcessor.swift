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
        let outputName = "pmvdl_\(shortUUID)_processed.\(operation.outputExtension)"
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
