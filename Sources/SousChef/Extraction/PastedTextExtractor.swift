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

    /// Structural evidence gathered during a parse — the signals the pipeline's structurer
    /// skip-gate needs to judge whether this deterministic parse can be trusted outright
    /// (no LLM call) or the caption is messy enough to be worth spending tokens on.
    struct ParseAudit: Sendable {
        /// Document-wide occurrences of an ingredients header ("Ingredients:", "You'll need").
        /// More than one means a multi-component caption this parser handles poorly.
        var ingredientHeaderCount = 0
        /// Document-wide occurrences of a steps header ("Instructions:", "Method").
        var stepHeaderCount = 0
        /// True when the parse ran the structured path with BOTH headers present.
        var usedExplicitHeaders = false
        /// Non-empty lines discarded when the step region stopped at a second ingredient
        /// header — a silently dropped second component. Zero for a clean caption.
        var linesDiscardedAfterSteps = 0
    }

    // MARK: - Entry point

    func extract(text rawText: String) -> ExtractionResult {
        extractWithAudit(text: rawText).result
    }

    func extractWithAudit(text rawText: String) -> (result: ExtractionResult, audit: ParseAudit) {
        var result = ExtractionResult(extractionMethod: Self.method)
        var audit = ParseAudit()

        // Instagram captions arrive HTML-encoded, so bullets and dashes come through as
        // entities (&#x2022;, &#x2013;). Decode first so markers strip and text renders.
        // Skip the regex pass when there's nothing to decode — the pipeline already decoded.
        let decoded = rawText.contains("&") ? rawText.decodedHTMLEntities : rawText

        // Strip social noise here rather than at each call site: this covers the paste
        // importer and the photo scanner, where users paste and screenshot Instagram captions
        // complete with hashtag walls. `clean` is idempotent, so the pipeline pre-cleaning
        // the same text costs nothing.
        let text = SocialTextFilter.clean(decoded)

        let lines = text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\r")))
        }

        var ingHeaderIdx: Int?
        var stepHeaderIdx: Int?
        var subsectionIdx: Int?
        for (i, line) in lines.enumerated() where !line.isEmpty {
            if Self.isIngredientHeader(line) {
                audit.ingredientHeaderCount += 1
                if ingHeaderIdx == nil { ingHeaderIdx = i }
            } else if Self.isStepHeader(line) {
                audit.stepHeaderCount += 1
                if stepHeaderIdx == nil { stepHeaderIdx = i }
            }
            if subsectionIdx == nil, Self.isSubsection(line) { subsectionIdx = i }
        }
        audit.usedExplicitHeaders = ingHeaderIdx != nil && stepHeaderIdx != nil

        var title: String?
        var ingredients: [RawIngredient] = []
        var steps: [RawStep] = []

        if ingHeaderIdx != nil || stepHeaderIdx != nil {
            (title, ingredients, steps) = parseStructured(
                lines: lines,
                ingHeaderIdx: ingHeaderIdx,
                stepHeaderIdx: stepHeaderIdx,
                subsectionIdx: subsectionIdx,
                audit: &audit
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
        return (result, audit)
    }

    // MARK: - Structured parse (headers present)

    private func parseStructured(
        lines: [String], ingHeaderIdx: Int?, stepHeaderIdx: Int?, subsectionIdx: Int?,
        audit: inout ParseAudit
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
        // Steps that follow the ingredient list with NO steps header (common in social
        // captions) are recovered here by splitting the ingredient region at the first
        // prose-sentence line.
        var inlineStepLines: [String] = []
        if let start = ingStart {
            let end: Int
            if let s = stepHeaderIdx, s > start { end = s } else { end = lines.count }
            var currentSection: String?
            var inSteps = false
            var lastIngredientHadMarker = false
            for i in start..<end {
                let line = lines[i]
                if line.isEmpty { continue }
                if Self.isStepHeader(line) || Self.isIngredientHeader(line) { continue }
                if Self.isSubsection(line), !inSteps {
                    currentSection = Self.stripMarker(line)
                        .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                    continue
                }
                if stepHeaderIdx == nil, !inSteps, Self.isStepTransition(line) {
                    inSteps = true
                }
                if inSteps {
                    inlineStepLines.append(line)
                } else if !Self.hasListMarker(line), lastIngredientHadMarker,
                          var previous = ingredients.last {
                    // OCR wraps a long bulleted ingredient onto a second, unmarked line. In a
                    // marker-styled list every real item carries its bullet, so an unmarked
                    // line after a marked item is that item's continuation, not a new one.
                    previous.text += " " + line.trimmingCharacters(in: .whitespaces)
                    ingredients[ingredients.count - 1] = previous
                } else {
                    ingredients.append(RawIngredient(text: Self.stripMarker(line), section: currentSection))
                    lastIngredientHadMarker = Self.hasListMarker(line)
                }
            }
        }

        // Step region: an explicit steps header wins; otherwise use any inline steps split
        // out of the ingredient region above.
        var steps: [RawStep] = []
        if let s = stepHeaderIdx {
            var block: [String] = []
            var secondComponentStart: Int?
            for i in (s + 1)..<lines.count {
                let line = lines[i]
                if line.isEmpty { continue }
                if Self.isIngredientHeader(line) {
                    // A second component's ingredient list starts here (a sauce, a garnish).
                    secondComponentStart = i
                    break
                }
                block.append(line)
            }
            steps = Self.assembleSteps(from: block)

            // Recover the trailing components instead of discarding them — the guanciale in
            // "…Steps:… Ingredients for the sauce:…" used to vanish entirely.
            if let start = secondComponentStart {
                let (moreIngredients, moreSteps) = Self.parseTrailingComponents(lines: lines, from: start)
                ingredients.append(contentsOf: moreIngredients)
                steps.append(contentsOf: moreSteps)
                // Still flag the caption as multi-component so the structurer skip-gate stays
                // conservative — deterministic multi-part recovery is newer and worth checking.
                audit.linesDiscardedAfterSteps = lines[start...].filter { !$0.isEmpty }.count
            }
        } else if !inlineStepLines.isEmpty {
            steps = Self.assembleSteps(from: inlineStepLines)
        }

        // Re-number the merged step sequence so recovered components don't collide.
        steps = steps.enumerated().map { RawStep(order: $0 + 1, text: $1.text, section: $1.section) }

        return (title, ingredients, steps)
    }

    /// Parse a run of trailing "Ingredients …:/Steps:…" component blocks, tagging each
    /// component's ingredients and steps with a section derived from its ingredient header
    /// ("Ingredients for the sauce" → "sauce"). Handles any number of components.
    private static func parseTrailingComponents(lines: [String], from start: Int) -> ([RawIngredient], [RawStep]) {
        var ingredients: [RawIngredient] = []
        var steps: [RawStep] = []
        var i = start
        while i < lines.count {
            guard isIngredientHeader(lines[i]) else { i += 1; continue }
            let section = sectionName(fromIngredientHeader: lines[i])
            i += 1
            // Ingredient lines until a step header or the next component's ingredient header.
            var lastHadMarker = false
            while i < lines.count {
                let line = lines[i]
                if line.isEmpty { i += 1; continue }
                if isStepHeader(line) || isIngredientHeader(line) { break }
                if !hasListMarker(line), lastHadMarker, var previous = ingredients.last {
                    previous.text += " " + line.trimmingCharacters(in: .whitespaces)
                    ingredients[ingredients.count - 1] = previous
                } else {
                    ingredients.append(RawIngredient(text: stripMarker(line), section: section))
                    lastHadMarker = hasListMarker(line)
                }
                i += 1
            }
            // Optional step header + step lines until the next component.
            if i < lines.count, isStepHeader(lines[i]) {
                i += 1
                var block: [String] = []
                while i < lines.count {
                    let line = lines[i]
                    if !line.isEmpty, isIngredientHeader(line) { break }
                    if !line.isEmpty { block.append(line) }
                    i += 1
                }
                for step in assembleSteps(from: block) {
                    steps.append(RawStep(order: 0, text: step.text, section: section))
                }
            }
        }
        return (ingredients, steps)
    }

    /// The component name embedded in an ingredient header, or nil for a bare "Ingredients:".
    /// "Ingredients for the sauce" → "sauce"; "Sauce ingredients" → "sauce".
    private static func sectionName(fromIngredientHeader line: String) -> String? {
        var s = normalizeHeader(line)   // lowercased, markers/colon stripped
        for prefix in ["ingredients for the ", "ingredients for ", "ingredients ", "ingredient "]
        where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)); break }
        if s.hasSuffix(" ingredients") { s = String(s.dropLast(" ingredients".count)) }
        s = s.trimmingCharacters(in: .whitespaces)
        return (s.isEmpty || s == "ingredients" || s == "ingredient") ? nil : s
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
            // In a marker-styled block (numbered / bulleted), an unmarked line is the
            // previous step's OCR wrap, not a new step. A plain unmarked block keeps its
            // line-per-step behavior — the >= 2 marked-lines requirement is what separates
            // the two shapes.
            let markedCount = block.filter { hasListMarker($0) }.count
            if markedCount >= 2 {
                parts = []
                for line in block {
                    if !hasListMarker(line), !parts.isEmpty {
                        parts[parts.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
                    } else {
                        parts.append(stripMarker(line))
                    }
                }
            } else {
                parts = block.map { stripMarker($0) }
            }
        }
        // Every step is born here, so this is where output filtering belongs: splitting a
        // block into sentences can re-expose a trailing tag run ("…until golden. #easyrecipes")
        // that line-based cleaning had no chance to see, because it wasn't its own line.
        return parts
            .compactMap { SocialTextFilter.cleanEntry($0) }
            .enumerated()
            .map { RawStep(order: $0.offset + 1, text: $0.element) }
    }

    // MARK: - Line classification

    private static func normalizeHeader(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        s = regexReplaceFirst(s, pattern: "^[#>*_`\\s]+", with: "")
        // Social captions decorate headers with emoji ("🤍🍑 Ingredients for 2 sides"). Without
        // stripping them the header goes unrecognized and the whole caption falls through to
        // headerless parsing, turning marketing prose into ingredients (real Instagram bug).
        s = s.drop { !$0.isLetter && !$0.isNumber }.description
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

    /// First prose-sentence line after an ingredient list — where steps begin when a
    /// caption has an ingredients header but no steps header. Ingredient-shaped lines never
    /// trigger it, so a header-less bulleted list stays intact until the method starts.
    static func isStepTransition(_ line: String) -> Bool {
        if looksLikeIngredient(line) { return false }
        let s = stripMarker(line)
        let wordCount = s.split(separator: " ").count
        if let last = s.trimmingCharacters(in: .whitespaces).last,
           ".!?".contains(last), wordCount >= 5 {
            return true
        }
        return looksLikeStep(line)
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

    /// True when the line opens with a list marker (bullet, checkbox, "1.", "Step 2:").
    static func hasListMarker(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let re = markerRE else { return false }
        return re.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
    }

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

// MARK: - HTML entity decoding

extension String {
    /// Decode HTML entities — the common named ones plus decimal (`&#8226;`) and hex
    /// (`&#x2022;`) numeric references. Instagram captions arrive HTML-encoded, so bullets
    /// (`&#x2022;`), en-dashes (`&#x2013;`), and ampersands (`&amp;`) would otherwise show
    /// verbatim in ingredients and steps. Idempotent, so decoding already-plain text is safe.
    var decodedHTMLEntities: String {
        var s = self
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                               ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        guard let re = try? NSRegularExpression(pattern: "&#([xX])?([0-9a-fA-F]+);") else { return s }
        let range = NSRange(s.startIndex..., in: s)
        for match in re.matches(in: s, range: range).reversed() {
            guard let codeRange = Range(match.range(at: 2), in: s),
                  let fullRange = Range(match.range, in: s) else { continue }
            let isHex = match.range(at: 1).location != NSNotFound
            guard let code = UInt32(s[codeRange], radix: isHex ? 16 : 10),
                  let scalar = Unicode.Scalar(code) else { continue }
            s.replaceSubrange(fullRange, with: String(scalar))
        }
        return s
    }
}
