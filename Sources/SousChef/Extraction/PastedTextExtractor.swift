import Foundation

/// Extracts a recipe from raw pasted text — fully offline, no network and no LLM.
///
/// Most pasted recipes are structured: a title, an "Ingredients" heading over a list, and
/// an "Instructions/Directions/Method" heading over numbered steps. That structure is
/// parsed directly. When there's no explicit ingredients heading we treat the lines
/// between the title and the steps heading as ingredients (handles "For the sauce:"–style
/// subsections), and with no headings at all we fall back to a per-line shape heuristic.
/// `ReviewView` is the safety net — whatever we get wrong, the user fixes before saving,
/// so the goal here is a good first pass rather than perfection.
struct PastedTextExtractor {
    static let method = "pasted-text"

    // MARK: - Header vocab

    private static let ingredientHeaders: Set<String> = [
        "ingredients", "ingredient", "what you need", "you'll need", "you will need",
        "shopping list",
    ]
    private static let stepHeaders: Set<String> = [
        "instructions", "instruction", "directions", "direction", "method", "steps",
        "step", "preparation", "how to make it", "how to make", "to make it", "to make",
    ]

    // MARK: - Entry point

    func extract(text: String) -> ExtractionResult {
        var result = ExtractionResult(extractionMethod: Self.method)

        let lines = text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\r")))
        }

        var ingHeaderIdx: Int?
        var stepHeaderIdx: Int?
        var subsectionIdx: Int?
        for (i, line) in lines.enumerated() where !line.isEmpty {
            if ingHeaderIdx == nil, Self.isIngredientHeader(line) { ingHeaderIdx = i }
            else if stepHeaderIdx == nil, Self.isStepHeader(line) { stepHeaderIdx = i }
            if subsectionIdx == nil, Self.isSubsection(line) { subsectionIdx = i }
        }

        var title: String?
        var ingredients: [RawIngredient] = []
        var steps: [RawStep] = []

        if ingHeaderIdx != nil || stepHeaderIdx != nil {
            (title, ingredients, steps) = parseStructured(
                lines: lines,
                ingHeaderIdx: ingHeaderIdx,
                stepHeaderIdx: stepHeaderIdx,
                subsectionIdx: subsectionIdx
            )
        } else {
            (title, ingredients, steps) = parseHeuristic(lines: lines)
        }

