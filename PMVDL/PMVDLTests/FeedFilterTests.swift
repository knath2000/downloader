import XCTest
@testable import VidDL

final class FeedFilterTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    func testFeedItemDefaultsOptionalMetadata() {
        let item = FeedItem(
            id: "one",
            title: "Fixture",
            url: "https://example.test/video",
            thumbnailURL: nil,
            uploadDate: Date(timeIntervalSince1970: 0),
            viewCount: 0,
            siteName: "example.test",
            studio: nil
        )

        XCTAssertNil(item.durationSeconds)
        XCTAssertEqual(item.categories, [])
        XCTAssertEqual(item.tags, [])
        XCTAssertEqual(item.performers, [])
        XCTAssertEqual(item.qualityLabels, [])
        XCTAssertEqual(item.sourceKind, .siteFeed)
    }

    func testFilterQueryMatchesMetadataAndCombinesGroups() {
        let item = feedItem(
            title: "Studio Feature",
            viewCount: 15_000,
            duration: 1_200,
            studio: "Brazzers",
            categories: ["Featured"],
            tags: ["redhead", "outdoor"],
            performers: ["Jane"],
            quality: ["1080p"]
        )

        var filters = FeedFilterState()
        filters.date = .all
        filters.query = "jane"
        filters.minViews = 10_000
        filters.minDurationSeconds = 600
        filters.maxDurationSeconds = 1_800
        filters.selectedStudios = ["Brazzers"]
        filters.selectedCategories = ["Featured"]
        filters.selectedQualityLabels = ["1080p"]
        filters.selectedTags = ["redhead"]

        XCTAssertTrue(filters.matches(item, calendar: calendar, now: Date()))

        filters.selectedQualityLabels = ["4K"]
        XCTAssertFalse(filters.matches(item, calendar: calendar, now: Date()))
    }

    func testTagAnyAndAllModes() {
        let item = feedItem(tags: ["one", "two"])
        var filters = FeedFilterState()
        filters.date = .all
        filters.selectedTags = ["one", "missing"]
        filters.requireAllTags = false
        XCTAssertTrue(filters.matches(item, calendar: calendar, now: Date()))

        filters.requireAllTags = true
        XCTAssertFalse(filters.matches(item, calendar: calendar, now: Date()))

        filters.selectedTags = ["one", "two"]
        XCTAssertTrue(filters.matches(item, calendar: calendar, now: Date()))
    }

    func testDateFiltersUseCalendarWindows() throws {
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 12)))
        let day3 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 3, hour: 12)))
        let day2 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 2, hour: 12)))
        let day7 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 29, hour: 12)))
        let day8 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 28, hour: 12)))

        XCTAssertTrue(FeedDateFilter.last3Days.matches(day3, calendar: calendar, now: now))
        XCTAssertFalse(FeedDateFilter.last3Days.matches(day2, calendar: calendar, now: now))
        XCTAssertTrue(FeedDateFilter.last7Days.matches(day7, calendar: calendar, now: now))
        XCTAssertFalse(FeedDateFilter.last7Days.matches(day8, calendar: calendar, now: now))
        XCTAssertTrue(FeedDateFilter.thisMonth.matches(day3, calendar: calendar, now: now))
        XCTAssertFalse(FeedDateFilter.thisMonth.matches(day7, calendar: calendar, now: now))
    }

    func testSortModesPlaceNilDurationsLast() {
        let short = feedItem(title: "Short", duration: 60)
        let long = feedItem(title: "Long", duration: 600)
        let unknown = feedItem(title: "Unknown", duration: nil)

        XCTAssertEqual(FeedSortMode.shortest.sort([unknown, long, short]).map(\.title), ["Short", "Long", "Unknown"])
        XCTAssertEqual(FeedSortMode.longest.sort([unknown, short, long]).map(\.title), ["Long", "Short", "Unknown"])
    }

    func testActiveFilterChipsAndRemoval() {
        var filters = FeedFilterState()
        filters.date = .last7Days
        filters.query = "miami"
        filters.minViews = 1_000
        filters.selectedQualityLabels = ["1080p"]
        filters.selectedTags = ["outdoor"]
        filters.requireAllTags = true

        XCTAssertEqual(
            filters.activeChips.map(\.id),
            ["date", "query", "views", "quality:1080p", "tag:outdoor"]
        )

        filters.removeActiveChip(id: "tag:outdoor")
        XCTAssertTrue(filters.selectedTags.isEmpty)
        XCTAssertFalse(filters.requireAllTags)

        filters.removeActiveChip(id: "query")
        XCTAssertEqual(filters.query, "")
    }

    func testFeedGridLayoutUsesWiderCardsOnLargeScreens() {
        XCTAssertEqual(FeedGridLayout(availableWidth: 900).columnMinWidth, 260)
        XCTAssertEqual(FeedGridLayout(availableWidth: 1500).columnMinWidth, 305)
        XCTAssertEqual(FeedGridLayout(availableWidth: 1900).columnMinWidth, 320)
        XCTAssertEqual(FeedGridLayout(availableWidth: 900).spacing, 12)
        XCTAssertEqual(FeedGridLayout(availableWidth: 1200).spacing, 18)
    }

    private func feedItem(
        title: String = "Fixture",
        viewCount: Int = 0,
        duration: Int? = nil,
        studio: String? = nil,
        categories: [String] = [],
        tags: [String] = [],
        performers: [String] = [],
        quality: [String] = []
    ) -> FeedItem {
        FeedItem(
            id: UUID().uuidString,
            title: title,
            url: "https://example.test/\(UUID().uuidString)",
            thumbnailURL: nil,
            uploadDate: Date(),
            viewCount: viewCount,
            siteName: "example.test",
            studio: studio,
            durationSeconds: duration,
            categories: categories,
            tags: tags,
            performers: performers,
            qualityLabels: quality
        )
    }
}
