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
            // 1. Instagram's own web JSON API (the technique yt-dlp uses). For public posts
            //    it returns the full caption — far more reliable than scraping og:description,
            //    which Instagram increasingly answers with a 403 / login wall.
            if let code = Self.instagramShortcode(from: videoURL),
               let meta = try? await fetchInstagramAPIMeta(shortcode: code),
               meta.caption?.isEmpty == false {
                return meta
            }
            // 2. Fall back to scraping og:description from the page HTML.
            if let meta = try? await fetchInstagramPageMeta(videoURL: videoURL) {
                return meta
            }
            // 3. Last resort: legacy oEmbed (needs auth now, but harmless to try).
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
