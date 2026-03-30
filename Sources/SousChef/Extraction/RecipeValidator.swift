import Foundation

enum ValidationSeverity {
    case pass
    case warn
    case fail
}

struct ValidationCheck {
    let name: String
    let severity: ValidationSeverity
    let message: String
}

struct ValidationReport {
    let checks: [ValidationCheck]

    var hasFailed: Bool { checks.contains { $0.severity == .fail } }
    var hasWarnings: Bool { checks.contains { $0.severity == .warn } }
    var failures: [ValidationCheck] { checks.filter { $0.severity == .fail } }
    var warnings: [ValidationCheck] { checks.filter { $0.severity == .warn } }
}

struct RecipeValidator {
    // Items exempt from quantity requirement
    private static let quantityExemptItems: Set<String> = [
        "salt", "pepper", "oil", "water", "ice", "sugar", "flour", "butter",
        "milk", "cream", "stock", "broth", "vinegar", "sauce", "seasoning",
        "herbs", "spices", "garnish"
    ]

    // Known valid units to detect measurement sanity
    private static let knownUnits: Set<String> = [
        "tablespoon", "teaspoon", "cup", "ounce", "pound", "gram", "kilogram",
        "milliliter", "liter", "fluid ounce", "quart", "pint", "gallon",
        "can", "package", "box", "bag", "bunch", "stalk", "head", "clove",
        "slice", "piece", "sprig", "pinch", "dash", "drop", "large", "medium", "small"
    ]

    func validate(result: ExtractionResult, ingredients: [ParsedIngredient]) -> ValidationReport {
        var checks: [ValidationCheck] = []

        // 1. Completeness — FAIL if no title + no ingredients + no steps
        if result.title == nil {
            checks.append(ValidationCheck(name: "completeness.title", severity: .fail, message: "Recipe has no title"))
        }
        if result.ingredients.isEmpty {
            checks.append(ValidationCheck(name: "completeness.ingredients", severity: .fail, message: "Recipe has no ingredients"))
        }
        if result.steps.isEmpty {
            checks.append(ValidationCheck(name: "completeness.steps", severity: .fail, message: "Recipe has no instructions"))
        }

        // If all three missing, stop here
        if result.title == nil && result.ingredients.isEmpty && result.steps.isEmpty {
            return ValidationReport(checks: checks)
        }

        // 2. Ingredient validity — FAIL if no ingredient has both quantity and item
        let hasValidIngredient = ingredients.contains { parsed in
            let isExempt = Self.quantityExemptItems.contains(parsed.item.lowercased()) ||
                           Self.quantityExemptItems.contains { parsed.item.lowercased().hasPrefix($0) }
            return (parsed.quantity != nil && !parsed.item.isEmpty) || isExempt
        }
        if !ingredients.isEmpty && !hasValidIngredient {
            checks.append(ValidationCheck(
                name: "ingredient.validity",
                severity: .fail,
                message: "No ingredient has a recognizable quantity and name"
            ))
        }

        // 3. Measurement sanity — WARN on unknown units or unreasonable quantities
        for parsed in ingredients {
            if let unit = parsed.unit, !Self.knownUnits.contains(unit) {
                checks.append(ValidationCheck(
                    name: "ingredient.unit.\(parsed.item)",
                    severity: .warn,
                    message: "Unknown unit '\(unit)' for ingredient '\(parsed.item)'"
                ))
            }
            // Unreasonable quantity (>100 cups, >50 lbs, etc.)
            if let qtyStr = parsed.quantity, let qty = parseQuantity(qtyStr) {
                let isLarge = (parsed.unit == "cup" && qty > 100) ||
                              (parsed.unit == "pound" && qty > 50) ||
                              (parsed.unit == "tablespoon" && qty > 200)
                if isLarge {
                    checks.append(ValidationCheck(
                        name: "ingredient.quantity.\(parsed.item)",
                        severity: .warn,
                        message: "Unreasonable quantity \(qtyStr) \(parsed.unit ?? "") for '\(parsed.item)'"
                    ))
                }
            }
        }

        // 4. Instruction coherence — WARN if ingredients not mentioned in steps
        let stepText = result.steps.map { $0.text.lowercased() }.joined(separator: " ")
        let mentionedCount = ingredients.filter { parsed in
            let word = parsed.item.lowercased().components(separatedBy: " ").first ?? ""
            return word.count > 3 && stepText.contains(word)
        }.count
        let relevantIngredients = ingredients.filter { !$0.item.isEmpty }
        if relevantIngredients.count >= 3 && mentionedCount == 0 {
            checks.append(ValidationCheck(
                name: "coherence.ingredients_in_steps",
                severity: .warn,
                message: "Ingredients don't appear to be referenced in the instructions"
            ))
        }

        // 5. Duplicate detection — WARN if possible duplicate (title similarity)
        // Note: full duplicate detection requires SwiftData query in the call site;
        // this validator operates on the ExtractionResult only.

        // If no failures and no warnings, add a pass check
        if !checks.contains(where: { $0.severity == .fail || $0.severity == .warn }) {
            checks.append(ValidationCheck(name: "overall", severity: .pass, message: "Recipe passed all checks"))
        }

        return ValidationReport(checks: checks)
    }

    // MARK: - Private

    private func parseQuantity(_ s: String) -> Double? {
        if let d = Double(s) { return d }
        let parts = s.components(separatedBy: "/")
        if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den != 0 {
            return num / den
        }
        // Range: take first number
        if s.contains("-") {
            let first = s.components(separatedBy: "-")[0]
            return Double(first)
        }
        return nil
    }
}
