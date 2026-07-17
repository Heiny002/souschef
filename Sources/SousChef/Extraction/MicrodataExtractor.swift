import Foundation
import SwiftSoup

/// Layer 2: Microdata Schema.org Recipe extraction.
/// Targets HTML attributes: itemtype="*schema.org/Recipe" + itemprop="*"
struct MicrodataExtractor {
    private static let method = "microdata"

    func extract(html: String) -> ExtractionResult {
        var result = ExtractionResult(extractionMethod: Self.method)
        guard let doc = try? SwiftSoup.parse(html) else { return result }

        // Find the root Recipe element
        guard let recipeEl = try? doc.select("[itemtype*='schema.org/Recipe']").first() else {
            return result
        }

        result.title = (try? prop(recipeEl, "name")?.text())?.cleaned
        result.description = (try? prop(recipeEl, "description")?.text())?.cleaned
        result.recipeYield = (try? prop(recipeEl, "recipeYield")?.text())?.cleaned

        // Times
        result.prepTime = isoDuration(recipeEl, "prepTime")
        result.cookTime = isoDuration(recipeEl, "cookTime")
        result.totalTime = isoDuration(recipeEl, "totalTime")

        // Ingredients — multiple [itemprop=recipeIngredient] elements
        if let els = try? recipeEl.select("[itemprop=recipeIngredient]") {
            result.ingredients = els.compactMap { el -> RawIngredient? in
                let text = (try? el.text())?.cleaned ?? ""
                guard !text.isEmpty else { return nil }
                return RawIngredient(text: text)
            }
        }

        // Instructions — HowToStep or plain text
        if let els = try? recipeEl.select("[itemprop=recipeInstructions]") {
            var steps: [RawStep] = []
            var order = 1
            for el in els {
                // Each element may itself contain [itemprop=text] children (HowToStep)
                if let substeps = try? el.select("[itemprop=text]"), !substeps.isEmpty() {
                    for sub in substeps {
                        let text = (try? sub.text())?.cleaned ?? ""
                        if !text.isEmpty {
                            steps.append(RawStep(order: order, text: text))
                            order += 1
                        }
                    }
                } else {
                    let text = (try? el.text())?.cleaned ?? ""
                    if !text.isEmpty {
                        steps.append(RawStep(order: order, text: text))
                        order += 1
                    }
                }
            }
            result.steps = steps
        }

        result.confidence = computeConfidence(result)
        return result
    }

    // MARK: - Private

    private func prop(_ root: Element, _ name: String) -> Element? {
        try? root.select("[itemprop=\(name)]").first()
    }

    private func isoDuration(_ root: Element, _ prop: String) -> Int? {
        guard let el = try? root.select("[itemprop=\(prop)]").first() else { return nil }
        // Prefer datetime (standard microdata), then content, then the element text.
        // SwiftSoup's attr() returns "" (not nil) for a missing attribute, so a `??` chain
        // stopped at the first candidate and silently dropped times on the very common
        // `<time itemprop="prepTime" content="PT15M">15 minutes</time>` markup (H16).
        let candidates = [try? el.attr("datetime"), try? el.attr("content"), try? el.text()]
        guard let value = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            return nil
        }
        return ISO8601DurationParser.seconds(from: value)
    }

    private func computeConfidence(_ result: ExtractionResult) -> Double {
        guard result.title != nil else { return 0.0 }
        if result.ingredients.count >= 3 && result.steps.count >= 2 { return 0.9 }
        if result.ingredients.count >= 1 && result.steps.count >= 1 { return 0.6 }
        return 0.2
    }
}

private extension String {
    var cleaned: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{00a0}", with: " ") // &nbsp;
    }
}
