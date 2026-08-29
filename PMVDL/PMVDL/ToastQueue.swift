import SwiftUI

@MainActor
final class ToastQueue: ObservableObject {
    static let shared = ToastQueue()

    @Published private(set) var toasts: [Toast] = []

    private init() {}

    func show(_ text: String, type: ToastType = .info, duration: TimeInterval = 3.0) {
        let toast = Toast(text: text, type: type, duration: duration)
        toasts.append(toast)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            dismiss(toast.id)
        }
    }

    /// Shows a toast with an undo action
    func showWithUndo(_ text: String, type: ToastType = .info, duration: TimeInterval = 8.0, actionText: String = "Undo", action: @escaping @MainActor () -> Void) {
        let toast = Toast(text: text, type: type, duration: duration, actionText: actionText, action: action)
        toasts.append(toast)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            dismiss(toast.id)
        }
    }

    func showError(_ text: String, duration: TimeInterval = 4.0) {
        show(text, type: .error, duration: duration)
    }

    func showSuccess(_ text: String, duration: TimeInterval = 3.0) {
        show(text, type: .success, duration: duration)
    }

    func showWarning(_ text: String, duration: TimeInterval = 3.5) {
        show(text, type: .warning, duration: duration)
    }

    func dismiss(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    func clear() {
        toasts.removeAll()
    }
}

struct Toast: Identifiable {
    let id = UUID()
    let text: String
    let type: ToastType
    let duration: TimeInterval
    let createdAt = Date()
    let actionText: String?
    let action: (@MainActor () -> Void)?

    init(text: String, type: ToastType, duration: TimeInterval, actionText: String? = nil, action: (@MainActor () -> Void)? = nil) {
        self.text = text
        self.type = type
        self.duration = duration
        self.actionText = actionText
        self.action = action
    }
}

enum ToastType {
    case info
    case success
    case warning
    case error

    var tint: Color {
        switch self {
        case .info:     return Theme.skyBlue
        case .success:  return Theme.success
        case .warning:  return Theme.warning
        case .error:    return Theme.error
        }
    }

    var icon: String {
        switch self {
        case .info:     return "info.circle.fill"
        case .success:  return "checkmark.circle.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .error:    return "xmark.circle.fill"
        }
    }
}

struct ToastView: View {
    let toast: Toast
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.type.icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(toast.type.tint)

            Text(toast.text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let actionText = toast.actionText, let action = toast.action {
                Button(action: {
                    action()
                    onDismiss()
                }) {
                    Text(actionText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(toast.type.tint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(toast.type.tint.opacity(0.15), in: Capsule())
                        .overlay(Capsule().strokeBorder(toast.type.tint.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Undo")
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    .frame(width: 20, height: 20)
                    .background(Theme.surface2.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .opacity(isHovered ? 1 : 0.6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Theme.surface1.opacity(0.98))
                .overlay(Capsule().strokeBorder(toast.type.tint.opacity(0.6), lineWidth: 1.2))
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
        .scaleEffect(isHovered && !reduceMotion ? 1.02 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: isHovered)
        .onHover { isHovered = $0 }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct ToastQueueView: View {
    @StateObject private var queue = ToastQueue.shared

    var body: some View {
        VStack(spacing: 8) {
            ForEach(queue.toasts) { toast in
                ToastView(toast: toast) {
                    queue.dismiss(toast.id)
                }
            }
        }
        .padding(.top, 12)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: queue.toasts.count)
    }
}

extension ToastQueue {
    func info(_ text: String) { show(text, type: .info) }
    func success(_ text: String) { showSuccess(text) }
    func warning(_ text: String) { showWarning(text) }
    func error(_ text: String) { showError(text) }
}