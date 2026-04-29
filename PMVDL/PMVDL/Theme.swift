import SwiftUI

enum Theme {
    static let surface0      = Color(hex: "#111111")
    static let surface1      = Color(hex: "#1C1C1C")
    static let surface2      = Color(hex: "#252525")
    static let border        = Color(hex: "#2D2D2D")
    static let accent        = Color(hex: "#E8933C")
    static let accentDim     = Color(hex: "#E8933C").opacity(0.15)
    static let textPrimary   = Color(hex: "#F0F0F0")
    static let textSecondary = Color(hex: "#7A7A7A")
    static let success       = Color(hex: "#4CAF50")
    static let error         = Color(hex: "#F44336")
    static let warning       = Color(hex: "#FF9500")
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.surface1)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 0.5))
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardStyle()) }
}

/// Sidebar-only vibrancy wrapper (cheap on Intel — composited by macOS, not the app).
struct SidebarVibrancy<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            host.topAnchor.constraint(equalTo: v.topAnchor),
            host.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        if let host = nsView.subviews.first as? NSHostingView<Content> {
            host.rootView = content
        }
    }
}
