import Foundation
import SwiftUI

/// Centralized drop validation and routing for URLs and video files.
struct DropHandler {
    /// Returns true if any item was accepted.
    @MainActor
    static func handleDroppedItems(_ providers: [NSItemProvider],
                                   onUrlPaste: @escaping (String) -> Void,
                                   onFileDrop: @escaping (URL) -> Void) -> Bool {
        var accepted = false

        for itemProvider in providers {
            // Try URL types (web URLs)
            if itemProvider.canLoadObject(ofClass: NSURL.self) {
                _ = itemProvider.loadObject(ofClass: NSURL.self) { node, error in
                    if let nsurl = node as? NSURL, let s = nsurl.absoluteString {
                        DispatchQueue.main.async {
                            if ClipboardManager.isLikelyVideoURL(s) {
                                onUrlPaste(s)
                            }
                        }
                    }
                }
                accepted = true
            }

            // Try file URLs
            if itemProvider.hasItemConformingToTypeIdentifier("public.file-url") {
                _ = itemProvider.loadItem(forTypeIdentifier: "public.file-url") { item, error in
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async { onFileDrop(url) }
                    } else if let nsurl = item as? NSURL, nsurl.isFileURL, let url = nsurl as URL? {
                        DispatchQueue.main.async { onFileDrop(url) }
                    }
                }
                accepted = true
            }

            // Try text URL paste
            if itemProvider.canLoadObject(ofClass: NSString.self) {
                _ = itemProvider.loadObject(ofClass: NSString.self) { node, error in
                    if let ns = node as? NSString {
                        let s = ns as String
                        DispatchQueue.main.async {
                            if ClipboardManager.isLikelyVideoURL(s) {
                                onUrlPaste(s)
                            }
                        }
                    }
                }
                accepted = true
            }
        }

        return accepted
    }
}

/// View modifier wrapping onDrop for AppKit NSItemProviders.
struct HomeDropDestination: ViewModifier {
    let onUrlPaste: (String) -> Void
    let onFileDrop: (URL) -> Void

    func body(content: Content) -> some View {
        content.onDrop(of: [.url, .fileURL], isTargeted: nil) { providers in
            _ = DropHandler.handleDroppedItems(providers, onUrlPaste: onUrlPaste, onFileDrop: onFileDrop)
            return true
        }
    }
}

/// A reusable drop zone view that accepts URLs and files.
struct DropZoneView: View {
    @Binding var isHighlighted: Bool
    let onUrlPaste: (String) -> Void
    let onFileDrop: (URL) -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc").font(.title)
                .foregroundStyle(isHighlighted ? .blue : .secondary)
            Text("Drop URLs or video files here")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(isHighlighted ? Color.blue.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isHighlighted ? Color.blue : Color.clear, lineWidth: 2))
        .onDrop(of: [.url, .fileURL], isTargeted: $isHighlighted) { providers in
            _ = DropHandler.handleDroppedItems(providers, onUrlPaste: onUrlPaste, onFileDrop: onFileDrop)
            return true
        }
    }
}
