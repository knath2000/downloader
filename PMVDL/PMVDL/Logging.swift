import os

enum Log {
    private static let subsystem = "com.pmvdl.app"

    static let extractionDood = Logger(subsystem: subsystem, category: "extraction.dood")
    static let extractionWebView = Logger(subsystem: subsystem, category: "extraction.webview")
    static let cloudKit = Logger(subsystem: subsystem, category: "cloudkit")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
}
