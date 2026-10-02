import SwiftUI
import WebKit

/// GOG's own sign-in page in a web view; we only watch for the redirect carrying the auth code.
/// Uses a non-persistent data store so no GOG cookies are left behind.
struct GOGLoginView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to GOG").font(Theme.font(18, .bold))
                Spacer()
                Button("Cancel") { app.showGOGLogin = false }.buttonStyle(PillButtonStyle(prominent: false))
            }
            .padding(16)
            GOGWebView { code in
                app.showGOGLogin = false
                Task { await app.completeGOGLogin(code: code) }
            }
        }
        .frame(width: 520, height: 700)
        .background(Theme.surface)
    }
}

private struct GOGWebView: NSViewRepresentable {
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: GOGService.loginURL))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, url.absoluteString.hasPrefix("https://embed.gog.com/on_login_success"),
               let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                   .queryItems?.first(where: { $0.name == "code" })?.value {
                decisionHandler(.cancel)
                onCode(code)
                return
            }
            decisionHandler(.allow)
        }
    }
}
