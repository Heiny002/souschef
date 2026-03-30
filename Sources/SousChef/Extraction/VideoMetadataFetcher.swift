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
            // Instagram oEmbed has required auth since 2020 — fall back to page HTML scraping
            if let meta = try? await fetchInstagramPageMeta(videoURL: videoURL) {
                return meta
            }
            // Last resort: try oEmbed anyway (may work for some embed configurations)
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

        let caption = extractOGContent(from: html, property: "og:description")
        let title   = extractOGContent(from: html, property: "og:title")
        let thumb   = extractOGContent(from: html, property: "og:image")

        guard caption != nil || title != nil else { throw VideoMetadataError.malformedResponse }

        // Try to extract author profile URL from og:url → derive profile from reel path
        let authorURL: String? = {
            guard let ogURL = extractOGContent(from: html, property: "og:url"),
                  let parsed = URL(string: ogURL),
                  parsed.host?.contains("instagram.com") == true else { return nil }
            // Reel URL format: /reel/XXX/ — creator profile is in page HTML elsewhere
            // Try to find profile link in the HTML
            let profilePattern = #"instagram\.com/([A-Za-z0-9_.]+)/?"#
            if let re = try? NSRegularExpression(pattern: profilePattern),
               let match = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let username = String(html[range])
                if username != "reel" && username != "p" && username != "explore" {
                    return "https://www.instagram.com/\(username)/"
                }
            }
            return nil
        }()

        return VideoMetadata(
            title: title,
            authorName: nil,
            authorURL: authorURL,
            caption: caption ?? title,
            thumbnailURL: thumb
        )
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
        let encodedURL = videoURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? videoURL
        guard let url = URL(string: "\(endpoint)?url=\(encodedURL)&format=json") else {
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
