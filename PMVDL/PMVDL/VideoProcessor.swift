import AppKit
import Foundation
import SwiftUI

struct VideoProcessingProgress: Equatable {
    let message: String
    let percent: Double?
}

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

    static func encoderAvailability(_ encoder: String) async -> Bool {
        guard let encoders = await availableEncoders() else { return false }
        return encoders.contains(encoder)
    }

    static func availableEncoders() async -> Set<String>? {
        await encoderCache.encoders {
            await loadAvailableEncoders()
        }
    }

    static func parseAvailableEncoders(from text: String) -> Set<String> {
        Set(text.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2,
                  parts[0].count == 6,
                  parts[1] != "=" else { return nil }
            return String(parts[1])
        })
    }

    private static let encoderCache = EncoderAvailabilityCache()

    private static func loadAvailableEncoders() async -> Set<String>? {
        guard let ffmpeg = findFFmpeg() else { return nil }

        do {
            let result = try await SubprocessRunner.run(
                executable: ffmpeg,
                arguments: ["-hide_banner", "-encoders"],
                timeout: 15
            )
            guard result.exitStatus == 0 else { return nil }
            return parseAvailableEncoders(from: result.stdout)
        } catch {
            return nil
        }
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

    static func inputDuration(for file: URL) async -> Double? {
        guard let ffprobe = findFFprobe() else { return nil }
        do {
            let result = try await SubprocessRunner.run(
                executable: ffprobe,
                arguments: [
                    "-v", "error",
                    "-show_entries", "format=duration",
                    "-of", "default=noprint_wrappers=1:nokey=1",
                    file.path
                ],
                timeout: 30
            )
            guard result.exitStatus == 0 else { return nil }
            return VideoProcessingProgressParser.duration(from: result.stdout)
        } catch {
            return nil
        }
    }

    enum ProcessOp {
        case downscale(targetHeight: Int)    // 1080, 720, 480
        case convert(format: OutputFormat)    // mp4, webm, mkv
        case optimize(preset: H265OptimizationPreset)
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
            case .optimize(let preset):
                return preset.ffmpegArgs
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

        var producesVideo: Bool {
            switch self {
            case .thumbnail:
                return false
            case .downscale, .convert, .optimize, .trim:
                return true
            }
        }

        func outputURL(for input: URL) -> URL {
            switch self {
            case .optimize(let preset):
                return preset.outputURL(for: input)
            case .downscale, .convert, .trim, .thumbnail:
                let shortUUID = UUID().uuidString.prefix(8).lowercased()
                let outputName = "viddl_\(shortUUID)_processed.\(outputExtension)"
                return FileManager.default.temporaryDirectory.appendingPathComponent(outputName)
            }
        }
    }

    enum OutputFormat: String { case mp4, webm, mkv }

    /// Process a video file. Returns the output file URL.
    func process(input: URL, operation: ProcessOp, onProgress: @escaping (VideoProcessingProgress) -> Void) async throws -> URL {
        guard let ffmpeg = Self.findFFmpeg() else {
            throw ProcessorError.ffmpegNotFound
        }
        if case .optimize(let preset) = operation {
            guard await Self.encoderAvailability(preset.requiredEncoder) else {
                throw ProcessorError.encoderUnavailable(preset.encoderUnavailableReason)
            }
        }

        let output = operation.outputURL(for: input)
        try? FileManager.default.removeItem(at: output)

        let duration = await Self.inputDuration(for: input)
        onProgress(VideoProcessingProgress(message: "Processing…", percent: duration == nil ? nil : 0))

        var args = ["-y", "-i", input.path, "-progress", "pipe:1", "-nostats"]
        args.append(contentsOf: operation.ffmpegArgs)
        args.append(output.path)

        let progressParser = VideoProcessingProgressParser(duration: duration)
        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(
                executable: ffmpeg,
                arguments: args,
                timeout: 7200,
                stdoutHandler: { text in
                    for progress in progressParser.append(text) {
                        onProgress(progress)
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
        if operation.producesVideo {
            onProgress(VideoProcessingProgress(message: "Verifying processed video…", percent: 99))
            try await Self.verifyForUpload(output)
        }

        onProgress(VideoProcessingProgress(message: "Processing complete", percent: 100))
        return output
    }
}

final class VideoProcessingProgressParser: @unchecked Sendable {
    private let duration: Double?
    private let lock = NSLock()
    private var buffer = ""

    init(duration: Double?) {
        self.duration = duration
    }

    func append(_ text: String) -> [VideoProcessingProgress] {
        lock.lock()
        defer { lock.unlock() }

        buffer += text
        let hasTerminator = buffer.unicodeScalars.last.map { CharacterSet.newlines.contains($0) } ?? false
        var lines = buffer.components(separatedBy: .newlines)
        if hasTerminator {
            buffer = ""
            if lines.last == "" {
                lines.removeLast()
            }
        } else {
            buffer = lines.popLast() ?? ""
        }
        return lines.compactMap { Self.progress(from: $0, duration: duration) }
    }

    static func progress(from line: String, duration: Double?) -> VideoProcessingProgress? {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

        switch key {
        case "out_time_us", "out_time_ms":
            guard let raw = Double(value), raw.isFinite else { return nil }
            return progress(encodedSeconds: raw / 1_000_000, duration: duration)
        case "out_time":
            guard let seconds = seconds(fromTimestamp: value) else { return nil }
            return progress(encodedSeconds: seconds, duration: duration)
        default:
            return nil
        }
    }

    static func duration(from output: String) -> Double? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let seconds = Double(trimmed), seconds.isFinite, seconds > 0 {
            return seconds
        }
        return seconds(fromTimestamp: trimmed)
    }

    private static func progress(encodedSeconds: Double, duration: Double?) -> VideoProcessingProgress {
        let encodedSeconds = max(0, encodedSeconds)
        let percent: Double?
        if let duration, duration > 0 {
            percent = min(max((encodedSeconds / duration) * 100, 0), 99)
        } else {
            percent = nil
        }
        return VideoProcessingProgress(
            message: "Processing… \(timestamp(from: encodedSeconds))",
            percent: percent
        )
    }

    private static func seconds(fromTimestamp value: String) -> Double? {
        let pieces = value.split(separator: ":")
        guard pieces.count == 3,
              let hours = Double(pieces[0]),
              let minutes = Double(pieces[1]),
              let seconds = Double(pieces[2]) else { return nil }
        let total = hours * 3600 + minutes * 60 + seconds
        return total.isFinite ? total : nil
    }

    private static func timestamp(from seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

private actor EncoderAvailabilityCache {
    private var cachedEncoders: Set<String>?
    private var loadingTask: Task<Set<String>?, Never>?

    func encoders(loader: @escaping @Sendable () async -> Set<String>?) async -> Set<String>? {
        if let cachedEncoders {
            return cachedEncoders
        }

        if let loadingTask {
            return await loadingTask.value
        }

        let task = Task {
            await loader()
        }
        loadingTask = task

        let encoders = await task.value
        loadingTask = nil
        if let encoders {
            cachedEncoders = encoders
        }
        return encoders
    }
}

enum H265OptimizationPreset: String, CaseIterable, Identifiable {
    case fast
    case balanced
    case small
    case highQuality
    case tenBit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: return "Fast H.265"
        case .balanced: return "Balanced H.265"
        case .small: return "Small H.265"
        case .highQuality: return "High Quality H.265"
        case .tenBit: return "10-bit H.265"
        }
    }

    var systemImage: String {
        switch self {
        case .fast: return "bolt.fill"
        case .balanced: return "speedometer"
        case .small: return "archivebox.fill"
        case .highQuality: return "sparkles"
        case .tenBit: return "10.circle.fill"
        }
    }

    var outputSuffix: String {
        switch self {
        case .fast: return "hevc-fast"
        case .balanced: return "hevc-balanced"
        case .small: return "hevc-small"
        case .highQuality: return "hevc-hq"
        case .tenBit: return "hevc-10bit"
        }
    }

    var requiredEncoder: String {
        switch self {
        case .fast:
            return "hevc_videotoolbox"
        case .balanced, .small, .highQuality, .tenBit:
            return "libx265"
        }
    }

    var encoderUnavailableReason: String {
        if self == .fast {
            return "Fast H.265 requires the hevc_videotoolbox encoder, which is not available in the current ffmpeg build."
        }
        return "\(title) requires the \(requiredEncoder) encoder, which is not available in the current ffmpeg build."
    }

    var ffmpegArgs: [String] {
        let compatibility = ["-tag:v", "hvc1", "-movflags", "+faststart", "-c:a", "copy"]
        switch self {
        case .fast:
            return ["-c:v", "hevc_videotoolbox", "-power_efficient", "1", "-b:v", "5000k"] + compatibility
        case .balanced:
            return ["-c:v", "libx265", "-crf", "26", "-preset", "medium"] + compatibility
        case .small:
            return ["-c:v", "libx265", "-crf", "30", "-preset", "slow"] + compatibility
        case .highQuality:
            return ["-c:v", "libx265", "-crf", "22", "-preset", "medium"] + compatibility
        case .tenBit:
            return ["-c:v", "libx265", "-crf", "24", "-preset", "slow", "-pix_fmt", "yuv420p10le", "-profile:v", "main10"] + compatibility
        }
    }

    func outputURL(for input: URL) -> URL {
        let baseName = VideoFileNaming.sanitizedBaseName(
            title: input.deletingPathExtension().lastPathComponent,
            fallback: input.lastPathComponent
        )
        return input.deletingLastPathComponent().appendingPathComponent("\(baseName).\(outputSuffix).mp4")
    }
}

enum ProcessorError: LocalizedError {
    case ffmpegNotFound
    case timedOut
    case processFailed(String)
    case encoderUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound: return "ffmpeg not found. Run: brew install ffmpeg"
        case .timedOut: return "Processing timed out (2 hours)"
        case .processFailed(let m): return "Processing failed: \(m)"
        case .encoderUnavailable(let message): return message
        }
    }
}

