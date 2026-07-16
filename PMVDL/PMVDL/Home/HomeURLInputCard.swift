import AppKit
import SwiftUI

struct HomeURLInputCard: View {
    @Binding var text: String
    let isLoading: Bool
    var isCompact = false
    var isCommandCenter = false
    var isYtDlpReady = true
    var isPro = false
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
        VStack(alignment: isCommandCenter ? .center : .leading, spacing: cardSpacing) {
            header
            if isCommandCenter {
                commandEditor
            } else {
                editor
                actions
            }
        }
        .padding(isCommandCenter ? 24 : (isCompact ? 12 : 16))
        .glassCard(tint: Theme.skyBlue.opacity(isCompact ? 0.04 : 0.07), cornerRadius: isCommandCenter ? 20 : HomeLayoutMetrics.cardCornerRadius)
    }

    private var cardSpacing: CGFloat {
        if isCommandCenter { return 18 }
        return isCompact ? 10 : 12
    }

    @ViewBuilder
    private var header: some View {
        if isCommandCenter {
            commandHeader
        } else {
            standardHeader
        }
    }

    private var commandHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HomeStatusPill(
                    label: isYtDlpReady ? "yt-dlp core" : "Install yt-dlp",
                    systemImage: isYtDlpReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    color: isYtDlpReady ? Theme.success : Theme.warning
                )
                HomeStatusPill(label: "ffmpeg engine", systemImage: "checkmark.circle.fill", color: Theme.success)
                if isPro {
                    HomeStatusPill(label: "Pro", systemImage: "crown.fill", color: Theme.gold)
                }
            }

            Text("Ready to Extract")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)

            Text("Paste a supported URL to begin parsing media assets.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var standardHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isCompact ? "Add URLs" : "Paste URLs")
                    .font(isCompact ? .subheadline.weight(.bold) : Theme.sectionHeader)
                    .foregroundStyle(Theme.textPrimary)
                Text(isCompact ? compactHelperText : model.helperText)
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

    private var commandEditor: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18)

            HomeURLTextEditor(
                text: $text,
                isFocused: $isFocused,
                placeholder: "https://"
            )
            .frame(minHeight: 34, maxHeight: text.contains("\n") ? 92 : 44)

            if model.readyCount > 0 {
                Text("\(model.readyCount)")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.success)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.success.opacity(0.12), in: Capsule())
            }

            Button {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onPaste()
                }
                onExtract()
            } label: {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    Text("Extracting")
                } else {
                    Label("Paste & Extract", systemImage: "bolt.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isLoading || (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !canExtract))
            .tint(.white)
            .foregroundStyle(Theme.surface0)
            .help("Paste from clipboard if empty, then extract video sources")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.surfaceGlass.opacity(0.52), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isFocused ? Theme.activeBlue.opacity(0.75) : Theme.borderSubtle, lineWidth: 1)
        )
        .shadow(color: isFocused ? Theme.activeBlue.opacity(0.18) : .clear, radius: 8)
        .accessibilityElement(children: .contain)
    }

    private var editor: some View {
        HomeURLTextEditor(
            text: $text,
            isFocused: $isFocused,
            placeholder: "https://example.com/video/...\nPaste one URL per line"
        )
        .frame(minHeight: isCompact ? 72 : 104, maxHeight: isCompact ? 92 : 140)
        .background(Theme.surface1.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isFocused ? Theme.activeBlue.opacity(0.7) : Theme.borderSubtle, lineWidth: 1)
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
            .controlSize(isCompact ? .regular : .large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canExtract)
            .tint(Theme.skyBlue)
            .help("Extract video sources from the URLs")
        }
    }

    private var compactHelperText: String {
        if !model.invalidLines.isEmpty {
            return model.helperText
        }
        if model.readyCount == 0 {
            return "Queue more links while downloads continue."
        }
        return model.helperText
    }
}

struct HomeStitchCommandPanel<CompletedContent: View, ResultsContent: View>: View {
    @Binding var text: String
    let isLoading: Bool
    let isYtDlpReady: Bool
    let isPro: Bool
    let onPaste: () -> Void
    let onClear: () -> Void
    let onExtract: () -> Void
    @ViewBuilder let completedContent: () -> CompletedContent
    @ViewBuilder let resultsContent: () -> ResultsContent

    @State private var isFocused = false
    @ObservedObject private var appState = AppStateManager.shared

