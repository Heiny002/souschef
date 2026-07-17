import Foundation
import SwiftSoup

/// Layer 3: Rule-based heuristic HTML scraping.
/// For sites without structured data. Confidence 0.5–0.8 depending on class matches.
struct HeuristicExtractor {
    private static let method = "heuristic-html"

    // Class fragments that strongly imply ingredient lists
    private static let ingredientClassFragments = [
        "ingredient", "ingred", "recipe-ingr"
    ]
    // Class fragments that imply instruction lists
    private static let instructionClassFragments = [
        "instruction", "direction", "method", "step", "preparation", "procedure"
    ]
    // Class fragments that imply recipe containers
    private static let recipeContainerFragments = [
        "recipe", "recipe-content", "recipe-body", "recipe-wrap", "recipe-container"
    ]

    func extract(html: String) -> ExtractionResult {
        var result = ExtractionResult(extractionMethod: Self.method)
        guard let doc = try? SwiftSoup.parse(html) else { return result }

        result.title = extractTitle(doc: doc)
        result.ingredients = extractIngredients(doc: doc)
        result.steps = extractSteps(doc: doc)
        result.recipeYield = extractYield(doc: doc)
        let (prep, cook, total) = extractTimes(doc: doc)
        result.prepTime = prep
        result.cookTime = cook
        result.totalTime = total
        result.appliances = ApplianceDetector.detect(
            in: result.ingredients.map { $0.text } + result.steps.map { $0.text }
        )
        result.confidence = computeConfidence(result)
        return result
    }

    // MARK: - Title

