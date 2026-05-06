import XCTest
@testable import VidDL

final class DownloadQueueResumeTests: XCTestCase {
    @MainActor
    func testInterruptedItemsWithRetryPayloadBecomePending() {
        let queue = DownloadQueue.shared
        let original = queue.queue
        queue.queue = []
        defer {
            queue.queue = original
            queue.save()
        }

        var item = DownloadQueueItem(
            url: payload.resolution.requestedUrl,
            quality: payload.resolution.queueQuality,
            targetCloud: .local,
            displayTitle: payload.resolution.title,
            retryPayload: payload
        )
        item.status = .downloading
        item.progress = 48
        queue.queue = [item]

        queue.normalizeInterruptedItemsForLaunch()

        XCTAssertEqual(queue.queue.first?.status, .pending)
        XCTAssertEqual(queue.queue.first?.progress, 0)
        XCTAssertEqual(queue.queue.first?.statusMessage, "Resuming after app restart…")
    }

    @MainActor
    func testInterruptedItemsWithoutRetryPayloadBecomeFailed() {
        let queue = DownloadQueue.shared
        let original = queue.queue
        queue.queue = []
        defer {
            queue.queue = original
            queue.save()
        }

        var item = DownloadQueueItem(url: "https://example.test/video.mp4", quality: "MP4", targetCloud: .local)
        item.status = .uploading
        queue.queue = [item]

        queue.normalizeInterruptedItemsForLaunch()

        guard case .failed(let reason) = queue.queue.first?.status else {
            return XCTFail("Expected failed status")
        }
        XCTAssertEqual(reason, "Interrupted and cannot resume because retry metadata is missing.")
    }

    @MainActor
    func testPausedAndCompletedItemsArePreserved() {
        let queue = DownloadQueue.shared
        let original = queue.queue
        queue.queue = []
        defer {
            queue.queue = original
            queue.save()
        }

        var paused = DownloadQueueItem(url: "https://example.test/paused.mp4", quality: "MP4", targetCloud: .local, retryPayload: payload)
        paused.status = .paused
        var completed = DownloadQueueItem(url: "https://example.test/done.mp4", quality: "MP4", targetCloud: .local, retryPayload: payload)
        completed.status = .completed
        queue.queue = [paused, completed]

        queue.normalizeInterruptedItemsForLaunch()

        XCTAssertEqual(queue.queue[0].status, .paused)
        XCTAssertEqual(queue.queue[1].status, .completed)
    }

    @MainActor
    func testInterruptedSeedboxItemsUseRemoteSafeNewFileStrategy() {
        let queue = DownloadQueue.shared
        let original = queue.queue
        queue.queue = []
        defer {
            queue.queue = original
            queue.save()
        }

        var item = DownloadQueueItem(
            url: payload.resolution.requestedUrl,
            quality: payload.resolution.queueQuality,
            targetCloud: .seedbox,
            displayTitle: payload.resolution.title,
            retryPayload: payload
        )
        item.status = .uploading
        queue.queue = [item]

        queue.normalizeInterruptedItemsForLaunch()

        XCTAssertEqual(queue.queue.first?.status, .pending)
        XCTAssertEqual(queue.queue.first?.resumeStrategy, .remoteSafeNewFile)
    }

    private var payload: DownloadRetryPayload {
        let quality = VideoSource.Quality(label: "MP4", url: "https://example.test/video.mp4", kind: .direct)
        let source = VideoSource(mp4: quality.url, hls: [quality], title: "Resume Fixture", siteName: "NativeVideoPage")
        let result = ExtractResult(url: "https://example.test/watch", source: source, error: nil)
        let resolution = DownloadResolution(
            requestedUrl: quality.url,
            finalUrl: quality.url,
            result: result,
            source: source,
            title: "Resume Fixture",
            mediaKind: .direct,
            headers: nil,
            sourcePageUrl: nil
        )
        return DownloadRetryPayload(
            resolution: resolution,
            target: .local,
            context: DownloadJobContext(
                megaRemotePath: "/Cloud/VidDL/",
                gdriveRemoteName: "gdrive",
                gdriveRemotePath: "VidDL/"
            ).retryContext,
            gdriveMegaRemotePath: nil
        )
    }
}
