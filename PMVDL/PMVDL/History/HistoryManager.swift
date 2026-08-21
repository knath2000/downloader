import Foundation

@MainActor
final class HistoryManager: ObservableObject {
    static let shared = HistoryManager()

    @Published private(set) var items: [HistoryItem] = []
    @Published private(set) var completedUploads: [CompletedUploadItem] = []
    @Published private(set) var isRestoring = true

    private let userDefaultsKey = "linkHistory"
    private let completedUploadsKey = "completedUploadHistory"
    private let limit = 100

    private init() {}

    func record(url: String, source: VideoSource) {
        let normalizedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedURL.isEmpty else { return }
        let title = cleanTitle(source.title, fallback: fallbackTitle(for: normalizedURL))
        let provider = providerName(for: source)
        items.removeAll { $0.url == normalizedURL }
        items.insert(HistoryItem(url: normalizedURL, title: title, provider: provider), at: 0)
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
        save()
    }

    func recordCompletedUpload(url: String, source: VideoSource, destination: String, remotePath: String) {
        let normalizedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedURL.isEmpty, !remotePath.isEmpty else { return }
        let title = cleanTitle(source.title, fallback: fallbackTitle(for: normalizedURL))
        let provider = providerName(for: source)
        completedUploads.removeAll { $0.remotePath == remotePath }
        completedUploads.insert(
            CompletedUploadItem(
                url: normalizedURL,
                title: title,
                provider: provider,
                destination: destination,
                remotePath: remotePath
            ),
            at: 0
        )
        if completedUploads.count > limit {
            completedUploads = Array(completedUploads.prefix(limit))
        }
        saveCompletedUploads()
    }

    func remove(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func removeCompletedUpload(_ item: CompletedUploadItem) {
        completedUploads.removeAll { $0.id == item.id }
        saveCompletedUploads()
    }

    func clear() {
        items.removeAll()
        completedUploads.removeAll()
        save()
        saveCompletedUploads()
    }

    func restorePersistedHistory() async {
        guard isRestoring else { return }
        let historyData = UserDefaults.standard.data(forKey: userDefaultsKey)
        let uploadsData = UserDefaults.standard.data(forKey: completedUploadsKey)
        let restored = await Task.detached(priority: .userInitiated) {
            let history = historyData.flatMap {
                try? JSONDecoder().decode([HistoryItem].self, from: $0)
            } ?? []
            let uploads = uploadsData.flatMap {
                try? JSONDecoder().decode([CompletedUploadItem].self, from: $0)
            } ?? []
            return (
                history.sorted { $0.recordedAt > $1.recordedAt },
                uploads.sorted { $0.completedAt > $1.completedAt }
            )
        }.value
        let currentItemURLs = Set(items.map(\.url))
        let currentUploadIDs = Set(completedUploads.map(\.id))
        items = restored.0.filter { !currentItemURLs.contains($0.url) } + items
        completedUploads = restored.1.filter { !currentUploadIDs.contains($0.id) } + completedUploads
        isRestoring = false
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }

    private func saveCompletedUploads() {
        if let encoded = try? JSONEncoder().encode(completedUploads) {
            UserDefaults.standard.set(encoded, forKey: completedUploadsKey)
        }
        LibraryPipelineStore.shared.rebuild(completedUploads: completedUploads)
    }

    private func cleanTitle(_ title: String?, fallback: String) -> String {
        let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? fallback : cleaned
    }

    private func fallbackTitle(for url: String) -> String {
        if let last = URL(string: url)?.lastPathComponent.removingPercentEncoding,
           !last.isEmpty {
            return last.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        }
        return "Untitled Video"
    }

    private func providerName(for source: VideoSource) -> String {
        let raw = source.siteName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return source.displaySiteName }
        if raw == "NativeVideoPage" || raw == "ProviderLink" {
            return source.displaySiteName
        }
        return raw
    }
}
