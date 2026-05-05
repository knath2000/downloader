import Foundation

/// Writes transfer status to UserDefaults in an App Group container for WidgetKit.
/// App group ID: "group.com.pmvdl.app"
struct WidgetDataStore {
    static let shared = WidgetDataStore()

    private let appGroup = "group.com.pmvdl.app"
    private let defaults: UserDefaults?

    init() {
        self.defaults = UserDefaults(suiteName: appGroup)
    }

    /// Updates widget transfer status.
    func updateTransferCount(_ count: Int, progress: Double) {
        defaults?.set(count, forKey: "widgetTransferCount")
        defaults?.set(progress, forKey: "widgetProgress")
        defaults?.set(Date().timeIntervalSince1970, forKey: "widgetLastUpdated")
        defaults?.synchronize()
    }

    /// Called when all transfers complete.
    func clearWidgetData() {
        defaults?.set(0, forKey: "widgetTransferCount")
        defaults?.set(0.0, forKey: "widgetProgress")
        defaults?.set(Date().timeIntervalSince1970, forKey: "widgetLastUpdated")
        defaults?.synchronize()
    }

    // Widget reads these values
    var transferCount: Int { defaults?.integer(forKey: "widgetTransferCount") ?? 0 }
    var progress: Double { defaults?.double(forKey: "widgetProgress") ?? 0.0 }
    var lastUpdated: Date? {
        guard let ts = defaults?.double(forKey: "widgetLastUpdated") else { return nil }
        return Date(timeIntervalSince1970: ts)
    }
}
