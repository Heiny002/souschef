import XCTest
@testable import SousChef

/// Tests for the dietary-safety cluster (see docs/AUDIT.md):
/// - resource bundling actually loads the JSON datasets,
/// - duplicate ingredient lines no longer crash (C1),
/// - category allergens resolve through the food dictionary (C2),
/// - matching is word-boundary / exception aware (H1),
/// - religious & specialty diets catch common product forms (H3/H4),
/// - Auto-Adapt building blocks reject a swap that introduces another diner's allergen (C3).
///
/// The test target is hosted in the app (TEST_HOST), so `Bundle.main` resolves to the app
/// bundle and these exercise the real bundled datasets end-to-end — a failure here also
/// signals a resource-packaging regression.
final class ProfileMatcherTests: XCTestCase {

    private let matcher = ProfileMatcher()

    // MARK: - Helpers

    private func ingredient(_ item: String, _ rawText: String? = nil, order: Int = 0) -> Ingredient {
        Ingredient(item: item, rawText: rawText ?? item, order: order)
    }

    private func diner(diets: [String] = [], allergies: [String] = [], custom: [String] = []) -> DinerProfile {
        let d = DinerProfile(name: "Test")
        d.diets = diets
        d.allergies = allergies
        d.customRestrictions = custom
        return d
    }

    private func level(_ item: String, _ rawText: String? = nil, diner: DinerProfile) -> CompatibilityLevel {
        let ing = ingredient(item, rawText)
        let results = matcher.match(ingredients: [ing], diners: [diner])
        return results.first?.results[ing.id]?.level ?? .green
    }

    // MARK: - Resource bundling (the escalated root cause)

    func testDatasetsLoadFromBundle() {
        XCTAssertFalse(DietLibrary.shared.diets.isEmpty, "diets.json failed to load — bundling regression")
        XCTAssertTrue(DietLibrary.shared.isLoaded)
        XCTAssertNotNil(DietLibrary.shared.diet(id: "gluten-free"))
        XCTAssertNotNil(FoodDictionary.shared.find(name: "shrimp"), "food-dictionary.json failed to load")
        XCTAssertFalse(SubstitutionLibrary.shared.options(for: "flour", diet: "gluten-free")?.isEmpty ?? true,
                       "substitutions.json failed to load")
    }

    // MARK: - C1: duplicate ingredient lines must not crash

    func testDuplicateIngredientLinesDoNotCrash() {
        let a = ingredient("salt", "1 tsp salt", order: 0)
        let b = ingredient("salt", "1 tsp salt", order: 1)  // identical rawText
        let results = matcher.match(ingredients: [a, b], diners: [diner(diets: ["vegan"])])
        // Keyed by stable id, both survive rather than trapping on a duplicate key.
        XCTAssertEqual(results.first?.results.count, 2)
    }

    // MARK: - C2: category allergens resolve through the dictionary

    func testCategoryAllergensAreCaught() {
        XCTAssertEqual(level("shrimp", diner: diner(allergies: ["shellfish"])), .red)
        XCTAssertEqual(level("prawns", diner: diner(allergies: ["shellfish"])), .red)
        XCTAssertEqual(level("mayonnaise", diner: diner(allergies: ["egg"])), .red)
        XCTAssertEqual(level("flour", diner: diner(allergies: ["gluten"])), .red)
    }

    func testDirectAllergyStillMatchesWithWordBoundary() {
        // "peanut" allergy must catch "peanut butter" (plural/typo tolerant, word-aware).
        XCTAssertEqual(level("peanut butter", diner: diner(allergies: ["peanut"])), .red)
        XCTAssertEqual(level("peanuts", diner: diner(allergies: ["peanut"])), .red)
    }

    func testUnresolvableIngredientIsYellowNotGreenForAllergicDiner() {
        // Not in the food dictionary → can't prove it's safe → YELLOW, never GREEN (C2 backstop).
        let lvl = level("dragonfruit gummy", diner: diner(allergies: ["peanut"]))
        XCTAssertEqual(lvl, .yellow)
    }

    // MARK: - H1: no more substring false positives

