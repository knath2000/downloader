import CloudKit
import Foundation

/// Manages CloudKit sync for VidDL data across devices.
@MainActor
class CloudKitManager: ObservableObject {
    static let shared = CloudKitManager()

    @Published var isSyncEnabled: Bool = UserDefaults.standard.bool(forKey: "cloudKitEnabled")
    @Published var syncStatus: SyncStatus = .idle
    @Published var lastSyncDate: Date?

    enum SyncStatus: String { case idle, syncing, error, success }

    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }

    // Record type names
    static let settingsRecordType = "PMVDLSettings"
    static let libraryRecordType = "PMVDLLibrary"

    private init() {
        self.container = CKContainer(identifier: "iCloud.com.pmvdl.app")
        // Only activate if user enabled it
        if isSyncEnabled {
            Task { await fetchLatest() }
        }
    }

    func enableSync() {
        isSyncEnabled = true
        UserDefaults.standard.set(true, forKey: "cloudKitEnabled")
        Task { await fetchLatest() }
    }

    func disableSync() {
        isSyncEnabled = false
        UserDefaults.standard.set(false, forKey: "cloudKitEnabled")
    }

    /// Push current local state to CloudKit.
    func pushLocalState() async {
        guard isSyncEnabled else { return }
        syncStatus = .syncing

        do {
            // Save settings
            let settings = CKRecord(recordType: Self.settingsRecordType, recordID: CKRecord.ID(recordName: "mainSettings"))
            settings["megaRemotePath"] = UserDefaults.standard.string(forKey: "megaRemotePath")
            settings["gdriveRemoteName"] = UserDefaults.standard.string(forKey: "gdriveRemoteName")
            settings["gdriveRemotePath"] = UserDefaults.standard.string(forKey: "gdriveRemotePath")
            settings["license_pro_active"] = LicenseManager.shared.isPro as CKRecordValue
            settings["modifiedAt"] = Date() as CKRecordValue
            try await database.save(settings)

            // Save library
            let libraryItems = VideoLibrary.shared.items
            for item in libraryItems {
                let record = CKRecord(recordType: Self.libraryRecordType,
                                     recordID: CKRecord.ID(recordName: item.id.uuidString))
                record["title"] = item.title
                record["url"] = item.url
                record["mp4Url"] = item.mp4Url
                record["extractedAt"] = item.extractedAt
                record["modifiedAt"] = Date() as CKRecordValue
                try await database.save(record)
            }

            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            // Graceful fallback — CloudKit not critical
            print("[VidDL] CloudKit push failed: \(error.localizedDescription)")
            syncStatus = .error
        }
    }

    /// Pull latest state from CloudKit.
    func fetchLatest() async {
        guard isSyncEnabled else { return }
        syncStatus = .syncing

        do {
            // Fetch settings
            let settingsID = CKRecord.ID(recordName: "mainSettings")
            if let settings = try? await database.record(for: settingsID) {
                if let v = settings["megaRemotePath"] as? String {
                    UserDefaults.standard.set(v, forKey: "megaRemotePath")
                }
                if let v = settings["gdriveRemoteName"] as? String {
                    UserDefaults.standard.set(v, forKey: "gdriveRemoteName")
                }
                if let v = settings["gdriveRemotePath"] as? String {
                    UserDefaults.standard.set(v, forKey: "gdriveRemotePath")
                }
            }

            // Fetch library items (last 100)
            let query = CKQuery(recordType: Self.libraryRecordType,
                               predicate: NSPredicate(value: true))
            query.sortDescriptors = [NSSortDescriptor(key: "modifiedAt", ascending: false)]

            let results = try await database.records(matching: query)
            for (_, result) in results.matchResults {
                if case .success(let record) = result {
                    let id = UUID(uuidString: record.recordID.recordName)
                    let title = record["title"] as? String ?? "Unknown"
                    let url = record["url"] as? String ?? ""
                    let mp4Url = record["mp4Url"] as? String
                    let date = record["extractedAt"] as? Date ?? Date()
                    if let id = id {
                        let item = LibraryItem(id: id, url: url, title: title,
                                               mp4Url: mp4Url, hlsUrls: [])
                        // Only add if not already present
                        if !VideoLibrary.shared.items.contains(where: { $0.url == item.url }) {
                            VideoLibrary.shared.addIfNew(item)
                        }
                    }
                }
            }

            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            print("[VidDL] CloudKit fetch failed: \(error.localizedDescription)")
            syncStatus = .error
        }
    }

    /// Subscribe to remote changes via CKSubscription.
    func setupSubscription() async {
        guard isSyncEnabled else { return }
        let subscription = CKQuerySubscription(recordType: Self.libraryRecordType,
                                                predicate: NSPredicate(value: true),
                                                subscriptionID: "libraryChanges")
        let notif = CKSubscription.NotificationInfo()
        notif.shouldSendContentAvailable = true
        subscription.notificationInfo = notif

        do {
            try await database.save(subscription)
        } catch {
            // Subscription may already exist
        }
    }
}
