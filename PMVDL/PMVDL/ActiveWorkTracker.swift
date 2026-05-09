import Foundation
import SwiftUI

/// Persistent singleton that tracks in-flight uploads and batch downloads.
/// Unlike @State in HomeView, this survives tab switches.
@MainActor
class ActiveWorkTracker: ObservableObject {
    static let shared = ActiveWorkTracker()

    @Published var megaUploads: [String: UploadState] = [:]
    @Published var gdriveUploads: [String: UploadState] = [:]
    @Published var seedboxUploads: [String: UploadState] = [:]
    @Published var localDownloads: [String: UploadState] = [:]
    /// Maps video source URL → remote Mega path (e.g. "/Cloud/VidDL/viddl_abc12345.mp4")
    /// for auto-deletion after successful GDrive upload.
    @Published var megaFilenames: [String: String] = [:]
    @Published var isBatchDownloading = false
    @Published var batchProgress = ""

    private init() {}

    /// Clear upload states and mega filename tracking for URLs that were part of a new extraction.
    func clear(except urls: Set<String>) {
        megaUploads = megaUploads.filter { urls.contains($0.key) }
        gdriveUploads = gdriveUploads.filter { urls.contains($0.key) }
        seedboxUploads = seedboxUploads.filter { urls.contains($0.key) }
        localDownloads = localDownloads.filter { urls.contains($0.key) }
        megaFilenames = megaFilenames.filter { urls.contains($0.key) }
    }

    func reset() {
        megaUploads = [:]
        gdriveUploads = [:]
        seedboxUploads = [:]
        localDownloads = [:]
        megaFilenames = [:]
        isBatchDownloading = false
        batchProgress = ""
    }

    var activeUploadCount: Int {
        megaUploads.values.filter {
            if case .uploading = $0 { return true }; return false
        }.count + gdriveUploads.values.filter {
            if case .uploading = $0 { return true }; return false
        }.count + seedboxUploads.values.filter {
            if case .uploading = $0 { return true }; return false
        }.count
    }

    func project(_ item: DownloadQueueItem) {
        guard let state = DownloadQueue.shared.projectedState(for: item) else { return }
        switch item.targetCloud {
        case .local:
            if localDownloads[item.url] != state {
                localDownloads[item.url] = state
            }
        case .mega:
            if megaUploads[item.url] != state {
                megaUploads[item.url] = state
            }
            if item.status == .completed, let finalPath = item.finalPath {
                megaFilenames[item.url] = finalPath
            }
        case .gdrive:
            if gdriveUploads[item.url] != state {
                gdriveUploads[item.url] = state
            }
        case .seedbox:
            if seedboxUploads[item.url] != state {
                seedboxUploads[item.url] = state
            }
        }
    }

    func project(queueId: UUID) {
        guard let item = DownloadQueue.shared.item(id: queueId) else { return }
        project(item)
    }

    func removeMegaFilename(for url: String) {
        megaFilenames.removeValue(forKey: url)
    }

    func projectFailure(url: String, target: CloudTarget, message: String) {
        let state = UploadState.failed(message)
        switch target {
        case .local:
            localDownloads[url] = state
        case .mega:
            megaUploads[url] = state
        case .gdrive:
            gdriveUploads[url] = state
        case .seedbox:
            seedboxUploads[url] = state
        }
    }
}