    private var model: HomeURLInputModel {
        HomeURLInputModel(rawText: text)
    }

    private var canExtract: Bool {
        !isLoading && !model.validURLs.isEmpty && model.invalidLines.isEmpty
    }

    private var isPasteAndExtractAction: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canRunPrimaryAction: Bool {
        !isLoading && (canExtract || isPasteAndExtractAction)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            editorBlock
            actionRow
            completedContent()
            resultsContent()
            supportedPlatforms
        }
        .padding(22)
        .frame(minHeight: AppShellSurfaceMetrics.mainPanelHeight(for: appState.windowSize), alignment: .topLeading)
        .mobileCard(tint: Theme.skyBlue.opacity(0.22), cornerRadius: MobileMetrics.sheetRadius, isElevated: true)
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image("LustreStudioLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 340, height: 98)
                .accessibilityLabel("LustreStudio")

            HStack(spacing: 8) {
                MobilePill(
                    label: isYtDlpReady ? "yt-dlp ready" : "Install yt-dlp",
                    systemImage: isYtDlpReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    tint: isYtDlpReady ? Theme.success : Theme.warning
                )
                MobilePill(label: "ffmpeg", systemImage: "checkmark.circle.fill", tint: Theme.success)
                if isPro {
                    MobilePill(label: "Pro", systemImage: "crown.fill", tint: Theme.gold)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var editorBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.readyCount == 0 ? "Add URLs" : "\(model.readyCount) Ready")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(model.invalidLines.isEmpty ? "Paste supported video URLs." : model.helperText)
                        .font(.caption)
                        .foregroundStyle(model.invalidLines.isEmpty ? Theme.textSecondary : Theme.warning)
                }

                Spacer()

                if model.readyCount > 0 {
                    MobilePill(label: "\(model.readyCount)", systemImage: "link", tint: Theme.success, isFilled: true)
                }
            }

            HomeURLTextEditor(
                text: $text,
                isFocused: $isFocused,
                placeholder: "https://example.com/video/...\nPaste one URL per line"
            )
            .frame(minHeight: text.contains("\n") ? 132 : 78, maxHeight: 168)
            .background(Theme.surface0.opacity(0.38), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isFocused ? Theme.skyBlue.opacity(0.86) : Theme.border.opacity(0.52), lineWidth: 1.2)
            )
            .shadow(color: isFocused ? Theme.skyBlue.opacity(0.20) : .clear, radius: 12)
            .accessibilityLabel("Video URLs")
        }
        .padding(14)
        .mobileCard(tint: Theme.skyBlue.opacity(isFocused ? 0.32 : 0.16), cornerRadius: 22, isElevated: false)
    }

    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                secondaryActions
                Spacer()
                extractButton
            }
            VStack(alignment: .leading, spacing: 10) {
                extractButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
                secondaryActions
            }
        }
    }

    private var secondaryActions: some View {
        HStack(spacing: 8) {
            Button(action: onPaste) {
                Label("Paste", systemImage: "clipboard")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .mobilePressFeedback()
            .help("Paste a URL from the clipboard")

            Button(role: .destructive, action: onClear) {
                Label("Clear", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .mobilePressFeedback(enabled: !text.isEmpty)
            .disabled(text.isEmpty)
        }
    }

    private var extractButton: some View {
        Button(action: onExtract) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
                Text("Extracting")
            } else {
                Label(isPasteAndExtractAction ? "Paste & Extract" : "Extract", systemImage: "bolt.fill")
            }
        }
        .buttonStyle(MobilePrimaryButtonStyle(tint: Theme.skyBlue))
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canRunPrimaryAction)
        .help(isPasteAndExtractAction ? "Paste a URL from the clipboard and extract its video sources" : "Extract video sources from the URLs")
    }

    private var supportedPlatforms: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Supported")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                StitchPlatformCard(title: "Video", systemImage: "play.rectangle.fill", tint: Theme.skyBlue)
                StitchPlatformCard(title: "Audio", systemImage: "music.note", tint: Color.purple)
                StitchPlatformCard(title: "Social", systemImage: "bubble.left.and.bubble.right.fill", tint: Theme.success)
                StitchPlatformCard(title: "Web", systemImage: "globe", tint: Theme.gold)
            }
        }
    }
}

private struct StitchPlatformCard: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(height: 34)

            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 88)
        .mobileCard(tint: tint.opacity(0.20), cornerRadius: 18, isElevated: false)
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
