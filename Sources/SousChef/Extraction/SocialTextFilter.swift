import Foundation

/// Strips the social-media wrapper from a recipe: engagement bait, calls to action, and
/// platform-generated titles. Instagram/TikTok captions bury the recipe inside marketing —
/// "Save this for your next dinner party", "follow for more", hashtag walls — and the
/// platforms' own page titles are engagement metadata, not recipe names.
///
/// This runs before parsing (deterministic path) and alongside the LLM prompt's exclusion
/// rules, so noise is dropped even when no API key is configured.
enum SocialTextFilter {

    // MARK: - Titles

    /// True when a title is platform metadata rather than a recipe name — e.g.
    /// "69K likes, 410 comments - foodswings.by.jose on July 3, 2025: …".
    /// These come from og:title / oEmbed and must never become the recipe's name.
    static func isMetadataTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        let t = title.lowercased()
        // Engagement counts are the giveaway: "69K likes", "410 comments".
        if t.range(of: #"\d+(\.\d+)?[km]?\s+(likes?|comments?|views?|shares?)"#,
                   options: .regularExpression) != nil { return true }
        for marker in [" on instagram", " on tiktok", "• instagram", "· instagram",
                       "instagram video", "tiktok video", "watch on ", "| tiktok"]
        where t.contains(marker) { return true }
        return false
    }

    /// A title we can show, or nil when it's platform metadata / empty.
    static func cleanTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isMetadataTitle(trimmed) else { return nil }
        return trimmed
    }

    // MARK: - Caption lines

    /// Calls to action and engagement bait — never part of a recipe.
    private static let ctaPhrases = [
        "save this", "save it", "save for later", "follow for more", "follow me",
        "comment below", "comment ", "drop a ", "tag a friend", "tag someone",
        "double tap", "like and", "share this", "link in bio", "recipe in bio",
        "full recipe", "check out my", "subscribe", "hit the", "let me know",
        "who would you", "watch till", "part 1", "new video",
    ]

    /// Marketing narrative that reads like a caption, not an instruction — e.g.
    /// "The kind of appetizer that looks effortlessly impressive".
    private static let narrativeOpeners = [
        "the kind of", "this is the", "trust me", "obsessed with", "my favorite",
        "you guys", "i can't stop", "pov:", "when you", "nothing beats", "if you love",
    ]

    /// True when a caption line is social noise rather than recipe content.
    static func isNoiseLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }   // blank lines preserve structure

        // Hashtag / mention walls.
        let tokens = trimmed.split(separator: " ")
        if !tokens.isEmpty, tokens.allSatisfy({ $0.hasPrefix("#") || $0.hasPrefix("@") }) {
            return true
        }

        // Emoji/punctuation-only decoration lines.
        if !trimmed.contains(where: { $0.isLetter || $0.isNumber }) { return true }

        // Strip leading emoji before phrase-matching — CTAs are often decorated ("💾 Save this!").
        let core = trimmed.drop { !$0.isLetter && !$0.isNumber }.description.lowercased()
        for phrase in ctaPhrases where core.hasPrefix(phrase) { return true }
        for opener in narrativeOpeners where core.hasPrefix(opener) { return true }
        return false
    }

    /// Drop noise lines, keeping blank lines so paragraph structure (and therefore header
    /// detection) survives.
    static func clean(_ caption: String) -> String {
        caption.components(separatedBy: .newlines)
            .filter { !isNoiseLine($0) }
            .joined(separator: "\n")
    }
}
