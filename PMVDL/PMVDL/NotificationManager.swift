import Foundation
import UserNotifications

struct NotificationManager {
    static let shared = NotificationManager()

    enum EventType: String {
        case uploadComplete = "uploadComplete"
        case uploadFailed = "uploadFailed"
        case scrapeComplete = "scrapeComplete"

        var userDefaultsKey: String { "notif_\(rawValue)" }
        var defaultValue: Bool { true }
    }

    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("[VidDL] Notification auth request failed: \(error)")
            }
        }
    }

    func isEnabled(_ type: EventType) -> Bool {
        UserDefaults.standard.object(forKey: type.userDefaultsKey) == nil
            ? type.defaultValue
            : UserDefaults.standard.bool(forKey: type.userDefaultsKey)
    }

    func setEnabled(_ type: EventType, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: type.userDefaultsKey)
    }

    func notifyUploadComplete(filename: String, destination: String) {
        guard isEnabled(.uploadComplete) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Upload Complete"
        content.body = "\(filename) uploaded to \(destination)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func notifyUploadFailed(filename: String, reason: String) {
        guard isEnabled(.uploadFailed) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Upload Failed"
        content.body = "\(filename): \(reason)"
        content.sound = .defaultCritical
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func notifyScrapeComplete(count: Int) {
        guard isEnabled(.scrapeComplete) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Extraction Complete"
        content.body = "Found videos on \(count) page(s)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
