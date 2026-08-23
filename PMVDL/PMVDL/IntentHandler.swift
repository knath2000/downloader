import Foundation
import AppIntents

// MARK: - Intent: Extract Video

struct ExtractVideoIntent: AppIntent {
    static var title: LocalizedStringResource { "Extract Video" }
    static var description: IntentDescription { "Extract download links from a video page." }

    @Parameter(title: "Video URL")
    var url: URL

    static var parameterSummary: any ParameterSummary {
        Summary("Extract video from \(\.$url)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let source = try await VideoScraper.extract(from: url.absoluteString)
        var links: [String] = []
        if let mp4 = source.mp4 { links.append(mp4) }
        for q in source.hls { links.append("\(q.label): \(q.url)") }
        return .result(value: links)
    }
}

// MARK: - Intent: Download Video

struct DownloadVideoIntent: AppIntent {
    static var title: LocalizedStringResource { "Download Video" }
    static var description: IntentDescription { "Extract and queue a video with the background Lustre Agent." }

    @Parameter(title: "Video URL")
    var url: URL

    static var parameterSummary: any ParameterSummary {
        Summary("Download \(\.$url)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard await LicenseManager.shared.preflight() else {
            throw IntentError.proRequired
        }
        let source = try await VideoScraper.extract(from: url.absoluteString)
        let resolution = try await DownloadResolver.resolve(
            sourcePageURL: url.absoluteString,
            preferredQualityLabel: source.hls.first?.label
        )
        let context = DownloadJobContext(megaRemotePath: "")
        _ = await DownloadJobRunner.shared.run(resolution: resolution, target: .local, context: context)
        await LicenseManager.shared.recordSuccessfulDownload()
        return .result(dialog: "Queued with the background Lustre Agent.")
    }
}

// MARK: - Intent Errors

enum IntentError: LocalizedError {
    case noMp4Found
    case proRequired

    var errorDescription: String? {
        switch self {
        case .noMp4Found: return "No MP4 video found on page."
        case .proRequired: return "LustreStudio Pro is required after \(LicenseManager.freeDownloadLimit) free downloads."
        }
    }
}
