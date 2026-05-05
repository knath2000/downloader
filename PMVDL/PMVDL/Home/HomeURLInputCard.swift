import AppKit
import SwiftUI

struct HomeURLInputCard: View {
    @Binding var text: String
    let isLoading: Bool
    let onPaste: () -> Void
    let onClear: () -> Void
    let onExtract: () -> Void

    @State private var isFocused = false

    private var model: HomeURLInputModel {
        HomeURLInputModel(rawText: text)
    }

    private var canExtract: Bool {
        !isLoading && !model.validURLs.isEmpty && model.invalidLines.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            editor
            actions
        }
        .padding(16)
        .glassCard(tint: Theme.skyBlue.opacity(0.10), cornerRadius: HomeLayoutMetrics.cardCornerRadius)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Paste URLs")
                    .font(Theme.sectionHeader)
                    .foregroundStyle(Theme.textPrimary)
                Text(model.helperText)
                    .font(.caption)
                    .foregroundStyle(model.invalidLines.isEmpty ? Theme.textSecondary : Theme.warning)
            }
            Spacer(minLength: 12)
            Text("\(model.readyCount)")
                .font(.caption.weight(.heavy))
                .foregroundStyle(model.readyCount > 0 ? Theme.success : Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.surface2.opacity(0.45), in: Capsule())
                .help("Valid URL count")
        }
    }

    private var editor: some View {
        HomeURLTextEditor(
            text: $text,
            isFocused: $isFocused,
            placeholder: "https://example.com/video/...\nPaste one URL per line"
        )
        .frame(minHeight: 104, maxHeight: 140)
        .background(Theme.surface1.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isFocused ? Theme.skyBlue.opacity(0.7) : Theme.border, lineWidth: 1)
        )
        .accessibilityLabel("Video URLs")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: onPaste) {
                Label("Paste", systemImage: "clipboard")
            }
            .buttonStyle(.bordered)
            .help("Paste a URL from the clipboard")

            Button(role: .destructive, action: onClear) {
                Label("Clear", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
            .disabled(text.isEmpty)

            Spacer()

            Button(action: onExtract) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    Text("Extracting")
                } else {
                    Label("Extract", systemImage: "bolt.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canExtract)
            .tint(Theme.skyBlue)
            .help("Extract video sources from the URLs")
        }
    }
}

private struct HomeURLTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> HomeURLTextViewContainer {
        let view = HomeURLTextViewContainer(placeholder: placeholder)
        view.textView.delegate = context.coordinator
        view.textView.string = text
        view.placeholderLabel.isHidden = isFocused || !text.isEmpty
        return view
    }

    func updateNSView(_ nsView: HomeURLTextViewContainer, context: Context) {
        context.coordinator.parent = self
        if nsView.textView.string != text {
            nsView.textView.string = text
        }
        nsView.placeholderLabel.stringValue = placeholder
        nsView.placeholderLabel.isHidden = isFocused || !text.isEmpty
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HomeURLTextEditor

        init(_ parent: HomeURLTextEditor) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private final class HomeURLTextViewContainer: NSView {
    let scrollView = NSScrollView()
    let textView = NSTextView()
    let placeholderLabel: NSTextField

    init(placeholder: String) {
        placeholderLabel = NSTextField(labelWithString: placeholder)
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        placeholderLabel = NSTextField(labelWithString: "")
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .systemBlue
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        placeholderLabel.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.72)
        placeholderLabel.backgroundColor = .clear
        placeholderLabel.isBordered = false
        placeholderLabel.isEditable = false
        placeholderLabel.isSelectable = false
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.cell?.wraps = true

        addSubview(scrollView)
        addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14)
        ])
    }
}
