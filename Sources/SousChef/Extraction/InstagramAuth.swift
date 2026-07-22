import Foundation
import WebKit

/// Authenticated Instagram caption extraction.
///
/// Logged-out requests hit a login wall for most reels — confirmed on-device, where even a
/// real WKWebView got walled. Once the user signs into Instagram in an in-app WebView (see
/// `InstagramConnectView`), the session cookies live in the shared `WKWebsiteDataStore`.
/// This reads those cookies and calls Instagram's own GraphQL endpoint with them — the same
/// call the website makes — returning the full, structured caption (no truncation, no wall).
///
/// The session stays on the device; it's only used to read captions the user asks to import.
enum InstagramAuth {

    /// Instagram cookies currently in the shared web data store.
    @MainActor
    static func sessionCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { all in
                continuation.resume(returning: all.filter { $0.domain.contains("instagram.com") })
            }
        }
    }

    /// True when a non-empty `sessionid` cookie is present (the user is logged in).
    static func isConnected() async -> Bool {
        await sessionCookies().contains { $0.name == "sessionid" && !$0.value.isEmpty }
    }

    /// Clear the in-app Instagram session (best-effort cookie delete).
    @MainActor
    static func disconnect() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in await sessionCookies() {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                store.delete(cookie) { c.resume() }
            }
        }
    }

    /// The GraphQL `variables` payload for loading a single post. Comment/like counts are
    /// zeroed — we only want the caption. Split out so it can be unit-tested.
    static func graphQLVariables(shortcode: String) -> String {
        #"{"shortcode":"\#(shortcode)","fetch_comment_count":0,"parent_comment_count":0,"#
        + #""child_comment_count":0,"fetch_like_count":0,"fetch_tagged_user_count":null,"#
        + #""fetch_preview_comment_count":0,"has_threaded_comments":true,"#
        + #""hoisted_comment_id":null,"hoisted_reply_id":null}"#
    }

    /// Fetch the caption for a post via authenticated GraphQL. Returns nil when the user
    /// isn't connected or the request fails (caller then falls back to logged-out routes).
    static func fetchCaption(shortcode: String) async -> String? {
        let cookies = await sessionCookies()
        guard cookies.contains(where: { $0.name == "sessionid" && !$0.value.isEmpty }),
              let url = URL(string: "https://www.instagram.com/graphql/query/") else { return nil }

        let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let csrf = cookies.first { $0.name == "csrftoken" }?.value ?? ""

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "doc_id", value: VideoMetadataFetcher.instagramPostDocID),
            URLQueryItem(name: "variables", value: graphQLVariables(shortcode: shortcode)),
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = components.percentEncodedQuery.map { Data($0.utf8) }
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(csrf, forHTTPHeaderField: "X-CSRFToken")
        request.setValue("936619743392459", forHTTPHeaderField: "X-IG-App-ID")
        request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: .ephemeral)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = VideoMetadataFetcher.parseInstagramGraphQLResponse(json),
              let caption = meta.caption, !caption.isEmpty else { return nil }
        return caption
    }
}