enum ProFeatureError: LocalizedError {
    case audioRequiresPro
    case subtitlesRequirePro
    case videoProcessingRequiresPro
    case localFileRequired

    var errorDescription: String? {
        switch self {
        case .audioRequiresPro: return "Audio-only downloads require LustreStudio Pro."
        case .subtitlesRequirePro: return "Subtitle downloads require LustreStudio Pro."
        case .videoProcessingRequiresPro: return "This tool requires LustreStudio Pro."
        case .localFileRequired: return "Download this item locally before using this tool."
        }
    }
}

enum VideoProcessingPreset: String, CaseIterable, Identifiable {
    case convertMP4
    case downscale720
    case optimizeH265Fast
    case optimizeH265Balanced
    case optimizeH265Small
    case optimizeH265HighQuality
    case optimizeH26510Bit
    case thumbnail

    var id: String { rawValue }

    static let topLevelCases: [VideoProcessingPreset] = [.convertMP4, .downscale720, .thumbnail]
    static let h265Cases: [VideoProcessingPreset] = [
        .optimizeH265Fast,
        .optimizeH265Balanced,
        .optimizeH265Small,
        .optimizeH265HighQuality,
        .optimizeH26510Bit
    ]

    var title: String {
        switch self {
        case .convertMP4: return "Convert to MP4"
        case .downscale720: return "Downscale to 720p"
        case .optimizeH265Fast,
             .optimizeH265Balanced,
             .optimizeH265Small,
             .optimizeH265HighQuality,
             .optimizeH26510Bit:
            return h265Preset?.title ?? "Optimize H.265"
        case .thumbnail: return "Extract Thumbnail"
        }
    }

