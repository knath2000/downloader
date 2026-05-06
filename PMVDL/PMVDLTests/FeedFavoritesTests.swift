import XCTest
@testable import VidDL

final class FeedFavoritesTests: XCTestCase {
    func testFavoriteItemUsesNormalizedURLAsStableID() {
        let item = FeedItem(
            id: "source-id",
            title: "Example",
            url: " https://example.test/video ",
            thumbnailURL: "https://example.test/thumb.jpg",
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
}
