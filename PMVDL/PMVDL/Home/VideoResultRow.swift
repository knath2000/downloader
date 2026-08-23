import AppKit
import SwiftUI

struct VideoResultRow: View {
    let result: ExtractResult
    let localState: UploadState?
    let megaState: UploadState?
    let onLocal: (String) -> Void
    let onMega: (String) -> Void

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
            if let mp4 = source.mp4 {
                HStack(spacing: 8) {
                    Text("MP4")
                        .font(.caption.weight(.semibold))
                        .frame(width: 42, alignment: .leading)
                    Button("Local") { onLocal(mp4) }
                        .buttonStyle(.borderedProminent)
                    Button("Mega") { onMega(mp4) }
                        .buttonStyle(.bordered)
                    Button("Copy") { copyToClipboard(mp4) }
                        .buttonStyle(.bordered)
                }
            }

            if !source.hls.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(source.hls, id: \.url) { quality in
                        HStack(spacing: 8) {
                            Text(quality.label)
                                .font(.caption.weight(.semibold))
                                .frame(width: 92, alignment: .leading)
                            Button("Local") { onLocal(quality.url) }
                                .buttonStyle(.borderedProminent)
                            Button("Mega") { onMega(quality.url) }
                                .buttonStyle(.bordered)
                            Button("Copy") { copyToClipboard(quality.url) }
                                .buttonStyle(.bordered)
                        }
                    }
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
