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
        let stored: [HTTPCookie] = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { all in
                continuation.resume(returning: all.filter { $0.domain.contains("instagram.com") })
            }
        }
        #if os(macOS)
        // The macOS harness has no "Connect Instagram" web login; fall back to a Netscape
        // cookies.txt (SOUSCHEF_COOKIES env var, or ./cookies.txt) — the same file the
        // desktop debug tools use.
        if !stored.contains(where: { $0.name == "sessionid" && !$0.value.isEmpty }) {
            let path = ProcessInfo.processInfo.environment["SOUSCHEF_COOKIES"] ?? "cookies.txt"
            let fromFile = cookiesFromNetscapeFile(atPath: path)
            if fromFile.contains(where: { $0.name == "sessionid" }) { return fromFile }
        }
        #endif
        return stored
    }

    #if os(macOS)
    /// Parse a Netscape-format cookies.txt into HTTPCookies for instagram.com.
    static func cookiesFromNetscapeFile(atPath path: String) -> [HTTPCookie] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return content.components(separatedBy: .newlines).compactMap { line -> HTTPCookie? in
            guard !line.hasPrefix("#"), !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 7, parts[0].lowercased().contains("instagram") else { return nil }
            return HTTPCookie(properties: [
                .domain: ".instagram.com", .path: "/", .name: parts[5], .value: parts[6],
            ])
        }
    }
    #endif

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
        // Rung 1: the authed media-info route — best quality candidates, needs a session.
        if let json = await fetchMediaInfo(shortcode: shortcode),
           let items = json["items"] as? [[String: Any]], let first = items.first {
            let urls = carouselImageURLs(fromItem: first)
            if !urls.isEmpty { return urls }
        }
        // Rung 2: the public EMBED page's gql_data sidecar — the logged-out route that makes
        // TikTok photo posts work. Without this, a missing/expired Instagram session silently
        // reduced a carousel post to its caption (live failure: the same collection post
        // extracted via TikTok's embed and failed via Instagram).
        return await fetchEmbedSidecarURLs(shortcode: shortcode)
    }

    /// Slide URLs from the embed page's inlined gql_data, no session required.
    static func fetchEmbedSidecarURLs(shortcode: String) async -> [URL] {
        guard let url = URL(string: "https://www.instagram.com/p/\(shortcode)/embed/captioned/") else {
            return []
        }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/120.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15
        let session = URLSession(configuration: .ephemeral)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8),
              let gql = VideoMetadataFetcher.extractEmbedGQLData(fromEmbedHTML: html) else {
            return []
        }
        return sidecarImageURLs(fromGQLData: gql)
    }

    /// Pull sidecar (carousel) slide URLs out of an embed page's gql_data. Pure + testable.
    /// Shape: shortcode_media.edge_sidecar_to_children.edges[].node — prefer the largest
    /// display_resources entry, fall back to display_url.
    static func sidecarImageURLs(fromGQLData gql: [String: Any]) -> [URL] {
        let media = (gql["shortcode_media"] ?? gql["xdt_shortcode_media"]) as? [String: Any]
        guard let sidecar = media?["edge_sidecar_to_children"] as? [String: Any],
              let edges = sidecar["edges"] as? [[String: Any]] else { return [] }
        return edges.compactMap { edge -> URL? in
            guard let node = edge["node"] as? [String: Any] else { return nil }
            if let resources = node["display_resources"] as? [[String: Any]] {
                let best = resources.max { a, b in
                    let areaA = ((a["config_width"] as? Int) ?? 0) * ((a["config_height"] as? Int) ?? 0)
                    let areaB = ((b["config_width"] as? Int) ?? 0) * ((b["config_height"] as? Int) ?? 0)
                    return areaA < areaB
                }
                if let src = best?["src"] as? String, let url = URL(string: src) { return url }
            }
            guard let display = node["display_url"] as? String else { return nil }
            return URL(string: display)
        }
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

    // MARK: - Creator comments

    /// Comment texts authored by the post's CREATOR (pinned/first comments included), in
    /// the order Instagram returns them. "Recipe in the comments" is one of the most common
    /// Instagram patterns — the caption is a hook and the recipe lives in the creator's own
    /// comment. Only the creator's comments are read: everyone else's are noise and
    /// occasionally adversarial. Empty when not connected or the fetch fails.
    static func fetchCreatorComments(shortcode: String) async -> [String] {
        guard let info = await fetchMediaInfo(shortcode: shortcode),
              let items = info["items"] as? [[String: Any]], let first = items.first,
              let owner = pkString((first["user"] as? [String: Any])?["pk"]),
              let mediaID = mediaID(fromShortcode: shortcode),
              let url = URL(string:
                "https://www.instagram.com/api/v1/media/\(mediaID)/comments/?can_support_threading=true")
        else { return [] }

        var texts: [String] = []
        if let json = await authedJSON(url: url,
                                       referer: "https://www.instagram.com/p/\(shortcode)/"),
           let comments = json["comments"] as? [[String: Any]] {
            texts = creatorCommentTexts(fromComments: comments, ownerPK: owner)
        }
        // The media-info payload carries a short comment preview — a lifeline if the
        // comments endpoint's shape shifts under us.
        if texts.isEmpty, let preview = first["preview_comments"] as? [[String: Any]] {
            texts = creatorCommentTexts(fromComments: preview, ownerPK: owner)
        }
        // A creator rarely needs more than a couple of comments for a recipe; the cap
        // bounds the downstream parse work on comment-happy accounts.
        return Array(texts.prefix(6))
    }

    /// Filter a comments array down to the creator's own texts. Pure + testable.
    static func creatorCommentTexts(fromComments comments: [[String: Any]],
                                    ownerPK: String) -> [String] {
        comments.compactMap { comment -> String? in
            guard pkString((comment["user"] as? [String: Any])?["pk"]) == ownerPK,
                  let text = comment["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return text
        }
    }

    /// Instagram serializes user pks inconsistently (number or string, 64-bit). Normalize
    /// to a string so owner comparison works across payload variants.
    static func pkString(_ value: Any?) -> String? {
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    // MARK: - Video URL (for burned-in-caption OCR)

    /// Highest-resolution video URL for a video post — nil for image posts or without a
    /// session. Feeds the frame-OCR rung that reads burned-in captions.
    static func fetchVideoURL(shortcode: String) async -> URL? {
        guard let info = await fetchMediaInfo(shortcode: shortcode),
              let items = info["items"] as? [[String: Any]], let first = items.first
        else { return nil }
        return videoURL(fromMediaItem: first)
    }

    /// Best video_versions candidate by pixel area. Pure + testable.
    static func videoURL(fromMediaItem item: [String: Any]) -> URL? {
        guard let versions = item["video_versions"] as? [[String: Any]] else { return nil }
        let best = versions.max { a, b in
            ((a["width"] as? Int) ?? 0) * ((a["height"] as? Int) ?? 0)
                < ((b["width"] as? Int) ?? 0) * ((b["height"] as? Int) ?? 0)
        }
        guard let urlString = best?["url"] as? String else { return nil }
        return URL(string: urlString)
    }

    // MARK: - Authed plumbing

    /// The raw media-info payload — shared by the caption, carousel, and comment readers.
    private static func fetchMediaInfo(shortcode: String) async -> [String: Any]? {
        guard let mediaID = mediaID(fromShortcode: shortcode),
              let url = URL(string: "https://www.instagram.com/api/v1/media/\(mediaID)/info/")
        else { return nil }
        return await authedJSON(url: url, referer: "https://www.instagram.com/p/\(shortcode)/")
    }

    /// GET an Instagram internal API URL with the user's session cookies. nil when not
    /// connected, on a non-2xx, or on a non-JSON body.
    private static func authedJSON(url: URL, referer: String) async -> [String: Any]? {
        let cookies = await sessionCookies()
        guard cookies.contains(where: { $0.name == "sessionid" && !$0.value.isEmpty })
        else { return nil }

        var request = URLRequest(url: url)
        request.setValue(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "),
                         forHTTPHeaderField: "Cookie")
        request.setValue(cookies.first { $0.name == "csrftoken" }?.value ?? "",
                         forHTTPHeaderField: "X-CSRFToken")
        request.setValue("936619743392459", forHTTPHeaderField: "X-IG-App-ID")
        request.setValue(referer, forHTTPHeaderField: "Referer")
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
