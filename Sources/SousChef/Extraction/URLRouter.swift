import Foundation

/// Classifies a URL into the appropriate source type for recipe extraction.
/// Pure string matching — no network calls.
enum URLSourceType: Equatable {
    case tikTok
    case instagram
    case youTube
    case webPage
}

enum URLRouter {
    /// Classify a URL string into a source type.
    static func classify(_ urlString: String) -> URLSourceType {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased() else {
            return .webPage
        }

        if isTikTok(host: host) { return .tikTok }
        if isInstagram(host: host, path: url.path) { return .instagram }
        if isYouTube(host: host, path: url.path) { return .youTube }
        return .webPage
    }

    // MARK: - Private

    private static func isTikTok(host: String) -> Bool {
        let hosts = ["tiktok.com", "www.tiktok.com", "vm.tiktok.com", "m.tiktok.com"]
        return hosts.contains(host) || host.hasSuffix(".tiktok.com")
    }

    private static func isInstagram(host: String, path: String) -> Bool {
        guard host == "instagram.com" || host == "www.instagram.com" else { return false }
        // Reels, posts, stories all count
        let validPaths = ["/reel/", "/reels/", "/p/", "/tv/", "/stories/"]
        return validPaths.contains { path.hasPrefix($0) }
    }

    private static func isYouTube(host: String, path: String) -> Bool {
        let ytHosts = ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be",
                       "music.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com"]
        guard ytHosts.contains(host) else { return false }
        if host == "youtu.be" { return true }
        return path.hasPrefix("/watch") || path.hasPrefix("/shorts/") || path.hasPrefix("/embed/") || path.hasPrefix("/v/")
    }

    // MARK: - Provenance helpers

    /// The `Recipe.sourceType` string to store for a given source URL. Defaults to "web".
    static func sourceType(forStoredURL urlString: String?) -> String {
        guard let urlString, !urlString.isEmpty else { return "web" }
        return classify(urlString).storageValue
    }

    /// An `https` URL safe to open in a `Link` or load in `AsyncImage`, or nil. Provenance
    /// values can originate from scraped/search content, so cleartext, non-http(s) schemes,
    /// and hostless URLs are rejected before they reach a user-visible sink.
    static func safeExternalURL(_ urlString: String?) -> URL? {
        guard let urlString, !urlString.isEmpty,
              let url = URL(string: urlString),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

extension URLSourceType {
    /// Value persisted in `Recipe.sourceType`.
    var storageValue: String {
        switch self {
        case .tikTok:    return "tiktok"
        case .instagram: return "instagram"
        case .youTube:   return "youtube"
        case .webPage:   return "web"
        }
    }
}
