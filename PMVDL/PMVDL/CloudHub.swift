import Foundation

// MARK: - Cloud Provider ID

enum CloudProviderID: String, Codable, CaseIterable, Identifiable {
    case mega, gdrive, seedbox, dropbox, onedrive, local

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mega: return "Mega"
        case .gdrive: return "Google Drive"
        case .seedbox: return "Seedbox"
        case .dropbox: return "Dropbox"
        case .onedrive: return "OneDrive"
        case .local: return "Local Folder"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .mega: return MegaManager.isAvailable && MegaManager.isLoggedIn
        case .gdrive: return GDriveManager.isAvailable && GDriveManager.isConfigured()
        case .seedbox:
            if UserDefaults.standard.string(forKey: "seedboxTransferMode") == "webdav" {
                let raw = UserDefaults.standard.string(forKey: "seedboxWebdavURL") ?? ""
                return URLTrustPolicy.validated(raw)?.scheme?.lowercased() == "https"
            }
            return SeedboxManager.isRcloneAvailable
        case .dropbox, .onedrive: return GDriveManager.isAvailable  // rclone-based
        case .local: return true
        }
    }
}

// MARK: - Upload Result

struct CloudUploadResult: Identifiable {
    let id: UUID
    let provider: CloudProviderID
    let success: Bool
    let message: String

    static func success(_ provider: CloudProviderID, message: String) -> CloudUploadResult {
        CloudUploadResult(id: UUID(), provider: provider, success: true, message: message)
    }
    static func failure(_ provider: CloudProviderID, error: Error) -> CloudUploadResult {
        CloudUploadResult(id: UUID(), provider: provider, success: false, message: error.localizedDescription)
    }
}

private enum CloudHubError: LocalizedError {
    case multiCloudRequiresPro

    var errorDescription: String? {
        switch self {
        case .multiCloudRequiresPro:
            return "Multi-cloud upload requires LustreStudio Pro."
        }
    }
}

// MARK: - CloudHub

@MainActor
class CloudHub: ObservableObject {
    static let shared = CloudHub()

    @Published var isUploading = false
    @Published var lastResults: [CloudUploadResult] = []

    private init() {}

    // MARK: - Upload

