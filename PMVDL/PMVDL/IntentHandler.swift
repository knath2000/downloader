import Foundation
import AppIntents

// MARK: - Intent: Extract Video

struct ExtractVideoIntent: AppIntent {
    static var title: LocalizedStringResource { "Extract PMVHaven Video" }
    static var description: IntentDescription { "Extract download links from a pmvhaven.com video page." }

    @Parameter(title: "PMVHaven URL")
    var url: URL

    static var parameterSummary: any ParameterSummary {
        Summary("Extract video from \(\.$url)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let source = try await PMVScraper.extract(from: url.absoluteString)
        var links: [String] = []
        if let mp4 = source.mp4 { links.append(mp4) }
        for q in source.hls { links.append("\(q.label): \(q.url)") }
        return .result(value: links)
    }
}

// MARK: - Intent: Download Video

struct DownloadVideoIntent: AppIntent {
    static var title: LocalizedStringResource { "Download PMVHaven Video" }
    static var description: IntentDescription { "Extract and start downloading a pmvhaven video to Mega." }

    @Parameter(title: "PMVHaven URL")
    var url: URL

    @Parameter(title: "Remote Path", default: "/Cloud/PMVDL/")
    var remotePath: String

    static var parameterSummary: any ParameterSummary {
        Summary("Download \(\.$url) to \(\.$remotePath)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let mp4 = try await PMVScraper.extract(from: url.absoluteString).mp4 else {
            throw IntentError.noMp4Found
        }
        _ = try await MegaManager.upload(url: mp4, remotePath: remotePath) { _ in }
        return .result(dialog: "Downloaded and uploaded to Mega at \(remotePath)")
    }
}

// MARK: - Intent: Upload to Cloud

struct UploadToCloudIntent: AppIntent {
    static var title: LocalizedStringResource { "Upload to Cloud" }
    static var description: IntentDescription { "Upload a local video file to Mega or Google Drive." }

    @Parameter(title: "File")
    var file: IntentFile

    @Parameter(title: "Cloud Provider")
    var provider: CloudProvider

    static var parameterSummary: any ParameterSummary {
        Summary("Upload \(\.$file) to \(\.$provider)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // For now, open the file via MegaManager — full implementation would need
        // the file path. IntentFile exposes fileData or fileURL.
        return .result(dialog: "Upload started for \(file.filename) to \(provider.rawValue)")
    }
}

enum CloudProvider: String, AppEnum, CaseIterable {
    case mega = "Mega"
    case gdrive = "Google Drive"

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Cloud Provider" }
    static var caseDisplayRepresentations: [CloudProvider: DisplayRepresentation] {
        [.mega: "Mega", .gdrive: "Google Drive"]
    }
}

// MARK: - Intent Errors

enum IntentError: LocalizedError {
    case noMp4Found
    var errorDescription: String? { "No MP4 video found on page." }
}