    var systemImage: String {
        switch self {
        case .convertMP4: return "film"
        case .downscale720: return "arrow.down.right.and.arrow.up.left"
        case .optimizeH265Fast,
             .optimizeH265Balanced,
             .optimizeH265Small,
             .optimizeH265HighQuality,
             .optimizeH26510Bit:
            return h265Preset?.systemImage ?? "speedometer"
        case .thumbnail: return "photo"
        }
    }

    var operation: VideoProcessor.ProcessOp {
        switch self {
        case .convertMP4: return .convert(format: .mp4)
        case .downscale720: return .downscale(targetHeight: 720)
        case .optimizeH265Fast: return .optimize(preset: .fast)
        case .optimizeH265Balanced: return .optimize(preset: .balanced)
        case .optimizeH265Small: return .optimize(preset: .small)
        case .optimizeH265HighQuality: return .optimize(preset: .highQuality)
        case .optimizeH26510Bit: return .optimize(preset: .tenBit)
        case .thumbnail: return .thumbnail
        }
    }

    var h265Preset: H265OptimizationPreset? {
        switch self {
        case .optimizeH265Fast: return .fast
        case .optimizeH265Balanced: return .balanced
        case .optimizeH265Small: return .small
        case .optimizeH265HighQuality: return .highQuality
        case .optimizeH26510Bit: return .tenBit
        case .convertMP4, .downscale720, .thumbnail: return nil
        }
    }

}

