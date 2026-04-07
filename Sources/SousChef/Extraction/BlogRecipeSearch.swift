import Foundation
import SwiftSoup

/// SC-073: Searches a blog for a specific recipe by keywords.
/// Strategies (ordered, short-circuits on first match):
/// 1. WordPress REST API  — /wp-json/wp/v2/posts?search=keywords
/// 2. WordPress HTML search — /?s=keywords
/// 3. Sitemap URL slug matching — /sitemap.xml
///
/// Zero LLM tokens. Maximum 1 HTTP request per strategy (chain short-circuits).
enum BlogRecipeSearch {

    /// Search a blog for a recipe matching the given keywords.
    /// Returns the recipe page URL, or nil if not found.
    static func search(blogURL: String, keywords: [String]) async -> String? {
        guard !keywords.isEmpty else { return nil }

        let baseURL = blogURL.hasSuffix("/") ? String(blogURL.dropLast()) : blogURL
        let query = keywords.joined(separator: " ")
        let fetcher = WebPageFetcher()

        // Strategy 1: WordPress REST API (returns JSON — cheapest to parse)
        if let result = await searchWordPressAPI(baseURL: baseURL, query: query, keywords: keywords, fetcher: fetcher) {
            return result
        }

        // Strategy 2: Substack Archive API — /api/v1/archive (Substack doesn't have WP endpoints)
        if let result = await searchSubstackAPI(baseURL: baseURL, keywords: keywords, fetcher: fetcher) {
            return result
        }

        // Strategy 3: WordPress HTML search page
        if let result = await searchWordPressHTML(baseURL: baseURL, query: query, fetcher: fetcher) {
            return result
        }

        // Strategy 4: Sitemap URL slug matching
        if let result = await searchSitemap(baseURL: baseURL, keywords: keywords, fetcher: fetcher) {
            return result
        }

        return nil
    }

    // MARK: - Strategy 1: WordPress REST API

    /// GET {baseURL}/wp-json/wp/v2/posts?search={query}&per_page=5
    /// Returns JSON with `link` and `title.rendered` per post.
    private static func searchWordPressAPI(
        baseURL: String, query: String, keywords: [String], fetcher: WebPageFetcher
    ) async -> String? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let endpoint = "\(baseURL)/wp-json/wp/v2/posts?search=\(encoded)&per_page=5"

        guard let jsonString = try? await fetcher.fetch(urlString: endpoint) else { return nil }
        guard let data = jsonString.data(using: .utf8),
              let posts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

        // Find first post where title contains at least 2 keywords
        for post in posts {
            guard let link = post["link"] as? String,
                  let titleObj = post["title"] as? [String: Any],
                  let rendered = titleObj["rendered"] as? String else { continue }

            let titleLower = rendered.lowercased()
            let matchCount = keywords.filter { titleLower.contains($0.lowercased()) }.count
            if matchCount >= min(2, keywords.count) {
                return link
            }
        }

        // If we got results but none matched well, return the first one
        // (WordPress search is usually relevant)
        if let first = posts.first, let link = first["link"] as? String {
            return link
        }

