import Foundation

/// Recipe discovery backed by Perplexity's Sonar models, which answer from a live web search
/// and return the URLs they used.
///
/// The citations are the point. Rather than trusting a model to recite quantities from memory —
/// the one thing a cooking app must not get wrong — we take the pages it found and run them
/// through the existing extraction chain (Schema.org → Microdata → heuristic → LLM), so the
/// recipe the user saves comes from the actual recipe page. Perplexity's own summary is kept
/// only as a preview and as a last-resort fallback when no cited page extracts cleanly.
///
/// Gated on `PERPLEXITY_API_KEY` (Secrets.xcconfig → Info.plist). Absent, search simply
/// returns nothing and the caller falls back to its other strategies.
enum PerplexitySearcher {

    /// What the user is searching by.
    enum Mode {
        /// A dish or recipe name: "chicken piccata", "birria tacos".
        case dish(String)
        /// Ingredients on hand: ["chicken", "lemon", "capers"] → dishes that use them.
        case ingredients([String])
    }

    /// One discovered recipe: where it lives, plus enough detail to show a useful card
    /// before the user commits to importing it.
    struct Discovery: Sendable, Identifiable {
        var id: String { url }
        let url: String
        let title: String
        let summary: String?
        let siteName: String?
    }

    static var apiKey: String? {
        (Bundle.main.infoDictionary?["PERPLEXITY_API_KEY"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            // Same fallback ladder as the Anthropic key: env, then Secrets.xcconfig — how
            // the macOS harness (no Info.plist injection) picks the key up.
            ?? ProcessInfo.processInfo.environment["PERPLEXITY_API_KEY"]
                .flatMap { $0.isEmpty ? nil : $0 }
            ?? XcconfigSecrets.value(forKey: "PERPLEXITY_API_KEY")
    }

    static var isConfigured: Bool { apiKey != nil }

    // MARK: - Search

    /// Search the web for recipes. Returns up to `limit` candidates, best first.
    static func search(_ mode: Mode, limit: Int = 6) async -> [Discovery] {
        guard let apiKey else { return [] }

        let body: [String: Any] = [
            "model": "sonar",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt(for: mode, limit: limit)],
            ],
            // Recipe sites only — keeps video platforms and pinboards out of the results,
            // since those need the social pipeline rather than page extraction.
            "search_domain_filter": ["-pinterest.com", "-instagram.com", "-tiktok.com", "-youtube.com"],
            "temperature": 0.2,
        ]

        guard let url = URL(string: "https://api.perplexity.ai/chat/completions") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return []
        }
        return parse(data: data, limit: limit)
    }

    // MARK: - Prompts

    private static let systemPrompt = """
    You find real, existing recipe pages on the web. You never invent recipes, URLs, or \
    quantities. Every recipe you list must come from a page you actually found in search.
    """

    private static func userPrompt(for mode: Mode, limit: Int) -> String {
        let ask: String
        switch mode {
        case .dish(let query):
            ask = "Find \(limit) well-regarded recipes for: \(query)."
        case .ingredients(let items):
            let list = items.joined(separator: ", ")
            ask = """
            I have these ingredients on hand: \(list). Find \(limit) recipes that use them as \
            the main components. Prefer recipes that need few extra ingredients beyond what \
            I listed.
            """
        }

        return """
        \(ask)

        For each one, give me on its own line, separated by pipes:
        TITLE | URL | one-sentence description

        Rules:
        - The URL must be the direct link to the recipe page you found, not a search or \
        category page.
        - Prefer established recipe sites and food blogs with full written recipes.
        - No video platforms, no Pinterest.
        - No preamble, no numbering, no markdown — just the lines.
        """
    }

    // MARK: - Response parsing (pure, testable)

    /// Perplexity replies with an OpenAI-shaped payload plus a `citations` array of URLs.
    static func parse(data: Data, limit: Int = 6) -> [Discovery] {
        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let citations = (outer["citations"] as? [String]) ?? []
        let content = ((outer["choices"] as? [[String: Any]])?.first?["message"]
            as? [String: Any])?["content"] as? String ?? ""

        var results = parseLines(content)

        // Fall back to raw citations when the model ignored the line format — the URLs are
        // still real search results, which is what actually matters downstream.
        if results.isEmpty {
            results = citations.compactMap { url in
                guard isUsableRecipeURL(url) else { return nil }
                return Discovery(url: url, title: hostName(of: url) ?? "Recipe",
                                 summary: nil, siteName: hostName(of: url))
            }
        }

        // De-duplicate by URL, keeping order.
        var seen = Set<String>()
        return results.filter { seen.insert($0.url).inserted }.prefix(limit).map { $0 }
    }

    /// "TITLE | URL | description" per line.
    private static func parseLines(_ content: String) -> [Discovery] {
        content.components(separatedBy: .newlines).compactMap { line -> Discovery? in
            let parts = line.components(separatedBy: "|").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count >= 2 else { return nil }
            // Strip any leading numbering/bullet the model added despite instructions.
            let title = parts[0]
                .replacingOccurrences(of: #"^[\-\*\d\.\)\s]+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "*_# "))
            let rawURL = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "<>() "))
            guard !title.isEmpty, isUsableRecipeURL(rawURL) else { return nil }
            let summary = parts.count >= 3 && !parts[2].isEmpty ? parts[2] : nil
            return Discovery(url: rawURL, title: title, summary: summary,
                             siteName: hostName(of: rawURL))
        }
    }

    /// An https page URL we can actually try to extract — not a search page, not a platform
    /// the page-extraction chain can't read.
    static func isUsableRecipeURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let host = url.host?.lowercased(),
              url.scheme?.lowercased() == "https" else { return false }
        let blocked = ["pinterest.", "instagram.com", "tiktok.com", "youtube.com", "youtu.be",
                       "facebook.com", "google.com/search", "bing.com"]
        if blocked.contains(where: { host.contains($0) || raw.lowercased().contains($0) }) {
            return false
        }
        // A bare domain root is a homepage, not a recipe.
        return url.path.count > 1
    }

    static func hostName(of raw: String) -> String? {
        guard let host = URL(string: raw)?.host else { return nil }
        return host.replacingOccurrences(of: "www.", with: "")
    }
}
