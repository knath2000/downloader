import Foundation

struct VideoQualityChoice: Identifiable, Equatable {
    let id: String
    let label: String
    let url: String
    let kind: VideoSource.Kind
    let headers: [String: String]?
    let resolutionMethod: String?
    /// Deferred (yt-dlp) format selector, e.g. "720p". Required to honor the chosen
    /// quality because every deferred quality shares the same page URL.
    let formatSelector: String?
}

struct VideoResultPresentation: Equatable {
    let title: String
    let siteName: String
    let thumbnailURL: String?
    let qualities: [VideoQualityChoice]
    let recommendedQualityID: String?
    let resolutionMethod: String?

    init(result: ExtractResult, fallbackThumbnailURL: String? = nil) {
        let source = result.source
        let sourceTitle = source?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = sourceTitle.isEmpty ? "Untitled Video" : sourceTitle
        siteName = source?.displaySiteName ?? "Video Site"
        thumbnailURL = source?.thumbnail ?? fallbackThumbnailURL
        qualities = Self.qualities(from: source)
        recommendedQualityID = qualities.first?.id
        resolutionMethod = qualities.first?.resolutionMethod ?? source?.resolutionMethod
    }

    static func qualities(from source: VideoSource?) -> [VideoQualityChoice] {
        guard let source else { return [] }
        var output: [VideoQualityChoice] = []
        if let mp4 = source.mp4 {
            output.append(
                VideoQualityChoice(
                    id: mp4,
                    label: "MP4",
                    url: mp4,
                    kind: .direct,
                    headers: source.headers,
                    resolutionMethod: source.resolutionMethod,
                    formatSelector: nil
                )
            )
        }
        // Deferred yt-dlp qualities share one page URL, so the id must include the
        // label to stay unique (otherwise the picker collapses and selection can't
        // distinguish e.g. 1080p from 720p).
        output.append(contentsOf: source.hls.map {
            VideoQualityChoice(
                id: "\($0.label)|\($0.url)",
                label: $0.label,
                url: $0.url,
                kind: $0.kind,
                headers: $0.headers,
                resolutionMethod: $0.resolutionMethod ?? source.resolutionMethod,
                formatSelector: $0.formatSelector
            )
        })
        return output
    }
}
