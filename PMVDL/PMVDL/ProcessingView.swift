import SwiftUI

@MainActor
struct ProcessingView: View {
    @State private var selectedProfile: ProcessingProfile = .web
    @State private var isProcessing = false
    @State private var progressMessage = ""
    @State private var selectedFileURL: URL?
    @State private var inputFilePicked = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "wand.and.stars").foregroundStyle(.purple)
                Text("Video Processing").font(.headline).foregroundStyle(Theme.textPrimary)
                Spacer()
                Label("ffmpeg: \(VideoProcessor.isAvailable ? "available" : "not installed")",
                      systemImage: VideoProcessor.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(VideoProcessor.isAvailable ? Theme.success : Theme.warning)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Form {
                Section("Processing Profile") {
                    Picker("Profile", selection: $selectedProfile) {
                        ForEach(ProcessingProfile.all) { p in
                            Text(p.name).tag(p)
                        }
                    }
                    Text(selectedProfile.description)
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }

                Section("Input File") {
                    if let selectedFileURL {
                        Text(selectedFileURL.lastPathComponent)
                            .font(.caption)
                    } else {
                        Text("No file selected")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Button("Select File") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.mpeg4Movie, .audiovisualContent, .movie]
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            selectedFileURL = url
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }

                if isProcessing {
                    Section("Status") {
                        ProgressView()
                        Text(progressMessage)
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal)

            Button("Process") {
                processFile()
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .disabled(!VideoProcessor.isAvailable || selectedFileURL == nil || isProcessing)

            Spacer()
        }
    }

    private func processFile() {
        guard let input = selectedFileURL else { return }
        isProcessing = true
        progressMessage = "Starting..."

        Task {
            do {
                let output = try await VideoProcessor.shared.process(input: input, operation: toOperation()) { msg in
                    DispatchQueue.main.async { progressMessage = msg }
                }
                progressMessage = "Output: \(output.lastPathComponent)"
                isProcessing = false
            } catch {
                progressMessage = "Error: \(error.localizedDescription)"
                isProcessing = false
            }
        }
    }

    private func toOperation() -> VideoProcessor.ProcessOp {
        switch selectedProfile.name {
        case "Web":
            return .convert(format: .mp4)
        case "Archive":
            return .convert(format: .mkv)
        case "Archive Small":
            return .optimize
        case "Thumbnail":
            return .thumbnail
        default:
            return .convert(format: .mp4)
        }
    }
}
