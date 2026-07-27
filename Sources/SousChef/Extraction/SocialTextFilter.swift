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

    // MARK: - Caption prefix

    /// Instagram's og:description — which several fetch routes use as the caption — is
    /// `N likes, M comments - user on Date: "the real caption"`. Left in place, that
    /// engagement preamble becomes the caption's first line and therefore the recipe's
    /// title. Strip everything up to the opening quote that introduces the real caption.
    static func stripEngagementPrefix(_ caption: String) -> String {
        // Only strip when the string actually starts with the engagement preamble, so a
        // caption that legitimately contains a quote isn't truncated.
        let head = caption.prefix(200)
        guard isMetadataTitle(String(head)) else { return caption }
        for delimiter in [": \u{201C}", ": \"", ": "] {
            if let r = caption.range(of: delimiter) {
                let body = caption[r.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D} \n\r\t"))
                if !body.isEmpty { return body }
            }
        }
        return caption
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

    /// A CTA phrase only condemns a line this short. Matching is by prefix, so without a cap
    /// "Full recipe: 2 cups flour, 1 tsp salt, 3 eggs, bake at 350" — a real ingredient line —
    /// would be deleted wholesale by the "full recipe" entry.
    private static let maxCTAWords = 12

    // MARK: - Tag tokens

    /// True when a whitespace-delimited token is a social tag rather than recipe notation.
    ///
    /// `#` and `@` both carry real culinary meaning, so this is deliberately strict:
    /// "1 # ground beef" (pounds), "a #10 can", "Bake @ 350F", "Roast @425F" must all survive.
    /// The rules: trailing punctuation/emoji are trimmed off first (so "#dinner." and "#food🍑"
    /// still count, and a bare "#" or "@" reduces to nothing and never counts); the body must be
    /// at least two word characters and contain a letter (so "#2" and "#10" are not tags).
    /// A `#` tag may start with a digit — "#30minutemeals" is an extremely common hashtag —
    /// but an `@` tag may not, which is what keeps "@350F" out.
    static func isTagToken(_ token: some StringProtocol) -> Bool {
        guard let marker = token.first, marker == "#" || marker == "@" else { return false }
        // Keep only the leading run of word characters — this both strips trailing
        // punctuation/emoji and rejects a token whose body isn't tag-shaped.
        let body = token.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        guard body.count >= 2, body.contains(where: { $0.isLetter }) else { return false }
        if marker == "@", let first = body.first, !(first.isLetter || first == "_") { return false }
        return true
    }

    /// Remove a trailing run of tag tokens — the shape social captions actually use.
    /// "Bake 20 minutes #easy #dinner" → "Bake 20 minutes". Stops at the first non-tag token,
    /// so a `#` earlier in the line is never touched. Returns "" when the line was only tags.
    static func stripTrailingTags(_ line: String) -> String {
        var tokens = line.split(whereSeparator: \.isWhitespace)
        while let last = tokens.last, isTagToken(last) { tokens.removeLast() }
        return tokens.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t·•-–—,;:"))
    }

    // MARK: - Cleaning

    /// Clean one line: nil to drop it, "" for a blank line (kept so paragraph structure — and
    /// therefore header detection — survives), otherwise the line minus its trailing tag run.
    static func cleanLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        if isNoiseLine(trimmed) { return nil }
        let stripped = stripTrailingTags(trimmed)
        // Stripping emptied it → it was a tag wall after all; drop rather than emit a blank.
        return stripped.isEmpty ? nil : stripped
    }

    /// Clean one extracted field — an ingredient or a step, which may be several lines when it
    /// carries a bulleted list. nil when nothing survives. This is the guard every extractor's
    /// OUTPUT should pass through, so noise can't reach a recipe even from text we never cleaned
    /// on the way in (the LLM receives the raw caption by design).
    static func cleanEntry(_ text: String) -> String? {
        let kept = text.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : cleanLine(trimmed)
        }
        let joined = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// True when a caption line is social noise rather than recipe content.
    static func isNoiseLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }   // blank lines preserve structure

        // Hashtag / mention walls.
        let tokens = trimmed.split(whereSeparator: \.isWhitespace)
        if !tokens.isEmpty, tokens.allSatisfy({ isTagToken($0) }) { return true }

        // Emoji/punctuation-only decoration lines.
        if !trimmed.contains(where: { $0.isLetter || $0.isNumber }) { return true }

        // Phrase-match against the line with tag runs removed from BOTH ends and leading emoji
        // dropped — CTAs are routinely decorated ("💾 Save this!") or tagged ("#easyrecipes
        // Save this for later"), and either used to hide the phrase from a prefix match.
        var core = trimmed
        var tokensNoTags = core.split(whereSeparator: \.isWhitespace)
        while let first = tokensNoTags.first, isTagToken(first) { tokensNoTags.removeFirst() }
        while let last = tokensNoTags.last, isTagToken(last) { tokensNoTags.removeLast() }
        core = tokensNoTags.joined(separator: " ")
        let stripped = core.drop { !$0.isLetter && !$0.isNumber }.description.lowercased()
        guard !stripped.isEmpty else { return true }   // nothing but tags and decoration

        // A CTA only condemns a SHORT line; a long one is a real instruction that happens to
        // open with a marketing-sounding phrase.
        if stripped.split(whereSeparator: \.isWhitespace).count <= maxCTAWords {
            for phrase in ctaPhrases where stripped.hasPrefix(phrase) { return true }
        }
        for opener in narrativeOpeners where stripped.hasPrefix(opener) { return true }
        return false
    }

    /// Drop noise lines and strip trailing tag runs from the survivors, keeping blank lines so
    /// paragraph structure (and therefore header detection) survives. Idempotent: the pipeline
    /// cleans a caption before parsing and PastedTextExtractor cleans again defensively.
    static func clean(_ caption: String) -> String {
        caption.components(separatedBy: .newlines)
            .compactMap { cleanLine($0) }
            .joined(separator: "\n")
    }

    // MARK: - Result sanitizing

    /// Last line of defence: strip social noise from a finished extraction, whatever produced
    /// it. Applied at the pipeline boundary so results from the LLM (which is sent the RAW
    /// caption by design), the transcript validator, and the web-search fallbacks are all
    /// covered by one pass. A clean recipe passes through unchanged.
    static func sanitize(_ result: ExtractionResult) -> ExtractionResult {
        var out = result
        out.title = cleanTitle(result.title)
        out.ingredients = result.ingredients.compactMap { ingredient in
            guard let text = cleanEntry(ingredient.text) else { return nil }
            return RawIngredient(text: text, section: ingredient.section)
        }
        out.steps = result.steps.compactMap { step -> RawStep? in
            guard let text = cleanEntry(step.text) else { return nil }
            return RawStep(order: step.order, text: text, section: step.section)
        }
        // Re-number so a dropped step doesn't leave a gap in the sequence.
        out.steps = out.steps.enumerated().map { idx, step in
            RawStep(order: idx + 1, text: step.text, section: step.section)
        }
        return out
    }
}
