import Foundation
import NaturalLanguage

/// SC-070: Analyzes video captions to detect "link in bio" patterns, direct recipe URLs,
/// and extract recipe keywords for blog search. Pure functions — zero network calls, zero LLM tokens.
enum CaptionAnalyzer {

    /// What the caption tells us about where the recipe lives.
    enum CaptionSignal: Equatable {
        case directURL(String)   // Caption contains a non-social-media URL
        case linkInBio           // "Link in bio" or equivalent detected
        case none                // Normal video — proceed with transcript extraction
    }

    // MARK: - Detection

    /// Analyze caption text for recipe location signals.
    static func analyze(_ text: String) -> CaptionSignal {
        let lowered = text.lowercased()

        // Check for direct non-social-media URLs first
        if let directURL = extractDirectURL(from: text) {
            return .directURL(directURL)
        }

        // Check for "link in bio" patterns
        if matchesLinkInBio(lowered) {
            return .linkInBio
        }

        return .none
    }

    // MARK: - Keyword Extraction

    /// Extract recipe-relevant keywords from caption text using NLP + FoodDictionary.
    /// Returns up to `limit` keywords, prioritizing food dictionary matches.
    static func extractKeywords(from text: String, using foodDict: FoodDictionary, limit: Int = 5) -> [String] {
        let cleaned = cleanCaption(text)
        let words = tokenizeWords(cleaned)
        let filtered = words.filter { !noiseWords.contains($0.lowercased()) }

        var keywords: [String] = []
        var used: Set<Int> = []  // indices already consumed

        // Pass 1: Two-word compound food entities ("sweet potato", "glass noodles", "soy sauce")
        for i in 0..<max(0, filtered.count - 1) {
            guard !used.contains(i) else { continue }
            let compound = "\(filtered[i]) \(filtered[i + 1])"
            if foodDict.find(name: compound) != nil {
                keywords.append(compound)
                used.insert(i)
                used.insert(i + 1)
                if keywords.count >= limit { return keywords }
            }
        }

        // Pass 2: Single-word food entities
        for (i, word) in filtered.enumerated() {
            guard !used.contains(i) else { continue }
            if foodDict.find(name: word) != nil {
                keywords.append(word.lowercased())
                used.insert(i)
                if keywords.count >= limit { return keywords }
            }
        }

        // Pass 3: Fuzzy food dictionary matches for remaining words
        for (i, word) in filtered.enumerated() {
            guard !used.contains(i), word.count >= 4 else { continue }
            if let entry = foodDict.fuzzyFind(name: word) {
                keywords.append(entry.name)
                used.insert(i)
                if keywords.count >= limit { return keywords }
            }
        }

        // Pass 4: If still < 2 keywords, include any remaining nouns that aren't noise
        if keywords.count < 2 {
            let tagger = NLTagger(tagSchemes: [.lexicalClass])
            tagger.string = cleaned
            tagger.enumerateTags(in: cleaned.startIndex..<cleaned.endIndex,
                                 unit: .word, scheme: .lexicalClass) { tag, range in
                if tag == .noun {
                    let word = String(cleaned[range]).lowercased()
                    if word.count >= 3 && !noiseWords.contains(word) && !keywords.contains(word) {
                        keywords.append(word)
                    }
                }
                return keywords.count < limit
            }
        }

        return Array(keywords.prefix(limit))
    }

    // MARK: - Private Helpers

