import SwiftUI
import WebKit

struct PornHubLoginView: View {
    @StateObject private var session = PornHubSessionManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log in to PornHub")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()

            PornHubWebView {
                Task { @MainActor in
                    await session.syncFromWebView()
                    dismiss()
                }
            }
        }
        .frame(width: 820, height: 660)
    }
}

private struct PornHubWebView: NSViewRepresentable {
    let onLoginDetected: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://www.pornhub.com/login")!))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoginDetected: onLoginDetected)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onLoginDetected: () -> Void
        private var didFire = false

        init(onLoginDetected: @escaping () -> Void) {
            self.onLoginDetected = onLoginDetected
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !didFire, let url = webView.url?.absoluteString else { return }
            if url.contains("pornhub.com"), !url.contains("/login") {
                didFire = true
                onLoginDetected()
            }
        }
    }
}
