import SwiftUI
import WebKit

struct EpornerLoginView: View {
    @StateObject private var session = EpornerSessionManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log in to Eporner")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()

            EpornerWebView {
                Task { @MainActor in
                    await session.syncFromWebView()
                    if session.isLoggedIn {
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 820, height: 660)
    }
}

private struct EpornerWebView: NSViewRepresentable {
    let onLoginDetected: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://www.eporner.com/login/")!))
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
            if url.contains("eporner.com"), !url.contains("/login") {
                didFire = true
                onLoginDetected()
            }
        }
    }
}
