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

        // Parse "X, Y, and Z" style object list
        let objects = parseObjectList(remainder)
        guard objects.count >= 3 else { return [trimmed] }  // Only expand 3+ item lists

        return objects.map { obj in
            capitalizeAndTerminate("\(rawVerb) \(obj)")
        }
    }

    /// Parses "X, Y, and Z" or "X and Y and Z" into ["X", "Y", "Z"].
    private static func parseObjectList(_ text: String) -> [String] {
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
            return []
        }

        return parts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { part in
                let wordCount = part.split(separator: " ").count
                return !part.isEmpty && wordCount <= 4  // Reject long phrases — they're not simple objects
            }
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
