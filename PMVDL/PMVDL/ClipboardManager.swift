import AppKit

struct ClipboardManager {
    static var currentURL: String? {
        NSPasteboard.general.string(forType: .string) ?? NSPasteboard.general.string(forType: .URL)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Returns true if the URL looks like a video page (has a host and path).
    static func isLikelyVideoURL(_ url: String) -> Bool {
        guard let parsed = URL(string: url),
              let host = parsed.host(),
              !host.isEmpty,
              !parsed.pathExtension.isEmpty || parsed.path != "/" else { return false }

        // Filter out obviously non-video domains
        let nonVideoExtensions = ["htm", "html", "php", "asp", "aspx", "jsp", "cgi"]
        if !parsed.pathExtension.isEmpty && nonVideoExtensions.contains(parsed.pathExtension.lowercased()) {
            return false
        }

        return true
    }

    @available(*, deprecated, message: "Use isLikelyVideoURL instead")
    static func isPMVHavenURL(_ url: String) -> Bool {
        if let parsed = URL(string: url) {
            return parsed.host()?.contains("pmvhaven.com") == true
        }
        return false
    }
}
