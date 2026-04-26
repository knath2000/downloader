import Foundation
import SwiftUI

/// Wraps Sparkle auto-update integration.
/// When Sparkle is not yet added to the project, this acts as a no-op placeholder.
@MainActor
class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    @Published var isChecking = false
    @Published var latestVersion: String?

    /// Call this to check for updates. Becomes functional when Sparkle is linked.
    func checkForUpdates() {
        // TODO: When Sparkle is added to the project via SPM:
        //   import Sparkle
        //   updater?.checkForUpdates()
        // For now, just show the user their current version.
        isChecking = true
        latestVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        isChecking = false
    }

    /// Whether auto-update checking feature is available (Sparkle linked).
    var isAvailable: Bool {
        // Change to `true` once Sparkle framework is added to the project.
        false
    }

    var currentVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?.?.?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

// Sparkle appcast feed — host this on GitHub Pages or similar:
// <?xml version="1.0" encoding="utf-8"?>
// <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
//   <channel>
//     <title>PMVDL Updates</title>
//     <item>
//       <title>Version 2.0.0</title>
//       <sparkle:releaseNotesLink>https://pmvdl.com/releasenotes/2.0.0.html</sparkle:releaseNotesLink>
//       <pubDate>Mon, 21 Apr 2026 00:00:00 +0000</pubDate>
//       <enclosure url="https://github.com/pmvdl/pmvidl/releases/download/v2.0.0/PMVDL-2.0.0.zip"
//                  sparkle:version="2" sparkle:shortVersionString="2.0.0"
//                  type="application/octet-stream"
//                  sparkle:edSignature="YOUR_ED25519_SIGNATURE_HERE"
//                  length="YOUR_FILE_SIZE_IN_BYTES"/>
//     </item>
//   </channel>
// </rss>
