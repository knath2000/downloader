import XCTest
@testable import VidDL

final class H265OptimizationPresetTests: XCTestCase {
    func testFastPresetUsesVideoToolboxEncoder() {
        XCTAssertTrue(H265OptimizationPreset.fast.ffmpegArgs.containsPair("-c:v", "hevc_videotoolbox"))
    }

    func testSoftwarePresetsUseX265Encoder() {
        for preset in [H265OptimizationPreset.balanced, .small, .highQuality, .tenBit] {
            XCTAssertTrue(preset.ffmpegArgs.containsPair("-c:v", "libx265"), "\(preset.title) should use libx265")
        }
    }

    func testAllH265PresetsUseMp4CompatibilityFlags() {
        for preset in H265OptimizationPreset.allCases {
            XCTAssertTrue(preset.ffmpegArgs.containsPair("-tag:v", "hvc1"), "\(preset.title) should tag HEVC as hvc1")
            XCTAssertTrue(preset.ffmpegArgs.containsPair("-movflags", "+faststart"), "\(preset.title) should enable faststart")
            XCTAssertEqual(preset.outputURL(for: URL(fileURLWithPath: "/Downloads/Foo.mp4")).pathExtension, "mp4")
        }
    }

    func testTenBitPresetUsesMain10PixelFormatAndProfile() {
        let args = H265OptimizationPreset.tenBit.ffmpegArgs

        XCTAssertTrue(args.containsPair("-pix_fmt", "yuv420p10le"))
        XCTAssertTrue(args.containsPair("-profile:v", "main10"))
    }

    func testBalancedOutputPathSavesBesideInputWithStableSuffix() {
        let input = URL(fileURLWithPath: "/Downloads/Foo.mp4")
        let output = H265OptimizationPreset.balanced.outputURL(for: input)

        XCTAssertEqual(output.path, "/Downloads/Foo.hevc-balanced.mp4")
    }

    func testOutputPathReplacesExistingExtensionCleanly() {
        let input = URL(fileURLWithPath: "/Downloads/Foo.final.mov")
        let output = H265OptimizationPreset.highQuality.outputURL(for: input)

        XCTAssertEqual(output.path, "/Downloads/Foo.final.hevc-hq.mp4")
    }

    func testGeneratedOutputNamesAreStableAndFilesystemSafe() {
        let input = URL(fileURLWithPath: "/Downloads/Foo<>.mp4")
        let first = H265OptimizationPreset.small.outputURL(for: input)
        let second = H265OptimizationPreset.small.outputURL(for: input)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, "Foo.hevc-small.mp4")
    }
}

final class VideoProcessorEncoderCapabilityTests: XCTestCase {
    func testParserDetectsVideoToolboxEncoder() {
        let output = """
        Encoders:
         V..... = Video
         V....D hevc_videotoolbox VideoToolbox H.265 Encoder
        """

        XCTAssertTrue(VideoProcessor.parseAvailableEncoders(from: output).contains("hevc_videotoolbox"))
    }

    func testParserDetectsX265Encoder() {
        let output = """
        Encoders:
         V..... libx264 libx264 H.264 / AVC encoder
         V....D libx265 libx265 H.265 / HEVC encoder
        """

        XCTAssertTrue(VideoProcessor.parseAvailableEncoders(from: output).contains("libx265"))
    }

    func testParserReturnsUnavailableWhenEncoderLineIsAbsent() {
        let output = """
        Encoders:
         V..... libx264 libx264 H.264 / AVC encoder
         A..... aac AAC encoder
        """

        let encoders = VideoProcessor.parseAvailableEncoders(from: output)

        XCTAssertFalse(encoders.contains("hevc_videotoolbox"))
        XCTAssertFalse(encoders.contains("libx265"))
    }
}

