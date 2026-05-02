import Foundation

// MARK: - Cloud Provider ID

enum CloudProviderID: String, Codable, CaseIterable, Identifiable {
    case mega, gdrive, dropbox, onedrive, local

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mega: return "Mega"
        case .gdrive: return "Google Drive"
        case .dropbox: return "Dropbox"
        case .onedrive: return "OneDrive"
        case .local: return "Local Folder"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .mega: return MegaManager.isAvailable && MegaManager.isLoggedIn
        case .gdrive: return GDriveManager.isAvailable && GDriveManager.isConfigured()
        case .dropbox, .onedrive: return GDriveManager.isAvailable  // rclone-based
        case .local: return true
        }
    }
}

// MARK: - Upload Rule

struct UploadRule: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let qualityCondition: String?   // ">= 2160p", "== 1080p", etc.
    let filenamePattern: String?    // regex, e.g. ".*uncensored.*"
    let targets: [CloudProviderID]

    init(id: UUID = UUID(), name: String, qualityCondition: String? = nil,
         filenamePattern: String? = nil, targets: [CloudProviderID]) {
        self.id = id; self.name = name
        self.qualityCondition = qualityCondition
        self.filenamePattern = filenamePattern
        self.targets = targets
    }

    /// Check if a video matches this rule.
    func matches(quality: String?, filename: String) -> Bool {
        if let qc = qualityCondition, !qualityMatches(qc, quality: quality) { return false }
        if let fp = filenamePattern,
           let regex = try? NSRegularExpression(pattern: fp),
           regex.firstMatch(in: filename, range: NSRange(filename.startIndex..<filename.endIndex, in: filename)) == nil {
            return false
        }
        return true
    }

    private func qualityMatches(_ condition: String, quality: String?) -> Bool {
        guard let quality else { return true }
        let qualityNums = ["2160p": 2160, "1440p": 1440, "1080p": 1080, "720p": 720, "480p": 480, "360p": 360]

        if condition.hasPrefix(">=") {
            let threshold = Int(condition.dropFirst(2).replacingOccurrences(of: "p", with: "")) ?? 0
            return (qualityNums[quality] ?? 0) >= threshold
        } else if condition.hasPrefix("<=") {
            let threshold = Int(condition.dropFirst(2).replacingOccurrences(of: "p", with: "")) ?? 0
            return (qualityNums[quality] ?? 0) <= threshold
        } else if condition.hasPrefix("==") {
            return quality == condition.dropFirst(2)
        }
        return true
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

// MARK: - CloudHub

@MainActor
class CloudHub: ObservableObject {
    static let shared = CloudHub()

    @Published var rules: [UploadRule] = []
    @Published var isUploading = false
    @Published var lastResults: [CloudUploadResult] = []

    private let rulesKey = "cloudHubRules"

    private init() { loadRules() }

    // MARK: - Rules Management

    private func loadRules() {
        if let data = UserDefaults.standard.data(forKey: rulesKey),
           let decoded = try? JSONDecoder().decode([UploadRule].self, from: data) {
            rules = decoded
        }
    }

    func saveRules() {
        if let encoded = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(encoded, forKey: rulesKey)
        }
    }

    func addRule(_ rule: UploadRule) {
        rules.append(rule); saveRules()
    }

    func removeRule(_ rule: UploadRule) {
        rules.removeAll { $0.id == rule.id }; saveRules()
    }

    /// Determine which clouds to upload to based on rules.
    func resolveTargets(quality: String?, filename: String) -> [CloudProviderID] {
        for rule in rules {
            if rule.matches(quality: quality, filename: filename) {
                return rule.targets.filter { $0.isAvailable }
            }
        }
        // Default: just Mega
        return [.mega]
    }

    // MARK: - Upload

    func uploadToAll(videoUrl: String, quality: String?, remotePath: String = "/Cloud/VidDL/", title: String? = nil,
                     onProgress: @escaping (CloudProviderID, String) -> Void) async -> [CloudUploadResult] {
        let targets = resolveTargets(quality: quality, filename: URL(string: videoUrl)?.lastPathComponent ?? "video")
        guard !targets.isEmpty else { return [] }

        isUploading = true
        var results: [CloudUploadResult] = []
        let filename = VideoFileNaming.mp4FileName(title: title, fallback: URL(string: videoUrl)?.lastPathComponent ?? "video")

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
            let dropboxOk = results.contains { $0.provider == .dropbox && $0.success }
            let onedriveOk = results.contains { $0.provider == .onedrive && $0.success }
            if gdriveOk || dropboxOk || onedriveOk {
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
}
