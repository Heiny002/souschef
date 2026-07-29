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

            // Could be a single object, an array, or a @graph wrapper.
            var candidates: [[String: Any]] = []
            if let array = json as? [[String: Any]] {
                candidates = array
            } else if let dict = json as? [String: Any] {
                if let graph = dict["@graph"] as? [[String: Any]] { candidates = graph }
                candidates.append(dict)
            }

            for item in candidates {
                guard let r = extractRecipe(from: item) else { continue }
                if r.isViable { return r }
                // A partial Recipe object — e.g. ingredients present but instructions in a
                // shape parseInstructions can't read — is still worth returning: the
                // pipeline's merge() gap-fills it from the microdata/heuristic layers.
                // Discarding it here starved that merge and returned an empty layer.
                if r.confidence > result.confidence { result = r }
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

        // Yield — sites emit a String, [String], or a bare number ("recipeYield": 4),
        // which was previously dropped (audit medium).
        if let yieldVal = dict["recipeYield"] {
            result.recipeYield = yieldString(from: yieldVal)
        }

        // Times
        result.prepTime = duration(from: dict, key: "prepTime")
        result.cookTime = duration(from: dict, key: "cookTime")
        result.totalTime = duration(from: dict, key: "totalTime")

        // Ingredients. Some sites fold group headers ("For the sauce:") into the flat
        // recipeIngredient array as bare entries; treat a short, quantity-free line ending
        // in a colon as a section heading for the ingredients that follow, and drop the
        // header line itself rather than saving it as a phantom ingredient.
        if let raw = dict["recipeIngredient"] as? [Any] {
            var currentSection: String?
            var ingredients: [RawIngredient] = []
            for item in raw {
                guard let text = (item as? String)?.htmlDecoded, !text.isEmpty else { continue }
                if Self.looksLikeGroupHeader(text) {
                    currentSection = text.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                        .nonEmptyOrNil
                    continue
                }
                ingredients.append(RawIngredient(text: text, section: currentSection))
            }
            result.ingredients = ingredients
        }

        // Instructions — multiple formats
        if let instructions = dict["recipeInstructions"] {
            result.steps = parseInstructions(instructions)
        }

        // Appliances: explicit schema.org `tool` entries UNION keyword detection —
        // detection previously overwrote the explicit list, losing stand mixers /
        // candy thermometers the site had declared outright (audit medium).
        var appliances: [String] = []
        if let tools = dict["tool"] as? [Any] {
            appliances = tools.compactMap { tool -> String? in
                if let str = tool as? String { return str.htmlDecoded }
                if let obj = tool as? [String: Any] { return (obj["name"] as? String)?.htmlDecoded }
                return nil
            }
        }
        let textForAppliances = result.ingredients.map { $0.text } + result.steps.map { $0.text }
        for detected in ApplianceDetector.detect(in: textForAppliances)
        where !appliances.contains(where: { $0.caseInsensitiveCompare(detected) == .orderedSame }) {
            appliances.append(detected)
        }
        result.appliances = appliances

        // Image / thumbnail — can be a String URL, ImageObject dict, or array of either
        if let imageVal = dict["image"] {
            if let imageStr = imageVal as? String {
                result.thumbnailURL = imageStr
            } else if let imageObj = imageVal as? [String: Any] {
                result.thumbnailURL = imageObj["url"] as? String
            } else if let imageArr = imageVal as? [Any] {
                // Array of strings or ImageObject dicts
                for item in imageArr {
                    if let str = item as? String { result.thumbnailURL = str; break }
                    if let obj = item as? [String: Any], let url = obj["url"] as? String {
                        result.thumbnailURL = url; break
                    }
                }
            }
        }

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
                    // Section contains itemListElement with HowToStep children. Its "name"
                    // is the component heading ("For the sauce", "Steak") — carry it onto
                    // each child step so multi-part web recipes get the same part tabs and
                    // sequencing that social recipes get.
                    let sectionName = (obj["name"] as? String)?.htmlDecoded
                        .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                        .nonEmptyOrNil
                    if let items = obj["itemListElement"] as? [[String: Any]] {
                        for item in items {
                            if let text = stepText(from: item), !text.isEmpty {
                                steps.append(RawStep(order: order, text: text, section: sectionName))
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

    /// recipeYield in the wild: "4 servings", ["4 servings", "4"], 4, 4.0.
    private func yieldString(from value: Any) -> String? {
        if let str = value as? String { return str.htmlDecoded }
        if let arr = value as? [Any] {
            return arr.compactMap { yieldString(from: $0) }.first
        }
        if let num = value as? NSNumber {
            let d = num.doubleValue
            return d == d.rounded() ? String(Int(d)) : String(d)
        }
        return nil
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

    /// A short, quantity-free line ending in a colon reads as an ingredient-group heading
    /// ("For the sauce:", "Marinade:"), not an ingredient. Kept deliberately strict so a
    /// real ingredient with a trailing colon note ("2 eggs: beaten") isn't swallowed: the
    /// line must end in the colon and carry no leading quantity.
    static func looksLikeGroupHeader(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.hasSuffix(":"), t.count <= 40 else { return false }
        let words = t.split(whereSeparator: \.isWhitespace)
        guard words.count <= 5 else { return false }
        // No leading quantity — headers name a component, they don't measure one.
        if let first = words.first?.first, first.isNumber || "½¼¾⅓⅔⅛⅜⅝⅞⅕⅙".contains(first) {
            return false
        }
        return true
    }
}

// MARK: - HTML Entity Decoding

private extension String {
    /// nil when empty after trimming — keeps `""` out of section names.
    var nonEmptyOrNil: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

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
        // Numeric entities — decimal (&#233;) AND hex (&#xe9; / &#X27;), which were
        // previously shown verbatim in titles/ingredients (audit medium).
        let numericPattern = try? NSRegularExpression(pattern: "&#([xX])?([0-9a-fA-F]+);")
        let range = NSRange(s.startIndex..., in: s)
        if let matches = numericPattern?.matches(in: s, range: range) {
            for match in matches.reversed() {
                guard let codeRange = Range(match.range(at: 2), in: s),
                      let fullRange = Range(match.range, in: s) else { continue }
                let isHex = match.range(at: 1).location != NSNotFound
                // A decimal entity must be all digits; [0-9a-fA-F] in the pattern is
                // for the hex case ("&#abc;" without x is left as-is).
                guard let code = UInt32(s[codeRange], radix: isHex ? 16 : 10),
                      let scalar = Unicode.Scalar(code) else { continue }
                s.replaceSubrange(fullRange, with: String(scalar))
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
