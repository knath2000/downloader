import SwiftUI

enum MobileMetrics {
    static let screenHorizontalPadding: CGFloat = 16
    static let screenVerticalPadding: CGFloat = 16
    static let cardRadius: CGFloat = 22
    static let compactCardRadius: CGFloat = 18
    static let sheetRadius: CGFloat = 26
    static let touchTarget: CGFloat = 44
    static let bottomSheetHandleWidth: CGFloat = 38
    static let bottomSheetHandleHeight: CGFloat = 4
}

enum MobileTransitionPolicy {
    static func screen(reduceMotion: Bool, performanceProfile: PerformanceProfile) -> AnyTransition {
        if reduceMotion || performanceProfile == .reducedEffects {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .trailing)),
            removal: .opacity.combined(with: .move(edge: .leading))
        )
    }

    static func card(reduceMotion: Bool, performanceProfile: PerformanceProfile) -> AnyTransition {
        if reduceMotion || performanceProfile == .reducedEffects {
            return .opacity
        }
        return .opacity
            .combined(with: .move(edge: .bottom))
            .combined(with: .scale(scale: 0.985, anchor: .center))
    }

    static func spring(reduceMotion: Bool, performanceProfile: PerformanceProfile) -> Animation? {
        reduceMotion || performanceProfile == .reducedEffects
            ? nil
            : .spring(response: 0.34, dampingFraction: 0.82)
    }
}

struct MobileScreenScaffold<Header: View, Content: View>: View {
    let title: String
    let subtitle: String?
    let accent: Color
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title)
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                            if let subtitle {
                                Text(subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        Spacer(minLength: 12)
                        header()
                    }
                }
                .padding(.horizontal, MobileMetrics.screenHorizontalPadding)
                .padding(.top, MobileMetrics.screenVerticalPadding)

                content()
                    .padding(.horizontal, MobileMetrics.screenHorizontalPadding)
                    .padding(.bottom, MobileMetrics.screenVerticalPadding)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.visible)
    }
}

struct MobileCardStyle: ViewModifier {
    let tint: Color
    var cornerRadius: CGFloat = MobileMetrics.cardRadius
    var isElevated = true

    @Environment(\.performanceProfile) private var performanceProfile

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Theme.surfaceGlass.opacity(0.66))
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.12), Theme.surface1.opacity(0.28)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [tint.opacity(0.34), Theme.borderSubtle],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: .black.opacity(isElevated && performanceProfile != .reducedEffects ? 0.24 : 0),
                radius: isElevated ? 16 : 0,
                x: 0,
                y: isElevated ? 10 : 0
            )
    }
}

struct MobilePrimaryButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(minHeight: MobileMetrics.touchTarget)
            .padding(.horizontal, 14)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.78 : 0.95))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(configuration.isPressed ? 0.12 : 0.20), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .shadow(color: tint.opacity(configuration.isPressed ? 0.10 : 0.28), radius: 10, x: 0, y: 5)
    }
}

struct MobilePill: View {
    let label: String
    let systemImage: String?
    let tint: Color
    var isFilled = false

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .heavy))
            }
            Text(label)
                .font(.caption.weight(.bold))
                .lineLimit(1)
        }
        .foregroundStyle(isFilled ? .white : tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isFilled ? tint.opacity(0.95) : tint.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(isFilled ? 0.18 : 0.30), lineWidth: 1))
    }
}

struct MobileBottomSheetHandle: View {
    var body: some View {
        Capsule()
            .fill(.white.opacity(0.24))
            .frame(width: MobileMetrics.bottomSheetHandleWidth, height: MobileMetrics.bottomSheetHandleHeight)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

extension View {
    func mobileCard(tint: Color = Theme.skyBlue, cornerRadius: CGFloat = MobileMetrics.cardRadius, isElevated: Bool = true) -> some View {
        modifier(MobileCardStyle(tint: tint, cornerRadius: cornerRadius, isElevated: isElevated))
    }

    func mobilePressFeedback(enabled: Bool = true) -> some View {
        pressEffect(scale: enabled ? 0.965 : 1)
    }
}
