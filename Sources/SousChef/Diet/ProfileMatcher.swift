import Foundation

/// SC-053: Diet compatibility checking — evaluates each recipe ingredient against each diner's active diets.
/// Returns RED (direct restriction), YELLOW (hidden restriction / may contain / unverified), or GREEN (compatible).
///
/// Safety notes (see docs/AUDIT.md, dietary-safety cluster):
/// - Matching is word/token based, not naive substring `contains`, so "egg" no longer flags
///   "eggplant" and "milk" no longer flags "almond milk" (H1).
/// - Allergies are resolved through `FoodDictionary` so category allergens match (shrimp →
///   shellfish, mayonnaise → eggs) rather than only the diner's literal typed string (C2).
/// - An ingredient that can't be resolved against the food dictionary is treated as YELLOW
///   (unverified), never GREEN, for a diner with allergies — the app must not claim an
///   ingredient is safe when it couldn't actually check it.

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
    /// Keyed by the ingredient's stable `id` (never `rawText`, which can repeat and would
    /// both crash `Dictionary(uniqueKeysWithValues:)` and collapse duplicate lines — C1).
    let results: [UUID: IngredientCompatibility]

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
        // Resolve each ingredient's food entry once (exact, O(1) lookups) rather than
        // re-running a whole-dictionary Levenshtein scan per ingredient per diner
        // (former performance hot spot). Exact resolution also avoids fuzzy mismatches
        // being amplified into RED safety flags.
        let resolved: [(ingredient: Ingredient, food: ResolvedFood)] = ingredients.map {
            ($0, resolveEntry(item: $0.item.lowercased(), text: $0.rawText.lowercased()))
        }

        return diners.map { diner in
            var results: [UUID: IngredientCompatibility] = [:]
            results.reserveCapacity(resolved.count)
            for pair in resolved {
                results[pair.ingredient.id] = evaluate(
                    item: pair.ingredient.item.lowercased(),
                    text: pair.ingredient.rawText.lowercased(),
                    resolved: pair.food,
                    diner: diner
                )
            }
            return DinerCompatibility(profile: diner, results: results)
        }
    }

    /// Evaluate a single (item, rawText) pair against one diner, resolving the food entry
    /// internally. Used by Auto-Adapt to verify a candidate substitution is safe for every
    /// diner before applying it (safe ⇔ result is `.green` for all).
    func evaluate(item rawItem: String, rawText: String, against diner: DinerProfile) -> IngredientCompatibility {
        let item = rawItem.lowercased()
        let text = rawText.lowercased()
        return evaluate(item: item, text: text, resolved: resolveEntry(item: item, text: text), diner: diner)
    }

    /// The ids of the diner's *diets* (never "Allergy"/"Custom Restriction") that flag this
    /// ingredient RED. Used by Auto-Adapt to enumerate which diet-specific substitution sets
    /// to consult. Empty when the red flag comes only from an allergy/custom restriction —
    /// those have no diet-keyed substitution and must be surfaced as unfixable, never guessed.
    func redFlaggingDietIds(item rawItem: String, rawText: String, diner: DinerProfile) -> [String] {
        let item = rawItem.lowercased()
        let text = rawText.lowercased()
        let resolved = resolveEntry(item: item, text: text)
        return diner.diets.filter { dietId in
            guard let diet = library.diet(id: dietId) else { return false }
            return checkDiet(item: item, text: text, resolved: resolved, diet: diet).level == .red
        }
    }

    // MARK: - Food-entry resolution

    /// A resolved food entry plus whether the resolution is trustworthy enough to inherit
    /// the entry's *category* and *declared allergens*.
    struct ResolvedFood {
        let entry: FoodEntry?
        /// False when resolved only via a "reformulable form" head noun — e.g. "buckwheat
        /// flour" / "rice flour" resolve to the wheat "flour" entry, and "vegan butter" to
        /// the dairy "butter" entry. The source modifier, not the form, determines the real
        /// category/allergens, so those must NOT be inherited from the entry. Direct
        /// word matches (e.g. an "almond"/"sesame" allergy) still apply regardless.
        let confident: Bool
    }

    private func resolveEntry(item: String, text: String) -> ResolvedFood {
        if let e = dictionary.find(name: item) { return ResolvedFood(entry: e, confident: true) }
        if let last = item.split(separator: " ").last.map(String.init),
           let e = dictionary.find(name: last) {
            return ResolvedFood(entry: e, confident: !IngredientMatcher.reformulableForms.contains(last))
        }
        if let last = text.split(separator: " ").last.map(String.init),
           let e = dictionary.find(name: last) {
            return ResolvedFood(entry: e, confident: !IngredientMatcher.reformulableForms.contains(last))
        }
        return ResolvedFood(entry: nil, confident: true)
    }

    // MARK: - Per-ingredient evaluation

    private func evaluate(item: String, text: String, resolved: ResolvedFood, diner: DinerProfile) -> IngredientCompatibility {
        let entry = resolved.entry

        // 1. Custom restrictions ("ingredients to avoid") — always RED on a match.
        for restriction in diner.customRestrictions {
            if IngredientMatcher.matches(term: restriction, item: item, text: text, entry: entry) {
                return IngredientCompatibility(
                    ingredientText: text,
                    level: .red,
                    triggeringDiet: "Custom Restriction",
                    reason: "Contains '\(restriction)'"
                )
            }
        }

        // 2. Allergies — always RED. Resolve through the food dictionary so category
        //    allergens (shrimp → shellfish, mayonnaise → eggs) are caught, not just the
        //    diner's literal typed word.
        for allergy in diner.allergies {
            if let reason = allergyReason(allergy: allergy, item: item, text: text, resolved: resolved) {
                return IngredientCompatibility(
                    ingredientText: text,
                    level: .red,
                    triggeringDiet: "Allergy",
                    reason: reason
                )
            }
        }

        // 3. Diet checks (RED / YELLOW).
        var worstLevel = CompatibilityLevel.green
        var worstDiet: String?
        var worstReason: String?
        for diet in diner.diets.compactMap({ library.diet(id: $0) }) {
            let result = checkDiet(item: item, text: text, resolved: resolved, diet: diet)
            if result.level > worstLevel {
                worstLevel = result.level
                worstDiet = diet.name
                worstReason = result.reason
            }
        }

        // 4. Safety backstop: for a diner with allergies, an ingredient we could not
        //    resolve against the food dictionary must never be reported GREEN. We can't
        //    prove it's free of their allergens, so surface YELLOW (unverified).
        if worstLevel == .green, !diner.allergies.isEmpty, entry == nil {
            return IngredientCompatibility(
                ingredientText: text,
                level: .yellow,
                triggeringDiet: "Allergy",
                reason: "Not in food database — can't verify against your allergies"
            )
        }

        return IngredientCompatibility(
            ingredientText: text,
            level: worstLevel,
            triggeringDiet: worstDiet,
            reason: worstReason
        )
    }

    // MARK: - Allergy resolution

    /// Returns a reason string if `allergy` applies to this ingredient, else nil.
    private func allergyReason(allergy: String, item: String, text: String, resolved: ResolvedFood) -> String? {
        let entry = resolved.entry

        // Direct word-boundary match on the typed allergy (e.g. "peanut" → "peanut butter").
        if IngredientMatcher.matches(term: allergy, item: item, text: text, entry: entry) {
            return "Allergen: \(allergy)"
        }

        // Category / allergen resolution through the food dictionary. Only trusted for a
        // confident resolution: "buckwheat flour" resolves via its head noun to the wheat
        // "flour" entry, whose gluten/wheat allergens are NOT buckwheat's. A real source
        // allergen ("almond flour") is caught by the direct word match above instead.
        guard let entry = entry, resolved.confident else { return nil }
        let profile = IngredientMatcher.allergenProfile(for: allergy)
        let entryAllergens = Set(entry.commonAllergens.map { $0.lowercased() })

        if !profile.allergens.isDisjoint(with: entryAllergens) {
            return "Contains \(allergy) (\(entry.name))"
        }
        // Category-based resolution is also skipped for a reformulated item ("vegan butter"
        // that resolves to the dairy "butter" entry is not dairy) — mirrors the diet check.
        if !IngredientMatcher.hasNegatingModifier(item: item, text: text) {
            let entryCategories = Set(entry.categories.map { $0.lowercased() })
            if !profile.categories.isDisjoint(with: entryCategories) {
                return "Contains \(allergy) (\(entry.name))"
            }
        }
        return nil
    }

    // MARK: - Diet check

    private struct CheckResult {
        let level: CompatibilityLevel
        let reason: String?
    }

    private func checkDiet(item: String, text: String, resolved: ResolvedFood, diet: DietDefinition) -> CheckResult {
        let entry = resolved.entry
        let negated = IngredientMatcher.hasNegatingModifier(item: item, text: text)

        // Category-level RED check. Uses the entry's category only when resolution is
        // confident (not a "buckwheat flour" → "flour" head-noun guess) and the item isn't
        // a reformulated "vegan"/"dairy-free" version that no longer belongs to the category.
        if resolved.confident, !negated {
            let categories = Set((entry?.categories ?? []).map { $0.lowercased() })
            for restricted in diet.restrictedCategories {
                if categories.contains(restricted.lowercased()) {
                    return CheckResult(level: .red, reason: "\(restricted.capitalized) not allowed on \(diet.name)")
                }
            }
        }

        // Ingredient-level RED check — matches the raw text/item and the resolved food
        // entry's canonical name, so "bacon"/"prosciutto" → the "pork" entry are caught.
        for restricted in diet.restrictedIngredients {
            if IngredientMatcher.matches(term: restricted, item: item, text: text, entry: entry) {
                return CheckResult(level: .red, reason: "'\(restricted)' not allowed on \(diet.name)")
            }
        }

        // Hidden restriction YELLOW check.
        for hidden in diet.hiddenRestrictions {
            if IngredientMatcher.matches(term: hidden, item: item, text: text, entry: entry) {
                return CheckResult(level: .yellow, reason: "May contain restricted ingredient (\(hidden))")
            }
        }

        // Allergen cross-reference with the diet's restricted ingredients — confident
        // resolutions only, so "buckwheat flour" doesn't inherit the wheat "flour" entry's
        // gluten/wheat allergens and get a spurious YELLOW on gluten-free.
        if let entry = entry, resolved.confident {
            for allergen in entry.commonAllergens {
                if diet.restrictedIngredients.contains(where: { $0.lowercased() == allergen.lowercased() }) {
                    return CheckResult(level: .yellow, reason: "May trigger \(allergen) restriction")
                }
            }
        }

        return CheckResult(level: .green, reason: nil)
    }
}

