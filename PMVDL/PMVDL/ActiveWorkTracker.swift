import Foundation
import SwiftUI

/// Persistent singleton that tracks in-flight uploads and batch downloads.
/// Unlike @State in HomeView, this survives tab switches.
@MainActor
class ActiveWorkTracker: ObservableObject {
    static let shared = ActiveWorkTracker()

    @Published var megaUploads: [String: UploadState] = [:]
    @Published var gdriveUploads: [String: UploadState] = [:]
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
        localDownloads = localDownloads.filter { urls.contains($0.key) }
        megaFilenames = megaFilenames.filter { urls.contains($0.key) }
    }

    func reset() {
        megaUploads = [:]
        gdriveUploads = [:]
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
        }.count
    }
}
