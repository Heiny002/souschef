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

        // 3b. Drop a connective "of" left once the amount/unit are gone: "2 cups of flour" →
        // "flour". Only when an amount or unit was actually found, so a real item that starts
        // with "of" (rare, but "offal") isn't truncated.
        if qty != nil || unit != nil,
           let r = remainder.range(of: #"^of\s+"#, options: [.regularExpression, .caseInsensitive]) {
            remainder = String(remainder[r.upperBound...])
        }

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

    /// Typographic dashes between digits → ASCII hyphen, so "2–3 cloves" (en dash, as
    /// recipe plugins emit) parses as a range exactly like "2-3" (audit medium).
    private static let typographicRangeDash = try? NSRegularExpression(
        pattern: #"(?<=\d)\s*[–—−]\s*(?=\d)"#
    )

    /// The leading numeric quantity of a line, as a single span. A scalar is a mixed number
    /// ("1 1/2"), a fraction ("1/2"), or an int/decimal ("2", "2.5"); a range is two scalars
    /// joined by a dash / "to" / "or". Matched against the whole normalized line BEFORE
    /// whitespace tokenization, so "2 to 3", "2 - 3", and "1 1/2 - 2" all come out whole
    /// instead of the parser truncating at the first number.
    private static let leadingQuantity: NSRegularExpression? = {
        let scalar = #"\d+\s+\d+/\d+|\d+/\d+|\d+(?:\.\d+)?"#
        let sep = #"\s*(?:to|or|-)\s*"#
        return try? NSRegularExpression(
            pattern: "^\\s*((?:\(scalar))(?:\(sep)(?:\(scalar)))?)",
            options: .caseInsensitive)
    }()

    private func extractQuantity(from text: String) -> (String?, String) {
        var s = text
        // Normalize unicode fractions and typographic range dashes to ASCII forms.
        for (char, replacement) in Self.unicodeFractions {
            s = s.replacingOccurrences(of: String(char), with: " " + replacement + " ")
        }
        if let dashRegex = Self.typographicRangeDash {
            s = dashRegex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "-")
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
             .trimmingCharacters(in: .whitespaces)

        // Word number at the very start ("one", "a", "half", "two").
        let firstToken = s.split(separator: " ").first.map(String.init) ?? ""
        if let wordVal = Self.wordNumbers[firstToken.lowercased()] {
            let quantityStr = wordVal == Double(Int(wordVal)) ? String(Int(wordVal)) : String(wordVal)
            let rest = String(s.dropFirst(firstToken.count)).trimmingCharacters(in: .whitespaces)
            return (quantityStr, rest)
        }

        // Leading numeric span (scalar or range), matched whole.
        guard let regex = Self.leadingQuantity,
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let full = Range(match.range(at: 1), in: s) else {
            return (nil, text)
        }
        let raw = String(s[full])
        // Drop a dangling separator the grammar left when a range's second operand was
        // absent ("1- cup sugar" → quantity "1", rest "cup sugar", not "- cup sugar").
        let rest = String(s[full.upperBound...])
            .replacingOccurrences(of: #"^[-–—\s]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return (Self.canonicalQuantity(raw), rest)
    }

    /// Collapse a captured quantity span's range separators to a bare hyphen so
    /// RecipeScaling.Quantity.parseValue reads the range ("2 to 3" → "2-3"). The span holds
    /// only scalars and separators — no item words — so this can't touch an ingredient name.
    static func canonicalQuantity(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s*(?:to|or|-)\s*"#, with: "-",
                                  options: [.regularExpression, .caseInsensitive])
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
