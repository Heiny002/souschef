import SwiftUI
import WebKit

/// One-time "Connect Instagram" login. Shows Instagram's real login page in a WebView using
/// the shared data store, so the resulting session cookies become available to
/// `InstagramAuth` for authenticated caption extraction. The session stays on-device.
struct InstagramConnectView: View {
    @Environment(\.dismiss) private var dismiss
    var onConnected: () -> Void = {}

    @State private var connected = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.scBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    banner
                    InstagramLoginWebView { connected = true }
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle("Connect Instagram")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.scBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Color.scTextSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish() }
                        .foregroundStyle(connected ? Color.scAccent : Color.scTextSecondary)
                        .disabled(!connected)
                }
            }
            .onChange(of: connected) { _, isOn in
                if isOn { finish() }   // auto-dismiss the moment login is detected
            }
        }
    }

    private var banner: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "lock.shield")
                .foregroundStyle(Color.scAccent)
            Text("Sign in to import recipes from reels. Your Instagram session stays on this device.")
                .font(.scCaption)
                .foregroundStyle(Color.scTextSecondary)
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.scSurface)
    }

    private func finish() {
        onConnected()
        dismiss()
    }
}

/// Instagram login page in a WebView. Reports success once the user lands on an
/// authenticated page and a `sessionid` cookie exists.
private struct InstagramLoginWebView: UIViewRepresentable {
    let onDetectLogin: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // shared with InstagramAuth
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        if let url = URL(string: "https://www.instagram.com/accounts/login/") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDetectLogin: onDetectLogin) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onDetectLogin: () -> Void
        private var reported = false

        init(onDetectLogin: @escaping () -> Void) { self.onDetectLogin = onDetectLogin }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !reported, let url = webView.url,
                  url.host?.contains("instagram.com") == true else { return }
            let path = url.path
            // Still on a login / verification page → not done yet.
            guard !path.contains("login"), !path.contains("challenge"),
                  !path.contains("accounts/onetap"), !path.contains("two_factor") else { return }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let hasSession = cookies.contains {
                    $0.name == "sessionid" && !$0.value.isEmpty && $0.domain.contains("instagram.com")
                }
                if hasSession {
                    self.reported = true
                    DispatchQueue.main.async { self.onDetectLogin() }
                }
            }
        }
    }
}
