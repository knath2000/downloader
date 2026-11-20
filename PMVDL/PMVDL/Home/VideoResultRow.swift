import AppKit
import SwiftUI

struct VideoResultRow: View {
    let result: ExtractResult
    let localState: UploadState?
    let megaState: UploadState?
    let onLocal: (VideoQualityChoice) -> Void
    let onMega: (VideoQualityChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: result.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.error == nil ? Theme.success : Theme.error)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)

                    Text(result.source?.displaySiteName ?? "Video Site")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)

                    if let method = result.source?.resolutionMethod {
                        Text("Resolved via \(method)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.skyBlue)
                    }

                    if let error = result.error {
                        Text(displayError(error))
                            .font(.caption)
                            .foregroundStyle(Theme.error)
                    }
                }

                Spacer(minLength: 0)
            }

            if let source = result.source {
                sourceButtons(for: source)
            }

            statusSummary
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private var displayTitle: String {
        guard let source = result.source else { return "Video URL" }
        let title = source.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Untitled Video" : title
    }

    private func displayError(_ error: String) -> String {
        if error.localizedCaseInsensitiveContains("invalid url") {
            return error
        }
        return "Could not extract video sources from this page."
    }

    @ViewBuilder
    private func sourceButtons(for source: VideoSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(VideoResultPresentation.qualities(from: source)) { choice in
                HStack(spacing: 8) {
                    Text(choice.label)
                        .font(.caption.weight(.semibold))
                        .frame(width: 92, alignment: .leading)
                    Button("Local") { onLocal(choice) }
                        .buttonStyle(.borderedProminent)
                    Button("Mega") { onMega(choice) }
                        .buttonStyle(.bordered)
                    Button("Copy") { copyToClipboard(choice.url) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private var statusSummary: some View {
        if let localState {
            stateLine(label: "Local", state: localState)
        }
        if let megaState {
            stateLine(label: "Mega", state: megaState)
        }
    }

    @ViewBuilder
    private func stateLine(label: String, state: UploadState) -> some View {
        switch state {
        case .uploading(let msg):
            Text("\(label): \(msg)")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        case .done(let msg):
            Text("\(label): \(msg)")
                .font(.caption)
                .foregroundStyle(Theme.success)
        case .failed(let msg):
            Text("\(label): \(msg)")
                .font(.caption)
                .foregroundStyle(Theme.error)
        }
    }
}
