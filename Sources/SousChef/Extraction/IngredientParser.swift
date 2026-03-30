import Foundation
import NaturalLanguage

/// Parsed representation of a single ingredient.
struct ParsedIngredient {
    var quantity: String?
    var unit: String?
    var item: String
    var preparation: String?
    var section: String?
    var rawText: String

    /// Items that don't need a quantity (salt, pepper, oil, water, etc.)
    static let quantityExempt: Set<String> = [
        "salt", "pepper", "oil", "water", "ice", "sugar", "flour",
        "butter", "milk", "cream", "stock", "broth", "vinegar",
        "sauce", "seasoning", "herbs", "spices"
    ]
}

/// Parses raw ingredient strings into structured ParsedIngredient values.
/// Pipeline: section detection → quantity → unit → preparation → item
struct IngredientParser {

    // MARK: - Public API

    func parse(raw: String, section: String? = nil) -> ParsedIngredient {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var remainder = text
        var result = ParsedIngredient(item: text, section: section, rawText: text)

        // 1. Strip optional parenthetical notes (save for preparation)
        let (cleaned, parenthetical) = stripParenthetical(from: remainder)
        remainder = cleaned

        // 2. Extract quantity
        let (qty, afterQty) = extractQuantity(from: remainder)
        result.quantity = qty
        remainder = afterQty.trimmingCharacters(in: .whitespaces)

        // 3. Extract unit
        let (unit, afterUnit) = extractUnit(from: remainder)
        result.unit = unit
        remainder = afterUnit.trimmingCharacters(in: .whitespaces)

        // 4. Extract preparation (trailing comma phrase or parenthetical)
        let (item, prep) = extractPreparation(from: remainder)
        result.item = item.trimmingCharacters(in: .whitespaces)

        // Combine parenthetical and comma-prep
        let preps = [parenthetical, prep].compactMap { $0 }.joined(separator: ", ")
        result.preparation = preps.isEmpty ? nil : preps

        // Fallback: if item is empty, use full text
        if result.item.isEmpty { result.item = text }

        return result
    }

    // MARK: - Quantity Extraction

    private static let unicodeFractions: [Character: String] = [
        "½": "1/2", "⅓": "1/3", "⅔": "2/3", "¼": "1/4", "¾": "3/4",
        "⅛": "1/8", "⅜": "3/8", "⅝": "5/8", "⅞": "7/8",
        "⅕": "1/5", "⅙": "1/6"
    ]