@MainActor
final class VideoProcessingCapabilities: ObservableObject {
    static let shared = VideoProcessingCapabilities()

    enum LoadState: Equatable {
        case unknown
        case available(Set<String>)
        case unavailable
    }

    @Published private(set) var state: LoadState

    private let encoderLoader: @Sendable () async -> Set<String>?
    private var loadTask: Task<Void, Never>?

    init(
        state: LoadState = .unknown,
        encoderLoader: @escaping @Sendable () async -> Set<String>? = { await VideoProcessor.availableEncoders() }
    ) {
        self.state = state
        self.encoderLoader = encoderLoader
    }

    func loadIfNeeded() {
        guard state == .unknown,
              loadTask == nil else { return }

        let encoderLoader = encoderLoader
        loadTask = Task { [weak self] in
            let encoders = await encoderLoader()
            guard let self else { return }
            if let encoders {
                state = .available(encoders)
            } else {
                state = .unavailable
            }
            loadTask = nil
        }
    }
}

struct VideoProcessingMenuItems: View {
    let process: (VideoProcessingPreset) -> Void

    @ObservedObject private var capabilities: VideoProcessingCapabilities

    @MainActor
    init(
        process: @escaping (VideoProcessingPreset) -> Void,
        capabilities: VideoProcessingCapabilities? = nil
    ) {
        self.process = process
        self.capabilities = capabilities ?? VideoProcessingCapabilities.shared
    }

    var body: some View {
        Group {
            ForEach(VideoProcessingPreset.topLevelCases) { preset in
                Button {
                    process(preset)
                } label: {
                    Label(preset.title, systemImage: preset.systemImage)
                }
            }

            Menu("Optimize H.265") {
                ForEach(VideoProcessingPreset.h265Cases) { preset in
                    switch h265Availability(for: preset) {
                    case .checking:
                        Button {} label: {
                            Label(preset.title, systemImage: "hourglass")
                        }
                        .disabled(true)
                        .help("Checking encoder...")
                    case .unavailable(let reason):
                        Button {} label: {
                            Label("\(preset.title) unavailable", systemImage: "exclamationmark.triangle")
                        }
                        .disabled(true)
                        .help(reason)
                    case .available:
                        Button {
                            process(preset)
                        } label: {
                            Label(preset.title, systemImage: preset.systemImage)
                        }
                    }
                }
            }
        }
        .task {
            capabilities.loadIfNeeded()
        }
    }

