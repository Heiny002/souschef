import Foundation
import WebKit

/// On-device Instagram caption fetch using a real browser engine.
///
/// Raw `URLSession` requests to Instagram get 403'd / login-walled from most networks. A
/// `WKWebView` is the same WebKit engine Safari uses — real TLS fingerprint, JavaScript
/// execution, a cookie jar — so Instagram serves it the link-preview metadata
/// (`og:description`, JSON-LD) it refuses to give a bare HTTP client. This is slower and
/// heavier than a URLSession call, so the pipeline only falls back to it when the fast
/// routes come back empty.
///
/// Note: `og:description` is often truncated by Instagram, so a very long recipe may come
/// back partial — still far better than nothing, and the user edits it in Review. Getting
/// the *full* caption reliably needs a logged-in session inside the web view (a future
/// step); this version works logged-out for public posts.
@MainActor
enum InstagramWebViewExtractor {

    /// Load `url` in an off-screen web view and return the caption parsed from its metadata,
    /// or nil on timeout / failure / no useful text.
    static func caption(from url: URL, timeout: TimeInterval = 12) async -> String? {
        let driver = WebViewDriver()
        return await driver.run(url: url, timeout: timeout)
    }
}

/// One-shot driver: owns a web view and a continuation for a single extraction, so there's
/// no shared mutable state to race. Retained by the `await` frame in `caption(from:)` for
/// its whole lifetime (WKWebView holds its navigationDelegate weakly).
@MainActor
private final class WebViewDriver: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<String?, Never>?
    private var webView: WKWebView?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    private static let mobileUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    func run(url: URL, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            self.continuation = cont

            let config = WKWebViewConfiguration()
            // Persistent store: if a logged-in-session feature is added later, cookies stick.
            config.websiteDataStore = .default()
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
            wv.customUserAgent = Self.mobileUA
            wv.navigationDelegate = self
            self.webView = wv

            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(nil)
            }

            wv.load(URLRequest(url: url))
        }
    }

    private func finish(_ caption: String?) {
        guard !finished else { return }   // timeout vs didFinish vs didFail — first wins
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        continuation?.resume(returning: caption)
        continuation = nil
    }

    // Read the caption out of the loaded page's head. og:description and JSON-LD live in
    // <head>, so they're present at didFinish without waiting on the (obfuscated) render.
    private static let extractionJS = """
    (function () {
      var out = { og: "", ld: "" };
      var og = document.querySelector('meta[property="og:description"]');
      if (og) out.og = og.content || "";
      var ld = document.querySelector('script[type="application/ld+json"]');
      if (ld) out.ld = ld.textContent || "";
      return JSON.stringify(out);
    })();
    """

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(Self.extractionJS) { [weak self] result, _ in
            self?.finish(InstagramCaptionParser.parse(jsResult: result as? String))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }
}

/// Pure parsing of the `{og, ld}` JSON the page-scraping JavaScript returns. Kept separate
/// from the web view so it's unit-testable without WebKit.
enum InstagramCaptionParser {

    static func parse(jsResult: String?) -> String? {
        guard let jsResult,
              let data = jsResult.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // JSON-LD tends to carry the fuller caption; prefer it, fall back to og:description.
        if let ld = obj["ld"] as? String, let caption = captionFromLDJSON(ld) {
            return caption
        }
        if let og = obj["og"] as? String, let caption = cleanOGDescription(og) {
            return caption
        }
        return nil
    }

    /// Pull a caption/description/articleBody out of a JSON-LD block (object or array).
    static func captionFromLDJSON(_ ld: String) -> String? {
        guard let data = ld.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }

        func fromDict(_ d: [String: Any]) -> String? {
            for key in ["caption", "articleBody", "description"] {
                if let v = d[key] as? String, isUseful(v) { return v }
            }
            return nil
        }

        if let d = obj as? [String: Any] {
            if let c = fromDict(d) { return c }
            if let graph = d["@graph"] as? [[String: Any]] {
                for node in graph { if let c = fromDict(node) { return c } }
            }
        }
        if let arr = obj as? [[String: Any]] {
            for node in arr { if let c = fromDict(node) { return c } }
        }
        return nil
    }

    /// og:description is usually `"N likes, M comments - user on Date: \"caption\""`. Strip
    /// that engagement/attribution prefix to the caption; if the pattern is absent, treat the
    /// whole string as the caption.
    static func cleanOGDescription(_ og: String) -> String? {
        var s = og
        for delimiter in [": \u{201C}", ": \""] {   // straight and curly opening quote
            if let r = s.range(of: delimiter) {
                s = String(s[r.upperBound...])
                break
            }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D} \n\r\t"))
        return isUseful(s) ? s : nil
    }

    /// Reject empty/too-short strings and Instagram's generic logged-out boilerplate, so a
    /// login wall doesn't masquerade as a caption.
    static func isUseful(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 8 else { return false }
        let lower = t.lowercased()
        let boilerplate = [
            "see photos and videos", "log in to instagram", "sign up to see",
            "see instagram photos and videos",
        ]
        return !boilerplate.contains { lower.contains($0) }
    }
}
