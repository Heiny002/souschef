import Foundation
import NaturalLanguage

/// SC-040: Layer 5 — Rule-based NLP extraction from video transcripts.
/// Pipeline: sentence tokenization → number normalization → quantity+unit regex →
/// food entity matching → proximity grouping → instruction extraction.
struct TranscriptExtractor {
    private static let method = "transcript-nlp"
    private let foodDict = FoodDictionary.shared
    private let ingredientParser = IngredientParser()

    func extract(transcript: String) -> ExtractionResult {
        var result = ExtractionResult(extractionMethod: Self.method)

        let normalized = normalizeNumbers(transcript)
        let sentences = tokenizeSentences(normalized)

        result.ingredients = extractIngredients(from: sentences, original: normalized)
        result.steps = extractSteps(from: sentences)
        result.recipeYield = extractYield(from: normalized)
        result.totalTime = extractTime(from: normalized, labels: ["total", "altogether", "in all"])
        result.cookTime = extractTime(from: normalized, labels: ["cook", "cooking", "bake", "baking", "roast"])
        result.prepTime = extractTime(from: normalized, labels: ["prep", "prepare", "preparation"])
        result.appliances = ApplianceDetector.detect(in: sentences)
        result.confidence = computeConfidence(result)
        return result
    }

    // MARK: - Number Normalization

    private static let wordToNumber: [(String, String)] = [
        ("one and a half", "1.5"), ("two and a half", "2.5"), ("three and a half", "3.5"),
        ("half a", "0.5"), ("a half", "0.5"), ("half", "0.5"),
        ("a quarter", "0.25"), ("one quarter", "0.25"),
        ("one", "1"), ("two", "2"), ("three", "3"), ("four", "4"), ("five", "5"),
        ("six", "6"), ("seven", "7"), ("eight", "8"), ("nine", "9"), ("ten", "10"),
        ("eleven", "11"), ("twelve", "12"), ("a dozen", "12"), ("dozen", "12"),
        ("a couple of", "2"), ("a couple", "2"), ("a few", "3"),
        ("a tablespoon", "1 tablespoon"), ("a teaspoon", "1 teaspoon"),
        ("a cup", "1 cup"), ("a handful", "1 handful"), ("a pinch", "1 pinch"),
        ("an ounce", "1 ounce"), ("a pound", "1 pound"),
        ("about", ""), ("approximately", ""), ("around", ""), ("roughly", "")
    ]

    private func normalizeNumbers(_ text: String) -> String {
        var result = text.lowercased()
        for (word, replacement) in Self.wordToNumber {
            result = result.replacingOccurrences(of: " \(word) ", with: " \(replacement) ")
            if result.hasPrefix("\(word) ") {
                result = replacement + " " + result.dropFirst(word.count + 1)
            }
        }
        return result
    }

    // MARK: - Sentence Tokenization