    private func extractTitle(doc: Document) -> String? {
        // Priority 1: h1 inside a recipe-class container
        for fragment in Self.recipeContainerFragments {
            if let el = try? doc.select("[\(classAttr(fragment))] h1").first(),
               let text = try? el.text(), !text.isEmpty {
                return text
            }
        }
        // Priority 2: single h1 on page
        if let h1s = try? doc.select("h1"), h1s.count == 1,
           let text = try? h1s.first()?.text(), !text.isEmpty {
            return text
        }
        // Priority 3: og:title meta tag
        if let meta = try? doc.select("meta[property=og:title]").first(),
           let content = try? meta.attr("content"), !content.isEmpty {
            return content
        }
        // Priority 4: <title> tag (strip site name after " | " or " - ").
        // Split ONLY on space-delimited separators — a CharacterSet split on "|-" cut at
        // every intra-word hyphen, truncating "Bang-Bang Shrimp | Food Blog" to "Bang" (H17).
        if let title = try? doc.title(), !title.isEmpty {
            for separator in [" | ", " - ", " – ", " — "] {
                if let first = title.components(separatedBy: separator).first, first != title {
                    let trimmed = first.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return title.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - Ingredients

    private func extractIngredients(doc: Document) -> [RawIngredient] {
        // Method 1: list items inside ingredient-class ancestor
        for fragment in Self.ingredientClassFragments {
            let selectors = ["ul.\(fragment) li", "ol.\(fragment) li",
                             "[\(classAttr(fragment))] li",
                             "[\(classAttr(fragment))] p"]
            for sel in selectors {
                if let els = try? doc.select(sel), !els.isEmpty() {
                    let items = els.compactMap { el -> RawIngredient? in
                        let text = (try? el.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        // Section headers often have no quantity-like content — keep for now, validator will flag
                        guard text.count > 2 else { return nil }
                        return RawIngredient(text: text)
                    }
                    if items.count >= 2 { return items }
                }
            }
        }

        // Method 2: any <li> whose text matches quantity-unit-food pattern.
        // Leading char class includes the unicode fractions — "½ cup flour" previously
        // required an ASCII digit first and was silently missed (audit medium).
        if let allLis = try? doc.select("li") {
            let quantityPattern = #"^\s*([\d½¼¾⅓⅔⅛⅜⅝⅞][\d\s/½¼¾⅓⅔⅛⅜⅝⅞]*|[a-z]+)\s+(tbsp|tsp|cup|oz|lb|g|kg|ml|can|bunch|clove|sprig|pinch|dash|tablespoon|teaspoon|ounce|pound|gram)"#
            let regex = try? NSRegularExpression(pattern: quantityPattern, options: .caseInsensitive)
            let matches = allLis.filter { el in
                guard let text = try? el.text() else { return false }
                let range = NSRange(text.startIndex..., in: text)
                return regex?.firstMatch(in: text, range: range) != nil
            }
            if matches.count >= 3 {
                return matches.compactMap { el -> RawIngredient? in
                    let text = (try? el.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return text.isEmpty ? nil : RawIngredient(text: text)
                }
            }
        }

        return []
    }

    // MARK: - Steps

    private func extractSteps(doc: Document) -> [RawStep] {
        // Method 1: list or divs inside instruction-class ancestor
        for fragment in Self.instructionClassFragments {
            let selectors = ["ol.\(fragment) li", "[\(classAttr(fragment))] li",
                             "[\(classAttr(fragment))] p", "div.\(fragment)"]
            for sel in selectors {
                if let els = try? doc.select(sel), !els.isEmpty() {
                    let steps = buildSteps(from: els)
                    if steps.count >= 2 { return steps }
                }
            }
        }

        // Method 2: ordered list where items look like cooking instructions (20+ chars)
        if let ols = try? doc.select("ol") {
            for ol in ols {
                if let lis = try? ol.select("li") {
                    let candidates = lis.filter { el in
                        let text = (try? el.text()) ?? ""
                        return text.count >= 20
                    }
                    if candidates.count >= 2 {
                        return buildSteps(from: candidates)
                    }
                }
            }
        }

        return []
    }

    private func buildSteps(from elements: Elements) -> [RawStep] {
        buildSteps(from: Array(elements))
    }

    private func buildSteps(from elements: [Element]) -> [RawStep] {
        elements.enumerated().compactMap { idx, el in
            let text = (try? el.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard text.count >= 10 else { return nil }
            return RawStep(order: idx + 1, text: text)
        }
    }

    // MARK: - Yield

    private func extractYield(doc: Document) -> String? {
        let text = (try? doc.text()) ?? ""
        // "Serves 4", "Makes 12 cookies", "Yield: 4 servings"
        let patterns = [
            #"[Ss]erves?\s*:?\s*(\d+(?:\s*[-–]\s*\d+)?(?:\s+\w+)?)"#,
            #"[Mm]akes?\s*:?\s*(\d+(?:\s*[-–]\s*\d+)?(?:\s+\w+)?)"#,
            #"[Yy]ield\s*:?\s*(\d+(?:\s*[-–]\s*\d+)?(?:\s+\w+)?)"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - Times

    private func extractTimes(doc: Document) -> (Int?, Int?, Int?) {
        let text = (try? doc.text()) ?? ""
        let prepTime = timeMinutes(from: text, labels: ["prep time", "prep", "preparation time"])
        let cookTime = timeMinutes(from: text, labels: ["cook time", "cooking time", "bake time"])
        let totalTime = timeMinutes(from: text, labels: ["total time", "total"])
        return (prepTime, cookTime, totalTime)
    }

    private func timeMinutes(from text: String, labels: [String]) -> Int? {
        // Shared parser handles compound values ("1 hr 30 min") and decimals — the old
        // inline regex stopped at the first number+unit, reading 90 minutes as 60.
        for label in labels {
            if let secs = DurationTextParser.seconds(in: text, after: label) { return secs }
        }
        return nil
    }

    // MARK: - Confidence

    private func computeConfidence(_ result: ExtractionResult) -> Double {
        guard result.title != nil else { return 0.0 }
        let hasClassMatchIngredients = result.ingredients.count >= 3
        let hasClassMatchSteps = result.steps.count >= 2
        if hasClassMatchIngredients && hasClassMatchSteps { return 0.8 }
        if result.ingredients.count >= 1 && result.steps.count >= 1 { return 0.5 }
        return 0.2
    }

    // MARK: - Helpers

    /// Generates CSS attribute selector fragment for class contains.
    private func classAttr(_ fragment: String) -> String {
        "class*=\(fragment)"
    }
}
