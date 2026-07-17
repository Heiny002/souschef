import Foundation

/// Splits compound cooking instructions into discrete micro-steps for Cook Mode.
/// Example: "Dice the carrots, celery, and onion." → ["Dice the carrots.", "Dice the celery.", "Dice the onion."]
/// Only splits when the result is 3+ items sharing the same action verb.
enum MicroStepSplitter {

    /// Break a single instruction into micro-steps. Returns [instruction] unchanged if no useful split found.
    static func split(_ instruction: String) -> [String] {
        // First pass: sentence / clause splitting
        let clauses = splitClauses(instruction)

        var results: [String] = []
        for clause in clauses {
            let compound = trySplitCompound(clause)
            results.append(contentsOf: compound)
        }
        return results.isEmpty ? [instruction] : results
    }

    // MARK: - Clause splitting on punctuation / conjunctions

    private static func splitClauses(_ text: String) -> [String] {
        var parts: [String] = [text]

        // Split on "; ", ". ", ", then ", " and then ", " then "
        let separators = ["; ", ". ", ", then ", " and then ", ", next "]
        for sep in separators {
            parts = parts.flatMap { part -> [String] in
                let pieces = part.components(separatedBy: sep)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                return pieces.count > 1 ? pieces : [part]
            }
        }
        return parts
    }

    // MARK: - Compound object detection ("verb X, Y, and Z")

    private static let actionVerbs: Set<String> = [
        "dice", "chop", "slice", "mince", "cut", "peel", "wash", "rinse", "drain",
        "add", "mix", "stir", "combine", "fold", "grate", "shred", "tear",
        "crush", "smash", "pound", "coat", "toss", "sprinkle", "drizzle",
        "squeeze", "season", "trim", "halve", "quarter", "julienne", "blanch",
        "toast", "roast", "fry", "sauté", "sear", "brown"
    ]

    private static func trySplitCompound(_ sentence: String) -> [String] {
        let trimmed = sentence.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        // Pull the leading verb (first word, stripped of punctuation)
        let words = trimmed.components(separatedBy: " ")
        guard let rawVerb = words.first else { return [trimmed] }
        let verb = rawVerb.trimmingCharacters(in: .punctuationCharacters).lowercased()
        guard actionVerbs.contains(verb) else { return [trimmed] }

        // Everything after the verb
        let remainder = words.dropFirst().joined(separator: " ")

        // Parse "X, Y, and Z" style object list. nil ⇒ some part didn't look like a
        // simple object — keep the sentence intact. Losing a split is safe; dropping an
        // ingredient or fabricating a step ("Add cook until fragrant.") is not (H10).
        guard let objects = parseObjectList(remainder), objects.count >= 3 else {
            return [trimmed]
        }

        return objects.map { obj in
            capitalizeAndTerminate("\(rawVerb) \(obj)")
        }
    }

    /// Words that mark a part as a trailing instruction clause, not an object —
    /// "…onion, garlic, and cook until fragrant, about 2 minutes."
    private static let clauseMarkers: Set<String> = [
        "cook", "stir", "simmer", "sauté", "saute", "heat", "bring", "let", "cover",
        "reduce", "season", "serve", "bake", "boil", "fry", "mix", "continue", "repeat",
        "set", "remove", "transfer", "add", "about", "until", "then",
    ]

    /// Parses "X, Y, and Z" or "X and Y and Z" into ["X", "Y", "Z"].
    /// Returns nil — meaning "don't split at all" — if ANY part fails the simple-object
    /// check. The old version silently *dropped* failing parts and split anyway, deleting
    /// instruction content ("…and the softened butter cut into cubes" vanished).
    private static func parseObjectList(_ text: String) -> [String]? {
        var s = text
        if s.hasSuffix(".") { s = String(s.dropLast()) }

        // Normalise "X, Y, and Z" → "X, Y, Z"
        s = s.replacingOccurrences(of: ", and ", with: ", ")
             .replacingOccurrences(of: ", or ", with: ", ")
             .replacingOccurrences(of: " and the ", with: " and ")

        var parts: [String]
        if s.contains(", ") {
            parts = s.components(separatedBy: ", ")
        } else if s.contains(" and ") {
            parts = s.components(separatedBy: " and ")
        } else {
            return nil
        }

        let trimmedParts = parts.map { $0.trimmingCharacters(in: .whitespaces) }
        for part in trimmedParts where !isSimpleObject(part) {
            return nil   // one bad part poisons the whole split
        }
        return trimmedParts
    }

    /// A short noun phrase like "the carrots" / "softened butter" — not an instruction
    /// clause, duration, or long phrase.
    private static func isSimpleObject(_ part: String) -> Bool {
        guard !part.isEmpty else { return false }
        let words = part.lowercased().split(separator: " ").map(String.init)
        guard words.count <= 4 else { return false }
        // A part that starts with (or contains) an instruction/duration marker is a
        // clause, not an object — "cook until fragrant", "about 2 minutes".
        guard let first = words.first else { return false }
        if clauseMarkers.contains(first) { return false }
        if words.contains("until") || words.contains("about") { return false }
        return true
    }

    private static func capitalizeAndTerminate(_ s: String) -> String {
        guard let first = s.first else { return s }
        var result = String(first).uppercased() + s.dropFirst()
        if !result.hasSuffix(".") && !result.hasSuffix("!") && !result.hasSuffix("?") {
            result += "."
        }
        return result
    }
}
