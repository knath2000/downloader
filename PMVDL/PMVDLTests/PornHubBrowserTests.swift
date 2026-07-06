import XCTest
@testable import VidDL

final class PornHubBrowserTests: XCTestCase {
    func testRentryAndEpornerAreBrowserBackedSites() throws {
        XCTAssertEqual(try XCTUnwrap(FeedBrowserSite(host: RentryFeedScraper.supportedHost)).host, RentryFeedScraper.supportedHost)
        XCTAssertEqual(try XCTUnwrap(FeedBrowserSite(host: EpornerFeedScraper.supportedHost)).host, EpornerFeedScraper.supportedHost)
    }

    @MainActor
    func testEpornerBrowserHomeFollowsSectionAndUploader() throws {
        let model = FeedViewModel()
        let browser = PornHubBrowserViewModel()
        browser.configure(site: .eporner)
        model.selectedEpornerSection = .liked
        XCTAssertEqual(browser.homeURL(feedModel: model)?.absoluteString, "https://www.eporner.com/my-likes/")

        model.epornerUploaderURL = "https://www.eporner.com/profile/fixture/"
        XCTAssertEqual(browser.homeURL(feedModel: model)?.absoluteString, "https://www.eporner.com/profile/fixture/videos")
    }

    @MainActor
    func testRentryBrowserHomeUsesConfiguredPage() {
        let model = FeedViewModel()
        let browser = PornHubBrowserViewModel()
        browser.configure(site: .rentry)
        XCTAssertEqual(browser.homeURL(feedModel: model)?.absoluteString, "https://rentry.co/OnlyFan420")
    }

    func testPornHubViewkeyNormalization() {
        XCTAssertEqual(
            PornHubBrowserFeedMapper.pornHubViewkey(from: "https://www.pornhub.com/view_video.php?viewkey=ABC123"),
            "abc123"
        )
        XCTAssertNil(PornHubBrowserFeedMapper.pornHubViewkey(from: "https://example.com/view_video.php?viewkey=ABC123"))
    }

