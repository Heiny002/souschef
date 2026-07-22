import Foundation

/// SC-031: Fetches video caption/title metadata via oEmbed endpoints.
/// No auth required. Returns caption text for recipe extraction.
struct VideoMetadata {
    let title: String?
    let authorName: String?
    let authorURL: String?    // SC-071: Creator's profile URL from oEmbed
    let caption: String?      // Often contains recipe outline
    let thumbnailURL: String?
}

actor VideoMetadataFetcher {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)
    }

    func fetch(videoURL: String) async throws -> VideoMetadata {
        let sourceType = URLRouter.classify(videoURL)
        switch sourceType {
        case .tikTok:
            return try await fetchOEmbed(endpoint: "https://www.tiktok.com/oembed", videoURL: videoURL)
        case .youTube:
            return try await fetchOEmbed(endpoint: "https://www.youtube.com/oembed", videoURL: videoURL)
        case .instagram:
            // Ordered by how reliably each survives Instagram's anti-scraping (the chain
            // InstaFix uses in production for Discord/Telegram embeds):
            if let code = Self.instagramShortcode(from: videoURL) {
                // 1. The public EMBED page — built for third-party sites, so it serves
                //    logged-out requests (even from server IPs). Caption lives in an
                //    inlined gql_data JSON blob, with rendered HTML as a second target.
                if let meta = try? await fetchInstagramEmbedMeta(shortcode: code),
                   meta.caption?.isEmpty == false {
                    return meta
                }
                // 2. The web GraphQL endpoint Instagram's own site calls. The doc_id is
                //    rotated by Instagram now and then — update it when this stops working.
                if let meta = try? await fetchInstagramGraphQLMeta(shortcode: code),
                   meta.caption?.isEmpty == false {
                    return meta
                }
                // 3. Legacy ?__a=1 JSON API (mostly login-walled now, but cheap to try).
                if let meta = try? await fetchInstagramAPIMeta(shortcode: code),
                   meta.caption?.isEmpty == false {
                    return meta
                }
            }
            // 4. Fall back to scraping og:description from the page HTML.
            if let meta = try? await fetchInstagramPageMeta(videoURL: videoURL) {
                return meta
            }
            // 5. Last resort: legacy oEmbed (needs auth now, but harmless to try).
            return try await fetchOEmbed(endpoint: "https://api.instagram.com/oembed", videoURL: videoURL)
        case .webPage:
            throw VideoMetadataError.unsupportedSource
        }
    }

    // MARK: - Instagram HTML scraping

    private func fetchInstagramPageMeta(videoURL: String) async throws -> VideoMetadata {
        guard let url = URL(string: videoURL) else { throw VideoMetadataError.invalidURL }

        var request = URLRequest(url: url)
        // Use a mobile browser UA so Instagram returns a full HTML page
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw VideoMetadataError.apiError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw VideoMetadataError.malformedResponse
        }

        let ogDescription = extractOGContent(from: html, property: "og:description")
        let ogTitle       = extractOGContent(from: html, property: "og:title")
        let ogURL         = extractOGContent(from: html, property: "og:url")
        let thumb         = extractOGContent(from: html, property: "og:image")

        guard ogDescription != nil || ogTitle != nil else { throw VideoMetadataError.malformedResponse }

        // Extract real name from og:title — format: "Real Name on Instagram: 'caption...'"
        // The part before " on Instagram:" is the creator's display name.
        var realName: String? = nil
        if let t = ogTitle {
            let namePattern = #"^(.+?)\s+on\s+Instagram"#
            if let re = try? NSRegularExpression(pattern: namePattern, options: .caseInsensitive),
               let match = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
               let range = Range(match.range(at: 1), in: t) {
                realName = String(t[range]).trimmingCharacters(in: .whitespaces)
            }
        }

        // Extract handle (username) for the author profile URL.
        // Priority:
        //   1. og:url path — most reliable: instagram.com/{username}/reel/...
        //   2. Scan HTML for instagram.com/{username}/ occurrences
        let reserved = Set(["reel", "p", "explore", "accounts", "login",
                            "direct", "stories", "tv", "ar", "static", "api", "graphql",
                            "rsrc", "rsrc.php"])
        let authorURL: String? = {
            // Method 1: og:url contains the canonical URL with the real username in path
            if let pageURL = ogURL, let url = URL(string: pageURL) {
                let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
                if let handle = parts.first, handle.count >= 2, !reserved.contains(handle.lowercased()) {
                    return "https://www.instagram.com/\(handle)/"
                }
            }
            // Method 2: scan ALL instagram.com/username/ occurrences as fallback
            let profilePattern = #"instagram\.com/([A-Za-z0-9_.]{3,30})/"#
            if let re = try? NSRegularExpression(pattern: profilePattern) {
                let nsRange = NSRange(html.startIndex..., in: html)
                for match in re.matches(in: html, options: [], range: nsRange) {
                    guard let r = Range(match.range(at: 1), in: html) else { continue }
                    let candidate = String(html[r])
                    if !reserved.contains(candidate.lowercased()) {
                        return "https://www.instagram.com/\(candidate)/"
                    }
                }
            }
            return nil
        }()

        // Caption: prefer og:description (has handle + like count + actual caption text)
        // og:title also contains part of the caption, use as fallback
        let caption = ogDescription ?? ogTitle

        return VideoMetadata(
            title: ogTitle,
            authorName: realName,
            authorURL: authorURL,
            caption: caption,
            thumbnailURL: thumb
        )
    }

    // MARK: - Instagram embed page (most reliable logged-out route)

    private static let desktopUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    /// Fetch `/p/{shortcode}/embed/captioned/` — the page Instagram serves to third-party
    /// sites that embed posts. Because it exists FOR logged-out rendering, it is the route
    /// that keeps working when everything else gets a login wall. The post data (caption,
    /// owner, thumbnail) is inlined as an escaped `gql_data` JSON blob inside a script; the
    /// rendered `.Caption` HTML is parsed as a fallback when that blob is absent.
    private func fetchInstagramEmbedMeta(shortcode: String) async throws -> VideoMetadata {
        guard let url = URL(string: "https://www.instagram.com/p/\(shortcode)/embed/captioned/") else {
            throw VideoMetadataError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue(Self.desktopUA, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw VideoMetadataError.apiError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw VideoMetadataError.malformedResponse
        }

        if let gql = Self.extractEmbedGQLData(fromEmbedHTML: html),
           let meta = Self.parseInstagramJSON(["graphql": gql]) {
            return meta
        }
        if let caption = Self.extractEmbedCaption(fromEmbedHTML: html) {
            return VideoMetadata(
                title: caption, authorName: nil, authorURL: nil,
                caption: caption, thumbnailURL: nil)
        }
        throw VideoMetadataError.malformedResponse
    }

    /// Pull the `gql_data` object out of embed-page HTML. It usually appears JSON-escaped
    /// inside a JS string (`\"gql_data\":{…}`), occasionally unescaped. Escaped fragments
    /// are decoded by parsing them as a JSON string literal — that handles every escape
    /// correctly without hand-rolled unescaping.
    static func extractEmbedGQLData(fromEmbedHTML html: String) -> [String: Any]? {
        // Escaped form.
        if let start = html.range(of: #"\"gql_data\":"#)?.upperBound {
            for fragment in Self.jsonObjectCandidates(in: html, from: start, escaped: true) {
                let quoted = "\"\(fragment)\""
                if let unescaped = (try? JSONSerialization.jsonObject(
                        with: Data(quoted.utf8), options: [.fragmentsAllowed])) as? String,
                   let obj = (try? JSONSerialization.jsonObject(with: Data(unescaped.utf8)))
                        as? [String: Any] {
                    return obj
                }
            }
        }
        // Unescaped form.
        if let start = html.range(of: #""gql_data":"#)?.upperBound {
            for fragment in Self.jsonObjectCandidates(in: html, from: start, escaped: false) {
                if let obj = (try? JSONSerialization.jsonObject(with: Data(fragment.utf8)))
                    as? [String: Any] {
                    return obj
                }
            }
        }
        return nil
    }

    /// Candidate substrings for the JSON object starting at `start`, tried in order until
    /// one parses. Brace depth is counted naively (string contents included), which is
    /// correct unless the caption itself contains unbalanced braces — so every later
    /// closing brace at depth ≤ 0 is offered as a further candidate, and a cut at the
    /// `hostname` sibling key (which follows gql_data in the context object) rounds out
    /// the list. The double-parse caller rejects wrong cuts, so extras are harmless.
    private static func jsonObjectCandidates(
        in text: String, from start: String.Index, escaped: Bool
    ) -> [String] {
        var candidates: [String] = []
        var depth = 0
        var idx = start
        while idx < text.endIndex, candidates.count < 8 {
            let c = text[idx]
            if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth <= 0 { candidates.append(String(text[start...idx])) }
            } else if c == "<" {
                break   // ran off the script into HTML
            }
            idx = text.index(after: idx)
        }
        let hostMarker = escaped ? #",\"hostname\""# : #","hostname""#
        if let host = text.range(of: hostMarker, range: start..<text.endIndex) {
            candidates.append(String(text[start..<host.lowerBound]))
        }
        return candidates
    }

    /// Fallback: pull the caption out of the embed page's rendered `.Caption` div —
    /// username anchor and comments block removed, `<br>` kept as line breaks so the
    /// "Ingredients / Instructions" structure survives for the recipe parser.
    static func extractEmbedCaption(fromEmbedHTML html: String) -> String? {
        guard let capMarker = html.range(of: #"class="Caption""#),
              let openEnd = html.range(of: ">", range: capMarker.upperBound..<html.endIndex)
        else { return nil }
        var segment = String(html[openEnd.upperBound...])

        if let comments = segment.range(of: #"class="CaptionComments""#) {
            let prefix = segment[..<comments.lowerBound]
            if let tagStart = prefix.range(of: "<div", options: .backwards) {
                segment = String(prefix[..<tagStart.lowerBound])
            } else {
                segment = String(prefix)
            }
        } else if let end = segment.range(of: "</div>") {
            segment = String(segment[..<end.lowerBound])
        }

        // Drop the leading username anchor.
        if let aStart = segment.range(of: "<a"),
           let aEnd = segment.range(of: "</a>"),
           aStart.lowerBound < aEnd.lowerBound {
            segment.removeSubrange(aStart.lowerBound..<aEnd.upperBound)
        }
        for br in ["<br />", "<br/>", "<br>"] {
            segment = segment.replacingOccurrences(of: br, with: "\n")
        }
        if let re = try? NSRegularExpression(pattern: "<[^>]+>") {
            segment = re.stringByReplacingMatches(
                in: segment, range: NSRange(segment.startIndex..., in: segment), withTemplate: "")
        }
        let cleaned = segment.htmlEntityDecoded
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Instagram web GraphQL

    /// The persisted query id Instagram's web app sends for "load this post". Instagram
    /// rotates it occasionally as an anti-scraping measure — when this layer stops
    /// returning data, pull the current value from a fresh instagram.com page load (or
    /// InstaFix's source, which tracks it).
    static let instagramPostDocID = "25531498899829322"

    private func fetchInstagramGraphQLMeta(shortcode: String) async throws -> VideoMetadata {
        guard let url = URL(string: "https://www.instagram.com/graphql/query/") else {
            throw VideoMetadataError.invalidURL
        }
        let variables = #"{"shortcode":"\#(shortcode)","fetch_comment_count":40,"#
            + #""parent_comment_count":24,"child_comment_count":3,"fetch_like_count":10,"#
            + #""fetch_tagged_user_count":null,"fetch_preview_comment_count":2,"#
            + #""has_threaded_comments":true,"hoisted_comment_id":null,"hoisted_reply_id":null}"#

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "doc_id", value: Self.instagramPostDocID),
            URLQueryItem(name: "variables", value: variables),
            URLQueryItem(name: "fb_api_req_friendly_name", value: "PolarisPostActionLoadPostQueryQuery"),
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = components.percentEncodedQuery.map { Data($0.utf8) }
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.desktopUA, forHTTPHeaderField: "User-Agent")
        request.setValue("936619743392459", forHTTPHeaderField: "X-IG-App-ID")
        request.setValue("PolarisPostActionLoadPostQueryQuery", forHTTPHeaderField: "X-FB-Friendly-Name")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("https://www.instagram.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw VideoMetadataError.apiError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = Self.parseInstagramGraphQLResponse(json) else {
            throw VideoMetadataError.malformedResponse
        }
        return meta
    }

    /// GraphQL responses carry the post under `data.xdt_shortcode_media` (newer) or
    /// `data.shortcode_media`; both share the classic media shape, so re-wrap and reuse
    /// the standard parser.
    static func parseInstagramGraphQLResponse(_ json: [String: Any]) -> VideoMetadata? {
        guard let dataDict = json["data"] as? [String: Any] else { return nil }
        let media = dataDict["xdt_shortcode_media"] as? [String: Any]
            ?? dataDict["shortcode_media"] as? [String: Any]
        guard let media else { return nil }
        return parseInstagramJSON(["graphql": ["shortcode_media": media]])
    }

    // MARK: - Instagram web JSON API (the yt-dlp technique)

    /// Instagram's website loads post data from this endpoint using its web "app id" header.
    /// For public posts it returns JSON that includes the full caption text — which is where
    /// creators write the recipe. Undocumented and a moving target, so every failure mode
    /// falls back to the HTML scrape; treat it as best-effort, not guaranteed.
    private func fetchInstagramAPIMeta(shortcode: String) async throws -> VideoMetadata {
        guard let url = URL(string: "https://www.instagram.com/p/\(shortcode)/?__a=1&__d=dis") else {
            throw VideoMetadataError.invalidURL
        }
        var request = URLRequest(url: url)
        // 936619743392459 is the public web app id Instagram's own site sends. Without it the
        // endpoint redirects logged-out requests to a login page instead of returning JSON.
        request.setValue("936619743392459", forHTTPHeaderField: "X-IG-App-ID")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw VideoMetadataError.apiError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = Self.parseInstagramJSON(json) else {
            throw VideoMetadataError.malformedResponse
        }
        return meta
    }

    /// Pull the shortcode from a `/reel/`, `/reels/`, `/p/` or `/tv/` Instagram URL.
    static func instagramShortcode(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        let markers: Set<String> = ["reel", "reels", "p", "tv"]
        for (i, comp) in parts.enumerated() where markers.contains(comp.lowercased()) {
            if i + 1 < parts.count { return parts[i + 1] }
        }
        return nil
    }

    /// Parse caption / author / thumbnail out of Instagram's JSON, tolerating both the newer
    /// `items[]` shape and the older `graphql.shortcode_media` shape.
    static func parseInstagramJSON(_ json: [String: Any]) -> VideoMetadata? {
        // Newer shape: { items: [ { caption:{text}, user:{username,full_name},
        //                           image_versions2:{candidates:[{url}]} } ] }
        if let items = json["items"] as? [[String: Any]],
           let item = items.first,
           let caption = (item["caption"] as? [String: Any])?["text"] as? String,
           !caption.isEmpty {
            let user = item["user"] as? [String: Any]
            let username = user?["username"] as? String
            let thumb = ((item["image_versions2"] as? [String: Any])?["candidates"]
                as? [[String: Any]])?.first?["url"] as? String
            return VideoMetadata(
                title: caption,
                authorName: user?["full_name"] as? String,
                authorURL: username.map { "https://www.instagram.com/\($0)/" },
                caption: caption,
                thumbnailURL: thumb)
        }
        // Older shape: { graphql: { shortcode_media: {
        //   edge_media_to_caption:{edges:[{node:{text}}]}, owner:{username,full_name}, display_url } } }
        let media = (json["graphql"] as? [String: Any])?["shortcode_media"] as? [String: Any]
            ?? (json["data"] as? [String: Any])?["shortcode_media"] as? [String: Any]
        if let media,
           let edges = (media["edge_media_to_caption"] as? [String: Any])?["edges"] as? [[String: Any]],
           let caption = (edges.first?["node"] as? [String: Any])?["text"] as? String,
           !caption.isEmpty {
            let owner = media["owner"] as? [String: Any]
            let username = owner?["username"] as? String
            return VideoMetadata(
                title: caption,
                authorName: owner?["full_name"] as? String,
                authorURL: username.map { "https://www.instagram.com/\($0)/" },
                caption: caption,
                thumbnailURL: media["display_url"] as? String)
        }
        return nil
    }

    /// Extract the `content` attribute of a `<meta property="..." content="...">` tag.
    private func extractOGContent(from html: String, property: String) -> String? {
        // Try both attribute orderings Instagram might use
        let patterns = [
            "property=[\"']\(NSRegularExpression.escapedPattern(for: property))[\"'][^>]+content=[\"']([^\"']*)[\"']",
            "content=[\"']([^\"']*)[\"'][^>]+property=[\"']\(NSRegularExpression.escapedPattern(for: property))[\"']",
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            return String(html[range]).htmlEntityDecoded
        }
        return nil
    }

    // MARK: - Private

    private func fetchOEmbed(endpoint: String, videoURL: String) async throws -> VideoMetadata {
        // URLComponents percent-encodes the value properly. The old manual encoding used
        // .urlQueryAllowed, which leaves "&" unescaped — a video URL containing query
        // params ("watch?v=…&t=30") was truncated at the first "&" server-side (audit medium).
        guard var components = URLComponents(string: endpoint) else {
            throw VideoMetadataError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "url", value: videoURL),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else {
            throw VideoMetadataError.invalidURL
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw VideoMetadataError.apiError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VideoMetadataError.malformedResponse
        }

        // TikTok and Instagram put the caption in "title" field
        // YouTube puts the video title in "title" and description isn't returned via oEmbed
        let title = dict["title"] as? String
        let authorName = dict["author_name"] as? String
        let authorURL = dict["author_url"] as? String  // SC-071

        // TikTok puts the full caption (often with recipe) in "title"
        // We treat it as caption since it's the closest we get without transcription
        let caption = dict["title"] as? String

        let thumbnailURL = dict["thumbnail_url"] as? String

        return VideoMetadata(
            title: title,
            authorName: authorName,
            authorURL: authorURL,
            caption: caption,
            thumbnailURL: thumbnailURL
        )
    }
}

// MARK: - HTML entity decoding

private extension String {
    var htmlEntityDecoded: String {
        var s = self
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&#x2F;", "/"), ("&#x27;", "'"),
        ]
        for (entity, char) in entities { s = s.replacingOccurrences(of: entity, with: char) }
        // Numeric entities &#NNN;
        if let re = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let matches = re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed()
            for match in matches {
                if let r = Range(match.range(at: 1), in: s),
                   let code = UInt32(s[r]),
                   let scalar = Unicode.Scalar(code) {
                    let fullRange = Range(match.range, in: s)!
                    s.replaceSubrange(fullRange, with: String(scalar))
                }
            }
        }
        return s
    }
}

enum VideoMetadataError: LocalizedError {
    case unsupportedSource
    case invalidURL
    case apiError(statusCode: Int)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .unsupportedSource:     return "This video source is not supported."
        case .invalidURL:            return "Could not construct oEmbed URL."
        case .apiError(let code):    return "oEmbed API returned HTTP \(code)."
        case .malformedResponse:     return "Could not parse oEmbed response."
        }
    }
}
