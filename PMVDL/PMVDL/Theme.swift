import SwiftUI

enum Theme {
    // Base surfaces (kept for legacy + fallback paths)
    static let surface0      = Color(hex: "#0D0D1A")
    static let surface1      = Color(hex: "#16162A")
    static let surface2      = Color(hex: "#1E1E35")
    static let border        = Color(hex: "#2D2D4D")

    // Brand amber (retained for continuity)
    static let amber         = Color(hex: "#E8933C")
    static let accent        = Color(hex: "#E8933C")
    static let accentDim     = Color(hex: "#E8933C").opacity(0.15)

    // Marketplace palette
    static let taoRed        = Color(hex: "#E31C23")
    static let coral         = Color(hex: "#FF6B6B")
    static let gold          = Color(hex: "#FFD700")
    static let hotPink       = Color(hex: "#FF1493")
    static let electricLime  = Color(hex: "#7FFF00")
    static let skyBlue       = Color(hex: "#00BFFF")
    static let lavender      = Color(hex: "#B388FF")

    // Status
    static let success       = Color(hex: "#4CAF50")
    static let error         = Color(hex: "#F44336")
    static let warning       = Color(hex: "#FF9500")

    // Text
    static let textPrimary   = Color(hex: "#F0F0F0")
    static let textSecondary = Color(hex: "#8A8AB0")

    // Mesh gradient stops
    static let meshDeepPurple = Color(hex: "#1A0A2E")
    static let meshNavy       = Color(hex: "#0D1B4B")
    static let meshMidnight   = Color(hex: "#0A0A1A")
    static let meshCoral      = Color(hex: "#3D0A2A")
    static let meshIndigo     = Color(hex: "#1A237E")

    // Typography tokens
    static let marketplaceTitle: Font  = .system(.title2, design: .default).weight(.black)
    static let badgeLabel: Font        = .system(.caption, design: .default).weight(.heavy)
    static let sectionHeader: Font     = .system(.headline, design: .default).weight(.black)

    // Per-destination sidebar accent colors
    static func destinationColor(_ dest: NavDestination) -> Color {
        switch dest {
        case .home:       return coral
        case .feed:       return lavender
        case .favorites:  return hotPink
        case .library:    return skyBlue
        case .downloads:  return electricLime
        case .files:      return skyBlue
        case .settings:   return Color(hex: "#A0A0FF")
        }
    }
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

// Legacy CardStyle kept for migration — new code uses GlassCard from GlassComponents.swift
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
