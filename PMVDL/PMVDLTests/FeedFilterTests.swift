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
        filters.selectedTags = ["one", "missing"]
        filters.requireAllTags = false
        XCTAssertTrue(filters.matches(item, calendar: calendar, now: Date()))

        filters.requireAllTags = true
        XCTAssertFalse(filters.matches(item, calendar: calendar, now: Date()))

        filters.selectedTags = ["one", "two"]
        XCTAssertTrue(filters.matches(item, calendar: calendar, now: Date()))
    }

    func testDefaultFilterShowsLoadedItemsAcrossDates() throws {
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 6, hour: 12)))
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 20)))
        let olderItem = feedItem(uploadDate: yesterday)
        let filters = FeedFilterState()

        XCTAssertEqual(filters.date, .all)
        XCTAssertTrue(filters.isDefault)
        XCTAssertTrue(filters.matches(olderItem, calendar: calendar, now: now))
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

    func testFeedOrderSortPreservesIncomingOrder() {
        let old = feedItem(title: "Old", uploadDate: Date(timeIntervalSince1970: 100))
        let new = feedItem(title: "New", uploadDate: Date(timeIntervalSince1970: 300))
        let middle = feedItem(title: "Middle", uploadDate: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(FeedSortMode.feedOrder.sort([old, new, middle]).map(\.title), ["Old", "New", "Middle"])
        XCTAssertEqual(FeedSortMode.newest.sort([old, new, middle]).map(\.title), ["New", "Middle", "Old"])
    }

    func testPornHubPersonalFeedDoesNotExhaustPaginationOnDateMiss() {
        var filters = FeedFilterState()
        filters.date = .today
        let oldItem = feedItem(uploadDate: Date(timeIntervalSince1970: 100))

        XCTAssertFalse(FeedViewModel.shouldStopPaginationForDateMiss(
            selectedSite: PornHubFeedScraper.supportedHost,
            selectedPornHubSection: .liked,
            pornHubUploaderURL: nil,
            selectedEpornerSection: .recommended,
            epornerUploaderURL: nil,
            filters: filters,
            pageItems: [oldItem]
        ))

        XCTAssertTrue(FeedViewModel.shouldStopPaginationForDateMiss(
            selectedSite: HQPornerFeedScraper.supportedHost,
            selectedPornHubSection: .recommended,
            pornHubUploaderURL: nil,
            selectedEpornerSection: .recommended,
            epornerUploaderURL: nil,
            filters: filters,
            pageItems: [oldItem]
        ))
    }

    func testPornHubUploaderLoadBypassesStaleLoginRequiredSection() {
        XCTAssertFalse(FeedViewModel.shouldBlockPornHubLoadForLogin(
            selectedSite: PornHubFeedScraper.supportedHost,
            selectedPornHubSection: .subscriptions,
            pornHubUploaderURL: "https://www.pornhub.com/model/fixture",
            isLoggedIn: false
        ))

        XCTAssertTrue(FeedViewModel.shouldBlockPornHubLoadForLogin(
            selectedSite: PornHubFeedScraper.supportedHost,
            selectedPornHubSection: .subscriptions,
            pornHubUploaderURL: nil,
            isLoggedIn: false
        ))
    }

    @MainActor
    func testPornHubUploaderBackRestoresPreviousFeedState() {
        let model = FeedViewModel()
        let first = feedItem(id: "liked-1", title: "Liked 1", siteName: PornHubFeedScraper.supportedHost)
        let second = feedItem(id: "liked-2", title: "Liked 2", siteName: PornHubFeedScraper.supportedHost)

        model.selectedSite = PornHubFeedScraper.supportedHost
        model.selectedPornHubSection = .liked
        model.sortMode = .feedOrder
        model.items = [first, second]
        model.currentPage = 4
        model.hasMore = true
        model.recordVisibleFeedAnchor(second.id)
        model.capturePornHubReturnStateIfNeeded()

        model.pornHubUploaderURL = "https://www.pornhub.com/model/fixture"
        model.pornHubUploaderName = "Fixture"
        model.items = [feedItem(id: "uploader-1", title: "Uploader", siteName: PornHubFeedScraper.supportedHost)]
        model.currentPage = 1
        model.hasMore = false

        XCTAssertTrue(model.restorePornHubReturnState())
        XCTAssertNil(model.pornHubUploaderURL)
        XCTAssertNil(model.pornHubUploaderName)
        XCTAssertEqual(model.selectedPornHubSection, .liked)
        XCTAssertEqual(model.sortMode, .feedOrder)
        XCTAssertEqual(model.items.map(\.id), ["liked-1", "liked-2"])
        XCTAssertEqual(model.currentPage, 4)
        XCTAssertTrue(model.hasMore)
        XCTAssertEqual(model.pendingScrollRestoreID, second.id)
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

        filters.removeActiveChip(id: "date")
        XCTAssertEqual(filters.date, .all)
    }

    func testFeedSelectionStorePreservesItemsAcrossSites() {
        let rentry = feedItem(id: "rentry", title: "Rentry", siteName: RentryFeedScraper.supportedHost)
        let eporner = feedItem(id: "eporner", title: "Eporner", siteName: EpornerFeedScraper.supportedHost)

        var selected: [String: FeedItem] = [:]
        selected = FeedSelectionStore.toggled(rentry, in: selected)
        selected = FeedSelectionStore.toggled(eporner, in: selected)

        XCTAssertEqual(Set(selected.values.map(\.siteName)), [RentryFeedScraper.supportedHost, EpornerFeedScraper.supportedHost])
        XCTAssertEqual(Set(selected.values.map(\.url)), [rentry.url, eporner.url])
    }

    func testFeedSelectionStoreSelectAllVisibleAddsWithoutClearingPriorSelection() {
        let prior = feedItem(id: "prior", title: "Prior", siteName: PornHubFeedScraper.supportedHost)
        let visibleOne = feedItem(id: "visible-1", title: "Visible 1", siteName: HQPornerFeedScraper.supportedHost)
        let visibleTwo = feedItem(id: "visible-2", title: "Visible 2", siteName: HQPornerFeedScraper.supportedHost)

        var selected: [String: FeedItem] = [:]
        selected = FeedSelectionStore.toggled(prior, in: selected)
        selected = FeedSelectionStore.adding([visibleOne, visibleTwo], to: selected)

        XCTAssertEqual(Set(selected.values.map(\.url)), [prior.url, visibleOne.url, visibleTwo.url])
    }

    func testViewportPrefetchTriggerIDsUsesTrailingVisibleWindow() {
        XCTAssertEqual(
            FeedViewModel.viewportPrefetchTriggerIDs(for: ["1", "2", "3", "4", "5"], threshold: 2),
            ["4", "5"]
        )

        XCTAssertEqual(
            FeedViewModel.viewportPrefetchTriggerIDs(for: ["1", "2", "3"], threshold: 10),
            ["3"]
        )

        XCTAssertEqual(
            FeedViewModel.viewportPrefetchTriggerIDs(for: [], threshold: 4),
            []
        )
    }

    @MainActor
    func testFeedViewModelDerivedStateUpdatesWhenItemsFiltersAndSortChange() {
        let model = FeedViewModel()
        let old = feedItem(
            id: "old",
            title: "Old Feature",
            uploadDate: Date(timeIntervalSince1970: 100),
            studio: "Studio B",
            categories: ["Action"],
            tags: ["outdoor"],
            quality: ["720p"]
        )
        let new = feedItem(
            id: "new",
            title: "New Feature",
            uploadDate: Date(timeIntervalSince1970: 300),
            studio: "Studio A",
            categories: ["Drama"],
            tags: ["studio"],
            quality: ["1080p"]
        )

        model.items = [old, new]

        XCTAssertEqual(model.filteredItems.map(\.id), ["new", "old"])
        XCTAssertEqual(model.dayBuckets.flatMap(\.items).map(\.id), ["new", "old"])
        XCTAssertEqual(model.availableStudios, ["Studio A", "Studio B"])
        XCTAssertEqual(model.availableCategories, ["Action", "Drama"])
        XCTAssertEqual(model.availableQualityLabels, ["1080p", "720p"])

        model.sortMode = .feedOrder
        XCTAssertEqual(model.filteredItems.map(\.id), ["old", "new"])

        model.filters.query = "New"
        XCTAssertEqual(model.filteredItems.map(\.id), ["new"])
    }

    func testPornHubSubscriptionParserExtractsUniqueUploaderLinks() {
        let html = """
        <div>
          <a href="/user/discover">Discover</a>
          <a href="/user/search">Search</a>
          <a href="/user/edit">Edit</a>
          <a href="/user/logout">Logout</a>
          <a href="/model/avatar-only"><img alt="Model Avatar"></a>
          <a href="/channels/fixture-channel"><img alt="Channel Avatar"></a>
          <a href="/model/fixture-model/videos"><img alt="Model Avatar"></a>
          <a href="/model/fixture-model" title="Fixture Model">Videos</a>
          <a href="/channels/fixture-channel">Fixture Channel</a>
          <a href="/model/fixture-model">Duplicate</a>
          <a href="/user/plain-user?from=feed">Plain User</a>
        </div>
        """

        let subscriptions = PornHubFeedScraper.parseSubscriptions(from: html)

        XCTAssertEqual(subscriptions.map(\.name), ["Fixture Model", "Fixture Channel", "Plain User"])
        XCTAssertEqual(subscriptions.map(\.url), [
            "https://www.pornhub.com/model/fixture-model",
            "https://www.pornhub.com/channels/fixture-channel",
            "https://www.pornhub.com/user/plain-user"
        ])
    }

    private func feedItem(
        id: String = UUID().uuidString,
        title: String = "Fixture",
        uploadDate: Date = Date(),
        viewCount: Int = 0,
        duration: Int? = nil,
        siteName: String = "example.test",
        studio: String? = nil,
        categories: [String] = [],
        tags: [String] = [],
        performers: [String] = [],
        quality: [String] = []
    ) -> FeedItem {
        FeedItem(
            id: id,
            title: title,
            url: "https://example.test/\(id)",
            thumbnailURL: nil,
            uploadDate: uploadDate,
            viewCount: viewCount,
            siteName: siteName,
            studio: studio,
            durationSeconds: duration,
            categories: categories,
            tags: tags,
            performers: performers,
            qualityLabels: quality
        )
    }
}
