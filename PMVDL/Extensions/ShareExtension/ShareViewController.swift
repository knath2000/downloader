import SwiftUI
import UniformTypeIdentifiers

/// Share Extension — activated when sharing URLs or video files to PMVDL.
struct ShareViewController: View {
    @Environment(\.dismiss) var dismiss
    @State private var shareUrl: String?
    @State private var isProcessing = false
    @State private var message = "Processing shared item..."

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "film")
                .resizable().scaledToFit()
                .frame(width: 32, height: 32)
                .foregroundStyle(.blue)

            Text("PMVDL").font(.headline)

            if isProcessing {
                ProgressView()
                    .padding()
                Text(message).font(.caption).foregroundStyle(.secondary)
            } else if let shareUrl {
                Text("URL received: \(shareUrl)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
        }
        .frame(width: 300, height: 200)
    }
}

/// Extension entry point for SwiftUI-based share sheet.
final class ShareExtensionDelegate: NSObject {
    static let shared = ShareExtensionDelegate()
}