final class VideoProcessingProgressParserTests: XCTestCase {
    func testOutTimeMsUsesDurationForPercent() throws {
        let progress = try XCTUnwrap(VideoProcessingProgressParser.progress(from: "out_time_ms=5000000", duration: 10))

        XCTAssertEqual(progress.percent ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(progress.message, "Processing… 00:00:05")
    }

    func testOutTimeUsUsesDurationForPercent() throws {
        let progress = try XCTUnwrap(VideoProcessingProgressParser.progress(from: "out_time_us=2500000", duration: 10))

        XCTAssertEqual(progress.percent ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(progress.message, "Processing… 00:00:03")
    }

    func testMissingDurationReturnsMessageOnlyProgress() throws {
        let progress = try XCTUnwrap(VideoProcessingProgressParser.progress(from: "out_time_us=5000000", duration: nil))

        XCTAssertNil(progress.percent)
        XCTAssertEqual(progress.message, "Processing… 00:00:05")
    }
}

final class VideoProcessingLauncherTests: XCTestCase {
    func testNonLocalInputIsRejected() {
        XCTAssertNil(VideoProcessingLauncher.localInputURL(from: "https://example.test/video.mp4"))
    }

    func testProcessedOutputBuildsLocalLibraryItem() {
        let output = URL(fileURLWithPath: "/Downloads/Foo.hevc-balanced.mp4")
        let item = VideoProcessingLauncher.processedLibraryItem(for: output)

        XCTAssertEqual(item.url, output.absoluteString)
        XCTAssertEqual(item.mp4Url, output.absoluteString)
        XCTAssertEqual(item.title, "Foo.hevc-balanced")
        XCTAssertTrue(item.hlsUrls.isEmpty)
    }

    func testSizeSavingsSummaryForSmallerOutput() {
        let summary = VideoProcessingLauncher.sizeSavingsSummary(originalBytes: 200, outputBytes: 100)

        XCTAssertTrue(summary.contains("saved 50.0%"))
    }

    func testSizeSavingsSummaryForSameSizeOutput() {
        let summary = VideoProcessingLauncher.sizeSavingsSummary(originalBytes: 200, outputBytes: 200)

        XCTAssertTrue(summary.contains("saved 0.0%"))
    }

    func testSizeSavingsSummaryForLargerOutput() {
        let summary = VideoProcessingLauncher.sizeSavingsSummary(originalBytes: 200, outputBytes: 250)

        XCTAssertTrue(summary.contains("saved -25.0%"))
    }

    func testFastH265RejectsWhenVideoToolboxEncoderIsAbsent() async {
        let reason = await VideoProcessingLauncher.encoderUnavailableReason(
            for: .optimizeH265Fast,
            encoderAvailability: { _ in false }
        )

        XCTAssertEqual(reason, H265OptimizationPreset.fast.encoderUnavailableReason)
    }

    func testSoftwareH265PresetsRejectWhenX265EncoderIsAbsent() async {
        for preset in VideoProcessingPreset.h265Cases.filter({ $0 != .optimizeH265Fast }) {
            let reason = await VideoProcessingLauncher.encoderUnavailableReason(
                for: preset,
                encoderAvailability: { encoder in encoder != "libx265" }
            )

            XCTAssertEqual(reason, preset.h265Preset?.encoderUnavailableReason)
        }
    }

    @MainActor
    func testStartingProcessingJobCreatesDownloadsRow() {
        withEmptyQueue {
            let id = VideoProcessingLauncher.registerProcessingJob(
                preset: .optimizeH265Balanced,
                inputPath: "/tmp/Foo.mp4",
                displayName: "Foo"
            )

            guard let item = DownloadQueue.shared.item(id: id) else {
                return XCTFail("Expected processing row")
            }
            XCTAssertEqual(item.status, .processing)
            XCTAssertEqual(item.progress, 0)
            XCTAssertEqual(item.statusMessage, "Checking encoder…")
            XCTAssertEqual(item.quality, "Balanced H.265")
            XCTAssertEqual(item.targetCloud, .local)
            XCTAssertTrue(item.isProcessingJob)
            XCTAssertFalse(item.canRetry)
        }
    }

    @MainActor
    func testProcessingProgressCallbackUpdatesQueueRow() async throws {
        try await withTempFiles { input, output in
            try await withEmptyQueueAsync {
                let id = VideoProcessingLauncher.registerProcessingJob(
                    preset: .optimizeH265Balanced,
                    inputPath: input.path,
                    displayName: "Foo"
                )

                let completed = await VideoProcessingLauncher.executeProcessingJob(
                    queueId: id,
                    preset: .optimizeH265Balanced,
                    inputPath: input.path,
                    displayName: "Foo",
                    encoderAvailability: { _ in true },
                    processor: { _, _, progress in
                        progress(VideoProcessingProgress(message: "Processing… 00:00:05", percent: 50))
                        try await Task.sleep(nanoseconds: 50_000_000)
                        await MainActor.run {
                            guard let item = DownloadQueue.shared.item(id: id) else {
                                return XCTFail("Expected processing row")
                            }
                            XCTAssertEqual(item.status, .processing)
                            XCTAssertEqual(item.progress, 50, accuracy: 0.001)
                            XCTAssertEqual(item.statusMessage, "Processing… 00:00:05")
                        }
                        FileManager.default.createFile(atPath: output.path, contents: Data(repeating: 1, count: 32))
                        return output
                    },
                    revealOutput: false,
                    registerOutput: false,
                    sendNotifications: false
                )

                XCTAssertTrue(completed)
            }
        }
    }

    @MainActor
    func testEncoderUnavailableFailsProcessingRow() async throws {
        try await withTempFiles { input, output in
            try await withEmptyQueueAsync {
                let id = VideoProcessingLauncher.registerProcessingJob(
                    preset: .optimizeH265Fast,
                    inputPath: input.path,
                    displayName: "Foo"
                )

                let completed = await VideoProcessingLauncher.executeProcessingJob(
                    queueId: id,
                    preset: .optimizeH265Fast,
                    inputPath: input.path,
                    displayName: "Foo",
                    encoderAvailability: { _ in false },
                    processor: { _, _, _ in
                        XCTFail("Processor should not run when encoder is unavailable")
                        return output
                    },
                    revealOutput: false,
                    registerOutput: false,
                    sendNotifications: false
                )

                XCTAssertFalse(completed)
                guard let item = DownloadQueue.shared.item(id: id) else {
                    return XCTFail("Expected processing row")
                }
                XCTAssertEqual(item.status, .failed(H265OptimizationPreset.fast.encoderUnavailableReason))
                XCTAssertEqual(item.statusMessage, H265OptimizationPreset.fast.encoderUnavailableReason)
            }
        }
    }

    @MainActor
    func testSuccessfulProcessingCompletesRowWithOutputPath() async throws {
        try await withTempFiles { input, output in
            try await withEmptyQueueAsync {
                let id = VideoProcessingLauncher.registerProcessingJob(
                    preset: .optimizeH265Balanced,
                    inputPath: input.path,
                    displayName: "Foo"
                )

                let completed = await VideoProcessingLauncher.executeProcessingJob(
                    queueId: id,
                    preset: .optimizeH265Balanced,
                    inputPath: input.path,
                    displayName: "Foo",
                    encoderAvailability: { _ in true },
                    processor: { _, _, _ in
                        FileManager.default.createFile(atPath: output.path, contents: Data(repeating: 1, count: 32))
                        return output
                    },
                    revealOutput: false,
                    registerOutput: false,
                    sendNotifications: false
                )

                XCTAssertTrue(completed)
                guard let item = DownloadQueue.shared.item(id: id) else {
                    return XCTFail("Expected processing row")
                }
                XCTAssertEqual(item.status, .completed)
                XCTAssertEqual(item.finalPath, output.path)
                XCTAssertEqual(item.statusMessage, "Processed \(output.lastPathComponent)")
            }
        }
    }

    @MainActor
    func testLocalFileRejectionFailsProcessingRow() async {
        await withEmptyQueueAsync {
            let id = VideoProcessingLauncher.registerProcessingJob(
                preset: .optimizeH265Balanced,
                inputPath: "/tmp/does-not-exist-\(UUID().uuidString).mp4",
                displayName: "Missing"
            )

            let completed = await VideoProcessingLauncher.executeProcessingJob(
                queueId: id,
                preset: .optimizeH265Balanced,
                inputPath: "/tmp/does-not-exist-\(UUID().uuidString).mp4",
                displayName: "Missing",
                encoderAvailability: { _ in true },
                processor: { _, _, _ in
                    XCTFail("Processor should not run for missing local files")
                    return URL(fileURLWithPath: "/tmp/unused.mp4")
                },
                revealOutput: false,
                registerOutput: false,
                sendNotifications: false
            )

            XCTAssertFalse(completed)
            guard let item = DownloadQueue.shared.item(id: id) else {
                return XCTFail("Expected processing row")
            }
            XCTAssertEqual(item.status, .failed(ProFeatureError.localFileRequired.localizedDescription))
            XCTAssertEqual(item.statusMessage, ProFeatureError.localFileRequired.localizedDescription)
        }
    }

    @MainActor
    private func withEmptyQueue(_ body: () -> Void) {
        let queue = DownloadQueue.shared
        let original = queue.queue
        queue.queue = []
        defer {
            queue.queue = original
            queue.save()
        }
        body()
    }

    @MainActor
    private func withEmptyQueueAsync(_ body: () async throws -> Void) async rethrows {
        let queue = DownloadQueue.shared
        let original = queue.queue
        queue.queue = []
        defer {
            queue.queue = original
            queue.save()
        }
        try await body()
    }

    private func withTempFiles(_ body: (URL, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("Foo.mp4")
        let output = directory.appendingPathComponent("Foo.hevc-balanced.mp4")
        FileManager.default.createFile(atPath: input.path, contents: Data(repeating: 1, count: 32))
        try await body(input, output)
    }
}

final class VideoProcessingMenuItemsTests: XCTestCase {
    @MainActor
    func testConstructingMenuItemsDoesNotStartCapabilityLoad() {
        let capabilities = VideoProcessingCapabilities(
            encoderLoader: {
                return nil
            }
        )

        let view = VideoProcessingMenuItems(process: { _ in }, capabilities: capabilities)
        _ = view.body

        XCTAssertEqual(capabilities.state, .unknown)
    }
}

final class DownloadProcessingFormattingTests: XCTestCase {
    func testProcessingStatusFormatting() {
        var item = DownloadQueueItem(
            url: "file:///tmp/Foo.mp4",
            quality: "Balanced H.265",
            targetCloud: .local,
            displayTitle: "Foo"
        )
        item.itemKind = .processing
        item.status = .processing
        item.progress = 42.5
        item.statusMessage = "Processing… 00:00:05"

        XCTAssertEqual(DownloadStatusFormatting.statusLabel(item), "Processing")
        XCTAssertEqual(DownloadStatusFormatting.statusIcon(item), "wand.and.stars")
        XCTAssertEqual(DownloadStatusFormatting.phaseLabel(for: item), "Process")
        XCTAssertEqual(DownloadStatusFormatting.metricsLine(for: item), "42.5% · Processing… 00:00:05")
    }
}

private extension Array where Element == String {
    func containsPair(_ key: String, _ value: String) -> Bool {
        zip(self, dropFirst()).contains { $0 == key && $1 == value }
    }
}