    func testDetectedItemsMapToStableFeedItems() {
        let items = PornHubBrowserFeedMapper.items(from: [
            [
                "url": "https://www.pornhub.com/view_video.php?viewkey=ABC123",
                "title": "First",
                "thumbnailURL": "https://thumb.test/one.jpg",
                "previewVideoURL": "https://preview.test/one.mp4",
                "uploaderName": "Uploader",
                "uploaderURL": "https://www.pornhub.com/model/uploader",
                "duration": "12:34"
            ],
            [
                "url": "https://www.pornhub.com/view_video.php?viewkey=ABC123",
                "title": "Duplicate"
            ],
            [
                "url": "https://example.com/view_video.php?viewkey=ZZZ"
            ]
        ])

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "pornhub-browser-abc123")
        XCTAssertEqual(items.first?.title, "First")
        XCTAssertEqual(items.first?.durationSeconds, 754)
        XCTAssertEqual(items.first?.studio, "Uploader")
    }

    func testDetectedHQPornerItemsMapToStableFeedItems() {
        let items = PornHubBrowserFeedMapper.items(from: [
            [
                "url": "https://hqporner.com/hdporn/12345-example-video/",
                "title": "HQ Video",
                "thumbnailURL": "https://img.test/hq.jpg",
                "duration": "12:34"
            ],
            [
                "url": "https://hqporner.com/hdporn/12345-example-video/",
                "title": "Duplicate"
            ],
            [
                "url": "https://example.com/hdporn/999-bad/"
            ]
        ], site: .hqPorner)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "hqporner-browser-12345")
        XCTAssertEqual(items.first?.siteName, HQPornerFeedScraper.supportedHost)
        XCTAssertEqual(items.first?.durationSeconds, 754)
    }

    func testDetectedAllPornStreamItemsMapToStableFeedItems() {
        let items = PornHubBrowserFeedMapper.items(from: [
            [
                "url": "https://allpornstream.com/post/abc123/example-video",
                "title": "APS Video",
                "thumbnailURL": "https://img.test/aps.jpg"
            ],
            [
                "url": "https://allpornstream.com/post/abc123/example-video",
                "title": "Duplicate"
            ],
            [
                "url": "https://example.com/post/bad/example"
            ]
        ], site: .allPornStream)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "allpornstream-browser-abc123")
        XCTAssertEqual(items.first?.siteName, AllPornStreamFeedScraper.supportedHost)
    }

    func testDetectedEpornerItemsMapToStableFeedItems() {
        let items = PornHubBrowserFeedMapper.items(from: [
            [
                "url": "https://www.eporner.com/video-abc123/example-video/",
                "title": "EP Video",
                "thumbnailURL": "https://img.test/ep.jpg"
            ],
            [
                "url": "https://www.eporner.com/video-abc123/example-video/",
                "title": "Duplicate"
            ],
            [
                "url": "https://example.com/video-abc123/bad/"
            ]
        ], site: .eporner)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "eporner-browser-abc123")
        XCTAssertEqual(items.first?.siteName, EpornerFeedScraper.supportedHost)
    }

    func testDetectedRentryProviderItemsMapToStableFeedItems() {
        let items = PornHubBrowserFeedMapper.items(from: [
            [
                "url": "https://lulustream.com/e/abc123",
                "title": "Provider Video",
                "thumbnailURL": "https://img.test/provider.jpg"
            ],
            [
                "url": "https://lulustream.com/e/abc123",
                "title": "Duplicate"
            ],
            [
                "url": "https://rentry.co/OnlyFan420"
            ]
        ], site: .rentry)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "rentry-browser-lulustream.com:abc123")
        XCTAssertEqual(items.first?.siteName, RentryFeedScraper.supportedHost)
    }

    func testContextResolverPrefersAllPornStreamCardHrefOverCurrentPage() throws {
        let currentURL = try XCTUnwrap(URL(string: "https://allpornstream.com/"))
        let target = FeedBrowserContextResolver.resolvedURL(
            anchorHref: nil,
            cardDataHref: "/post/d3c68614-e741-4a28-81dc-ff0b7afb0a73/glowing-desire-mia-james-soaking-it-up-07-02-2026",
            descendantHref: nil,
            currentURL: currentURL
        )

        XCTAssertEqual(
            target.absoluteString,
            "https://allpornstream.com/post/d3c68614-e741-4a28-81dc-ff0b7afb0a73/glowing-desire-mia-james-soaking-it-up-07-02-2026"
        )
    }

    func testContextResolverPrefersAllPornStreamTitleLinkOverCardHref() throws {
        let currentURL = try XCTUnwrap(URL(string: "https://allpornstream.com/"))
        let target = FeedBrowserContextResolver.resolvedURL(
            anchorHref: "/post/d3c68614-e741-4a28-81dc-ff0b7afb0a73/glowing-desire-mia-james-soaking-it-up-07-02-2026",
            cardDataHref: "/post/other/other-video",
            descendantHref: nil,
            currentURL: currentURL
        )

        XCTAssertEqual(
            target.absoluteString,
            "https://allpornstream.com/post/d3c68614-e741-4a28-81dc-ff0b7afb0a73/glowing-desire-mia-james-soaking-it-up-07-02-2026"
        )
    }

    func testContextResolverFallsBackToCurrentPageWhenNoVideoURLExistsNearby() throws {
        let currentURL = try XCTUnwrap(URL(string: "https://allpornstream.com/"))
        let target = FeedBrowserContextResolver.resolvedURL(
            anchorHref: "/models/mia-james",
            cardDataHref: nil,
            descendantHref: "/categories/latest",
            currentURL: currentURL
        )

        XCTAssertEqual(target, currentURL)
    }

    func testContextResolverRecognizesEpornerVideoLinks() throws {
        let currentURL = try XCTUnwrap(URL(string: "https://www.eporner.com/"))
        let target = FeedBrowserContextResolver.resolvedURL(
            anchorHref: "/video-abc123/example-video/",
            cardDataHref: nil,
            descendantHref: nil,
            currentURL: currentURL
        )

        XCTAssertEqual(target.absoluteString, "https://www.eporner.com/video-abc123/example-video/")
    }

    func testContextResolverRecognizesRentryProviderLinks() throws {
        let currentURL = try XCTUnwrap(URL(string: "https://rentry.co/OnlyFan420"))
        let target = FeedBrowserContextResolver.resolvedURL(
            anchorHref: "https://vidara.so/d/abc123",
            cardDataHref: nil,
            descendantHref: nil,
            currentURL: currentURL
        )

        XCTAssertEqual(target.absoluteString, "https://vidara.so/d/abc123")
    }
}
