import Foundation

/// Wraps ffmpeg CLI for video processing operations.
struct VideoProcessor {
    static let shared = VideoProcessor()

    static var isAvailable: Bool { findFFmpeg() != nil }

    static func findFFmpeg() -> URL? {
        ToolLocator.find("ffmpeg")
    }

    static func findFFprobe() -> URL? {
        ToolLocator.find("ffprobe")
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
        do {
            let result = try await SubprocessRunner.run(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
            return (result.exitStatus, result.stdout, result.stderr)
        } catch SubprocessRunnerError.timedOut {
            throw VideoValidationError.invalidFile("Video verification timed out.")
        }
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

        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(
                executable: ffmpeg,
                arguments: args,
                timeout: 7200,
                stderrHandler: { text in
                    if let timeMatch = try? NSRegularExpression(
                        pattern: "time=(\\d+):(\\d+):(\\d+\\.\\d+)"
                    ).firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
                       let timeRange = Range(timeMatch.range, in: text) {
                        let timeStr = text[timeRange].dropFirst(5)
                        onProgress("Processing… \(timeStr)")
                    }
                }
            )
        } catch SubprocessRunnerError.timedOut {
            throw ProcessorError.timedOut
        }

        guard result.exitStatus == 0,
              FileManager.default.fileExists(atPath: output.path) else {
            throw ProcessorError.processFailed("Exit code \(result.exitStatus)")
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
