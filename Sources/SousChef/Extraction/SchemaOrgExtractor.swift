import Foundation
import SwiftSoup

/// Layer 1: JSON-LD Schema.org Recipe extraction.
/// Confidence 0.9 when title + 3+ ingredients + 2+ steps present.
struct SchemaOrgExtractor {
    private static let method = "schema-org-jsonld"

    func extract(html: String) -> ExtractionResult {
        var result = ExtractionResult(extractionMethod: Self.method)

        guard let doc = try? SwiftSoup.parse(html) else { return result }

        // Find all <script type="application/ld+json"> blocks
        guard let scripts = try? doc.select("script[type=application/ld+json]") else { return result }

        for script in scripts {
            guard let jsonText = try? script.html(),
                  let data = jsonText.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }

            // Could be a single object or an array
            if let array = json as? [[String: Any]] {
                for item in array {
                    if let r = extractRecipe(from: item), r.isViable {
                        result = r
                        return result
                    }
                }
            } else if let dict = json as? [String: Any] {
                // Handle @graph wrapper
                if let graph = dict["@graph"] as? [[String: Any]] {
                    for item in graph {
                        if let r = extractRecipe(from: item), r.isViable {
                            result = r
                            return result
                        }
                    }
                }
                if let r = extractRecipe(from: dict), r.isViable {
                    result = r
                    return result
                }
            }
        }

        return result
    }

    // MARK: - Private

    private func extractRecipe(from dict: [String: Any]) -> ExtractionResult? {
        // @type can be a string or array of strings
        let types: [String]
        if let typeStr = dict["@type"] as? String {
            types = [typeStr]
        } else if let typeArr = dict["@type"] as? [String] {
            types = typeArr
        } else {
            return nil
        }

        guard types.contains(where: { $0.lowercased().contains("recipe") }) else { return nil }

        var result = ExtractionResult(extractionMethod: Self.method)

        // Title
        result.title = string(from: dict, key: "name")?.htmlDecoded

        // Description
        result.description = string(from: dict, key: "description")?.htmlDecoded

        // Yield
        if let yieldVal = dict["recipeYield"] {
            if let str = yieldVal as? String {
                result.recipeYield = str
            } else if let arr = yieldVal as? [String] {
                result.recipeYield = arr.first
            }
        }

        // Times
        result.prepTime = duration(from: dict, key: "prepTime")
        result.cookTime = duration(from: dict, key: "cookTime")
        result.totalTime = duration(from: dict, key: "totalTime")

        // Ingredients
        if let raw = dict["recipeIngredient"] as? [Any] {
            result.ingredients = raw.compactMap { item -> RawIngredient? in
                guard let text = (item as? String)?.htmlDecoded, !text.isEmpty else { return nil }
                return RawIngredient(text: text)
            }
        }

        // Instructions — multiple formats
        if let instructions = dict["recipeInstructions"] {
            result.steps = parseInstructions(instructions)
        }

        // Appliances (tools/supplies)
        if let tools = dict["tool"] as? [Any] {
            result.appliances = tools.compactMap { ($0 as? String)?.htmlDecoded }
        }

        // Appliance detection from ingredients + steps
        let textForAppliances = result.ingredients.map { $0.text } + result.steps.map { $0.text }
        result.appliances = ApplianceDetector.detect(in: textForAppliances)

        // Confidence scoring
        result.confidence = computeConfidence(result)
        return result
    }

    private func parseInstructions(_ value: Any) -> [RawStep] {
        // Format 1: plain array of strings
        if let strings = value as? [String] {
            return strings.enumerated().map { idx, text in
                RawStep(order: idx + 1, text: text.htmlDecoded)
            }
        }

        // Format 2: array of HowToStep or HowToSection objects
        if let objects = value as? [[String: Any]] {
            var steps: [RawStep] = []
            var order = 1
            for obj in objects {
                let type_ = (obj["@type"] as? String)?.lowercased() ?? ""
                if type_.contains("howtosection") {
                    // Section contains itemListElement with HowToStep children
                    if let items = obj["itemListElement"] as? [[String: Any]] {
                        for item in items {
                            if let text = stepText(from: item), !text.isEmpty {
                                steps.append(RawStep(order: order, text: text))
                                order += 1
                            }
                        }
                    }
                } else {
                    // HowToStep or plain dict with text/name
                    if let text = stepText(from: obj), !text.isEmpty {
                        steps.append(RawStep(order: order, text: text))
                        order += 1
                    }
                }
            }
            return steps
        }

        // Format 3: single string
        if let str = value as? String, !str.isEmpty {
            return [RawStep(order: 1, text: str.htmlDecoded)]
        }

        return []
    }

    private func stepText(from dict: [String: Any]) -> String? {
        let text = (dict["text"] as? String) ?? (dict["name"] as? String)
        return text?.htmlDecoded
    }

    private func string(from dict: [String: Any], key: String) -> String? {
        return dict[key] as? String
    }

    private func duration(from dict: [String: Any], key: String) -> Int? {
        guard let val = dict[key] as? String else { return nil }
        return ISO8601DurationParser.seconds(from: val)
    }

    private func computeConfidence(_ result: ExtractionResult) -> Double {
        guard result.title != nil else { return 0.0 }
        let hasIngredients = result.ingredients.count >= 3
        let hasSteps = result.steps.count >= 2
        if hasIngredients && hasSteps { return 0.9 }
        if result.ingredients.count >= 1 && result.steps.count >= 1 { return 0.6 }
        return 0.2
    }
}

// MARK: - HTML Entity Decoding

private extension String {
    var htmlDecoded: String {
        // Common HTML entities in JSON-LD strings
        var s = self
        s = s.replacingOccurrences(of: "&amp;",  with: "&")
        s = s.replacingOccurrences(of: "&lt;",   with: "<")
        s = s.replacingOccurrences(of: "&gt;",   with: ">")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#39;",  with: "'")
        s = s.replacingOccurrences(of: "&apos;", with: "'")
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        // Numeric entities
        let numericPattern = try? NSRegularExpression(pattern: "&#(\\d+);")
        let range = NSRange(s.startIndex..., in: s)
        if let matches = numericPattern?.matches(in: s, range: range) {
            for match in matches.reversed() {
                if let codeRange = Range(match.range(at: 1), in: s),
                   let code = UInt32(s[codeRange]),
                   let scalar = Unicode.Scalar(code) {
                    let char = String(scalar)
                    if let fullRange = Range(match.range, in: s) {
                        s.replaceSubrange(fullRange, with: char)
                    }
                }
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
