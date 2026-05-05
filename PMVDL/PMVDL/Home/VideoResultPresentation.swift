import Foundation

struct VideoQualityChoice: Identifiable, Equatable {
    let id: String
    let label: String
    let url: String
    let kind: VideoSource.Kind
    let headers: [String: String]?
}

struct VideoResultPresentation: Equatable {
    let title: String
    let siteName: String
    let thumbnailURL: String?
    let qualities: [VideoQualityChoice]
    let recommendedQualityID: String?

    init(result: ExtractResult) {
        let source = result.source
        let sourceTitle = source?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = sourceTitle.isEmpty ? "Untitled Video" : sourceTitle
        siteName = source?.displaySiteName ?? "Video Site"
        thumbnailURL = source?.thumbnail
        qualities = Self.qualities(from: source)
        recommendedQualityID = qualities.first?.id
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
                    headers: source.headers
                )
            )
        }
        output.append(contentsOf: source.hls.map {
            VideoQualityChoice(
                id: $0.url,
                label: $0.label,
                url: $0.url,
                kind: $0.kind,
                headers: $0.headers
            )
        })
        return output
    }
}