        return nil
    }

    // MARK: - Strategy 2: Substack Archive API

    /// GET {baseURL}/api/v1/archive?sort=new&limit=50
    /// Substack returns a JSON array of post objects with canonical_url and title.
    private static func searchSubstackAPI(
        baseURL: String, keywords: [String], fetcher: WebPageFetcher
    ) async -> String? {
        let endpoint = "\(baseURL)/api/v1/archive?sort=new&limit=50"
        guard let jsonString = try? await fetcher.fetch(urlString: endpoint) else { return nil }
        guard let data = jsonString.data(using: .utf8),
              let posts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !posts.isEmpty else { return nil }

        var best: (url: String, score: Int) = ("", 0)

        for post in posts {
            // Substack post objects have canonical_url and title
            guard let canonicalURL = post["canonical_url"] as? String else { continue }
            let title = (post["title"] as? String ?? "").lowercased()
            let slug  = URL(string: canonicalURL)?.path.lowercased() ?? ""

            let score = keywords.reduce(0) { count, keyword in
                let kw = keyword.lowercased()
                let inTitle = title.contains(kw) ? 1 : 0
                let inSlug  = slug.contains(kw) ? 1 : 0
                return count + inTitle + inSlug
            }

            if score > best.score {
                best = (url: canonicalURL, score: score)
            }
        }

        let threshold = min(2, keywords.count)
        if best.score >= threshold { return best.url }

        // No keyword match — not a Substack or search returned irrelevant posts
        return nil
    }

    // MARK: - Strategy 3: WordPress HTML Search

    /// GET {baseURL}/?s={query} — parse HTML for recipe links.
    private static func searchWordPressHTML(
        baseURL: String, query: String, fetcher: WebPageFetcher
    ) async -> String? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let searchURL = "\(baseURL)/?s=\(encoded)"

        guard let html = try? await fetcher.fetch(urlString: searchURL) else { return nil }

        do {
            let doc = try SwiftSoup.parse(html)

            // Look for links inside article/post containers
            let selectors = [
                "article a[href]",
                ".post a[href]",
                ".entry a[href]",
                ".search-result a[href]",
                ".result a[href]",
                "h2 a[href]",  // Many themes put post titles in h2 > a
                "h3 a[href]",
            ]

            for selector in selectors {
                let links = try doc.select(selector)
                for link in links {
                    let href = try link.attr("abs:href")
                    // Must be on the same domain and look like a post (not a category/tag page)
                    if href.hasPrefix(baseURL) && looksLikeRecipePage(href) {
                        return href
                    }
                }
            }

            // Broader fallback: any internal link that looks like a recipe
            let allLinks = try doc.select("a[href]")
            for link in allLinks {
                let href = try link.attr("abs:href")
                if href.hasPrefix(baseURL) && looksLikeRecipePage(href) {
                    return href
                }
            }
        } catch {
            // Parse error
        }

        return nil
    }

    // MARK: - Strategy 3: Sitemap URL Slug Matching

    /// Fetch sitemap.xml, score URLs by keyword overlap in the slug.
    private static func searchSitemap(
        baseURL: String, keywords: [String], fetcher: WebPageFetcher
    ) async -> String? {
        // Try common sitemap locations
        let sitemapURLs = [
            "\(baseURL)/sitemap.xml",
            "\(baseURL)/post-sitemap.xml",
            "\(baseURL)/sitemap_index.xml",
        ]

        for sitemapURL in sitemapURLs {
            guard var xml = try? await fetcher.fetch(urlString: sitemapURL) else { continue }

            // Sitemap index: follow child sitemaps (one level deep)
            if xml.contains("<sitemapindex") {
                let locPattern = #"<loc>\s*(https?://[^\s<]+)\s*</loc>"#
                if let re = try? NSRegularExpression(pattern: locPattern) {
                    let allMatches = re.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
                    // Prefer post-specific child sitemaps; fall back to first child
                    let childURLs = allMatches.compactMap { m -> String? in
                        guard let r = Range(m.range(at: 1), in: xml) else { return nil }
                        return String(xml[r])
                    }
                    let preferred = childURLs.first { $0.contains("post") || $0.contains("recipe") }
                        ?? childURLs.first
                    if let childURL = preferred,
                       let childXML = try? await fetcher.fetch(urlString: childURL) {
                        xml = childXML
                    }
                }
                if xml.contains("<sitemapindex") { continue }  // two levels deep — give up
            }

            let urls = extractURLsFromSitemap(xml: xml, baseURL: baseURL)
            if urls.isEmpty { continue }

            // Score each URL by keyword matches in the slug
            var best: (url: String, score: Int) = ("", 0)

            for pageURL in urls {
                let slug = URL(string: pageURL)?.path.lowercased() ?? ""
                let score = keywords.reduce(0) { count, keyword in
                    // Check both hyphenated and non-hyphenated forms
                    let kw = keyword.lowercased()
                    let hyphenated = kw.replacingOccurrences(of: " ", with: "-")
                    if slug.contains(hyphenated) || slug.contains(kw) {
                        return count + 1
                    }
                    return count
                }
                if score > best.score {
                    best = (url: pageURL, score: score)
                }
            }

            // Require at least 2 keyword matches (or all keywords if < 2)
            let threshold = min(2, keywords.count)
            if best.score >= threshold {
                return best.url
            }
        }

        return nil
    }

    // MARK: - Helpers

    /// Extract <loc> URLs from a flat sitemap XML string (not an index).
    private static func extractURLsFromSitemap(xml: String, baseURL: String) -> [String] {
        var urls: [String] = []
        let pattern = #"<loc>\s*(.*?)\s*</loc>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        for match in matches {
            guard let range = Range(match.range(at: 1), in: xml) else { continue }
            let url = String(xml[range])
            // Only include URLs on the same domain
            if url.hasPrefix(baseURL) {
                urls.append(url)
            }
        }

        return urls
    }

    /// Heuristic: does this URL look like a recipe post (not a category/tag/page)?
    private static func looksLikeRecipePage(_ urlString: String) -> Bool {
        let path = URL(string: urlString)?.path.lowercased() ?? ""

        // Exclude non-recipe paths
        let excludePatterns = ["/category/", "/tag/", "/author/", "/page/",
                               "/wp-admin", "/wp-login", "/cart", "/checkout",
                               "/about", "/contact", "/privacy", "/terms"]
        if excludePatterns.contains(where: { path.contains($0) }) { return false }

        // Must have a non-trivial path (not just the root)
        return path.count > 1 && path != "/"
    }
}
