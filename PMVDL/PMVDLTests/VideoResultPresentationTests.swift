import XCTest
@testable import VidDL

final class VideoResultPresentationTests: XCTestCase {
    private func makeResults() -> [ExtractResult] {
        [
            ExtractResult(
                url: "https://example.test/one",
                source: VideoSource(mp4: "https://cdn.example.test/one.mp4", hls: [], title: "One"),
                error: nil
            ),
            ExtractResult(
                url: "https://example.test/two",
                source: nil,
                error: "Failed two"
            ),
            ExtractResult(
                url: "https://example.test/three",
                source: nil,
                error: "Failed three"
            )
        ]
    }

    func testMP4SourceProducesMP4Choice() {
        let source = VideoSource(mp4: "https://cdn.example.test/video.mp4", hls: [], title: "Example")
        let presentation = VideoResultPresentation(result: ExtractResult(url: "https://example.test/watch", source: source, error: nil))

        XCTAssertEqual(presentation.title, "Example")
        XCTAssertEqual(presentation.qualities.count, 1)
        XCTAssertEqual(presentation.qualities.first?.label, "MP4")
        XCTAssertEqual(presentation.recommendedQualityID, "https://cdn.example.test/video.mp4")
    }

    func testHLSLabelsArePreserved() {
        let source = VideoSource(
            mp4: nil,
            hls: [
                VideoSource.Quality(label: "2160p", url: "https://cdn.example.test/2160.m3u8"),
                VideoSource.Quality(label: "1080p", url: "https://cdn.example.test/1080.m3u8")
            ],
            title: "Example",
            thumbnail: "https://cdn.example.test/thumb.jpg"
        )
        let presentation = VideoResultPresentation(result: ExtractResult(url: "https://example.test/watch", source: source, error: nil))

        XCTAssertEqual(presentation.thumbnailURL, "https://cdn.example.test/thumb.jpg")
        XCTAssertEqual(presentation.qualities.map(\.label), ["2160p", "1080p"])
    }

    func testUntitledSourceFallsBack() {
        let source = VideoSource(mp4: nil, hls: [], title: " ")
        let presentation = VideoResultPresentation(result: ExtractResult(url: "https://example.test/watch", source: source, error: nil))

        XCTAssertEqual(presentation.title, "Untitled Video")
        XCTAssertTrue(presentation.qualities.isEmpty)
    }

    func testErrorResultHasNoQualities() {
        let presentation = VideoResultPresentation(result: ExtractResult(url: "https://example.test/watch", source: nil, error: "failed"))

        XCTAssertEqual(presentation.title, "Untitled Video")
        XCTAssertTrue(presentation.qualities.isEmpty)
    }

    func testExtractionRetrySupportFindsFailedIndices() {
        XCTAssertEqual(ExtractionRetrySupport.failedIndices(in: makeResults()), [1, 2])
    }

    func testExtractionRetrySupportExcludesAlreadyRetryingIndices() {
        XCTAssertEqual(
            ExtractionRetrySupport.retryableFailedIndices(in: makeResults(), retryingIndices: [2]),
            [1]
        )
    }

    func testExtractionRetrySupportReplacesOnlyTargetIndex() {
        let results = makeResults()
        let replacement = ExtractResult(
            url: "https://example.test/two",
            source: VideoSource(mp4: "https://cdn.example.test/two.mp4", hls: [], title: "Two"),
            error: nil
        )

        let updated = ExtractionRetrySupport.replacingResult(at: 1, in: results, with: replacement)

        XCTAssertEqual(updated[0], results[0])
        XCTAssertEqual(updated[1], replacement)
        XCTAssertEqual(updated[2], results[2])
    }

    func testExtractionSlotsStartOnePendingRowPerURL() {
        let slots = ExtractionSlotSupport.startingSlots(for: [
            "https://example.test/one",
            "https://example.test/two"
        ])

        XCTAssertEqual(slots.count, 2)
        XCTAssertEqual(slots.map(\.url), ["https://example.test/one", "https://example.test/two"])
        XCTAssertTrue(slots.allSatisfy { $0.result == nil })
        XCTAssertNotEqual(slots[0].id, slots[1].id)
    }