// MARK: - IngredientMatcher

/// Word/token-aware matching for diet, allergy, and custom-restriction terms.
///
/// Replaces naive `String.contains`, which produced both dangerous false negatives
/// ("shellfish" not matching "shrimp") and constant false positives ("egg" flagging
/// "eggplant", "milk" flagging "almond milk"). Matching is:
/// - whole-word / whole-phrase (regex word boundaries),
/// - plural-aware (a term and its plural both match),
/// - exception-aware (a curated list of phrases that must not be flagged by a broader term),
/// - dictionary-aware (also matches the resolved food entry's canonical name).
enum IngredientMatcher {

    /// Phrases that must NOT be flagged by the (broader) key term.
    ///
    /// Two purposes: (1) kill substring false positives — "milk" must not flag the plant
    /// milks, "egg" must not flag "eggplant"; (2) let genuinely-compliant substitutes pass
    /// re-validation — e.g. "rice flour" and "cashew cream" are gluten-free / dairy-free
    /// respectively and must not be rejected by the bare "flour" / "cream" restriction.
    /// Suppressing a term here never hides a *different* diner's flag: an almond-based swap
    /// is still caught for a nut allergy via the "almond"/nut path, not via "flour".
    static let exceptions: [String: [String]] = [
        "milk": ["coconut milk", "almond milk", "oat milk", "soy milk", "rice milk",
                 "cashew milk", "hemp milk", "pea milk", "flax milk", "macadamia milk",
                 "almond milk yogurt", "oat milk yogurt"],
        "egg": ["eggplant", "eggplants"],
        "eggs": ["eggplant", "eggplants"],
        "wheat": ["buckwheat"],
        "butter": ["peanut butter", "almond butter", "cashew butter", "sunflower butter",
                   "sunflower seed butter", "pumpkin seed butter", "cocoa butter",
                   "apple butter", "nut butter", "shea butter", "seed butter",
                   "vegan butter", "plant butter", "plant-based butter", "dairy-free butter"],
        "cream": ["cream of tartar", "coconut cream", "cashew cream", "oat cream",
                  "vegan cream", "vegan sour cream", "cashew sour cream",
                  "vegan cream cheese", "cashew cream cheese", "tofu cream cheese"],
        "cheese": ["vegan cheese", "cashew cheese", "vegan cream cheese",
                   "cashew cream cheese", "tofu cream cheese", "dairy-free cheese"],
        "flour": ["almond flour", "coconut flour", "rice flour", "oat flour",
                  "tapioca flour", "cassava flour", "chickpea flour", "corn flour",
                  "potato flour", "buckwheat flour", "sorghum flour", "teff flour",
                  "gluten-free flour", "gluten free flour"],
    ]

