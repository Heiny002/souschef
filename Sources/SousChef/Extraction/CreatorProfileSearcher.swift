import Foundation
import SwiftSoup

/// Discovers a creator's real name, aggregator pages, and blog URLs via web search.
/// Called before Stage A1 in ExtractionPipeline when direct profile access fails.
///
/// Resolution approach:
/// 1. Ask server to search DuckDuckGo for the handle (aggregators included).
/// 2. Navigate any Linktree / Beacons pages → score links by dish keywords.
/// 3. Run BlogRecipeSearch on discovered blog / substack roots.
/// 4. Return real name (if found in search titles) so Stage A1 can use it.
enum CreatorProfileSearcher {

    struct DiscoveredProfile {
        /// Creator's real name extracted from search result titles (e.g. "Carina Wolff").
        let realName: String?
        /// Recipe page URLs found on aggregator pages that match the dish keywords.
        /// Try each via extractFromWebPage before falling through to A1.
        let recipePageURLs: [String]
        /// Blog / substack root URLs for BlogRecipeSearch to probe.
        let blogURLs: [String]

        var isEmpty: Bool { realName == nil && recipePageURLs.isEmpty && blogURLs.isEmpty }
    }

    // MARK: - Public

    /// Discover profile information for a creator handle (without the @ prefix).
    /// Runs server web search and direct aggregator probes in parallel for speed.
    static func discover(handle: String, keywords: [String]) async -> DiscoveredProfile {
        // Run web search and direct aggregator probes concurrently
        async let serverResult = fetchProfileLinks(handle: handle)
        async let directProbes = probeAggregatorURLs(handle: handle)

        let (links, realName) = await serverResult
        let probedAggregators = await directProbes

        // Direct probes go first (more reliable than search-discovered URLs)
        var aggregatorURLs: [String] = probedAggregators
        var blogURLs: [String] = []

        for link in links {
            guard let url = URL(string: link.url),
                  let host = url.host?.lowercased() else { continue }
            if socialHosts.contains(where: { host.hasSuffix($0) }) { continue }
            if aggregatorHosts.contains(where: { host.hasSuffix($0) }) {
                if !aggregatorURLs.contains(link.url) {
                    aggregatorURLs.append(link.url)
                }
            } else {
                blogURLs.append(link.url)
            }
        }

        // Navigate aggregator pages for keyword-matched recipe links
        let fetcher = WebPageFetcher()
        var recipePageURLs: [String] = []
        for aggURL in aggregatorURLs.prefix(5) {   // up to 5: probes + search finds
            let found = await extractKeywordLinks(from: aggURL, keywords: keywords, fetcher: fetcher)
            for url in found where !recipePageURLs.contains(url) {
                recipePageURLs.append(url)
            }
        }

        return DiscoveredProfile(
            realName: realName,
            recipePageURLs: recipePageURLs,
            blogURLs: Array(blogURLs.prefix(3))
        )
    }

    // MARK: - Direct aggregator probe

    /// Aggregator services that use https://{host}/{handle} URL patterns.
    /// HEAD-check all of them in parallel — fast 5-second timeout per request.
    private static let aggregatorPatterns: [String] = [
        "https://linktr.ee/{handle}",
        "https://beacons.ai/{handle}",
        "https://bio.link/{handle}",
        "https://lnk.bio/{handle}",
        "https://allmylinks.com/{handle}",
        "https://campsite.bio/{handle}",
        "https://hoo.be/{handle}",
        "https://stan.store/{handle}",
        "https://tap.bio/@{handle}",
        "https://provecho.bio/{handle}",
        "https://provecho.co/{handle}",
    ]

    private static func probeAggregatorURLs(handle: String) async -> [String] {
        let candidates = aggregatorPatterns.map {
            $0.replacingOccurrences(of: "{handle}", with: handle)
        }

        return await withTaskGroup(of: (String, Bool).self) { group in
            for urlString in candidates {
                group.addTask {
                    guard let url = URL(string: urlString) else { return (urlString, false) }
                    var req = URLRequest(url: url)
                    req.httpMethod = "HEAD"
                    req.timeoutInterval = 5
                    let exists = (try? await URLSession.shared.data(for: req))
                        .map { _, resp in (resp as? HTTPURLResponse)?.statusCode == 200 } ?? false
                    return (urlString, exists)
                }
            }
            var found: [String] = []
            for await (urlString, exists) in group where exists {
                found.append(urlString)
            }
            return found
        }
    }

    // MARK: - Server request

    private struct ServerLink: Decodable {
        let url: String
        let title: String
    }

    private struct ServerResponse: Decodable {
        let links: [ServerLink]
        let real_name: String?
    }

    private static func fetchProfileLinks(handle: String) async -> (links: [ServerLink], realName: String?) {
        guard let url = URL(string: "http://localhost:8000/find-creator-profile") else {
            return ([], nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["handle": handle])

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let parsed = try? JSONDecoder().decode(ServerResponse.self, from: data) else {
            return ([], nil)
        }
        return (parsed.links, parsed.real_name)
    }

    // MARK: - Aggregator navigation

    /// Fetch an aggregator page (Linktree, Beacons, etc.) and return links whose
    /// text or URL slug match the given food keywords. Scored: keyword match in
    /// link text (+3), keyword match in URL slug (+2), recipe/blog path words (+1).
    /// Only returns links with score >= 3 (at least one keyword hit in link text).
    private static func extractKeywordLinks(
        from aggregatorURL: String,
        keywords: [String],
        fetcher: WebPageFetcher
    ) async -> [String] {
        guard let html = try? await fetcher.fetch(urlString: aggregatorURL) else { return [] }

        do {
            let doc = try SwiftSoup.parse(html)
            var scored: [(url: String, score: Int)] = []

            for link in try doc.select("a[href]") {
                let href = try link.attr("abs:href")
                let text = try link.text().lowercased()
                guard let linkURL = URL(string: href),
                      let host = linkURL.host?.lowercased(),
                      href.hasPrefix("http") else { continue }

                if socialHosts.contains(where: { host.hasSuffix($0) }) { continue }
                if aggregatorHosts.contains(where: { host.hasSuffix($0) }) { continue }

                var score = 0
                let slug = linkURL.path.lowercased()

                for keyword in keywords {
                    let kw = keyword.lowercased()
                    if text.contains(kw)  { score += 3 }
                    if slug.contains(kw)  { score += 2 }
                }

                // Generic recipe/blog path signals (lower weight than keywords)
                if slug.contains("recipe") || slug.contains("blog") { score += 1 }
                if text.contains("recipe") { score += 1 }

                if score >= 3 {   // requires at least one keyword match in link text
                    scored.append((url: href, score: score))
                }
            }

            return scored
                .sorted { $0.score > $1.score }
                .prefix(3)
                .map(\.url)
        } catch {
            return []
        }
    }

    // MARK: - Host lists (mirrors BioLinkResolver)

    private static let aggregatorHosts: Set<String> = [
        "linktr.ee", "beacons.ai", "stan.store", "komi.io",
        "linkpop.com", "tap.bio", "link.bio", "campsite.bio",
        "hoo.be", "snipfeed.co", "lnk.bio", "withkoji.com",
        "linkin.bio", "allmylinks.com", "bio.link",
        "provecho.bio", "provecho.co",
    ]

    private static let socialHosts: Set<String> = [
        "instagram.com", "tiktok.com", "youtube.com", "youtu.be",
        "twitter.com", "x.com", "facebook.com", "fb.com",
        "threads.net", "snapchat.com",
    ]
}
