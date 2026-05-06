import SwiftUI

struct RemoteFileEditorView: View {
    let item: RemoteFileItem
    let loadText: () async throws -> String
    let saveText: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var originalText = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var hasChanges: Bool {
        text != originalText
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if isLoading {
                ProgressView("Loading \(item.name)...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(8)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Theme.error)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer
        }
        .frame(minWidth: 720, minHeight: 520)
        .task {
            await load()
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "doc.text.fill")
                .foregroundStyle(Theme.skyBlue)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)

                Text(item.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            if hasChanges {
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }

            Spacer()

            Button("Cancel") {
                dismiss()
            }

            Button {
                Task { await save() }
            } label: {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Save")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading || isSaving || !hasChanges)
        }
        .padding(12)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil

        do {
            let loaded = try await loadText()
            text = loaded
            originalText = loaded
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func save() async {
        isSaving = true
        errorMessage = nil

        do {
            try await saveText(text)
            originalText = text
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }

        isSaving = false
    }
}