    func uploadToAll(videoUrl: String, quality: String?, remotePath: String = "/Cloud/VidDL/", title: String? = nil,
                     onProgress: @escaping (CloudProviderID, String) -> Void) async -> [CloudUploadResult] {
        let targets: [CloudProviderID] = [.mega]
        guard !targets.isEmpty else { return [] }
        guard targets.count == 1 || ProFeatureGate.canMultiUpload else {
            let results = [CloudUploadResult.failure(targets[0], error: CloudHubError.multiCloudRequiresPro)]
            lastResults = results
            return results
        }

        isUploading = true
        var results: [CloudUploadResult] = []
        let filename = VideoFileNaming.mp4FileName(title: title, fallback: URL(string: videoUrl)?.lastPathComponent ?? "video")
        let seedboxMode = try? seedboxModeFromDefaults()

        // First upload to Mega to establish the file, then to other targets
        // For auto-delete: track Mega upload result, then delete after GDrive succeeds
        var megaRemotePath: String?

        // Upload to Mega first if it's a target
        if targets.contains(.mega) {
            do {
                let result = try await MegaManager.upload(url: videoUrl, remotePath: remotePath, title: title) { event in
                    onProgress(.mega, "\(event.message) \(Int(event.percent))%")
                }
                megaRemotePath = result.remotePath
                results.append(.success(.mega, message: "Uploaded to Mega"))
            } catch {
                results.append(.failure(.mega, error: error))
            }
            // Remove mega from targets since we already uploaded
        }

        let remainingTargets = targets.filter { $0 != .mega }

        // Upload to remaining targets
        if !remainingTargets.isEmpty {
            await withTaskGroup(of: (CloudUploadResult, String?).self) { group in
                for target in remainingTargets {
                    group.addTask {
                        do {
                            switch target {
                            case .gdrive:
                                try await GDriveManager.upload(url: videoUrl, remoteName: "gdrive", remotePath: "VidDL/", title: title) { msg in
                                    onProgress(.gdrive, msg)
                                }
                                return (.success(.gdrive, message: "Uploaded to GDrive"), nil)
                            case .seedbox:
                                guard let seedboxMode else { throw SeedboxError.notConfigured }
                                let manager = SeedboxManager(mode: seedboxMode)
                                guard let sourceURL = URL(string: videoUrl) else { throw SeedboxError.invalidSourceURL }
                                _ = try await manager.upload(sourceURL: sourceURL, filename: filename) { progress in
                                    onProgress(.seedbox, String(format: "Transferring to seedbox… %.0f%%", progress * 100))
                                }
                                return (.success(.seedbox, message: "Uploaded to Seedbox"), nil)
                            case .dropbox:
                                try await GDriveManager.upload(url: videoUrl, remoteName: "dropbox", remotePath: "VidDL/", title: title) { msg in
                                    onProgress(.dropbox, msg)
                                }
                                return (.success(.dropbox, message: "Uploaded to Dropbox"), nil)
                            case .onedrive:
                                try await GDriveManager.upload(url: videoUrl, remoteName: "onedrive", remotePath: "VidDL/", title: title) { msg in
                                    onProgress(.onedrive, msg)
                                }
                                return (.success(.onedrive, message: "Uploaded to OneDrive"), nil)
                            case .local:
                                if let url = URL(string: videoUrl),
                                   let data = try? Data(contentsOf: url) {
                                    let destDir = FileManager.default.homeDirectoryForCurrentUser
                                        .appendingPathComponent("Downloads/VidDL")
                                    try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                                    let dest = destDir.appendingPathComponent(filename)
                                    try data.write(to: dest)
                                    if quality?.localizedCaseInsensitiveContains("audio") != true {
                                        onProgress(.local, "Verifying video…")
                                        try await VideoProcessor.verifyForUpload(dest)
                                    }
                                    return (.success(.local, message: "Saved to \(dest.path)"), nil)
                                }
                                throw NSError(domain: "VidDL", code: -1,
                                             userInfo: [NSLocalizedDescriptionKey: "Failed to download file"])
                            case .mega:
                                fatalError("Mega should have been filtered out")
                            }
                        } catch {
                            return (.failure(target, error: error), nil)
                        }
                    }
                }

                for await (result, _) in group {
                    results.append(result)
                }
            }
        }

        // After all uploads complete, delete Mega files that were successfully copied to GDrive/Dropbox/OneDrive
        if let megaPath = megaRemotePath {
            let gdriveOk = results.contains { $0.provider == .gdrive && $0.success }
            let seedboxOk = results.contains { $0.provider == .seedbox && $0.success }
            let dropboxOk = results.contains { $0.provider == .dropbox && $0.success }
            let onedriveOk = results.contains { $0.provider == .onedrive && $0.success }
            if gdriveOk || seedboxOk || dropboxOk || onedriveOk {
                do {
                    try await MegaManager.delete(remotePath: megaPath)
                } catch {
                    results.append(.failure(.mega, error: error))
                }
            }
        }

        isUploading = false
        lastResults = results
        return results
    }

    private func seedboxModeFromDefaults() throws -> SeedboxTransferMode {
        let remotePath = UserDefaults.standard.string(forKey: "seedboxRemotePath") ?? "/"
        if UserDefaults.standard.string(forKey: "seedboxTransferMode") == "webdav" {
            let rawURL = UserDefaults.standard.string(forKey: "seedboxWebdavURL") ?? ""
            guard let baseURL = URLTrustPolicy.validated(rawURL), baseURL.scheme?.lowercased() == "https" else { throw SeedboxError.notConfigured }
            return .webdav(
                baseURL: baseURL,
                user: UserDefaults.standard.string(forKey: "seedboxWebdavUser") ?? "",
                password: SecureStore.string(forKey: "seedboxWebdavPassword") ?? "",
                remotePath: remotePath,
                allowSelfSigned: UserDefaults.standard.bool(forKey: "seedboxWebdavAllowSelfSigned")
            )
        }
        return .rclone(
            remoteName: UserDefaults.standard.string(forKey: "seedboxRemoteName") ?? "seedbox",
            remotePath: remotePath
        )
    }
}