    /// Diner allergy term → (food-dictionary allergen tokens, food-dictionary category tokens).
    /// Matching either set against a resolved `FoodEntry` flags the allergen.
    static let allergySynonyms: [String: (allergens: [String], categories: [String])] = [
        // Milk / dairy
        "milk": (["milk"], ["dairy"]),
        "dairy": (["milk"], ["dairy"]),
        "lactose": (["milk"], ["dairy"]),
        "casein": (["milk"], ["dairy"]),
        "whey": (["milk"], ["dairy"]),
        // Egg
        "egg": (["eggs"], []),
        "eggs": (["eggs"], []),
        // Peanut
        "peanut": (["peanuts"], []),
        "peanuts": (["peanuts"], []),
        // Tree nuts
        "tree nut": (["tree nuts", "nuts"], ["nut"]),
        "tree nuts": (["tree nuts", "nuts"], ["nut"]),
        "nut": (["nuts", "tree nuts", "peanuts"], ["nut"]),
        "nuts": (["nuts", "tree nuts", "peanuts"], ["nut"]),
        "almond": (["tree nuts", "nuts"], ["nut"]),
        "almonds": (["tree nuts", "nuts"], ["nut"]),
        "walnut": (["tree nuts", "nuts"], ["nut"]),
        "walnuts": (["tree nuts", "nuts"], ["nut"]),
        "cashew": (["tree nuts", "nuts"], ["nut"]),
        "cashews": (["tree nuts", "nuts"], ["nut"]),
        "pecan": (["tree nuts", "nuts"], ["nut"]),
        "pecans": (["tree nuts", "nuts"], ["nut"]),
        "pistachio": (["tree nuts", "nuts"], ["nut"]),
        "pistachios": (["tree nuts", "nuts"], ["nut"]),
        "hazelnut": (["tree nuts", "nuts"], ["nut"]),
        "hazelnuts": (["tree nuts", "nuts"], ["nut"]),
        "macadamia": (["tree nuts", "nuts"], ["nut"]),
        // Shellfish
        "shellfish": (["shellfish"], ["shellfish"]),
        "shrimp": (["shellfish"], ["shellfish"]),
        "prawn": (["shellfish"], ["shellfish"]),
        "prawns": (["shellfish"], ["shellfish"]),
        "crab": (["shellfish"], ["shellfish"]),
        "lobster": (["shellfish"], ["shellfish"]),
        "crawfish": (["shellfish"], ["shellfish"]),
        "crayfish": (["shellfish"], ["shellfish"]),
        "oyster": (["shellfish"], ["shellfish"]),
        "oysters": (["shellfish"], ["shellfish"]),
        "clam": (["shellfish"], ["shellfish"]),
        "clams": (["shellfish"], ["shellfish"]),
        "mussel": (["shellfish"], ["shellfish"]),
        "mussels": (["shellfish"], ["shellfish"]),
        "scallop": (["shellfish"], ["shellfish"]),
        "scallops": (["shellfish"], ["shellfish"]),
        // Fish
        "fish": (["fish"], ["fish"]),
        // Soy
        "soy": (["soy"], ["soy"]),
        "soya": (["soy"], ["soy"]),
        // Wheat / gluten
        "wheat": (["wheat", "gluten"], []),
        "gluten": (["gluten", "wheat"], []),
        // Sesame
        "sesame": (["sesame"], []),
        // Sulfites
        "sulfite": (["sulfites"], []),
        "sulfites": (["sulfites"], []),
    ]

