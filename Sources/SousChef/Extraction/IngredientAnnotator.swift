import Foundation
import SwiftData

/// Annotates microstep text with ingredient measurements on first mention.
/// "Dice the carrots." → "Dice the carrots (2 cups)." when the recipe has 2 cups of carrots.
enum IngredientAnnotator {

    /// Annotate a sequence of microstep instructions, inserting measurement on first mention of each ingredient.
    static func annotate(_ instructions: [String], with ingredients: [Ingredient]) -> [String] {
        // Sort ingredients longest-item-first so "olive oil" matches before "oil"
        let sorted = ingredients.sorted { $0.item.count > $1.item.count }
        var mentioned: Set<String> = []  // normalised item names already annotated
        return instructions.map { text in
            annotateStep(text, ingredients: sorted, mentioned: &mentioned)
        }
    }

    // MARK: - Private

    private static func annotateStep(
        _ text: String,
        ingredients: [Ingredient],
        mentioned: inout Set<String>
    ) -> String {
        // Collect every insertion first, as `String.Index` positions in the ORIGINAL text,
        // then apply them right-to-left. Two bugs this avoids:
        //  1. NSRange (UTF-16) offsets were fed to `index(_:offsetBy:)` (grapheme counting),
        //     so any emoji/accented char — routine in scraped step text — mis-placed the
        //     measurement or trapped when the offset ran past the end.
        //  2. Offsets measured against the fixed original were inserted into a progressively
        //     mutated string, so later insertions landed short by the earlier ones' length
        //     ("Add the olive oil (2 tbsp) a (1 clove)nd garlic.").
        // Inserting from the highest index downward keeps every remaining index valid.
        var result = text
        var insertions: [(at: String.Index, text: String)] = []
        var claimed: [Range<String.Index>] = []

        for ingredient in ingredients {
            let key = ingredient.item.lowercased()
            guard !mentioned.contains(key) else { continue }

            // Skip ingredients with no quantity info to annotate
            guard ingredient.quantity != nil || ingredient.unit != nil else { continue }

            // Find the ingredient name (case-insensitive) in the original text.
            guard let range = findIngredient(key, in: result) else { continue }

            // Skip a shorter name nested inside an already-claimed longer one
            // ("oil" inside a matched "olive oil").
            guard !claimed.contains(where: { $0.overlaps(range) }) else { continue }

            let measurement = formatMeasurement(ingredient)
            guard !measurement.isEmpty else { continue }

            mentioned.insert(key)
            claimed.append(range)
            insertions.append((range.upperBound, " (\(measurement))"))
        }

        for insertion in insertions.sorted(by: { $0.at > $1.at }) {
            result.insert(contentsOf: insertion.text, at: insertion.at)
        }
        return result
    }

    /// Find ingredient name in text, handling singular/plural.
    /// Returns the range (in `text`'s own index space) of the match.
    private static func findIngredient(_ item: String, in text: String) -> Range<String.Index>? {
        let variants = nameVariants(item)
        for variant in variants {
            if let range = wordBoundaryRange(of: variant, in: text) {
                return range
            }
        }
        return nil
    }

    /// Generate matching variants: exact, singular/plural, and first-word for multi-word items.
    private static func nameVariants(_ item: String) -> [String] {
        var variants = [item]

        // Plural ↔ singular
        if item.hasSuffix("ies") {
            variants.append(String(item.dropLast(3)) + "y")  // berries → berry
        } else if item.hasSuffix("es") {
            variants.append(String(item.dropLast(2)))         // tomatoes → tomato
            variants.append(String(item.dropLast(1)))         // cloves → clov… fallback
        } else if item.hasSuffix("s") {
            variants.append(String(item.dropLast()))          // carrots → carrot
        } else {
            variants.append(item + "s")                       // carrot → carrots
            variants.append(item + "es")                      // tomato → tomatoes
        }

        // For multi-word items like "garlic cloves", also try the first word
        let words = item.split(separator: " ")
        if words.count > 1, let first = words.first, first.count > 3 {
            variants.append(String(first))
        }

        return variants
    }

    /// Find a word-boundary match, returning a `String.Index` range in `text`.
    /// `Range(_:in:)` maps the regex's UTF-16 offsets back to grapheme-cluster indices, so
    /// emoji/accented characters before the match no longer corrupt the position.
    private static func wordBoundaryRange(of term: String, in text: String) -> Range<String.Index>? {
        guard !term.isEmpty else { return nil }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: term))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              let range = Range(match.range, in: text) else { return nil }
        return range
    }

    /// Format a compact measurement string: "2 cups", "3 tbsp", "1".
    private static func formatMeasurement(_ ingredient: Ingredient) -> String {
        let qty = ingredient.quantity?.trimmingCharacters(in: .whitespaces)
        let unit = ingredient.unit?.trimmingCharacters(in: .whitespaces)

        switch (qty, unit) {
        case let (q?, u?) where !q.isEmpty && !u.isEmpty:
            return "\(q) \(abbreviate(u))"
        case let (q?, _) where !q.isEmpty:
            return q
        case let (_, u?) where !u.isEmpty:
            return u
        default:
            return ""
        }
    }

    /// Abbreviate common units for compact display.
    private static func abbreviate(_ unit: String) -> String {
        switch unit.lowercased() {
        case "tablespoon", "tablespoons": return "tbsp"
        case "teaspoon", "teaspoons":     return "tsp"
        case "pound", "pounds":           return "lb"
        case "ounce", "ounces":           return "oz"
        case "kilogram", "kilograms":     return "kg"
        case "gram", "grams":             return "g"
        case "milliliter", "milliliters", "millilitre", "millilitres": return "ml"
        case "liter", "liters", "litre", "litres": return "L"
        default: return unit
        }
    }
}