    private static let wordNumbers: [String: Double] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "a": 1, "an": 1, "half": 0.5,
        "dozen": 12, "handful": 1
    ]

    private func extractQuantity(from text: String) -> (String?, String) {
        var s = text
        // Normalize unicode fractions
        for (char, replacement) in Self.unicodeFractions {
            s = s.replacingOccurrences(of: String(char), with: " " + replacement + " ")
        }
        s = s.trimmingCharacters(in: .whitespaces)

        // Pattern: optional range like "2-3", mixed number "1 1/2", fraction "1/2", decimal "2.5", whole number "2"
        // Also handles word numbers like "one", "a"
        let tokens = s.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard let first = tokens.first else { return (nil, text) }

        // Word number
        if let wordVal = Self.wordNumbers[first.lowercased()] {
            // Check for following fraction (e.g., "one and a half")
            let quantityStr = wordVal == Double(Int(wordVal)) ? String(Int(wordVal)) : String(wordVal)
            let rest = tokens.dropFirst().joined(separator: " ")
            return (quantityStr, rest)
        }

        // Try to parse a numeric quantity from the start
        var quantityParts: [String] = []
        var tokenIndex = 0

        while tokenIndex < tokens.count {
            let token = tokens[tokenIndex]
            if isNumericToken(token) {
                quantityParts.append(token)
                tokenIndex += 1
                // Check if next token is a fraction (handles "1 1/2")
                if tokenIndex < tokens.count, isFraction(tokens[tokenIndex]) {
                    quantityParts.append(tokens[tokenIndex])
                    tokenIndex += 1
                }
                break
            } else if token == "-" && !quantityParts.isEmpty {
                // Range separator
                quantityParts.append(token)
                tokenIndex += 1
            } else {
                break
            }
        }

        if quantityParts.isEmpty { return (nil, text) }

        let quantity = quantityParts.joined(separator: " ")
        let rest = tokens[tokenIndex...].joined(separator: " ")
        return (quantity, rest)
    }

    private func isNumericToken(_ s: String) -> Bool {
        if s.allSatisfy({ $0.isNumber }) { return true }
        if isFraction(s) { return true }
        if let _ = Double(s) { return true }
        // Range: "2-3"
        if s.contains("-") {
            let parts = s.components(separatedBy: "-")
            return parts.count == 2 && parts.allSatisfy { $0.allSatisfy { $0.isNumber } }
        }
        return false
    }

    private func isFraction(_ s: String) -> Bool {
        let parts = s.components(separatedBy: "/")
        return parts.count == 2 && parts.allSatisfy { $0.allSatisfy { $0.isNumber } }
    }

    // MARK: - Unit Extraction

    private static let unitMappings: [String: String] = [
        // Volume
        "tbsp": "tablespoon", "tbsps": "tablespoon", "T": "tablespoon",
        "Tbsp": "tablespoon", "tablespoon": "tablespoon", "tablespoons": "tablespoon",
        "tsp": "teaspoon", "tsps": "teaspoon", "t": "teaspoon",
        "teaspoon": "teaspoon", "teaspoons": "teaspoon",
        "cup": "cup", "cups": "cup", "c": "cup", "c.": "cup",
        "fl oz": "fluid ounce", "fluid ounce": "fluid ounce", "fluid ounces": "fluid ounce",
        "oz": "ounce", "ozs": "ounce", "ounce": "ounce", "ounces": "ounce",
        "lb": "pound", "lbs": "pound", "pound": "pound", "pounds": "pound",
        "g": "gram", "gram": "gram", "grams": "gram",
        "kg": "kilogram", "kilogram": "kilogram", "kilograms": "kilogram",
        "ml": "milliliter", "mL": "milliliter", "milliliter": "milliliter", "milliliters": "milliliter",
        "l": "liter", "L": "liter", "liter": "liter", "liters": "liter",
        "qt": "quart", "quart": "quart", "quarts": "quart",
        "pt": "pint", "pint": "pint", "pints": "pint",
        "gal": "gallon", "gallon": "gallon", "gallons": "gallon",
        // Count/container
        "can": "can", "cans": "can",
        "package": "package", "packages": "package", "pkg": "package",
        "box": "box", "boxes": "box",
        "bag": "bag", "bags": "bag",
        "bunch": "bunch", "bunches": "bunch",
        "stalk": "stalk", "stalks": "stalk",
        "head": "head", "heads": "head",
        "clove": "clove", "cloves": "clove",
        "slice": "slice", "slices": "slice",
        "piece": "piece", "pieces": "piece",
        "sprig": "sprig", "sprigs": "sprig",
        "pinch": "pinch", "pinches": "pinch",
        "dash": "dash", "dashes": "dash",
        "drop": "drop", "drops": "drop",
        "large": "large", "medium": "medium", "small": "small"
    ]

    private func extractUnit(from text: String) -> (String?, String) {
        let tokens = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return (nil, text) }

        // Check first one or two tokens for a unit match
        for length in [2, 1] {
            guard tokens.count >= length else { continue }
            let candidate = tokens[0..<length].joined(separator: " ")
            if let normalized = Self.unitMappings[candidate] {
                let rest = tokens[length...].joined(separator: " ")
                return (normalized, rest)
            }
        }
        return (nil, text)
    }

    // MARK: - Preparation Extraction

    private func extractPreparation(from text: String) -> (String, String?) {
        // Look for comma-separated preparation phrase at end: "garlic, minced" → item: "garlic", prep: "minced"
        if let commaRange = text.range(of: ",") {
            let item = String(text[..<commaRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let prep = String(text[commaRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !item.isEmpty && !prep.isEmpty {
                return (item, prep)
            }
        }
        return (text, nil)
    }

    // MARK: - Parenthetical Stripping

    private func stripParenthetical(from text: String) -> (String, String?) {
        guard let open = text.firstIndex(of: "("),
              let close = text[open...].firstIndex(of: ")") else {
            return (text, nil)
        }
        let content = String(text[text.index(after: open)..<close])
        let without = (String(text[..<open]) + String(text[text.index(after: close)...]))
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "  ", with: " ")
        return (without, content.isEmpty ? nil : content)
    }
}