    /// Canonical allergen/category profile for a diner-typed allergy term.
    /// Falls back to treating the term itself as both an allergen token and a category.
    static func allergenProfile(for allergy: String) -> (allergens: Set<String>, categories: Set<String>) {
        let key = allergy.lowercased().trimmingCharacters(in: .whitespaces)
        if let syn = allergySynonyms[key] {
            return (Set(syn.allergens), Set(syn.categories))
        }
        return ([key], [key])
    }

    /// True if `term` matches the ingredient — via the raw item/text or the resolved
    /// food entry's canonical name — as a whole word/phrase, plural-aware, and not
    /// solely inside an exception phrase.
    static func matches(term: String, item: String, text: String, entry: FoodEntry?) -> Bool {
        let t = term.lowercased().trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return false }   // ignore empty / 1-char noise

        if wholeWord(t, in: item) || wholeWord(t, in: text) { return true }

        // Consult the resolved food entry's canonical NAME ONLY when the term is not
        // literally present as a word in the item/text. That is the genuine "bacon → pork"
        // mapping (the restriction word isn't in the raw text at all). When the word *is*
        // present but excepted — "flour" in "rice flour", which resolves via its head noun
        // to the "flour" entry — the item/text check above is authoritative, so we must not
        // re-introduce the flag through the head-noun entry.
        //
        // Only the entry NAME is matched, never its aliases: a canonical entry aggregates
        // many product forms as aliases (the "flour" entry lists "wheat flour", "bread
        // flour", …), so matching a restriction against aliases would make a head-noun
        // resolution ("rice flour" → flour) inherit unrelated restricted words. Product
        // forms that need catching are covered by explicit restricted ingredients and by
        // category resolution instead.
        if let entry = entry, !rawWordMatch(t, in: item), !rawWordMatch(t, in: text) {
            if wholeWord(t, in: entry.name.lowercased()) { return true }
        }
        return false
    }

    /// Whole-word / whole-phrase, plural-aware match of `needle` within `haystack`,
    /// ignoring occurrences that fall entirely inside a configured exception phrase.
    static func wholeWord(_ needle: String, in haystack: String) -> Bool {
        // Strip exception phrases first so their embedded term doesn't count
        // (e.g. remove "almond milk" before searching for "milk").
        var scrubbed = haystack
        for ex in exceptions[needle] ?? [] {
            scrubbed = scrubbed.replacingOccurrences(of: ex, with: " ")
        }
        return rawWordMatch(needle, in: scrubbed)
    }

    /// "Form" head nouns that can be made from many different sources, so a modifier in
    /// front of them changes the food's real category and allergens: "rice/buckwheat flour"
    /// is not wheat, "almond/oat milk" is not dairy, "vegan butter" is not dairy. When an
    /// item resolves to a food entry only via one of these head nouns, the entry's category
    /// and declared allergens are not trusted (the source modifier decides them instead).
    /// The head noun itself and any real source allergen are still caught by direct word
    /// matching (e.g. an "almond" or "sesame" allergy against "almond flour" / "sesame oil").
    static let reformulableForms: Set<String> = [
        "flour", "milk", "butter", "cream", "cheese", "yogurt", "yoghurt", "oil",
    ]

    /// Modifiers that reformulate a food out of its head noun's class, so its head-noun
    /// category must not be inherited: "vegan butter" is not dairy, "meatless crumbles" are
    /// not meat. Used to suppress category-based flags (never word/allergen-token matches).
    static let negatingModifiers: [String] = [
        "vegan", "plant-based", "plant based", "non-dairy", "nondairy", "dairy-free",
        "dairy free", "meatless", "meat-free", "meat free", "vegetarian", "mock",
        "imitation", "faux", "egg-free", "eggless",
    ]

    static func hasNegatingModifier(item: String, text: String) -> Bool {
        for mod in negatingModifiers where rawWordMatch(mod, in: item) || rawWordMatch(mod, in: text) {
            return true
        }
        return false
    }

    /// Whole-word, plural-aware regex match, without any exception handling.
    static func rawWordMatch(_ needle: String, in haystack: String) -> Bool {
        let base = singularize(needle)
        guard !base.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: base)
        // Optional trailing plural on the final word.
        let pattern = "\\b\(escaped)(?:es|s)?\\b"
        return haystack.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Drop a single trailing plural "s" so the term and its plural both match via the
    /// optional-plural regex suffix. Leaves "ss" endings ("grass") and short words alone.
    static func singularize(_ word: String) -> String {
        guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") else { return word }
        return String(word.dropLast())
    }
}
