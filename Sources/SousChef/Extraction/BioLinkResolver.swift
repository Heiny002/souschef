import Foundation
import SwiftSoup

/// SC-072: Resolves a social media creator's identity to their recipe blog URL.
/// Resolution chain (short-circuits on first success):
/// 1. In-memory + UserDefaults cache (30-day TTL)
/// 2. blogURL from TranscriptFetcher (server-side, already fetched)
/// 3. Fetch authorURL profile page → extract bio link
/// 4. If bio link is a link aggregator → navigate to find blog
///
/// Zero LLM tokens. All deterministic HTTP + HTML parsing.
actor BioLinkResolver {
    static let shared = BioLinkResolver()

    private var cache: [String: CachedBlogEntry] = [:]
    private var rateLimitTimestamps: [String: Date] = [:]
    private let fetcher = WebPageFetcher()

    private static let cacheKey = "souschef_biolink_cache"
    private static let ttlSeconds: TimeInterval = 30 * 24 * 3600  // 30 days
    private static let rateLimitInterval: TimeInterval = 2.0

    private init() {
        // Load cache synchronously from UserDefaults (no actor isolation needed for init)
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let decoded = try? JSONDecoder().decode([String: CachedBlogEntry].self, from: data) {
            cache = decoded.filter { !$0.value.isExpired }
        }
    }

    // MARK: - Public

    /// Resolve a creator's blog URL. Returns nil if resolution fails at every step.
    func resolve(authorName: String?, authorURL: String?, serverBlogURL: String?) async -> String? {
        let cacheKey = (authorName ?? "").lowercased().trimmingCharacters(in: .whitespaces)

        // Step 1: Cache hit
        if !cacheKey.isEmpty, let cached = cache[cacheKey], !cached.isExpired {
            return cached.blogURL
        }

        // Step 2: Server-provided blogURL (from TranscriptFetcher, already fetched)
        if let blogURL = serverBlogURL, !blogURL.isEmpty, !isSocialMediaURL(blogURL) {
            cacheResult(key: cacheKey, blogURL: blogURL)
            return blogURL
        }

        // Step 3: Fetch author profile page → extract bio link
        if let profileURL = authorURL, !profileURL.isEmpty {
            if let bioLink = await extractBioLink(from: profileURL) {
                // Check if bio link is a link aggregator
                if isAggregator(bioLink) {
                    // Step 4: Navigate aggregator to find blog
                    if let blogURL = await extractBlogFromAggregator(aggregatorURL: bioLink) {
                        cacheResult(key: cacheKey, blogURL: blogURL)
                        return blogURL
                    }
                } else if !isSocialMediaURL(bioLink) {
                    // Bio link is directly a blog
                    cacheResult(key: cacheKey, blogURL: bioLink)
                    return bioLink
                }
            }
        }

        return nil
    }

    // MARK: - Step 3: Profile Page Bio Link Extraction

    private func extractBioLink(from profileURL: String) async -> String? {
        guard let html = await rateLimitedFetch(urlString: profileURL) else { return nil }

        do {
            let doc = try SwiftSoup.parse(html)

            // Look for external links in the page that aren't social media
            let links = try doc.select("a[href]")
            for link in links {
                let href = try link.attr("abs:href")
                guard !href.isEmpty,
                      let url = URL(string: href),
                      let host = url.host?.lowercased() else { continue }

                // Skip internal links and social media
                if isSocialMediaHost(host) { continue }
                if host.contains("instagram.com") || host.contains("tiktok.com") { continue }

                // Prefer known aggregator or blog-like URLs
                if isAggregatorHost(host) || looksLikeBlog(href) {
                    return href
                }
            }

            // Fallback: first external non-social link
            for link in links {
                let href = try link.attr("abs:href")
                guard let url = URL(string: href),
                      let host = url.host?.lowercased() else { continue }
                if !isSocialMediaHost(host) && href.hasPrefix("http") {
                    return href
                }
            }
        } catch {
            // SwiftSoup parse error — profile page HTML may be unusual
        }

        return nil
    }

    // MARK: - Step 4: Link Aggregator Navigation

    private func extractBlogFromAggregator(aggregatorURL: String) async -> String? {
        guard let html = await rateLimitedFetch(urlString: aggregatorURL) else { return nil }

        do {
            let doc = try SwiftSoup.parse(html)
            let links = try doc.select("a[href]")

            var scored: [(url: String, score: Int)] = []

            for link in links {
                let href = try link.attr("abs:href")
                let text = try link.text().lowercased()
                guard let url = URL(string: href),
                      let host = url.host?.lowercased(),
                      href.hasPrefix("http") else { continue }

                // Skip social media platforms entirely
                if isSocialMediaHost(host) { continue }

                var score = 0
                let path = url.path.lowercased()

                // URL path signals
                if path.contains("blog") || path.contains("recipe") || path.contains("food") { score += 3 }

                // Custom domain (not a subdomain of an aggregator)
                if !isAggregatorHost(host) { score += 2 }

                // WordPress indicators
                if href.contains("wp-content") || href.contains("wp-json") || href.contains("wordpress") { score += 2 }

                // Link text signals
                if text.contains("blog") || text.contains("website") || text.contains("recipes") ||
                   text.contains("my site") || text.contains("head to") { score += 1 }

                if score > 0 {
                    scored.append((url: href, score: score))
                }
            }

            // Return highest-scoring link
            if let best = scored.max(by: { $0.score < $1.score }) {
                return best.url
            }

            // Fallback: first external link that's a custom domain (not aggregator, not social)
            for link in links {
                let href = try link.attr("abs:href")
                guard let url = URL(string: href),
                      let host = url.host?.lowercased(),
                      href.hasPrefix("http") else { continue }
                if !isSocialMediaHost(host) && !isAggregatorHost(host) {
                    return href
                }
            }
        } catch {
            // Parse error
        }

        return nil
    }

    // MARK: - Rate-Limited Fetch

    private func rateLimitedFetch(urlString: String) async -> String? {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return nil }

        // Enforce rate limit
        if let lastFetch = rateLimitTimestamps[host] {
            let elapsed = Date.now.timeIntervalSince(lastFetch)
            if elapsed < Self.rateLimitInterval {
                try? await Task.sleep(for: .seconds(Self.rateLimitInterval - elapsed))
            }
        }
        rateLimitTimestamps[host] = Date.now

        return try? await fetcher.fetch(urlString: urlString)
    }

    // MARK: - URL Classification

    private static let socialHosts: Set<String> = [
        "tiktok.com", "instagram.com", "youtube.com", "youtu.be",
        "twitter.com", "x.com", "facebook.com", "fb.com",
        "pinterest.com", "threads.net", "snapchat.com",
    ]

    private static let aggregatorHosts: Set<String> = [
        "linktr.ee", "beacons.ai", "stan.store", "komi.io",
        "linkpop.com", "tap.bio", "link.bio", "campsite.bio",
        "hoo.be", "snipfeed.co", "lnk.bio", "withkoji.com",
        "linkin.bio", "allmylinks.com", "bio.link",
    ]

    private func isSocialMediaURL(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return isSocialMediaHost(host)
    }

    private func isSocialMediaHost(_ host: String) -> Bool {
        Self.socialHosts.contains(where: { host.hasSuffix($0) })
    }

    private func isAggregator(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return isAggregatorHost(host)
    }

    private func isAggregatorHost(_ host: String) -> Bool {
        Self.aggregatorHosts.contains(where: { host.hasSuffix($0) })
    }

    private func looksLikeBlog(_ urlString: String) -> Bool {
        let lower = urlString.lowercased()
        return lower.contains("blog") || lower.contains("recipe") ||
               lower.contains("food") || lower.contains("cook")
    }

    // MARK: - Cache

    private struct CachedBlogEntry: Codable {
        let blogURL: String
        let timestamp: Date

        var isExpired: Bool {
            Date.now.timeIntervalSince(timestamp) > BioLinkResolver.ttlSeconds
        }
    }

    private func cacheResult(key: String, blogURL: String) {
        guard !key.isEmpty else { return }
        let entry = CachedBlogEntry(blogURL: blogURL, timestamp: Date.now)
        cache[key] = entry
        saveCache()
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let decoded = try? JSONDecoder().decode([String: CachedBlogEntry].self, from: data) else { return }
        // Filter out expired entries on load
        cache = decoded.filter { !$0.value.isExpired }
    }

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }
}
