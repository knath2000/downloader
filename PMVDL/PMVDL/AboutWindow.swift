import AppKit
import SwiftUI

final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    private override init(window: NSWindow!) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = AboutView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
            styleMask: [.closable, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "About LustreStudio"
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}

struct AboutView: View {
    var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?.?.?"
    }
    var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Icon + title
            Image("brandLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .padding(.top, 16)

            Text("LustreStudio").font(.title.bold())
            Text("Version \(version) (\(build))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            Divider().padding(.horizontal).padding(.vertical, 8)

            VStack(spacing: 10) {
                LinkRow(icon: "link", title: "GitHub", url: "https://github.com/knath2000/downloader")
                LinkRow(icon: "bug", title: "Report an Issue", url: "https://github.com/knath2000/downloader/issues")
                LinkRow(icon: "questionmark.circle", title: "Support", url: "mailto:support@viddl.com")
            }
            .padding(.horizontal)

            Divider().padding(.horizontal).padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 4) {
                Text("Changelog").font(.subheadline.bold())
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ChangelogEntry(version: "v2.0.0", date: "Apr 2026",
                            changes: ["Dual window + menu bar mode",
                                      "Library view with thumbnails",
                                      "Download queue management",
                                      "Notifications for uploads & scrapes",
                                      "Keyboard shortcuts (⌘1-4, ⌘N)"])
                        ChangelogEntry(version: "v1.2.0", date: "Apr 2026",
                            changes: ["Batch MP4 download to Mega",
                                      "Google Drive support via rclone",
                                      "Transfer polling view"])
                        ChangelogEntry(version: "v1.0.0", date: "Apr 2026",
                            changes: ["Initial release — menubar + window app",
                                      "Multi-site video extraction",
                                      "Mega upload support"])
                    }
                    .padding(.horizontal)
                }
                .frame(maxHeight: 120)
            }
            .padding(.horizontal)

            Spacer()

            Text("LustreStudio sends a per-Mac hardware identifier to enforce the free download limit and Pro license redemption.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 6)

            // Footer
            Text("Built for macOS 14.0+")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .frame(width: 460)
    }
}

struct LinkRow: View {
    let icon: String; let title: String; let url: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.blue)
                .frame(width: 20)
            Text(title).font(.caption)
            Spacer()
            Link("Open", destination: URL(string: url)!)
                .font(.caption)
        }
    }
}

struct ChangelogEntry: View {
    let version: String; let date: String; let changes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(version).font(.caption.bold())
                Text("— \(date)").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(changes, id: \.self) { c in
                Text("• \(c)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// Show About from menu bar
func showAboutWindow() {
    AboutWindowController.shared.show()
}