    /// Extract the first URL from text whose host is NOT a social media platform.
    private static func extractDirectURL(from text: String) -> String? {
        let pattern = #"https?://[^\s,)}\]\"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let urlString = String(text[range])
            guard let url = URL(string: urlString), let host = url.host?.lowercased() else { continue }

            // Skip social media platforms — these aren't recipe links
            let isSocial = socialHosts.contains(where: { host.contains($0) })
            if !isSocial {
                return urlString
            }
        }
        return nil
    }

    /// Check if text matches any "link in bio" pattern.
    private static func matchesLinkInBio(_ lowered: String) -> Bool {
        for pattern in bioPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(lowered.startIndex..., in: lowered)
                if regex.firstMatch(in: lowered, options: [], range: range) != nil {
                    return true
                }
            }
        }
        return false
    }

    /// Remove emoji, hashtags, @mentions, and excessive punctuation.
    private static func cleanCaption(_ text: String) -> String {
        var cleaned = text

        // Remove URLs
        cleaned = cleaned.replacingOccurrences(
            of: #"https?://[^\s]+"#, with: " ",
            options: .regularExpression)

        // Remove @mentions and #hashtags
        cleaned = cleaned.replacingOccurrences(
            of: #"[@#]\w+"#, with: " ",
            options: .regularExpression)

        // Remove emoji (Unicode ranges)
        cleaned = cleaned.unicodeScalars.filter { scalar in
            // Keep basic Latin, Latin supplements, general punctuation
            scalar.value < 0x1F600 || scalar.value > 0x1FAFF
        }.map { String($0) }.joined()

        // Collapse whitespace
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+"#, with: " ",
            options: .regularExpression).trimmingCharacters(in: .whitespaces)

        return cleaned
    }

    /// Tokenize text into words using NLTokenizer.
    private static func tokenizeWords(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).map {
            String(text[$0])
        }
    }

    // MARK: - Constants

    /// Regex patterns that indicate "link in bio" or equivalent.
    private static let bioPatterns: [String] = [
        // Explicit "bio" references
        #"link\s+in\s+(my\s+)?bio"#,
        #"full\s+recipe\s+(on|in)\s+(my\s+)?bio"#,
        #"check\s+(my\s+)?bio"#,
        #"bio\s+for\s+(the\s+)?(full\s+)?recipe"#,
        #"recipe\s+link\s+in\s+(my\s+)?bio"#,

        // "recipe(s) on my blog/website/site" — broad matching
        #"recipes?\s+(is\s+)?(on|at)\s+(my\s+)?(blog|website|site)"#,
        #"recipes?\s+on\s+(my\s+)?(blog|website|site|substack)"#,
        #"head\s+to\s+my\s+(blog|site|website|substack)"#,
        #"get\s+the\s+(full\s+)?recipe\s+(on|at)\s+my"#,
        #"find\s+(the\s+)?(full\s+)?recipe\s+(on|at|in)"#,
        #"(full\s+)?recipe\s+on\s+(the\s+)?(blog|website|site|substack|newsletter)"#,

        // Newsletter / Substack / subscription signals (recipe is off-platform)
        #"recipe.*went\s+out\s+on\s+(the\s+)?(newsletter|substack)"#,
        #"recipe.*on\s+(my\s+)?(substack|newsletter)"#,
        #"comment\s+\w+\s+to\s+get\s+(it|the\s+recipe)"#,
        #"(subscribe|sign\s+up).*for\s+(the\s+)?(full\s+)?recipe"#,
    ]

    /// Social media hosts — URLs on these are NOT direct recipe links.
    private static let socialHosts: Set<String> = [
        "tiktok.com", "instagram.com", "youtube.com", "youtu.be",
        "twitter.com", "x.com", "facebook.com", "fb.com",
        "pinterest.com", "threads.net",
    ]

    /// Words to filter out during keyword extraction (platform noise + stop words).
    private static let noiseWords: Set<String> = [
        // Platform noise
        "link", "bio", "follow", "like", "comment", "share", "subscribe",
        "video", "tiktok", "instagram", "reel", "recipe", "viral", "fyp",
        "foryou", "foryoupage", "trending", "foodtok", "cooktok",
        // Common filler
        "the", "a", "an", "for", "with", "and", "this", "that", "your",
        "my", "our", "get", "make", "making", "made", "try", "tonight",
        "today", "dinner", "lunch", "breakfast", "meal", "food", "easy",
        "quick", "best", "simple", "delicious", "amazing", "perfect",
        "minute", "minutes", "hour", "hours", "full",
    ]
}