    func testNoSubstringFalsePositives() {
        XCTAssertEqual(level("eggplant", diner: diner(diets: ["vegan"])), .green, "egg must not flag eggplant")
        XCTAssertEqual(level("almond milk", diner: diner(diets: ["dairy-free"])), .green, "milk must not flag almond milk")
        XCTAssertEqual(level("buckwheat flour", "buckwheat", diner: diner(diets: ["gluten-free"])), .green, "wheat must not flag buckwheat")
    }

    /// A source-modified "form" ingredient must not inherit the plain form's category or
    /// allergens via head-noun resolution ("rice/buckwheat flour" → the wheat "flour" entry,
    /// "vegan butter" → the dairy "butter" entry).
    func testReformulableFormsNotFlaggedByHeadNoun() {
        XCTAssertEqual(level("rice flour", diner: diner(diets: ["gluten-free"])), .green)
        XCTAssertEqual(level("coconut flour", diner: diner(diets: ["gluten-free"])), .green)
        XCTAssertEqual(level("vegan butter", diner: diner(diets: ["dairy-free"])), .green)
        // A wheat-allergic diner is also safe with a wheat-free flour.
        XCTAssertEqual(level("rice flour", diner: diner(allergies: ["wheat"])), .green)
    }

    /// The head-noun resolution that the confidence gate protects must still work for real
    /// category hits: "pork shoulder"/"beef brisket" resolve via their head noun to a meat
    /// entry, and meat-restricting diets must still flag them.
    func testHeadNounCategoryStillCatchesMeat() {
        XCTAssertEqual(level("pork shoulder", diner: diner(diets: ["pescatarian"])), .red)
        XCTAssertEqual(level("pork shoulder", diner: diner(diets: ["vegetarian"])), .red)
        XCTAssertEqual(level("cheddar cheese", diner: diner(diets: ["dairy-free"])), .red)
    }

    // MARK: - H3: religious diets catch common product forms

    func testKosherCatchesPorkAndShellfishForms() {
        XCTAssertEqual(level("bacon", diner: diner(diets: ["kosher"])), .red)
        XCTAssertEqual(level("prosciutto", diner: diner(diets: ["kosher"])), .red)
        XCTAssertEqual(level("prawns", diner: diner(diets: ["kosher"])), .red)
        XCTAssertEqual(level("pepperoni", diner: diner(diets: ["kosher"])), .red)
    }

    func testHalalCatchesSpirits() {
        XCTAssertEqual(level("vodka", diner: diner(diets: ["halal"])), .red)
        XCTAssertEqual(level("pancetta", diner: diner(diets: ["halal"])), .red)
    }

    // MARK: - H4: gluten-free & low-sodium gaps

    func testGlutenFreeCatchesHiddenGlutenGrains() {
        XCTAssertEqual(level("couscous", diner: diner(diets: ["gluten-free"])), .red)
        XCTAssertEqual(level("seitan", diner: diner(diets: ["gluten-free"])), .red)
        XCTAssertEqual(level("orzo", diner: diner(diets: ["gluten-free"])), .red)
    }

    func testLowSodiumFlagsSalt() {
        XCTAssertEqual(level("salt", "2 tsp salt", diner: diner(diets: ["low-sodium"])), .red)
    }

    // MARK: - C3: Auto-Adapt safety building blocks

    func testSubstituteThatIntroducesAnotherAllergenIsRejected() {
        // Auto-Adapt verifies each candidate against every diner. "almond flour" is a common
        // gluten-free swap for "flour" but is RED for a nut-allergic diner, so it must be
        // rejected rather than applied and labelled "Adapted".
        let nutAllergic = diner(allergies: ["tree nuts"])
        XCTAssertEqual(matcher.evaluate(item: "almond flour", rawText: "almond flour", against: nutAllergic).level, .red)
    }

    func testRedFlaggingDietIdsEnumeratesDietOnly() {
        // A diet red flag exposes the diet id (so substitutions can be looked up)...
        let gf = diner(diets: ["gluten-free"])
        XCTAssertEqual(matcher.redFlaggingDietIds(item: "flour", rawText: "2 cups flour", diner: gf), ["gluten-free"])
        // ...but an allergy-only red flag exposes no diet id (unfixable, never guessed).
        let allergic = diner(allergies: ["shellfish"])
        XCTAssertTrue(matcher.redFlaggingDietIds(item: "shrimp", rawText: "shrimp", diner: allergic).isEmpty)
    }
}
