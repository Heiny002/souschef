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
        var result = text
        let lowered = text.lowercased()

        for ingredient in ingredients {
            let key = ingredient.item.lowercased()
            guard !mentioned.contains(key) else { continue }

            // Skip ingredients with no quantity info to annotate
            guard ingredient.quantity != nil || ingredient.unit != nil else { continue }

            // Find the ingredient name in the text
            guard let range = findIngredient(key, in: lowered) else { continue }

            mentioned.insert(key)

            let measurement = formatMeasurement(ingredient)
            guard !measurement.isEmpty else { continue }

            // Insert " (measurement)" right after the matched name, before any trailing punctuation
            let matchEnd = result.index(result.startIndex, offsetBy: range.upperBound)
            result.insert(contentsOf: " (\(measurement))", at: matchEnd)
        }
        return result
    }

    /// Find ingredient name in text, handling singular/plural.
    /// Returns the character range (in the lowercased text) of the match.
    private static func findIngredient(_ item: String, in text: String) -> Range<Int>? {
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

    /// Find a word-boundary match, returning the integer character range.
    private static func wordBoundaryRange(of term: String, in text: String) -> Range<Int>? {
        guard !term.isEmpty else { return nil }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: term))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange) else { return nil }
        return match.range.location ..< (match.range.location + match.range.length)
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