    private func h265Availability(for preset: VideoProcessingPreset) -> MenuAvailability {
        guard let h265Preset = preset.h265Preset else { return .available }

        switch capabilities.state {
        case .unknown:
            return h265Preset == .fast ? .checking : .available
        case .available(let encoders):
            return encoders.contains(h265Preset.requiredEncoder) ? .available : .unavailable(h265Preset.encoderUnavailableReason)
        case .unavailable:
            return .unavailable(h265Preset.encoderUnavailableReason)
        }
    }

    private enum MenuAvailability {
        case checking
        case available
        case unavailable(String)
    }
}

@MainActor
enum VideoProcessingLauncher {
    private static var runningTasks: [UUID: Task<Void, Never>] = [:]

    static func run(
        preset: VideoProcessingPreset,
        inputPath: String?,
        displayName: String,
        onUpgradeRequired: () -> Void
    ) {
        guard ProFeatureGate.isPro else {
            onUpgradeRequired()
            return
        }

        let queueId = registerProcessingJob(preset: preset, inputPath: inputPath, displayName: displayName)
        let task = Task { @MainActor in
            _ = await executeProcessingJob(
                queueId: queueId,
                preset: preset,
                inputPath: inputPath,
                displayName: displayName
            )
            runningTasks[queueId] = nil
        }
        runningTasks[queueId] = task
    }

    static func cancel(queueId: UUID) {
        runningTasks[queueId]?.cancel()
        runningTasks[queueId] = nil
    }

    @discardableResult
    static func registerProcessingJob(
        preset: VideoProcessingPreset,
        inputPath: String?,
        displayName: String
    ) -> UUID {
        let queueId = DownloadQueue.shared.addProcessing(
            url: processingSourcePath(inputPath: inputPath, displayName: displayName),
            quality: preset.title,
            displayTitle: displayName
        )
        ActiveWorkTracker.shared.project(queueId: queueId)
        return queueId
    }

    @discardableResult
    static func executeProcessingJob(
        queueId: UUID,
        preset: VideoProcessingPreset,
        inputPath: String?,
        displayName: String,
        encoderAvailability: @escaping (String) async -> Bool = VideoProcessor.encoderAvailability,
        processor: @escaping (URL, VideoProcessor.ProcessOp, @escaping (VideoProcessingProgress) -> Void) async throws -> URL = { input, operation, progress in
            try await VideoProcessor.shared.process(input: input, operation: operation, onProgress: progress)
        },
        revealOutput: Bool = true,
        registerOutput: Bool = true,
        sendNotifications: Bool = true
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let input = localInputURL(from: inputPath) else {
            failProcessing(
                queueId: queueId,
                displayName: displayName,
                reason: ProFeatureError.localFileRequired.localizedDescription,
                sendNotification: sendNotifications
            )
            return false
        }

        if let reason = await encoderUnavailableReason(for: preset, encoderAvailability: encoderAvailability) {
            failProcessing(queueId: queueId, displayName: displayName, reason: reason, sendNotification: sendNotifications)
            return false
        }

        guard !Task.isCancelled else { return false }
        DownloadQueue.shared.update(id: queueId, status: .processing, progress: 0, message: "Processing…")
        ActiveWorkTracker.shared.project(queueId: queueId)
        if sendNotifications {
            NotificationManager.shared.notifyProcessingStarted(filename: displayName, preset: preset.title)
        }

        let originalSize = fileSize(for: input)
        do {
            let output = try await processor(input, preset.operation) { progress in
                Task { @MainActor in
                    apply(progress, queueId: queueId)
                }
            }
            guard !Task.isCancelled else { return false }
            completeProcessing(
                queueId: queueId,
                output: output,
                originalSize: originalSize,
                revealOutput: revealOutput,
                registerOutput: registerOutput,
                sendNotification: sendNotifications
            )
            return true
        } catch {
            if error is CancellationError || Task.isCancelled {
                return false
            }
            failProcessing(
                queueId: queueId,
                displayName: displayName,
                reason: error.localizedDescription,
                sendNotification: sendNotifications
            )
            return false
        }
    }

