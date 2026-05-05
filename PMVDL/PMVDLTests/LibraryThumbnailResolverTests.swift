import AppKit
import XCTest
@testable import VidDL

private final class ResolverCallCounter {
    var fetchCalled = false
}

final class HTMLThumbnailMetadataExtractorTests: XCTestCase {
    func testExtractsOpenGraphImage() {
        let html = #"<meta property="og:image" content="https://cdn.example.test/thumb.jpg">"#
        let pageURL = URL(string: "https://pmvhaven.com/video/example")!

        XCTAssertEqual(
            HTMLThumbnailMetadataExtractor.extractThumbnailURL(from: html, pageURL: pageURL),
            "https://cdn.example.test/thumb.jpg"
        )
    }

    func testGenericExtractorMatchesPMVHavenOpenGraphImage() {
        let html = #"<meta property="og:image" content="https://cdn.pmvhaven.com/thumbs/appetite.jpg">"#
        let pageURL = URL(string: "https://pmvhaven.com/video/appetite_69b359ef6f11592f7f502f61")!

        XCTAssertEqual(
            HTMLThumbnailMetadataExtractor.extractThumbnailURL(from: html, pageURL: pageURL),
            "https://cdn.pmvhaven.com/thumbs/appetite.jpg"
        )
    }

    func testExtractsTwitterImage() {
        let html = #"<meta name="twitter:image" content="https://cdn.example.test/twitter.jpg">"#
        let pageURL = URL(string: "https://example.test/watch/1")!

        XCTAssertEqual(
            HTMLThumbnailMetadataExtractor.extractThumbnailURL(from: html, pageURL: pageURL),
            "https://cdn.example.test/twitter.jpg"
        )
    }

    func testResolvesRelativeImageURLAgainstPageURL() {
        let html = #"<meta property="og:image" content="/assets/thumb.jpg">"#
        let pageURL = URL(string: "https://pmvhaven.com/video/appetite")!

        XCTAssertEqual(
            HTMLThumbnailMetadataExtractor.extractThumbnailURL(from: html, pageURL: pageURL),
            "https://pmvhaven.com/assets/thumb.jpg"
        )
    }

    func testExtractsLinkImageSrc() {
        let html = #"<link href="https://cdn.example.test/link.jpg" rel="image_src">"#
        let pageURL = URL(string: "https://example.test/watch/1")!

        XCTAssertEqual(
            HTMLThumbnailMetadataExtractor.extractThumbnailURL(from: html, pageURL: pageURL),
            "https://cdn.example.test/link.jpg"
        )
    }

    func testExtractsVideoPosterWhenMetaMissing() {
        let html = #"<video controls poster="https://cdn.example.test/poster.jpg"></video>"#
        let pageURL = URL(string: "https://example.test/watch/1")!

        XCTAssertEqual(
            HTMLThumbnailMetadataExtractor.extractThumbnailURL(from: html, pageURL: pageURL),
            "https://cdn.example.test/poster.jpg"
        )
    }

    func testExtractsJWPlayerImage() {
        let html = #"jwplayer("v").setup({ image: "https://cdn.example.test/jw.jpg" })"#
        let pageURL = URL(string: "https://example.test/watch/1")!

        XCTAssertEqual(
            HTMLThumbnailMetadataExtractor.extractThumbnailURL(from: html, pageURL: pageURL),
            "https://cdn.example.test/jw.jpg"
        )
    }

    func testExtractsJSONLDThumbnailURL() {
        let html = #"<script type="application/ld+json">{"thumbnailUrl":"https://cdn.example.test/jsonld.jpg"}</script>"#
        let pageURL = URL(string: "https://example.test/watch/1")!

        XCTAssertEqual(
            HTMLThumbnailMetadataExtractor.extractThumbnailURL(from: html, pageURL: pageURL),
            "https://cdn.example.test/jsonld.jpg"
        )
    }
}

