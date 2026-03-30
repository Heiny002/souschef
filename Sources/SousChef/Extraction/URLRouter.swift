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
}