    func testExtractionSlotsReplaceOnePendingRowAtATime() {
        let slots = ExtractionSlotSupport.startingSlots(for: [
            "https://example.test/one",
            "https://example.test/two"
        ])
        let first = ExtractResult(
            url: "https://example.test/one",
            source: VideoSource(mp4: "https://cdn.example.test/one.mp4", hls: [], title: "One"),
            error: nil
        )

        let updated = ExtractionSlotSupport.replacingSlot(id: slots[0].id, in: slots, with: first)

        XCTAssertEqual(updated[0].id, slots[0].id)
        XCTAssertEqual(updated[0].result, first)
        XCTAssertNil(updated[1].result)
        XCTAssertEqual(ExtractionSlotSupport.completedResults(in: updated), [first])
    }

    func testExtractionSlotsPreserveOrderAsRowsCompleteOutOfOrder() {
        let slots = ExtractionSlotSupport.startingSlots(for: [
            "https://example.test/one",
            "https://example.test/two"
        ])
        let first = ExtractResult(
            url: "https://example.test/one",
            source: VideoSource(mp4: "https://cdn.example.test/one.mp4", hls: [], title: "One"),
            error: nil
        )
        let second = ExtractResult(
            url: "https://example.test/two",
            source: nil,
            error: "Failed two"
        )

        let secondOnly = ExtractionSlotSupport.replacingSlot(id: slots[1].id, in: slots, with: second)
        let completed = ExtractionSlotSupport.replacingSlot(id: slots[0].id, in: secondOnly, with: first)

        XCTAssertEqual(ExtractionSlotSupport.completedResults(in: secondOnly), [second])
        XCTAssertEqual(ExtractionSlotSupport.completedResults(in: completed), [first, second])
        XCTAssertEqual(ExtractionSlotSupport.slotIDForCompletedResult(at: 1, in: completed), slots[1].id)
    }

    func testExtractionRevealDelayCascadesTopToBottomWithCap() {
        XCTAssertEqual(ExtractionRevealAnimationSupport.delay(forRowIndex: 0, reduceMotion: false), 0)
        XCTAssertEqual(ExtractionRevealAnimationSupport.delay(forRowIndex: 1, reduceMotion: false), 0.045, accuracy: 0.0001)
        XCTAssertEqual(ExtractionRevealAnimationSupport.delay(forRowIndex: 99, reduceMotion: false), ExtractionRevealAnimationSupport.maxDelay)
    }

    func testExtractionRevealDelayDisablesForReducedMotion() {
        XCTAssertEqual(ExtractionRevealAnimationSupport.delay(forRowIndex: 4, reduceMotion: true), 0)
    }

    func testVPNServiceParsingFromScutilOutput() {
        let output = """
        Available network connection services in the current set (*=enabled):
        * (Connected)      D419AB1B-01F2-46FE-9940-B1BC779D83EE VPN (io.nextdns.NextDNSMac) "NextDNS"                        [VPN:io.nextdns.NextDNSMac]
        * (Disconnected)   FEC1F266-2F9C-4D12-99F7-E5D124A1B46D VPN (com.anchorfree.hss-mac) "Hotspot Shield VPN (Hydra)"     [VPN:com.anchorfree.hss-mac]
        """

        let services = ExtractionVPNManager.parseServices(from: output)

        XCTAssertEqual(services.map(\.name), ["NextDNS", "Hotspot Shield VPN (Hydra)"])
        XCTAssertTrue(services[0].isConnected)
        XCTAssertFalse(services[1].isConnected)
    }

    func testVPNRetrySlotReplacementPreservesOrder() {
        let slots = ExtractionSlotSupport.startingSlots(for: [
            "https://example.test/one",
            "https://example.test/two"
        ])
        let failed = ExtractResult(url: "https://example.test/one", source: nil, error: "Timed out")
        let ready = ExtractResult(
            url: "https://example.test/two",
            source: VideoSource(mp4: "https://cdn.example.test/two.mp4", hls: [], title: "Two"),
            error: nil
        )
        let repaired = ExtractResult(
            url: "https://example.test/one",
            source: VideoSource(mp4: "https://cdn.example.test/one.mp4", hls: [], title: "One"),
            error: nil
        )

        let failedFirst = ExtractionSlotSupport.replacingSlot(id: slots[0].id, in: slots, with: failed)
        let both = ExtractionSlotSupport.replacingSlot(id: slots[1].id, in: failedFirst, with: ready)
        let retriedWithVPN = ExtractionSlotSupport.replacingSlot(id: slots[0].id, in: both, with: repaired)

        XCTAssertEqual(ExtractionSlotSupport.completedResults(in: retriedWithVPN), [repaired, ready])
    }
}
