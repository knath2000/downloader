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

final class LibraryTimelineTests: XCTestCase {
    func testTimelineSortsEntriesNewestFirst() {
        let base = Date(timeIntervalSince1970: 1_000)
        let video = makeLibraryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            url: "https://example.test/video",
            title: "Saved Video",
            extractedAt: base.addingTimeInterval(10)
        )
        let link = HistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            url: "https://example.test/link",
            title: "Recent Link",
            provider: "Video Site",
            recordedAt: base.addingTimeInterval(20)
        )
        let upload = CompletedUploadItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            url: "https://example.test/upload",
            title: "Uploaded Video",
            provider: "Video Site",
            destination: "mega",
            remotePath: "/Cloud/VidDL/upload.mp4",
            completedAt: base.addingTimeInterval(30)
        )

        let entries = LibraryTimelineBuilder.entries(
            libraryItems: [video],
            historyItems: [link],
            completedUploads: [upload]
        )

        XCTAssertEqual(entries.map(\.id), [
            "upload-00000000-0000-0000-0000-000000000003",
            "link-00000000-0000-0000-0000-000000000002",
            "video-00000000-0000-0000-0000-000000000001"
        ])
    }

    func testTimelineSuppressesHistoryLinkWhenURLExistsInLibrary() {
        let saved = makeLibraryItem(url: "https://example.test/watch/1", title: "Saved")
        let duplicate = HistoryItem(
            url: " https://example.test/watch/1 ",
            title: "Duplicate Link",
            provider: "Video Site"
        )
        let other = HistoryItem(
            url: "https://example.test/watch/2",
            title: "Other Link",
            provider: "Video Site"
        )

        let entries = LibraryTimelineBuilder.entries(
            libraryItems: [saved],
            historyItems: [duplicate, other],
            completedUploads: []
        )

        let links = entries.compactMap { entry -> HistoryItem? in
            if case .link(let item) = entry { return item }
            return nil
        }
        XCTAssertEqual(links.map(\.url), ["https://example.test/watch/2"])
    }

    func testTimelineKeepsUploadWhenSourceExistsInLibrary() {
        let saved = makeLibraryItem(url: "https://example.test/watch/1", title: "Saved")
        let duplicate = HistoryItem(
            url: "https://example.test/watch/1",
            title: "Duplicate Link",
            provider: "Video Site"
        )
        let upload = CompletedUploadItem(
            url: "https://example.test/watch/1",
            title: "Uploaded Saved Video",
            provider: "Video Site",
            destination: "gdrive",
            remotePath: "gdrive:VidDL/saved.mp4"
        )

        let entries = LibraryTimelineBuilder.entries(
            libraryItems: [saved],
            historyItems: [duplicate],
            completedUploads: [upload]
        )

        XCTAssertTrue(entries.contains { if case .video = $0 { return true }; return false })
        XCTAssertTrue(entries.contains { if case .upload = $0 { return true }; return false })
        XCTAssertFalse(entries.contains { if case .link = $0 { return true }; return false })
    }

    func testTimelineFilteringSearchesAllEntryTypes() {
        let saved = makeLibraryItem(
            url: "https://videos.example.test/watch/1",
            title: "Saved Video",
            remotePaths: ["mega": "/Cloud/VidDL/saved.mp4"]
        )
        let link = HistoryItem(
            url: "https://links.example.test/watch/2",
            title: "Recent Link",
            provider: "LuluStream"
        )
        let upload = CompletedUploadItem(
            url: "https://uploads.example.test/watch/3",
            title: "Uploaded Video",
            provider: "Video Site",
            destination: "seedbox",
            remotePath: "/seedbox/complete/uploaded.mp4"
        )
        let entries = LibraryTimelineBuilder.entries(
            libraryItems: [saved],
            historyItems: [link],
            completedUploads: [upload]
        )

        XCTAssertEqual(
            LibraryTimelineBuilder.filteredEntries(entries, query: "lulustream", filter: .all).map(\.id),
            [LibraryTimelineEntry.link(link).id]
        )
        XCTAssertEqual(
            LibraryTimelineBuilder.filteredEntries(entries, query: "seedbox/complete", filter: .uploads).map(\.id),
            [LibraryTimelineEntry.upload(upload).id]
        )
        XCTAssertEqual(
            LibraryTimelineBuilder.filteredEntries(entries, query: "Cloud/VidDL", filter: .videos).map(\.id),
            [LibraryTimelineEntry.video(saved).id]
        )
        XCTAssertTrue(LibraryTimelineBuilder.filteredEntries(entries, query: "recent", filter: .videos).isEmpty)
    }

    func testSelectedEntryFallbackChoosesNewestVisibleEntryWhenCurrentDisappears() {
        let newest = HistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            url: "https://example.test/newest",
            title: "Newest",
            provider: "Video Site",
            recordedAt: Date(timeIntervalSince1970: 3_000)
        )
        let older = makeLibraryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            url: "https://example.test/older",
            title: "Older",
            extractedAt: Date(timeIntervalSince1970: 2_000)
        )
        let entries = LibraryTimelineBuilder.entries(
            libraryItems: [older],
            historyItems: [newest],
            completedUploads: []
        )

        XCTAssertEqual(
            LibraryTimelineBuilder.selectedEntryID(currentID: "missing-entry", in: entries),
            LibraryTimelineEntry.link(newest).id
        )
        XCTAssertEqual(
            LibraryTimelineBuilder.selectedEntry(currentID: LibraryTimelineEntry.video(older).id, in: entries)?.id,
            LibraryTimelineEntry.video(older).id
        )
    }

    func testBulkVideoSelectionIgnoresLinkAndUploadEntries() {
        let video = makeLibraryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
            url: "https://example.test/video",
            title: "Video"
        )
        let link = HistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
            url: "https://example.test/link",
            title: "Link",
            provider: "Video Site"
        )
        let upload = CompletedUploadItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000023")!,
            url: "https://example.test/upload",
            title: "Upload",
            provider: "Video Site",
            destination: "mega",
            remotePath: "/Cloud/VidDL/upload.mp4"
        )

        var selection = LibraryTimelineBuilder.videoSelection([], toggling: .link(link))
        selection = LibraryTimelineBuilder.videoSelection(selection, toggling: .upload(upload))
        XCTAssertTrue(selection.isEmpty)

        selection = LibraryTimelineBuilder.videoSelection(selection, toggling: .video(video))
        XCTAssertEqual(selection, Set([video.id]))

        selection = LibraryTimelineBuilder.videoSelection(selection, toggling: .video(video))
        XCTAssertTrue(selection.isEmpty)
    }

    private func makeLibraryItem(
        id: UUID = UUID(),
        url: String,
        title: String,
        extractedAt: Date = Date(timeIntervalSince1970: 1_000),
        remotePaths: [String: String] = [:]
    ) -> VidDL.LibraryItem {
        VidDL.LibraryItem(
            id: id,
            url: url,
            title: title,
            mp4Url: "https://cdn.example.test/video.mp4",
            hlsUrls: [],
            extractedAt: extractedAt,
            thumbnailURL: nil,
            remotePaths: remotePaths
        )
    }
}
