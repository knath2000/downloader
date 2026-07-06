import Foundation

enum DownloadPaths {
    static let customDownloadDirectoryKey = "customDownloadDirectory"

    static var defaultDownloadDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/VidDL")
    }

    static var downloadDir: URL {
        guard let rawPath = UserDefaults.standard.string(forKey: customDownloadDirectoryKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return defaultDownloadDir
        }
        return URL(fileURLWithPath: rawPath, isDirectory: true)
    }

    static var hasCustomDownloadDir: Bool {
        UserDefaults.standard.string(forKey: customDownloadDirectoryKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
    }

    static func ensureDownloadDir() {
        try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
    }

    static func setCustomDownloadDir(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: customDownloadDirectoryKey)
        ensureDownloadDir()
    }

    static func resetCustomDownloadDir() {
        UserDefaults.standard.removeObject(forKey: customDownloadDirectoryKey)
        ensureDownloadDir()
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