        result.title = (title?.isEmpty == false) ? title : firstNonEmpty(lines)
        result.ingredients = ingredients
        result.steps = steps
        result.recipeYield = Self.extractYield(from: text)
        result.totalTime = Self.extractTime(from: text, labels: ["total", "altogether"])
        result.cookTime = Self.extractTime(from: text, labels: ["cook", "bake", "roast", "grill"])
        result.prepTime = Self.extractTime(from: text, labels: ["prep", "prepare", "preparation"])
        result.confidence = Self.confidence(ingredients: ingredients, steps: steps)
        return result
    }

    // MARK: - Structured parse (headers present)

    private func parseStructured(
        lines: [String], ingHeaderIdx: Int?, stepHeaderIdx: Int?, subsectionIdx: Int?
    ) -> (String?, [RawIngredient], [RawStep]) {
        let anchors = [ingHeaderIdx, stepHeaderIdx, subsectionIdx].compactMap { $0 }
        let earliest = anchors.min() ?? 0

        // Title: first substantive line above the earliest structural anchor.
        var title: String?
        var titleIdx: Int?
        for i in 0..<earliest where !lines[i].isEmpty {
            if !Self.isIngredientHeader(lines[i]),
               !Self.isStepHeader(lines[i]),
               !Self.isSubsection(lines[i]) {
                title = Self.stripMarker(lines[i])
                titleIdx = i
                break
            }
        }

        // Ingredient region: after the ingredients header, or (when there's no explicit
        // ingredients header) everything from just below the title down to the steps header.
        var ingStart: Int?
        if let h = ingHeaderIdx {
            ingStart = h + 1
        } else if stepHeaderIdx != nil {
            ingStart = (titleIdx.map { $0 + 1 }) ?? 0
        }

        var ingredients: [RawIngredient] = []
        if let start = ingStart {
            let end: Int
            if let s = stepHeaderIdx, s > start { end = s } else { end = lines.count }
            var currentSection: String?
            for i in start..<end {
                let line = lines[i]
                if line.isEmpty { continue }
                if Self.isStepHeader(line) || Self.isIngredientHeader(line) { continue }
                if Self.isSubsection(line) {
                    currentSection = Self.stripMarker(line)
                        .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                    continue
                }
                ingredients.append(RawIngredient(text: Self.stripMarker(line), section: currentSection))
            }
        }

        // Step region: after the steps header to the end (or a stray ingredients header).
        var steps: [RawStep] = []
        if let s = stepHeaderIdx {
            var block: [String] = []
            for i in (s + 1)..<lines.count {
                let line = lines[i]
                if line.isEmpty { continue }
                if Self.isIngredientHeader(line) { break }
                block.append(line)
            }
            steps = Self.assembleSteps(from: block)
        }

        return (title, ingredients, steps)
    }

    // MARK: - Heuristic parse (no headers)

    /// Title is the first line; then accumulate ingredient-shaped lines until the first
    /// clearly step-shaped line, after which everything is a step. "Salt to taste" (no
    /// quantity) still lands in ingredients because it precedes the first instruction.
    private func parseHeuristic(lines: [String]) -> (String?, [RawIngredient], [RawStep]) {
        let body = lines.filter { !$0.isEmpty }
        guard let first = body.first else { return (nil, [], []) }
        let title = Self.stripMarker(first)

        var ingredients: [RawIngredient] = []
        var stepLines: [String] = []
        var inSteps = false
        for line in body.dropFirst() {
            if !inSteps, Self.looksLikeStep(line), !Self.looksLikeIngredient(line) {
                inSteps = true
            }
            if inSteps {
                stepLines.append(line)
            } else {
                ingredients.append(RawIngredient(text: Self.stripMarker(line), section: nil))
            }
        }
        return (title, ingredients, Self.assembleSteps(from: stepLines))
    }

    // MARK: - Step assembly

    /// Turn a block of step lines into ordered steps. A single-line block that packs
    /// several sentences (or inline "1. … 2. …" numbering) is exploded so the cook sees
    /// discrete steps; multi-line blocks are taken line-per-step.
    private static func assembleSteps(from block: [String]) -> [RawStep] {
        var parts: [String]
        if block.count == 1 {
            parts = splitInlineNumbered(block[0])
            if parts.count == 1 {
                let sentences = splitSentences(parts[0])
                if sentences.count > 1 { parts = sentences }
            }
        } else {
            parts = block.map { stripMarker($0) }
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { RawStep(order: $0.offset + 1, text: $0.element) }
    }

    // MARK: - Line classification

    private static func normalizeHeader(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        s = regexReplaceFirst(s, pattern: "^[#>*_`\\s]+", with: "")
        s = regexReplaceFirst(s, pattern: "[#*_`:：\\s]+$", with: "")
        s = regexReplaceFirst(s, pattern: "^\\d+[.)]\\s*", with: "")
        return s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func isIngredientHeader(_ line: String) -> Bool {
        let n = normalizeHeader(line)
        return ingredientHeaders.contains(n) || n.hasPrefix("ingredient")
    }

    private static func isStepHeader(_ line: String) -> Bool {
        let n = normalizeHeader(line)
        return stepHeaders.contains(n)
            || n.hasPrefix("instruction") || n.hasPrefix("direction") || n.hasPrefix("method")
    }

    /// "For the sauce:", "For the topping" — an ingredient subsection label, not a header.
    private static func isSubsection(_ line: String) -> Bool {
        let n = normalizeHeader(line)
        return (n.hasPrefix("for the ") || n.hasPrefix("for ")) && n.count < 40
    }

    private static let fractionScalars = Set("½¼¾⅓⅔⅛⅜⅝⅞".unicodeScalars)
    private static let quantityWords: Set<String> = [
        "a", "an", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "half", "quarter", "dozen",
    ]
    private static let unitTokens: Set<String> = [
        "cup", "cups", "tbsp", "tablespoon", "tablespoons", "tsp", "teaspoon", "teaspoons",
        "oz", "ounce", "ounces", "lb", "lbs", "pound", "pounds", "g", "gram", "grams", "kg",
        "ml", "l", "liter", "liters", "can", "cans", "clove", "cloves", "pinch", "dash",
        "slice", "slices", "stick", "sticks", "bunch", "handful", "package", "packages",
        "pkg", "sprig", "sprigs", "head", "stalk", "stalks",
    ]
    private static let cookVerbs: Set<String> = [
        "preheat", "mix", "stir", "cook", "heat", "bake", "roast", "fry", "saute", "sauté",
        "boil", "simmer", "blend", "chop", "dice", "slice", "peel", "season", "combine",
        "pour", "place", "put", "remove", "transfer", "drain", "fold", "whisk", "beat",
        "cream", "knead", "roll", "cut", "serve", "let", "allow", "rest", "cool",
        "refrigerate", "freeze", "marinate", "coat", "brush", "sprinkle", "garnish",
        "squeeze", "grate", "mince", "crush", "press", "add", "bring", "reduce", "cover",
        "toss", "spread", "top", "arrange", "warm", "melt", "sear",
    ]

    private static func looksLikeIngredient(_ line: String) -> Bool {
        let s = stripMarker(line).lowercased()
        guard let first = s.split(separator: " ").first else { return false }
        if let scalar = first.unicodeScalars.first,
           CharacterSet.decimalDigits.contains(scalar) || fractionScalars.contains(scalar) {
            return true
        }
        if quantityWords.contains(String(first)), s.split(separator: " ").count <= 6 { return true }
        let words = Set(s.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return !words.isDisjoint(with: unitTokens)
    }

    private static func looksLikeStep(_ line: String) -> Bool {
        let s = stripMarker(line).lowercased()
        if let first = s.split(separator: " ").first {
            let word = String(first).trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
            if cookVerbs.contains(word) { return true }
        }
        return s.count > 60
    }

    // MARK: - Yield + time

    private static func extractYield(from text: String) -> String? {
        let patterns = [
            #"serves?\s*(\d+(?:\s*[-–]\s*\d+)?)"#,
            #"makes?\s*(\d+(?:\s*[-–]\s*\d+)?(?:\s+\w+)?)"#,
            #"(\d+)\s+servings?"#,
            #"yield[:\s]+(\d+(?:\s+\w+)?)"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range(at: 1), in: text) {
                return text[r].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func extractTime(from text: String, labels: [String]) -> Int? {
        let lower = text.lowercased()
        for label in labels {
            if let secs = DurationTextParser.seconds(in: lower, after: label) { return secs }
        }
        return nil
    }

    // MARK: - Confidence

    private static func confidence(ingredients: [RawIngredient], steps: [RawStep]) -> Double {
        if ingredients.count >= 3 && steps.count >= 2 { return 0.75 }
        if !ingredients.isEmpty && !steps.isEmpty { return 0.5 }
        if !ingredients.isEmpty || !steps.isEmpty { return 0.3 }
        return 0.1
    }

    // MARK: - Text utilities

    private func firstNonEmpty(_ lines: [String]) -> String? {
        lines.first { !$0.isEmpty }.map { Self.stripMarker($0) }
    }

    private static let markerRE = try? NSRegularExpression(
        pattern: #"^\s*(?:[-*•·▢□◦‣⁃]\s+|\[\s?\]\s*|\d+\s*[.)]\s+|step\s*\d+\s*[:.)-]?\s*)"#,
        options: .caseInsensitive
    )

    /// Strip a single leading list marker (bullet, "1.", "Step 2:", checkbox).
    static func stripMarker(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let re = markerRE else { return trimmed }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let m = re.firstMatch(in: trimmed, range: range),
              let r = Range(m.range, in: trimmed) else { return trimmed }
        return String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// Split "1. do this 2. do that" packed onto one line.
    private static func splitInlineNumbered(_ line: String) -> [String] {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard let re = try? NSRegularExpression(pattern: #"(?<=\s)(?=\d+\s*[.)]\s+)"#) else {
            return [stripMarker(text)]
        }
        // Insert a delimiter before each interior "N." marker, then split on it.
        let ns = NSMutableString(string: text)
        let count = re.replaceMatches(
            in: ns, range: NSRange(location: 0, length: ns.length), withTemplate: "\u{0001}")
        guard count > 0 else { return [stripMarker(text)] }
        return (ns as String).components(separatedBy: "\u{0001}")
            .map { stripMarker($0) }
            .filter { !$0.isEmpty }
    }

    /// Split a paragraph into sentences at "…. Capital"/"…! 3" boundaries.
    private static func splitSentences(_ paragraph: String) -> [String] {
        let text = paragraph.trimmingCharacters(in: .whitespaces)
        guard let re = try? NSRegularExpression(pattern: #"(?<=[.!?])\s+(?=[A-Z0-9])"#) else {
            return [text]
        }
        let ns = NSMutableString(string: text)
        re.replaceMatches(
            in: ns, range: NSRange(location: 0, length: ns.length), withTemplate: "\u{0001}")
        return (ns as String).components(separatedBy: "\u{0001}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func regexReplaceFirst(_ s: String, pattern: String, with repl: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), let r = Range(m.range, in: s) else { return s }
        return s.replacingCharacters(in: r, with: repl)
    }
}
