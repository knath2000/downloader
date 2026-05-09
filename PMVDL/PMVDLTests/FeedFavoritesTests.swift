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

    func testProfileStatsPromotesHighCountIgnoredLibraryUploader() throws {
        let input = profileInput(uploaderSignals: [
            ProfileEvidenceSignal(
                name: "niquuiok",
                count: 19,
                sources: [ProfileSourceCount(source: "Download History", count: 19)],
                sampleTitles: ["Fixture"],
                sampleURLs: ["https://example.test/video"],
                signalKind: "libraryUploader"
            )
        ])
        let response = try profileResponse("""
        {
          "narrativeMarkdown": "Profile",
          "topPerformers": [],
          "topCategories": [],
          "topTags": [],
          "topStudios": [],
          "preferredQuality": [],
          "ignoredSignals": [
            {
              "name": "niquuiok",
              "count": 19,
              "sources": [{"source": "Download History", "count": 19}],
              "reason": "Uploader account, not enough title evidence."
            }
          ]
        }
        """)

        let stats = response.stats(derivedFrom: input)

        XCTAssertEqual(stats.topPerformers.map(\.name), ["niquuiok"])
        XCTAssertEqual(stats.topPerformers.first?.count, 19)
        XCTAssertEqual(stats.topPerformers.first?.sources, [ProfileSourceCount(source: "Download History", count: 19)])
        XCTAssertEqual(stats.ignoredSignals.map(\.name), ["niquuiok"])
    }

    func testProfileStatsKeepsLowCountIgnoredUploaderOutOfPerformers() throws {
        let input = profileInput(uploaderSignals: [
            ProfileEvidenceSignal(
                name: "Michell Bunny7",
                count: 2,
                sources: [ProfileSourceCount(source: "Download History", count: 2)],
                sampleTitles: ["Fixture"],
                sampleURLs: ["https://example.test/video"],
                signalKind: "libraryUploader"
            )
        ])
        let response = try profileResponse("""
        {
          "narrativeMarkdown": "Profile",
          "topPerformers": [],
          "topCategories": [],
          "topTags": [],
          "topStudios": [],
          "preferredQuality": [],
          "ignoredSignals": [
            {
              "name": "Michell Bunny7",
              "count": 2,
              "sources": [{"source": "Download History", "count": 2}],
              "reason": "Uploader account, not enough evidence for performer or studio."
            }
          ]
        }
        """)

        let stats = response.stats(derivedFrom: input)

        XCTAssertTrue(stats.topPerformers.isEmpty)
        XCTAssertTrue(stats.topStudios.isEmpty)
        XCTAssertEqual(stats.ignoredSignals.first?.name, "Michell Bunny7")
        XCTAssertEqual(stats.ignoredSignals.first?.count, 2)
    }

    func testProfileStatsDoesNotDuplicateHighCountLibraryUploaderClassifiedAsStudio() throws {
        let input = profileInput(uploaderSignals: [
            ProfileEvidenceSignal(
                name: "Studio Handle",
                count: 12,
                sources: [ProfileSourceCount(source: "Download History", count: 12)],
                sampleTitles: ["Fixture"],
                sampleURLs: ["https://example.test/video"],
                signalKind: "libraryUploader"
            )
        ])
        let response = try profileResponse("""
        {
          "narrativeMarkdown": "Profile",
          "topPerformers": [],
          "topCategories": [],
          "topTags": [],
          "topStudios": [
            {"name": "Studio Handle", "count": 12, "sources": [{"source": "Download History", "count": 12}]}
          ],
          "preferredQuality": [],
          "ignoredSignals": []
        }
        """)

        let stats = response.stats(derivedFrom: input)

        XCTAssertTrue(stats.topPerformers.isEmpty)
        XCTAssertEqual(stats.topStudios.map(\.name), ["Studio Handle"])
    }

    func testProfileStatsExcludesSourceSitesFromRankings() throws {
        let response = try profileResponse("""
        {
          "narrativeMarkdown": "Profile",
          "topPerformers": [{"name": "PornHub", "count": 9, "sources": [{"source": "Download History", "count": 9}]}],
          "topCategories": [],
          "topTags": [],
          "topStudios": [{"name": "www.pornhub.com", "count": 5, "sources": [{"source": "PornHub Liked", "count": 5}]}],
          "preferredQuality": [],
          "ignoredSignals": []
        }
        """)

        let stats = response.stats(derivedFrom: profileInput(uploaderSignals: []))

        XCTAssertTrue(stats.topPerformers.isEmpty)
        XCTAssertTrue(stats.topStudios.isEmpty)
    }

    func testOldProfileResultDecodesWithoutImageFields() throws {
        let json = """
        {
          "narrative": "Profile",
          "generatedAt": 0,
          "stats": {
            "topPerformers": [
              {"name": "Fixture Performer", "count": 3, "sources": [{"source": "Download History", "count": 3}]}
            ],
            "topCategories": [],
            "topTags": [],
            "topStudios": [],
            "preferredQuality": []
          }
        }
        """

        let result = try JSONDecoder().decode(ProfileResult.self, from: Data(json.utf8))

        XCTAssertEqual(result.narrative, "Profile")
        XCTAssertEqual(result.stats.topPerformers.first?.name, "Fixture Performer")
        XCTAssertNil(result.stats.topPerformers.first?.imageURL)
        XCTAssertNil(result.stats.topPerformers.first?.imageReferer)
        XCTAssertNil(result.stats.topPerformers.first?.imageSource)
        XCTAssertNil(result.stats.topPerformers.first?.profileURL)
        XCTAssertNil(result.stats.topPerformers.first?.profileReferer)
        XCTAssertNil(result.audit)
    }

    func testProfileImageEnrichmentPrefersProfileHeadshotOverEvidenceThumbnail() async {
        let evidence = profileEvidence(
            title: "Fixture Performer Scene",
            url: "https://www.pornhub.com/view_video.php?viewkey=headshot",
            uploaderName: "Fixture Performer",
            uploaderURL: "https://www.pornhub.com/model/fixture-performer",
            thumbnailURL: "https://cdn.example.test/evidence.jpg",
            thumbnailReferer: "https://www.pornhub.com/"
        )
        let stats = profileStats(performerName: "Fixture Performer")
        let enriched = await ProfileImageResolver.enrichedStats(
            stats,
            input: profileInput(items: [evidence], uploaderSignals: [
                profileSignal(name: "Fixture Performer", url: evidence.url)
            ])
        ) { pageURL, referer in
            XCTAssertEqual(pageURL, "https://www.pornhub.com/model/fixture-performer")
            XCTAssertEqual(referer, "https://www.pornhub.com/")
            return "https://cdn.example.test/headshot.jpg"
        }

        let performer = enriched.topPerformers.first
        XCTAssertEqual(performer?.imageURL, "https://cdn.example.test/headshot.jpg")
        XCTAssertEqual(performer?.imageReferer, "https://www.pornhub.com/model/fixture-performer")
        XCTAssertEqual(performer?.imageSource, "profile")
        XCTAssertEqual(performer?.profileURL, "https://www.pornhub.com/model/fixture-performer")
        XCTAssertEqual(performer?.profileReferer, "https://www.pornhub.com/")
    }

    func testProfileEnrichmentAttachesPornHubUploaderURLWithoutProfileImage() async {
        let evidence = profileEvidence(
            title: "Fixture Performer Scene",
            url: "https://www.pornhub.com/view_video.php?viewkey=profilelink",
            uploaderName: "Fixture Performer",
            uploaderURL: "https://www.pornhub.com/pornstar/fixture-performer/videos?page=2",
            thumbnailURL: nil,
            thumbnailReferer: "https://www.pornhub.com/"
        )
        let stats = profileStats(performerName: "Fixture Performer")
        let enriched = await ProfileImageResolver.enrichedStats(
            stats,
            input: profileInput(items: [evidence], uploaderSignals: [
                profileSignal(name: "Fixture Performer", url: evidence.url)
            ])
        ) { _, _ in
            nil
        }

        let performer = enriched.topPerformers.first
        XCTAssertNil(performer?.imageURL)
        XCTAssertEqual(performer?.profileURL, "https://www.pornhub.com/pornstar/fixture-performer")
        XCTAssertEqual(performer?.profileReferer, "https://www.pornhub.com/")
    }

    func testProfileEnrichmentIgnoresNonPornHubUploaderURLForClickableProfile() async {
        let evidence = profileEvidence(
            title: "Fixture Performer Scene",
            url: "https://example.test/video",
            uploaderName: "Fixture Performer",
            uploaderURL: "https://example.test/model/fixture-performer",
            thumbnailURL: "https://cdn.example.test/evidence.jpg",
            thumbnailReferer: "https://example.test/video"
        )
        let stats = profileStats(performerName: "Fixture Performer")
        let enriched = await ProfileImageResolver.enrichedStats(
            stats,
            input: profileInput(items: [evidence], uploaderSignals: [
                profileSignal(name: "Fixture Performer", url: evidence.url)
            ])
        ) { _, _ in
            nil
        }

        let performer = enriched.topPerformers.first
        XCTAssertNil(performer?.profileURL)
        XCTAssertNil(performer?.profileReferer)
    }

    func testProfileImageEnrichmentFallsBackToEvidenceThumbnailForLibraryUploader() async {
        let evidence = profileEvidence(
            source: "Download History",
            title: "Library Fixture",
            url: "https://www.pornhub.com/view_video.php?viewkey=library",
            uploaderName: "Library Performer",
            uploaderURL: nil,
            thumbnailURL: "https://cdn.example.test/library-thumb.jpg",
            thumbnailReferer: "https://www.pornhub.com/view_video.php?viewkey=library"
        )
        let stats = profileStats(performerName: "Library Performer")
        let enriched = await ProfileImageResolver.enrichedStats(
            stats,
            input: profileInput(items: [evidence], uploaderSignals: [
                profileSignal(name: "Library Performer", url: evidence.url, count: 8)
            ])
        ) { _, _ in
            XCTFail("Library-only fallback should not fetch a missing profile page")
            return nil
        }

        let performer = enriched.topPerformers.first
        XCTAssertEqual(performer?.imageURL, "https://cdn.example.test/library-thumb.jpg")
        XCTAssertEqual(performer?.imageReferer, "https://www.pornhub.com/view_video.php?viewkey=library")
        XCTAssertEqual(performer?.imageSource, "evidenceThumbnail")
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

    private func profileResponse(_ json: String) throws -> ProfileAIResponse {
        try JSONDecoder().decode(ProfileAIResponse.self, from: Data(json.utf8))
    }

    private func profileStats(performerName: String) -> ProfileStats {
        ProfileStats(
            topPerformers: [
                ProfileStats.RankedEntry(
                    name: performerName,
                    count: 3,
                    sources: [ProfileSourceCount(source: "Download History", count: 3)]
                )
            ],
            topCategories: [],
            topTags: [],
            topStudios: [],
            preferredQuality: [],
            favoritesCount: 0,
            pornhubLikedCount: 0,
            pornhubFavoritesCount: 0,
            libraryCount: 3,
            libraryTitleSample: [],
            titleSamples: [],
            avgDurationMinutes: nil,
            durationSampleCount: 0,
            durationSources: []
        )
    }

    private func profileSignal(name: String, url: String, count: Int = 3) -> ProfileEvidenceSignal {
        ProfileEvidenceSignal(
            name: name,
            count: count,
            sources: [ProfileSourceCount(source: "Download History", count: count)],
            sampleTitles: ["Fixture"],
            sampleURLs: [url],
            signalKind: "libraryUploader"
        )
    }

    private func profileEvidence(
        source: String = "PornHub Liked",
        title: String,
        url: String,
        uploaderName: String?,
        uploaderURL: String?,
        thumbnailURL: String?,
        thumbnailReferer: String?
    ) -> ProfileEvidenceItem {
        ProfileEvidenceItem(
            id: url,
            source: source,
            title: title,
            url: url,
            uploaderName: uploaderName,
            uploaderURL: uploaderURL,
            uploaderPath: nil,
            scraperPerformers: uploaderName.map { [$0] } ?? [],
            categories: [],
            tags: [],
            metadataStudio: nil,
            sourceSiteName: PornHubFeedScraper.supportedHost,
            durationSeconds: nil,
            qualityLabels: [],
            eventDate: Date(timeIntervalSince1970: 100),
            thumbnailURL: thumbnailURL,
            thumbnailReferer: thumbnailReferer
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

    private func profileInput(
        items: [ProfileEvidenceItem] = [],
        uploaderSignals: [ProfileEvidenceSignal]
    ) -> ProfileGenerationInput {
        ProfileGenerationInput(
            items: items,
            uploaderSignals: uploaderSignals,
            explicitPerformerSignals: [],
            titleNameSignals: [],
            favoritesCount: 0,
            pornhubLikedCount: 0,
            pornhubFavoritesCount: 0,
            libraryCount: uploaderSignals.reduce(0) { $0 + $1.count },
            libraryTitleSample: [],
            titleSamples: [],
            avgDurationMinutes: nil,
            durationSampleCount: 0,
            durationSources: [],
            qualitySignals: []
        )
    }
}
