import Foundation

struct FeedFavoriteItem: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let url: String
    let thumbnailURL: String?
    let referer: String?
    let uploadDate: Date
    let favoritedAt: Date
    let viewCount: Int
    let siteName: String
    let studio: String?
    let durationSeconds: Int?
    let categories: [String]
    let tags: [String]
    let performers: [String]
    let qualityLabels: [String]
    let sourceKind: String

    init(
        id: String,
        title: String,
        url: String,
        thumbnailURL: String?,
        referer: String? = nil,
        uploadDate: Date,
        favoritedAt: Date = Date(),
        viewCount: Int,
        siteName: String,
        studio: String?,
        durationSeconds: Int?,
        categories: [String],
        tags: [String],
        performers: [String],
        qualityLabels: [String],
        sourceKind: String
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.referer = referer
        self.uploadDate = uploadDate
        self.favoritedAt = favoritedAt
        self.viewCount = viewCount
        self.siteName = siteName
        self.studio = studio
        self.durationSeconds = durationSeconds
        self.categories = categories
        self.tags = tags
        self.performers = performers
        self.qualityLabels = qualityLabels
        self.sourceKind = sourceKind
    }
}

extension FeedFavoriteItem {
    init(feedItem item: FeedItem, favoritedAt: Date = Date()) {
        let normalizedURL = Self.normalizedURL(item.url)
        self.init(
            id: normalizedURL,
            title: item.title,
            url: normalizedURL,
            thumbnailURL: item.thumbnailURL,
            referer: item.referer,
            uploadDate: item.uploadDate,
            favoritedAt: favoritedAt,
            viewCount: item.viewCount,
            siteName: item.siteName,
            studio: item.studio,
            durationSeconds: item.durationSeconds,
            categories: item.categories,
            tags: item.tags,
            performers: item.performers,
            qualityLabels: item.qualityLabels,
            sourceKind: item.sourceKind.rawValue
        )
    }

    static func normalizedURL(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
