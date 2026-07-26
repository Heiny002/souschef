import Foundation

/// Estimates how many people a recipe serves when it doesn't say.
///
/// Scaling needs a base yield: without it there's no factor to compute, so the servings
/// stepper can't work at all. Many social recipes never state one. Rather than silently
/// defaulting, the review screen asks the user — and offers this estimate as a starting
/// point so answering is one tap instead of a guess from scratch.
///
/// The estimate is protein-led because that's how portioning actually works in a kitchen:
/// one chicken breast or one steak per person. It is explicitly a suggestion, never applied
/// without the user confirming.
enum ServingSizeInferrer {

    /// Per-person portions for proteins sold or cooked as discrete pieces.
    /// (keywords, servings per unit)
    private static let perPieceProteins: [(keywords: [String], perUnit: Double)] = [
        (["chicken breast", "chicken thigh", "chicken cutlet"], 1),
        (["steak", "ribeye", "sirloin", "filet", "pork chop", "lamb chop"], 1),
        (["salmon fillet", "fish fillet", "salmon", "cod", "tilapia"], 1),
        (["burger patty", "patty"], 1),
        (["egg"], 0.5),                 // ~2 eggs per person
        (["sausage", "bratwurst"], 0.5),
    ]

    /// Weight-based proteins: grams of raw protein per person.
    private static let gramsPerPerson: Double = 170   // ~6 oz

    private static let bulkProteinKeywords = [
        "ground beef", "ground turkey", "ground chicken", "ground pork", "mince",
        "chicken", "beef", "pork", "shrimp", "turkey", "lamb", "tofu",
    ]

    /// Best guess at servings from the ingredient list, or nil when there's no protein
    /// signal to reason from. Clamped to a sane 1...12.
    static func infer(from ingredients: [ParsedIngredient]) -> Int? {
        var best: Double?

        for ingredient in ingredients {
            let name = ingredient.item.lowercased()
            let quantity = Quantity.parse(quantity: ingredient.quantity, unit: ingredient.unit)

            // Discrete proteins: count × servings-per-unit (2 chicken breasts → 2 people).
            for entry in perPieceProteins
            where entry.keywords.contains(where: { IngredientConverter.matchesWholeWord($0, in: name) }) {
                let count = quantity?.low ?? 1
                let servings = count * entry.perUnit
                if servings >= 1 { best = max(best ?? 0, servings) }
            }

            // Bulk proteins: convert to grams and divide by a per-person portion.
            guard bulkProteinKeywords.contains(where: { IngredientConverter.matchesWholeWord($0, in: name) }),
                  let quantity, let unit = quantity.unit, unit.dimension == .mass else { continue }
            let grams = quantity.low * unit.baseFactor
            let servings = grams / gramsPerPerson
            if servings >= 1 { best = max(best ?? 0, servings) }
        }

        guard let best else { return nil }
        return min(12, max(1, Int(best.rounded())))
    }

    /// A short explanation of the estimate for the review screen, so the number isn't a
    /// black box the user has to trust blindly.
    static func rationale(for servings: Int) -> String {
        "Estimated from the protein in the ingredient list — adjust if that's not right."
    }
}
