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

    /// Fetch the caption for a post. Tries the media-info API first (stable — no rotating
    /// doc_id), then GraphQL. Returns nil when the user isn't connected or both fail.
    static func fetchCaption(shortcode: String) async -> String? {
        if let caption = await fetchCaptionViaMediaAPI(shortcode: shortcode) { return caption }
        return await fetchCaptionViaGraphQL(shortcode: shortcode)
    }

    /// Instagram shortcodes are base64 (URL-safe alphabet) of the numeric media id. Decode
    /// it so we can hit /api/v1/media/{id}/info/ directly. Returns nil on an unexpected char
    /// or (vanishingly rare) 64-bit overflow.
    static func mediaID(fromShortcode code: String) -> String? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        var index: [Character: UInt64] = [:]
        for (i, c) in alphabet.enumerated() { index[c] = UInt64(i) }
        var id: UInt64 = 0
        for ch in code {
            guard let v = index[ch] else { return nil }
            let (mul, o1) = id.multipliedReportingOverflow(by: 64)
            guard !o1 else { return nil }
            let (add, o2) = mul.addingReportingOverflow(v)
            guard !o2 else { return nil }
            id = add
        }
        return String(id)
    }

    /// The stable authenticated route: Instagram's internal media-info API, keyed by the
    /// media id derived from the shortcode — no rotating GraphQL doc_id involved. This is
    /// the route that works today (verified end-to-end with the desktop tool).
    /// Image URLs for a carousel post's slides, highest-resolution first, in slide order.
    /// Empty for a single-image post or a reel.
    ///
    /// Many recipe carousels put the ingredients and method IN the slides and leave the caption
    /// as a one-liner, so this is the only way to reach those recipes. Uses the same
    /// authenticated media-info call as the caption, so it costs one request we may already
    /// have made.
    static func fetchCarouselImageURLs(shortcode: String) async -> [URL] {
        guard let json = await fetchMediaInfo(shortcode: shortcode),
              let items = json["items"] as? [[String: Any]], let first = items.first else {
            return []
        }
        return carouselImageURLs(fromItem: first)
    }

    /// Pull slide image URLs out of a media-info item. Split out so it can be unit-tested
    /// against a captured payload without a network call or a session.
    static func carouselImageURLs(fromItem item: [String: Any]) -> [URL] {
        guard let media = item["carousel_media"] as? [[String: Any]] else { return [] }
        return media.compactMap { slide -> URL? in
            guard let versions = slide["image_versions2"] as? [String: Any],
                  let candidates = versions["candidates"] as? [[String: Any]] else { return nil }
            // Candidates are ordered largest-first; take the biggest by area anyway rather than
            // trusting the order, since OCR accuracy tracks resolution.
            let best = candidates.max { a, b in
                let areaA = ((a["width"] as? Int) ?? 0) * ((a["height"] as? Int) ?? 0)
                let areaB = ((b["width"] as? Int) ?? 0) * ((b["height"] as? Int) ?? 0)
                return areaA < areaB
            }
            guard let urlString = best?["url"] as? String else { return nil }
            return URL(string: urlString)
        }
    }

    /// The raw media-info payload — shared by the caption and carousel readers.
    private static func fetchMediaInfo(shortcode: String) async -> [String: Any]? {
        let cookies = await sessionCookies()
        guard cookies.contains(where: { $0.name == "sessionid" && !$0.value.isEmpty }),
              let mediaID = mediaID(fromShortcode: shortcode),
              let url = URL(string: "https://www.instagram.com/api/v1/media/\(mediaID)/info/")
        else { return nil }

        var request = URLRequest(url: url)
        request.setValue(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "),
                         forHTTPHeaderField: "Cookie")
        request.setValue(cookies.first { $0.name == "csrftoken" }?.value ?? "",
                         forHTTPHeaderField: "X-CSRFToken")
        request.setValue("936619743392459", forHTTPHeaderField: "X-IG-App-ID")
        request.setValue("https://www.instagram.com/p/\(shortcode)/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: .ephemeral)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    static func fetchCaptionViaMediaAPI(shortcode: String) async -> String? {
        let cookies = await sessionCookies()
        guard cookies.contains(where: { $0.name == "sessionid" && !$0.value.isEmpty }),
              let mediaID = mediaID(fromShortcode: shortcode),
              let url = URL(string: "https://www.instagram.com/api/v1/media/\(mediaID)/info/")
        else { return nil }

        var request = URLRequest(url: url)
        request.setValue(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "),
                         forHTTPHeaderField: "Cookie")
        request.setValue(cookies.first { $0.name == "csrftoken" }?.value ?? "",
                         forHTTPHeaderField: "X-CSRFToken")
        request.setValue("936619743392459", forHTTPHeaderField: "X-IG-App-ID")
        request.setValue("https://www.instagram.com/reel/\(shortcode)/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: .ephemeral)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]], let first = items.first,
              let caption = (first["caption"] as? [String: Any])?["text"] as? String,
              !caption.isEmpty else { return nil }
        return caption
    }

    /// Legacy authenticated GraphQL route. Instagram rotates the doc_id, so this dies
    /// periodically — kept as a fallback behind the media API.
    static func fetchCaptionViaGraphQL(shortcode: String) async -> String? {
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