final class LibraryThumbnailResolverTests: XCTestCase {
    func testResolverPrefersStoredThumbnailURL() async {
        let item = LibraryItem(
            url: "https://pmvhaven.com/video/appetite_abc",
            title: "Appetite",
            mp4Url: nil,
            hlsUrls: [],
            thumbnailURL: "https://cdn.example.test/stored.jpg"
        )

        let counter = ResolverCallCounter()
        let resolver = LibraryThumbnailResolver(
            fetchHTML: { _ in counter.fetchCalled = true; return "" },
            extractSource: { _ in throw VideoExtractorError.noVideoSources },
            downloadImage: { _, _, _ in NSImage(size: .init(width: 1, height: 1)) },
            generateFrame: { _ in NSImage(size: .init(width: 1, height: 1)) }
        )

        let result = await resolver.resolveThumbnailURL(for: item)

        XCTAssertEqual(result?.thumbnailURL, "https://cdn.example.test/stored.jpg")
        XCTAssertEqual(result?.source, .storedThumbnailURL)
        XCTAssertFalse(counter.fetchCalled)
    }

    func testResolverBackfillsFromPageMetadata() async {
        let item = LibraryItem(
            url: "https://pmvhaven.com/video/appetite_abc",
            title: "Appetite",
            mp4Url: nil,
            hlsUrls: [],
            thumbnailURL: nil
        )

        let resolver = LibraryThumbnailResolver(
            fetchHTML: { _ in #"<meta property="og:image" content="https://cdn.example.test/page.jpg">"# },
            extractSource: { _ in throw VideoExtractorError.noVideoSources },
            downloadImage: { _, _, _ in NSImage(size: .init(width: 1, height: 1)) },
            generateFrame: { _ in NSImage(size: .init(width: 1, height: 1)) }
        )

        let result = await resolver.resolveThumbnailURL(for: item)

        XCTAssertEqual(result?.thumbnailURL, "https://cdn.example.test/page.jpg")
        XCTAssertEqual(result?.source, .pageMetadata)
    }

    func testResolverFallsBackToScraperThumbnail() async {
        let item = LibraryItem(
            url: "https://example.test/watch/123",
            title: "Example",
            mp4Url: nil,
            hlsUrls: [],
            thumbnailURL: nil
        )

        let resolver = LibraryThumbnailResolver(
            fetchHTML: { _ in "<html></html>" },
            extractSource: { _ in
                VideoSource(
                    mp4: nil,
                    hls: [],
                    title: "Example",
                    thumbnail: "https://cdn.example.test/scraper.jpg"
                )
            },
            downloadImage: { _, _, _ in NSImage(size: .init(width: 1, height: 1)) },
            generateFrame: { _ in NSImage(size: .init(width: 1, height: 1)) }
        )

        let result = await resolver.resolveThumbnailURL(for: item)

        XCTAssertEqual(result?.thumbnailURL, "https://cdn.example.test/scraper.jpg")
        XCTAssertEqual(result?.source, .scraperMetadata)
    }

    func testResolverDoesNotTreatMP4OrHLSAsPageURL() {
        XCTAssertFalse(LibraryThumbnailResolver.isLikelyPageURL("https://cdn.example.test/video.mp4"))
        XCTAssertFalse(LibraryThumbnailResolver.isLikelyPageURL("https://cdn.example.test/master.m3u8"))
        XCTAssertTrue(LibraryThumbnailResolver.isLikelyPageURL("https://pmvhaven.com/video/appetite_abc"))
    }

    func testMediaFallbackNeverUsesPageURL() {
        let item = LibraryItem(
            url: "https://pmvhaven.com/video/appetite_abc",
            title: "Appetite",
            mp4Url: nil,
            hlsUrls: [VideoSource.Quality(label: "Page", url: "https://example.test/player", kind: .pageUrl)],
            thumbnailURL: nil
        )

        XCTAssertNil(LibraryThumbnailResolver.mediaFallbackURL(for: item))
    }

    func testAddIfNewMergePreservesNewThumbnailForExistingURL() {
        let existing = LibraryItem(
            id: UUID(),
            url: "https://pmvhaven.com/video/appetite",
            title: "Appetite",
            mp4Url: nil,
            hlsUrls: [],
            thumbnailURL: nil
        )
        let incoming = LibraryItem(
            id: UUID(),
            url: "https://pmvhaven.com/video/appetite",
            title: "Appetite",
            mp4Url: nil,
            hlsUrls: [],
            thumbnailURL: "https://cdn.example.test/appetite.jpg"
        )

        let merged = VideoLibrary.mergedLibraryItems(existing: [existing], incoming: incoming)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, existing.id)
        XCTAssertEqual(merged[0].thumbnailURL, "https://cdn.example.test/appetite.jpg")
    }
}
