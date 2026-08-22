import XCTest
@testable import VidDL

final class DownloadQueueProjectionTests: XCTestCase {

    // MARK: - Helpers

    private func makeRetryTestResolution() -> DownloadResolution {
        let quality = VideoSource.Quality(
            label: "1080p",
            url: "https://video.example.test/movie/1080p.m3u8",
            kind: .hlsManifest,
            headers: ["Referer": "https://example.test/watch"],
            sourcePageUrl: "https://example.test/watch"
        )
        let source = VideoSource(
            mp4: nil,
            hls: [quality],
            title: "Retry Fixture",
            siteName: "NativeVideoPage",
            headers: ["User-Agent": NetworkConstants.chromeUserAgent]
        )
        let result = ExtractResult(url: "https://example.test/watch", source: source, error: nil)
        return DownloadResolution(
            requestedUrl: quality.url,
            finalUrl: quality.url,
            result: result,
            source: source,
            title: "Retry Fixture",
            mediaKind: .hls,
            headers: quality.headers,
            sourcePageUrl: quality.sourcePageUrl
        )
    }

    // MARK: - Retry payload round-trip

    func testRetryPayloadRoundTripsSourceTargetAndNonSecretContext() throws {
        let context = DownloadJobContext(
            megaRemotePath: "/Original/Mega/",
            gdriveRemoteName: "gdrive-original",
            gdriveRemotePath: "Original/VidDL/",
            seedboxTransferMode: "webdav",
            seedboxRemoteName: "seedbox-original",
            seedboxRemotePath: "/downloads/original/",
            seedboxWebdavURL: "https://seedbox.example.test/webdav/",
            seedboxWebdavUser: "seedbox-user",
            seedboxWebdavPassword: "do-not-persist"
        )
        let payload = DownloadRetryPayload(
            resolution: makeRetryTestResolution(),
            target: .seedbox,
            context: context.retryContext,
            gdriveMegaRemotePath: nil
        )

        let encoded = try JSONEncoder().encode(payload)
        let json = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("do-not-persist"),
                       "Password must not appear in encoded JSON")
        XCTAssertFalse(json.contains("seedboxWebdavPassword"),
                       "Password key must not appear in encoded JSON")
        XCTAssertTrue(json.contains("https://example.test/watch"))
        XCTAssertFalse(json.contains("https://video.example.test/movie/1080p.m3u8"),
                       "Resolved media URL must not be persisted in the retry payload")

