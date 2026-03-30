import Foundation

/// SC-053: Diet compatibility checking — evaluates each recipe ingredient against each diner's active diets.
/// Returns RED (direct restriction), YELLOW (hidden restriction / may contain), or GREEN (compatible).

enum CompatibilityLevel: Int, Comparable {
    case green = 0
    case yellow = 1
    case red = 2

    static func < (lhs: CompatibilityLevel, rhs: CompatibilityLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .green:  return "Compatible"
        case .yellow: return "May Contain"
        case .red:    return "Not Compatible"
        }
    }
}

struct IngredientCompatibility {
    let ingredientText: String
    let level: CompatibilityLevel
    /// Which diet triggered the flag (first match wins).
    let triggeringDiet: String?
    /// The specific restriction reason.
    let reason: String?
}

struct DinerCompatibility {
    let profile: DinerProfile
    /// Keyed by ingredient rawText.
    let results: [String: IngredientCompatibility]

    var worstLevel: CompatibilityLevel {
        results.values.map { $0.level }.max() ?? .green
    }

    var flaggedCount: Int {
        results.values.filter { $0.level > .green }.count
    }
}

// MARK: - ProfileMatcher

struct ProfileMatcher {
    private let library = DietLibrary.shared
    private let dictionary = FoodDictionary.shared

    /// Evaluate all diners against all recipe ingredients.
    /// Returns one DinerCompatibility per diner.
    func match(ingredients: [Ingredient], diners: [DinerProfile]) -> [DinerCompatibility] {
        diners.map { diner in
            let results = Dictionary(uniqueKeysWithValues:
                ingredients.map { ingredient in
                    let compat = evaluate(ingredient: ingredient, diner: diner)
                    return (ingredient.rawText, compat)
                }
            )
            return DinerCompatibility(profile: diner, results: results)
        }
    }

    // MARK: - Per-ingredient evaluation

    private func evaluate(ingredient: Ingredient, diner: DinerProfile) -> IngredientCompatibility {
        let text = ingredient.rawText.lowercased()
        let item = ingredient.item.lowercased()

        // Collect all active diet definitions
        let activeDiets = diner.diets.compactMap { library.diet(id: $0) }

        // Check custom restrictions first
        for restriction in diner.customRestrictions {
            let r = restriction.lowercased()
            if text.contains(r) || item.contains(r) {
                return IngredientCompatibility(
                    ingredientText: ingredient.rawText,
                    level: .red,
                    triggeringDiet: "Custom Restriction",
                    reason: "Contains '\(restriction)'"
                )
            }
        }

        // Check allergies (always RED)
        for allergy in diner.allergies {
            let a = allergy.lowercased()
            if text.contains(a) || item.contains(a) {
                return IngredientCompatibility(
                    ingredientText: ingredient.rawText,
                    level: .red,
                    triggeringDiet: "Allergy",
                    reason: "Allergen: \(allergy)"
                )
            }
        }

        // Resolve food entry for category-based checks
        let foodEntry = dictionary.fuzzyFind(name: item) ?? dictionary.fuzzyFind(name: text.split(separator: " ").last.map(String.init) ?? "")

        var worstLevel = CompatibilityLevel.green
        var worstDiet: String?
        var worstReason: String?

        for diet in activeDiets {
            let result = checkDiet(item: item, text: text, foodEntry: foodEntry, diet: diet)
            if result.level > worstLevel {
                worstLevel = result.level
                worstDiet = diet.name
                worstReason = result.reason
            }
        }

        return IngredientCompatibility(
            ingredientText: ingredient.rawText,
            level: worstLevel,
            triggeringDiet: worstDiet,
            reason: worstReason
        )
    }

    // MARK: - Diet check

    private struct CheckResult {
        let level: CompatibilityLevel
        let reason: String?
    }

    private func checkDiet(item: String, text: String, foodEntry: FoodEntry?, diet: DietDefinition) -> CheckResult {
        let categories = foodEntry?.categories ?? []

        // Category-level RED check
        for restricted in diet.restrictedCategories {
            if categories.contains(restricted.lowercased()) {
                return CheckResult(level: .red, reason: "\(restricted.capitalized) not allowed on \(diet.name)")
            }
        }

        // Ingredient-level RED check
        for restricted in diet.restrictedIngredients {
            let r = restricted.lowercased()
            if item.contains(r) || text.contains(r) {
                return CheckResult(level: .red, reason: "'\(restricted)' not allowed on \(diet.name)")
            }
        }

        // Hidden restriction YELLOW check
        for hidden in diet.hiddenRestrictions {
            let h = hidden.lowercased()
            if item.contains(h) || text.contains(h) {
                return CheckResult(level: .yellow, reason: "May contain restricted ingredient (\(hidden))")
            }
        }

        // Allergen cross-reference with diet
        if let entry = foodEntry {
            for allergen in entry.commonAllergens {
                if diet.restrictedIngredients.contains(where: { $0.lowercased() == allergen.lowercased() }) {
                    return CheckResult(level: .yellow, reason: "May trigger \(allergen) restriction")
                }
            }
        }

        return CheckResult(level: .green, reason: nil)
    }
}
