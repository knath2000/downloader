import XCTest
@testable import VidDL

final class FeedFavoritesTests: XCTestCase {
    func testFavoriteItemUsesNormalizedURLAsStableID() {
        let item = FeedItem(
            id: "source-id",
            title: "Example",
            url: " https://example.test/video ",
            thumbnailURL: "https://example.test/thumb.jpg",
            referer: "https://example.test/",
            uploadDate: Date(timeIntervalSince1970: 100),
            viewCount: 42,
            siteName: "Example",
            studio: "Studio",
            durationSeconds: 120,
            categories: ["Featured"],
            tags: ["tag"],
            performers: ["Performer"],
            qualityLabels: ["1080p"],
            sourceKind: .siteFeed
        )

        let favorite = FeedFavoriteItem(feedItem: item, favoritedAt: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(favorite.id, "https://example.test/video")
        XCTAssertEqual(favorite.url, "https://example.test/video")
        XCTAssertEqual(favorite.title, "Example")
        XCTAssertEqual(favorite.thumbnailURL, "https://example.test/thumb.jpg")
        XCTAssertEqual(favorite.referer, "https://example.test/")
        XCTAssertEqual(favorite.viewCount, 42)
        XCTAssertEqual(favorite.siteName, "Example")
        XCTAssertEqual(favorite.studio, "Studio")
        XCTAssertEqual(favorite.durationSeconds, 120)
        XCTAssertEqual(favorite.categories, ["Featured"])
        XCTAssertEqual(favorite.tags, ["tag"])
        XCTAssertEqual(favorite.performers, ["Performer"])
        XCTAssertEqual(favorite.qualityLabels, ["1080p"])
        XCTAssertEqual(favorite.sourceKind, "siteFeed")
    }

    func testSortedAndDedupedKeepsNewestFavoriteForURL() {
        let older = favorite(
            id: "https://example.test/a",
            title: "Older",
            favoritedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = favorite(
            id: "https://example.test/a",
            title: "Newer",
            favoritedAt: Date(timeIntervalSince1970: 200)
        )
        let other = favorite(
            id: "https://example.test/b",
            title: "Other",
            favoritedAt: Date(timeIntervalSince1970: 150)
        )

        let result = FeedFavoritesStore.sortedAndDeduped([older, other, newer])

        XCTAssertEqual(result.map(\.title), ["Newer", "Other"])
    }

    func testFavoritesDisplaySearchMatchesTitleSiteStudioAndTags() {
        let item = favorite(
            title: "Beach Scene",
            siteName: "HQPorner",
            studio: "Studio A",
            tags: ["outdoor", "sunny"]
        )

        XCTAssertEqual(
            FavoritesDisplay.filteredAndSorted(items: [item], query: "sunny", sortMode: .newestFavorited).map(\.id),
            [item.id]
        )

        XCTAssertTrue(
            FavoritesDisplay.filteredAndSorted(items: [item], query: "missing", sortMode: .newestFavorited).isEmpty
        )
    }

    func testFavoritesDisplaySortModes() {
        let older = favorite(
            id: "a",
            title: "Zeta",
            uploadDate: Date(timeIntervalSince1970: 300),
            favoritedAt: Date(timeIntervalSince1970: 100),
            viewCount: 10,
            siteName: "B"
        )

        let newer = favorite(
            id: "b",
            title: "Alpha",
            uploadDate: Date(timeIntervalSince1970: 100),
            favoritedAt: Date(timeIntervalSince1970: 200),
            viewCount: 99,
            siteName: "A"
        )

        XCTAssertEqual(FavoritesDisplay.sorted([older, newer], by: .newestFavorited).map(\.id), ["b", "a"])
        XCTAssertEqual(FavoritesDisplay.sorted([older, newer], by: .titleAZ).map(\.id), ["b", "a"])
        XCTAssertEqual(FavoritesDisplay.sorted([older, newer], by: .mostViewed).map(\.id), ["b", "a"])
        XCTAssertEqual(FavoritesDisplay.sorted([older, newer], by: .site).map(\.id), ["b", "a"])
    }

    func testFavoritesFilterMatchesOnlyFavoriteEntriesOrFavoritedVideos() {
        let favorite = favorite(id: "fav", title: "Favorited")
        let video = LibraryTimelineEntry.video(
            LibraryItem(
                url: "https://example.test/video",
                title: "Downloaded",
                mp4Url: "https://cdn.example.test/video.mp4",
                hlsUrls: [],
                extractedAt: Date(timeIntervalSince1970: 100)
            )
        )
        let favoriteEntry = LibraryTimelineEntry.favorite(favorite)

        XCTAssertTrue(LibraryTimelineFilter.favorites.matches(favoriteEntry))
        XCTAssertFalse(LibraryTimelineFilter.favorites.matches(video))
    }

    @MainActor
    func testLibraryFavoritesActionRoutesExtractionToHome() {
        let appState = AppStateManager.shared
        let originalDestination = appState.selectedDestination
        let originalURL = appState.pendingExtractURL
        let originalShouldStart = appState.pendingExtractShouldStart
        let item = favorite(id: "route", title: "Route Me", url: "https://example.test/route")

        defer {
            appState.selectedDestination = originalDestination
            appState.pendingExtractURL = originalURL
            appState.pendingExtractShouldStart = originalShouldStart
        }

        LibraryFavoritesActions.extract(item, appState: appState)

        XCTAssertEqual(appState.selectedDestination, .home)
        XCTAssertEqual(appState.pendingExtractURL, item.url)
        XCTAssertTrue(appState.pendingExtractShouldStart)
    }

    @MainActor
    func testFeedFavoritesStoreRemoveDeletesAddedFavorite() {
        let store = FeedFavoritesStore.shared
        let item = favorite(id: "remove-\(UUID().uuidString)", title: "Remove Me", url: "https://example.test/remove-\(UUID().uuidString)")

        store.remove(url: item.url)
        store.add(item)

        XCTAssertTrue(store.contains(url: item.url))

        store.remove(id: item.id)

        XCTAssertFalse(store.contains(url: item.url))
    }

    @MainActor
    func testPipelineStoreSearchTextIncludesFailureMessages() {
        let store = LibraryPipelineStore.shared
        store.rebuild(
            libraryItems: [],
            completedUploads: [],
            queueItems: [
                queueItem(
                    url: "https://example.test/video",
                    target: .gdrive,
                    status: .failed("Drive rejected upload")
                )
            ]
        )

        XCTAssertTrue(store.searchText(for: "https://example.test/video").contains("drive rejected upload"))
    }

    func testDownloadedFeedIndexMatchesPornHubViewkey() {
        let libraryID = UUID()
        let libraryItem = LibraryItem(
            id: libraryID,
            url: "https://www.pornhub.com/view_video.php?viewkey=ABC123&extra=1",
            title: "Downloaded PornHub Video",
            mp4Url: nil,
            hlsUrls: [],
            extractedAt: Date(timeIntervalSince1970: 100)
        )
        let feedItem = feedItem(
            url: "https://www.pornhub.com/view_video.php?foo=bar&viewkey=abc123",
            siteName: PornHubFeedScraper.supportedHost
        )

        let match = DownloadedFeedIndex(items: [libraryItem]).match(for: feedItem)

        XCTAssertEqual(match?.libraryID, libraryID)
        XCTAssertEqual(match?.title, "Downloaded PornHub Video")
    }

    func testDownloadedFeedIndexMatchesNonPornHubNormalizedURL() {
        let libraryID = UUID()
        let libraryItem = LibraryItem(
            id: libraryID,
            url: " HTTPS://Example.test/Video?a=1#ignored ",
            title: "Downloaded Example Video",
            mp4Url: nil,
            hlsUrls: [],
            extractedAt: Date(timeIntervalSince1970: 100)
        )
        let feedItem = feedItem(url: "https://example.test/Video?a=1", siteName: "example.test")

        let match = DownloadedFeedIndex(items: [libraryItem]).match(for: feedItem)

        XCTAssertEqual(match?.libraryID, libraryID)
    }

    private func favorite(
        id: String = UUID().uuidString,
        title: String = "Favorite",
        url: String? = nil,
        thumbnailURL: String? = nil,
        uploadDate: Date = Date(timeIntervalSince1970: 0),
        favoritedAt: Date = Date(timeIntervalSince1970: 0),
        viewCount: Int = 0,
        siteName: String = "Example",
        studio: String? = nil,
        durationSeconds: Int? = nil,
        categories: [String] = [],
        tags: [String] = [],
        performers: [String] = [],
        qualityLabels: [String] = []
    ) -> FeedFavoriteItem {
        FeedFavoriteItem(
            id: id,
            title: title,
            url: url ?? "https://example.test/\(id)",
            thumbnailURL: thumbnailURL,
            uploadDate: uploadDate,
            favoritedAt: favoritedAt,
            viewCount: viewCount,
            siteName: siteName,
            studio: studio,
            durationSeconds: durationSeconds,
            categories: categories,
            tags: tags,
            performers: performers,
            qualityLabels: qualityLabels,
            sourceKind: "siteFeed"
        )
    }

    private func feedItem(url: String, siteName: String) -> FeedItem {
        FeedItem(
            id: url,
            title: "Feed Fixture",
            url: url,
            thumbnailURL: nil,
            uploadDate: Date(timeIntervalSince1970: 0),
            viewCount: 0,
            siteName: siteName,
            studio: nil
        )
    }

    private func queueItem(url: String, target: CloudTarget, status: QueueStatus) -> DownloadQueueItem {
        var item = DownloadQueueItem(url: url, quality: "Video", targetCloud: target, displayTitle: "Fixture")
        item.status = status
        return item
    }
}