        let decoded = try JSONDecoder().decode(DownloadRetryPayload.self, from: encoded)
        XCTAssertEqual(decoded.sourcePageURL, "https://example.test/watch")
        XCTAssertNil(decoded.preferredQualityURL)
        XCTAssertEqual(decoded.preferredQualityLabel, "1080p")
        XCTAssertEqual(decoded.target, .seedbox)
        XCTAssertEqual(decoded.context.seedboxTransferMode, "webdav")
        XCTAssertEqual(decoded.context.seedboxWebdavURL, "https://seedbox.example.test/webdav/")
    }

    // MARK: - Queue reset for retry

    @MainActor
    func testResetForRetryClearsFailureStateAndPreservesPayload() {
        let queue = DownloadQueue.shared
        let original = queue.queue
        queue.queue = []
        defer {
            queue.queue = original
            queue.save()
        }

        let payload = DownloadRetryPayload(
            resolution: makeRetryTestResolution(),
            target: .local,
            context: DownloadJobContext(
                megaRemotePath: "/Cloud/VidDL/",
                gdriveRemoteName: "gdrive",
                gdriveRemotePath: "VidDL/"
            ).retryContext,
            gdriveMegaRemotePath: nil
        )

        let id = queue.add(
            url: payload.resolution.requestedUrl,
            quality: payload.resolution.queueQuality,
            targetCloud: payload.target,
            displayTitle: payload.resolution.title,
            retryPayload: payload
        )
        queue.complete(id: id, finalPath: "/tmp/stale.mp4", message: "Stale success")
        queue.fail(id: id, message: "Network failed")

        XCTAssertTrue(queue.resetForRetry(id: id))

        guard let item = queue.item(id: id) else { return XCTFail("Missing queue item") }
        XCTAssertEqual(item.status, .pending)
        XCTAssertEqual(item.progress, 0)
        XCTAssertNil(item.finalPath)
        XCTAssertNil(item.uploadStarted)
        XCTAssertEqual(item.statusMessage, "Retrying…")
        XCTAssertEqual(item.retryPayload?.resolution.title, "Retry Fixture")
    }

    // MARK: - Retry eligibility

    @MainActor
    func testFailedItemWithoutPayloadCannotRetry() {
        var item = DownloadQueueItem(url: "https://example.test/video.mp4", quality: "Video")
        item.status = .failed("Network")
        XCTAssertFalse(item.canRetry)
    }

    @MainActor
    func testFailedItemWithPayloadCanRetryButCompletedCannot() {
        let payload = DownloadRetryPayload(
            resolution: makeRetryTestResolution(),
            target: .local,
            context: DownloadJobContext(
                megaRemotePath: "/Cloud/VidDL/",
                gdriveRemoteName: "gdrive",
                gdriveRemotePath: "VidDL/"
            ).retryContext,
            gdriveMegaRemotePath: nil
        )
        var item = DownloadQueueItem(
            url: payload.resolution.requestedUrl,
            quality: payload.resolution.queueQuality,
            targetCloud: .local,
            displayTitle: payload.resolution.title,
            retryPayload: payload
        )

        item.status = .failed("Network")
        XCTAssertTrue(item.canRetry)

        item.status = .completed
        XCTAssertFalse(item.canRetry)
    }

    @MainActor
    func testIdenticalTerminalProjectionDoesNotPublishAgain() {
        let queue = DownloadQueue.shared
        let original = queue.queue
        queue.queue = []
        defer {
            queue.queue = original
            queue.save()
        }

        let id = queue.add(url: "https://example.test/completed.mp4", quality: "Video", targetCloud: .local)
        XCTAssertTrue(queue.update(id: id, status: .completed, progress: 100, message: "Completed."))
        XCTAssertFalse(queue.update(id: id, status: .completed, progress: 100, message: "Completed."))
    }

    func testManualStartRequiresProPendingStatusAndPayload() {
        let payload = DownloadRetryPayload(
            resolution: makeRetryTestResolution(),
            target: .local,
            context: DownloadJobContext(
                megaRemotePath: "/Cloud/VidDL/",
                gdriveRemoteName: "gdrive",
                gdriveRemotePath: "VidDL/"
            ).retryContext,
            gdriveMegaRemotePath: nil
        )
        var item = DownloadQueueItem(
            url: payload.resolution.requestedUrl,
            quality: payload.resolution.queueQuality,
            targetCloud: .local,
            displayTitle: payload.resolution.title,
            retryPayload: payload
        )

        XCTAssertTrue(DownloadQueueManualStartPolicy.canStartNow(item, isPro: true))
        XCTAssertFalse(DownloadQueueManualStartPolicy.canStartNow(item, isPro: false))

        item.retryPayload = nil
        XCTAssertFalse(DownloadQueueManualStartPolicy.canStartNow(item, isPro: true))

        item.retryPayload = payload
        item.status = .paused
        XCTAssertFalse(DownloadQueueManualStartPolicy.canStartNow(item, isPro: true))
    }

    func testSeedboxMaterializationCompletionProjectsToPreparationState() {
        let projection = ProgressEvent.completed(msg: "Download complete").seedboxMaterializationProjection

        XCTAssertNotEqual(projection.status, .completed)
        XCTAssertEqual(projection.status, .verifying)
        XCTAssertEqual(projection.progress, 99)
        XCTAssertEqual(projection.message, "Preparing seedbox upload…")
    }

    func testHomeQueueCountsUseNonTerminalVisibleItemsAsRemaining() {
        let items = [
            queueItem(status: .pending),
            queueItem(status: .downloading),
            queueItem(status: .verifying),
            queueItem(status: .uploading),
            queueItem(status: .processing),
            queueItem(status: .paused),
            queueItem(status: .completed),
            queueItem(status: .failed("Network"))
        ]

        let counts = HomeQueueCounts(items: items)

        XCTAssertEqual(counts.total, 8)
        XCTAssertEqual(counts.remaining, 5)
        XCTAssertEqual(counts.active, 3)
        XCTAssertEqual(counts.queued, 1)
        XCTAssertEqual(counts.paused, 1)
        XCTAssertEqual(counts.completed, 1)
        XCTAssertEqual(counts.failed, 1)
        XCTAssertEqual(counts.activeEntry, 7)
        XCTAssertEqual(counts.summaryText, "5 remaining · 3 active · 1 queued · 1 paused")
    }

    func testHomeQueueModalEntryCountsExcludeOnlyCompletedItems() {
        let items = [
            queueItem(status: .pending),
            queueItem(status: .paused),
            queueItem(status: .failed("Network")),
            queueItem(status: .completed)
        ]

        let counts = HomeQueueCounts(items: items)

        XCTAssertEqual(counts.activeEntry, 3)
        XCTAssertEqual(counts.completed, 1)
        XCTAssertEqual(counts.failed, 1)
        XCTAssertEqual(counts.paused, 1)
    }

    func testHomeDetailLineForLocalDownloadIncludesMetricsWithoutRepeatingLocation() {
        var item = queueItem(status: .downloading)
        item.progress = 42.5
        item.bytesDownloaded = 512 * 1024 * 1024
        item.totalBytes = 1024 * 1024 * 1024
        item.bytesPerSecond = 2 * 1024 * 1024
        item.statusMessage = "Downloading… 42%"

        XCTAssertEqual(DownloadStatusFormatting.stageLabel(for: item), "Downloading")
        XCTAssertEqual(DownloadStatusFormatting.transferLocation(for: item), DownloadPaths.downloadDir.path)
        XCTAssertEqual(
            DownloadStatusFormatting.homeDetailLine(for: item),
            "512.0 MB of 1.0 GB · 2.0 MB/s · 4m 16s left · 42.5% · Downloading… 42%"
        )
    }

    func testTotalETAUsesLongestConcurrentTransfer() {
        var first = queueItem(status: .downloading)
        first.bytesDownloaded = 50
        first.totalBytes = 100
        first.bytesPerSecond = 10

        var second = queueItem(status: .downloading)
        second.bytesDownloaded = 20
        second.totalBytes = 100
        second.bytesPerSecond = 10

        XCTAssertEqual(DownloadStatusFormatting.etaDuration(for: first), "5s")
        XCTAssertEqual(DownloadStatusFormatting.totalETA(for: [first, second]), "8s")
    }

    func testTotalETAWaitsUntilEveryActiveTransferHasMetrics() {
        var measured = queueItem(status: .downloading)
        measured.bytesDownloaded = 50
        measured.totalBytes = 100
        measured.bytesPerSecond = 10

        XCTAssertNil(DownloadStatusFormatting.totalETA(for: [measured, queueItem(status: .downloading)]))
    }

    func testHomeTransferLocationUsesRemoteTargetsFromRetryPayload() {
        let payload = DownloadRetryPayload(
            resolution: makeRetryTestResolution(),
            target: .gdrive,
            context: DownloadJobContext(
                megaRemotePath: "/Cloud/VidDL/",
                gdriveRemoteName: "gdrive",
                gdriveRemotePath: "VidDL/Inbox/",
                seedboxTransferMode: "rclone",
                seedboxRemoteName: "seedbox",
                seedboxRemotePath: "/downloads/inbox/"
            ).retryContext,
            gdriveMegaRemotePath: nil
        )

        var driveItem = DownloadQueueItem(
            url: payload.resolution.requestedUrl,
            quality: payload.resolution.queueQuality,
            targetCloud: .gdrive,
            displayTitle: payload.resolution.title,
            retryPayload: payload
        )
        driveItem.status = .uploading

        XCTAssertEqual(DownloadStatusFormatting.transferLocation(for: driveItem), "gdrive:VidDL/Inbox/")

        let megaItem = DownloadQueueItem(
            url: payload.resolution.requestedUrl,
            quality: payload.resolution.queueQuality,
            targetCloud: .mega,
            displayTitle: payload.resolution.title,
            retryPayload: payload
        )
        XCTAssertEqual(DownloadStatusFormatting.transferLocation(for: megaItem), "/Cloud/VidDL/")

        let seedboxItem = DownloadQueueItem(
            url: payload.resolution.requestedUrl,
            quality: payload.resolution.queueQuality,
            targetCloud: .seedbox,
            displayTitle: payload.resolution.title,
            retryPayload: payload
        )
        XCTAssertEqual(DownloadStatusFormatting.transferLocation(for: seedboxItem), "seedbox:/downloads/inbox/")
    }

    func testHomeTransferLocationPrefersCompletedFinalPath() {
        var item = queueItem(status: .completed)
        item.finalPath = "/tmp/VidDL/video.mp4"

        XCTAssertEqual(DownloadStatusFormatting.stageLabel(for: item), "Completed")
        XCTAssertEqual(DownloadStatusFormatting.transferLocation(for: item), "/tmp/VidDL/video.mp4")
    }

    func testHomeFailureMessagePrefersFailedReason() {
        var item = queueItem(status: .failed("Seedbox authentication failed"))
        item.statusMessage = "Upload failed"

        XCTAssertEqual(DownloadStatusFormatting.stageLabel(for: item), "Failed")
        XCTAssertEqual(DownloadStatusFormatting.failureMessage(for: item), "Seedbox authentication failed")
        XCTAssertEqual(
            DownloadStatusFormatting.homeDetailLine(for: item),
            "0.0% · Upload failed · Seedbox authentication failed"
        )
    }

    @MainActor
    func testActiveDownloadCountOnlyIncludesRunningWork() {
        let queue = DownloadQueue.shared
        let original = queue.queue
        queue.queue = [
            queueItem(status: .pending),
            queueItem(status: .downloading),
            queueItem(status: .verifying),
            queueItem(status: .uploading),
            queueItem(status: .processing),
            queueItem(status: .paused),
            queueItem(status: .completed),
            queueItem(status: .failed("Network"))
        ]
        defer {
            queue.queue = original
            queue.save()
        }

        XCTAssertEqual(queue.activeDownloadCount, 4)
    }

    func testSleepPreventionPolicyOnlyKeepsAwakeForRunningWorkWhenEnabled() {
        let idleItems = [
            queueItem(status: .pending),
            queueItem(status: .paused),
            queueItem(status: .completed),
            queueItem(status: .failed("Network"))
        ]
        let runningItems = idleItems + [
            queueItem(status: .downloading),
            queueItem(status: .verifying),
            queueItem(status: .uploading),
            queueItem(status: .processing)
        ]

        XCTAssertFalse(SleepPreventionPolicy.shouldPreventSleep(isEnabled: false, items: runningItems))
        XCTAssertFalse(SleepPreventionPolicy.shouldPreventSleep(isEnabled: true, items: idleItems))
        XCTAssertTrue(SleepPreventionPolicy.shouldPreventSleep(isEnabled: true, items: runningItems))
    }

    func testCapacitySeparatesReadyWaitingAndActiveWork() {
        let capacity = DownloadQueueCapacity(
            items: [
                queueItem(status: .pending),
                queueItem(status: .pending),
                queueItem(status: .waiting),
                queueItem(status: .downloading),
                queueItem(status: .uploading)
            ],
            limit: 5
        )

        XCTAssertEqual(capacity.ready, 2)
        XCTAssertEqual(capacity.waiting, 1)
        XCTAssertEqual(capacity.active, 2)
        XCTAssertEqual(capacity.availableSlots, 2)
    }

    func testPendingStateUsesReadyMessageInsteadOfStaleTransferMessage() {
        var item = queueItem(status: .pending)
        item.statusMessage = "Transferring to seedbox…"

        XCTAssertEqual(DownloadStatusFormatting.statusLabel(item), "Ready")
        XCTAssertEqual(DownloadStatusFormatting.operationalMessage(for: item), "Ready to start")
    }

    @MainActor
    func testSeedboxHLSLocalMaterializationStaysActiveUntilFinalCompletion() {
        let queue = DownloadQueue.shared
        let original = queue.queue
        queue.queue = []
        defer {
            queue.queue = original
            queue.save()
        }

        let id = queue.add(url: "https://vidara.example.test/video.m3u8", quality: "HLS → Seedbox", targetCloud: .seedbox, displayTitle: "Vidara Fixture")

        queue.update(id: id, status: .downloading, progress: 10, message: "Materializing HLS…")
        assertQueueItemIsActive(id: id, message: "Materializing HLS…")

        let materialized = ProgressEvent.completed(msg: "Download complete").seedboxMaterializationProjection
        queue.update(id: id, status: materialized.status, progress: materialized.progress, message: materialized.message, metrics: materialized.metrics)
        assertQueueItemIsActive(id: id, message: "Preparing seedbox upload…")

        queue.update(id: id, status: .uploading, progress: 0, message: "Uploading to seedbox… 0%")
        assertQueueItemIsActive(id: id, message: "Uploading to seedbox… 0%")

        queue.complete(id: id, finalPath: "/downloads/Vidara Fixture.mp4", message: "Uploaded to Seedbox")

        guard let completed = queue.item(id: id),
              let completedState = queue.projectedState(for: completed) else {
            return XCTFail("Expected completed queue item")
        }
        XCTAssertEqual(completed.status, .completed)
        if case .done(let message) = completedState {
            XCTAssertEqual(message, "Uploaded to Seedbox")
        } else {
            XCTFail("Expected final done projection")
        }
    }

    // MARK: - Existing projection test

    @MainActor
    func testQueueItemProjectsUploadState() {
        let queue = DownloadQueue.shared
        let original = queue.queue
        queue.queue = []
        defer {
            queue.queue = original
            queue.save()
        }

        let id = queue.add(url: "https://example.test/video.mp4", quality: "Video", targetCloud: .local, displayTitle: "Video")
        queue.update(id: id, status: .downloading, progress: 42, message: "Downloading… 42%")

        guard let downloading = queue.item(id: id),
              let state = queue.projectedState(for: downloading) else {
            return XCTFail("Expected projected state")
        }

        if case .uploading(let message) = state {
            XCTAssertEqual(message, "Downloading… 42%")
        } else {
            XCTFail("Expected uploading projection")
        }

        queue.complete(id: id, finalPath: "/tmp/video.mp4", message: "Saved to video.mp4")
        guard let completed = queue.item(id: id),
              let completedState = queue.projectedState(for: completed) else {
            return XCTFail("Expected completed state")
        }

        if case .done(let message) = completedState {
            XCTAssertEqual(message, "Saved to video.mp4")
        } else {
            XCTFail("Expected done projection")
        }
    }

    func testAutomaticRetryPolicyOnlyRetriesTransientFailures() {
        XCTAssertTrue(DownloadAutomaticRetryPolicy.shouldRetry(URLError(.timedOut), after: 0))
        XCTAssertTrue(DownloadAutomaticRetryPolicy.shouldRetry(URLError(.networkConnectionLost), after: 1))
        XCTAssertTrue(DownloadAutomaticRetryPolicy.shouldRetry(NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "Source returned HTTP 503"]), after: 0))
        XCTAssertFalse(DownloadAutomaticRetryPolicy.shouldRetry(URLError(.userAuthenticationRequired), after: 0))
        XCTAssertFalse(DownloadAutomaticRetryPolicy.shouldRetry(URLError(.timedOut), after: DownloadAutomaticRetryPolicy.maximumAttempts))
    }

    @MainActor
    func testAutomaticRetryKeepsItemWaitingUntilItsRetryTime() {
        let queue = DownloadQueue.shared
        let original = queue.queue
        queue.queue = []
        defer {
            queue.queue = original
            queue.save()
        }

        let id = queue.add(
            url: "https://example.test/video.mp4",
            quality: "Video",
            targetCloud: .local,
            retryPayload: DownloadRetryPayload(
                resolution: makeRetryTestResolution(),
                target: .local,
                context: DownloadJobContext(megaRemotePath: "/", gdriveRemoteName: "gdrive", gdriveRemotePath: "/").retryContext,
                gdriveMegaRemotePath: nil
            )
        )

        XCTAssertTrue(queue.scheduleAutomaticRetry(id: id, attempt: 1, after: 5))
        guard let item = queue.item(id: id) else { return XCTFail("Missing queue item") }
        XCTAssertEqual(item.status, .waiting)
        XCTAssertEqual(item.automaticRetryCount, 1)
        XCTAssertNotNil(queue.automaticRetryDelay(for: item))
        XCTAssertEqual(item.statusMessage, "Temporary connection issue. Retrying in 5s…")
    }

    @MainActor
    private func assertQueueItemIsActive(id: UUID, message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let item = DownloadQueue.shared.item(id: id),
              let state = DownloadQueue.shared.projectedState(for: item) else {
            return XCTFail("Expected active queue item", file: file, line: line)
        }

        XCTAssertFalse(item.status.isTerminal, file: file, line: line)
        if case .uploading(let projectedMessage) = state {
            XCTAssertEqual(projectedMessage, message, file: file, line: line)
        } else {
            XCTFail("Expected non-terminal upload projection", file: file, line: line)
        }
    }

    private func queueItem(status: QueueStatus) -> DownloadQueueItem {
        var item = DownloadQueueItem(url: "https://example.test/\(UUID().uuidString).mp4", quality: "Video", targetCloud: .local)
        item.status = status
        return item
    }
}