    private func tokenizeSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        return sentences.isEmpty ? text.components(separatedBy: ". ") : sentences
    }

    // MARK: - Ingredient Extraction

    private static let unitTokens: Set<String> = [
        "tablespoon", "tablespoons", "tbsp", "teaspoon", "teaspoons", "tsp",
        "cup", "cups", "ounce", "ounces", "oz", "pound", "pounds", "lb", "lbs",
        "gram", "grams", "g", "kilogram", "kilograms", "kg",
        "milliliter", "milliliters", "ml", "liter", "liters",
        "can", "cans", "bunch", "bunches", "clove", "cloves", "piece", "pieces",
        "slice", "slices", "sprig", "sprigs", "pinch", "pinches", "dash", "dashes",
        "handful", "handfuls", "head", "heads", "stalk", "stalks"
    ]

    private func extractIngredients(from sentences: [String], original: String) -> [RawIngredient] {
        var ingredients: [RawIngredient] = []
        var seen = Set<String>()

        for sentence in sentences {
            let tokens = tokenizeWords(sentence)

            for i in 0..<tokens.count {
                // Look for quantity token
                guard isQuantityToken(tokens[i]) else { continue }

                // Look for unit within 2 tokens
                var unitIndex: Int? = nil
                for j in (i+1)..<min(i+3, tokens.count) {
                    if Self.unitTokens.contains(tokens[j].lowercased()) {
                        unitIndex = j
                        break
                    }
                }

                // Look for food entity within 5 tokens of quantity (or unit)
                let searchStart = (unitIndex ?? i) + 1
                let searchEnd = min(searchStart + 5, tokens.count)
                for k in searchStart..<searchEnd {
                    let word = tokens[k].lowercased()
                    // Direct lookup
                    if let _ = foodDict.find(name: word) {
                        let ingredient = buildIngredientText(tokens: tokens, from: i, to: k)
                        let key = ingredient.lowercased()
                        if !seen.contains(key) {
                            ingredients.append(RawIngredient(text: ingredient))
                            seen.insert(key)
                        }
                        break
                    }
                    // Two-word compound (e.g. "chicken breast")
                    if k + 1 < tokens.count {
                        let twoWord = "\(word) \(tokens[k+1].lowercased())"
                        if let _ = foodDict.find(name: twoWord) {
                            let ingredient = buildIngredientText(tokens: tokens, from: i, to: k + 1)
                            let key = ingredient.lowercased()
                            if !seen.contains(key) {
                                ingredients.append(RawIngredient(text: ingredient))
                                seen.insert(key)
                            }
                            break
                        }
                    }
                    // Fuzzy match (misspellings)
                    if word.count > 4, let _ = foodDict.fuzzyFind(name: word) {
                        let ingredient = buildIngredientText(tokens: tokens, from: i, to: k)
                        let key = ingredient.lowercased()
                        if !seen.contains(key) {
                            ingredients.append(RawIngredient(text: ingredient))
                            seen.insert(key)
                        }
                        break
                    }
                }
            }
        }

        return ingredients
    }

    private func buildIngredientText(tokens: [String], from start: Int, to end: Int) -> String {
        tokens[start...min(end, tokens.count-1)].joined(separator: " ")
    }

    private func isQuantityToken(_ s: String) -> Bool {
        if let _ = Double(s) { return true }
        if s.contains("/") {
            let parts = s.components(separatedBy: "/")
            return parts.count == 2 && parts.allSatisfy { Double($0) != nil }
        }
        return false
    }

    private func tokenizeWords(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "/."))) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Step Extraction

    // Temporal marker words that signal a new cooking step
    private static let temporalMarkers = [
        "first", "second", "third", "next", "then", "after", "once", "when",
        "now", "finally", "lastly", "meanwhile", "while", "start by", "begin by",
        "to start", "to finish", "step 1", "step 2", "step 3", "step 4", "step 5",
        "step one", "step two", "step three"
    ]

    private func extractSteps(from sentences: [String]) -> [RawStep] {
        // Filter to instruction-like sentences (contains a verb + cooking action)
        let cookingVerbs = Set(["add", "mix", "stir", "cook", "heat", "bake", "roast", "fry",
                                "sauté", "saute", "boil", "simmer", "blend", "chop", "dice",
                                "slice", "peel", "season", "combine", "pour", "place", "put",
                                "remove", "transfer", "drain", "fold", "whisk", "beat", "cream",
                                "knead", "roll", "cut", "serve", "let", "allow", "rest", "cool",
                                "refrigerate", "freeze", "marinate", "coat", "brush", "sprinkle",
                                "garnish", "squeeze", "grate", "mince", "crush", "press"])

        var steps: [RawStep] = []
        var order = 1

        for sentence in sentences {
            let lower = sentence.lowercased()
            let words = Set(lower.components(separatedBy: .whitespaces))

            // Include sentence if it contains a cooking verb or temporal marker
            let hasCookingVerb = !words.intersection(cookingVerbs).isEmpty
            let hasTemporalMarker = Self.temporalMarkers.contains { lower.hasPrefix($0) || lower.contains(" \($0) ") }

            if (hasCookingVerb || hasTemporalMarker) && sentence.count > 15 {
                steps.append(RawStep(order: order, text: sentence))
                order += 1
            }
        }

        // If we got very few steps from filtering, fall back to all long sentences
        if steps.count < 2 {
            steps = sentences.enumerated().compactMap { idx, s in
                guard s.count > 20 else { return nil }
                return RawStep(order: idx + 1, text: s)
            }
        }

        return steps
    }

    // MARK: - Yield + Time

    private func extractYield(from text: String) -> String? {
        let patterns = [
            #"serves?\s*(\d+(?:\s*[-–]\s*\d+)?)"#,
            #"makes?\s*(\d+(?:\s*[-–]\s*\d+)?(?:\s+\w+)?)"#,
            #"(\d+)\s+servings?"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }
        }
        return nil
    }

    private func extractTime(from text: String, labels: [String]) -> Int? {
        for label in labels {
            let pattern = "\(NSRegularExpression.escapedPattern(for: label))\\s*(?:for\\s*)?(\\d+(?:\\.\\d+)?)\\s*(hr?s?|hour?s?|min(?:ute)?s?)"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let numRange = Range(match.range(at: 1), in: text),
               let unitRange = Range(match.range(at: 2), in: text),
               let value = Double(text[numRange]) {
                let unit = text[unitRange].lowercased()
                return Int(unit.hasPrefix("h") ? value * 3600 : value * 60)
            }
        }
        return nil
    }

    // MARK: - Confidence

    private func computeConfidence(_ result: ExtractionResult) -> Double {
        if result.ingredients.count >= 3 && result.steps.count >= 2 { return 0.7 }
        if result.ingredients.count >= 1 && result.steps.count >= 1 { return 0.4 }
        return 0.1
    }
}
