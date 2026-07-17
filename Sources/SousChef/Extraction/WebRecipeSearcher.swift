import Foundation

/// SC-076: Searches the web for recipe pages matching a keyword query.
/// Two strategies (ordered, short-circuit):
/// 1. Server-side search endpoint (POST /search-recipe) — avoids client CAPTCHA blocks
/// 2. Google Custom Search API (free 100/day) — fallback if server unavailable
///
/// Returns up to 3 candidate recipe URLs, filtered to exclude social media and aggregators.
enum WebRecipeSearcher {

    struct SearchResult {
        let url: String
        let title: String
    }

    /// Search for recipe pages matching the query. Returns up to 3 filtered candidate URLs.
    static func search(query: String) async -> [SearchResult] {
        // Strategy 1: Server-side search endpoint
        if let results = await serverSearch(query: query), !results.isEmpty {
            return filterRecipeResults(results)
        }

        // Strategy 2: Google Custom Search API
        if let results = await googleCSESearch(query: query), !results.isEmpty {
            return filterRecipeResults(results)
        }

        return []
    }

    // MARK: - Strategy 1: Server-Side Search

    private static func serverSearch(query: String) async -> [SearchResult]? {
        guard let base = BackendConfig.baseURL,
              let url = URL(string: "\(base)/search-recipe") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }

        return parseServerResponse(data: data)
    }

    private static func parseServerResponse(data: Data) -> [SearchResult]? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = dict["results"] as? [[String: Any]] else {
            return nil
        }

        return items.compactMap { item in
            guard let url = item["url"] as? String,
                  let title = item["title"] as? String else { return nil }
            return SearchResult(url: url, title: title)
        }
    }

    // MARK: - Strategy 2: Google Custom Search API

    private static func googleCSESearch(query: String) async -> [SearchResult]? {
        guard let apiKey = Bundle.main.infoDictionary?["GOOGLE_CSE_API_KEY"] as? String,
              !apiKey.isEmpty,
              let cseID = Bundle.main.infoDictionary?["GOOGLE_CSE_ID"] as? String,
              !cseID.isEmpty else {
            return nil  // Not configured — skip
        }

        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.googleapis.com/customsearch/v1?q=\(encodedQuery)&key=\(apiKey)&cx=\(cseID)&num=5") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }

        return parseGoogleResponse(data: data)
    }

    private static func parseGoogleResponse(data: Data) -> [SearchResult]? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = dict["items"] as? [[String: Any]] else {
            return nil
        }

        return items.compactMap { item in
            guard let url = item["link"] as? String,
                  let title = item["title"] as? String else { return nil }
            return SearchResult(url: url, title: title)
        }
    }

    // MARK: - Filtering

    /// Filter search results: remove social media and aggregators, prefer recipe-like URLs.
    /// Returns up to 3 candidates.
    private static func filterRecipeResults(_ results: [SearchResult]) -> [SearchResult] {
        let filtered = results.filter { result in
            guard let url = URL(string: result.url),
                  let host = url.host?.lowercased() else { return false }

            // Skip social media platforms
            if socialHosts.contains(where: { host.contains($0) }) { return false }

            // Skip link aggregators
            if aggregatorHosts.contains(where: { host.contains($0) }) { return false }

            return true
        }

        // Sort: recipe-like URLs first
        let scored = filtered.map { result -> (result: SearchResult, score: Int) in
            let lower = result.url.lowercased()
            var score = 0
            if lower.contains("recipe") { score += 3 }
            if lower.contains("food") || lower.contains("cook") || lower.contains("kitchen") { score += 2 }
            if lower.contains("blog") { score += 1 }
            return (result, score)
        }.sorted { $0.score > $1.score }

        return Array(scored.prefix(3).map(\.result))
    }

    // MARK: - Constants

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
        "provecho.bio", "provecho.co",
    ]
}