    nonisolated static func encoderUnavailableReason(
        for preset: VideoProcessingPreset,
        encoderAvailability: (String) async -> Bool
    ) async -> String? {
        guard let h265Preset = preset.h265Preset else {
            return nil
        }
        guard await encoderAvailability(h265Preset.requiredEncoder) == false else { return nil }
        return h265Preset.encoderUnavailableReason
    }

    nonisolated static func localInputURL(from rawPath: String?) -> URL? {
        guard let rawPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else { return nil }

        let url: URL
        if rawPath.hasPrefix("file://"), let parsed = URL(string: rawPath) {
            url = parsed
        } else {
            url = URL(fileURLWithPath: rawPath)
        }

        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    nonisolated static func processingSourcePath(inputPath: String?, displayName: String) -> String {
        if let input = localInputURL(from: inputPath) {
            return input.absoluteString
        }
        let rawPath = inputPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return rawPath.isEmpty ? displayName : rawPath
    }

    nonisolated static func sizeSavingsSummary(originalBytes: Int64?, outputBytes: Int64?) -> String {
        guard let originalBytes,
              let outputBytes,
              originalBytes > 0 else {
            return "Output size \(MegaManager.fmt(outputBytes ?? 0))"
        }
        let percentSaved = (Double(originalBytes - outputBytes) / Double(originalBytes)) * 100
        return "\(MegaManager.fmt(originalBytes)) -> \(MegaManager.fmt(outputBytes)), saved \(String(format: "%.1f", percentSaved))%"
    }

    nonisolated static func processedLibraryItem(for output: URL) -> LibraryItem {
        LibraryItem(
            url: output.absoluteString,
            title: VideoFileNaming.sanitizedBaseName(
                title: output.deletingPathExtension().lastPathComponent,
                fallback: output.lastPathComponent
            ),
            mp4Url: output.absoluteString,
            hlsUrls: [],
            thumbnailURL: nil
        )
    }

    private static func registerProcessedOutput(_ output: URL) {
        VideoLibrary.shared.addIfNew(processedLibraryItem(for: output))
    }

    private static func apply(_ progress: VideoProcessingProgress, queueId: UUID) {
        guard let item = DownloadQueue.shared.item(id: queueId),
              item.status == .processing else { return }
        let percent = progress.percent.map { min(max($0, 0), 100) } ?? item.progress
        DownloadQueue.shared.update(
            id: queueId,
            status: .processing,
            progress: percent,
            message: progress.message
        )
        ActiveWorkTracker.shared.project(queueId: queueId)
    }

    private static func completeProcessing(
        queueId: UUID,
        output: URL,
        originalSize: Int64?,
        revealOutput: Bool,
        registerOutput: Bool,
        sendNotification: Bool
    ) {
        guard DownloadQueue.shared.item(id: queueId) != nil else { return }
        if registerOutput {
            registerProcessedOutput(output)
        }
        DownloadQueue.shared.complete(
            id: queueId,
            finalPath: output.path,
            message: "Processed \(output.lastPathComponent)"
        )
        ActiveWorkTracker.shared.project(queueId: queueId)
        if revealOutput {
            NSWorkspace.shared.activateFileViewerSelecting([output])
        }
        if sendNotification {
            NotificationManager.shared.notifyProcessingComplete(
                filename: output.lastPathComponent,
                summary: sizeSavingsSummary(
                    originalBytes: originalSize,
                    outputBytes: fileSize(for: output)
                )
            )
        }
    }

    private static func failProcessing(
        queueId: UUID,
        displayName: String,
        reason: String,
        sendNotification: Bool
    ) {
        DownloadQueue.shared.fail(id: queueId, message: reason)
        ActiveWorkTracker.shared.project(queueId: queueId)
        if sendNotification {
            NotificationManager.shared.notifyProcessingFailed(filename: displayName, reason: reason)
        }
    }

    private static func fileSize(for url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize else { return nil }
        return Int64(size)
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
