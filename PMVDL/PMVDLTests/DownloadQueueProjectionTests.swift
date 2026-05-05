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

    func testRetryPayloadRoundTripsResolutionTargetAndNonSecretContext() throws {
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

        let decoded = try JSONDecoder().decode(DownloadRetryPayload.self, from: encoded)
        XCTAssertEqual(decoded.resolution.title, "Retry Fixture")
        XCTAssertEqual(decoded.resolution.mediaKind, .hls)
        XCTAssertEqual(decoded.resolution.headers?["Referer"], "https://example.test/watch")
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
}
