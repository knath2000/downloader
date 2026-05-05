import Foundation

enum DownloadPaths {
    static let downloadDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads/VidDL")

    static func ensureDownloadDir() {
        try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
    }
}

enum DownloadPreferences {
    static var subtitlesEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "downloadSubtitles") }
        set { UserDefaults.standard.set(newValue, forKey: "downloadSubtitles") }
    }

    static var embeddedSubsMode: Bool {
        get { UserDefaults.standard.bool(forKey: "embeddedSubsMode") }
        set { UserDefaults.standard.set(newValue, forKey: "embeddedSubsMode") }
    }
}
