import XCTest
@testable import SousChef

/// The scaling engine is pure arithmetic + formatting — the LLM supplies structured amounts,
/// this turns "serves 4 → cooking for 6" into correct, human-readable quantities. These tests
/// pin the behaviours the whole scaling feature stands on: parsing, scaling, whole-unit rounding,
/// culinary-fraction display, "to taste" pass-through, and metric ⇄ imperial conversion.
final class RecipeScalingTests: XCTestCase {

    // MARK: Parsing

    func testParsesWholeFractionMixedAndRange() {
        XCTAssertEqual(Quantity.parse(quantity: "2", unit: "cup")?.low, 2)
        XCTAssertEqual(Quantity.parse(quantity: "1/2", unit: "cup")?.low, 0.5)
        XCTAssertEqual(Quantity.parse(quantity: "1 1/2", unit: "cup")?.low, 1.5)
        XCTAssertEqual(Quantity.parse(quantity: "0.25", unit: "teaspoon")?.low, 0.25)

        let range = Quantity.parse(quantity: "2-3", unit: "clove")
        XCTAssertEqual(range?.low, 2)
        XCTAssertEqual(range?.high, 3)
        XCTAssertTrue(range?.isRange ?? false)
    }

    func testNoNumericQuantityReturnsNil() {
        // "salt to taste" has no parseable amount — the parser must not invent one.
        XCTAssertNil(Quantity.parse(quantity: nil, unit: nil))
        XCTAssertNil(Quantity.parse(quantity: "  ", unit: "pinch"))
    }

    func testBareCountHasNoUnit() {
        let eggs = Quantity.parse(quantity: "3", unit: nil)
        XCTAssertEqual(eggs?.low, 3)
        XCTAssertNil(eggs?.unit)
        XCTAssertTrue(eggs?.isCount ?? false)
    }

    // MARK: Scaling

    func testScaleMeasureDoublesValue() {
        let twoCups = Quantity.parse(quantity: "2", unit: "cup")!
        XCTAssertEqual(twoCups.scaled(by: 2).low, 4)
        XCTAssertEqual(QuantityFormatter.string(twoCups.scaled(by: 2)), "4 cups")
    }

    func testScaleProducesCulinaryFraction() {
        let halfCup = Quantity.parse(quantity: "1/2", unit: "cup")!
        // ½ cup × 3 = 1½ cups
        XCTAssertEqual(QuantityFormatter.string(halfCup.scaled(by: 3)), "1½ cups")
        // ½ cup × 1.5 = ¾ cup (singular under/at 1)
        XCTAssertEqual(QuantityFormatter.string(halfCup.scaled(by: 1.5)), "¾ cup")
    }

    func testScaleRangeScalesBothEnds() {
        let cloves = Quantity.parse(quantity: "2-3", unit: "clove")!
        XCTAssertEqual(QuantityFormatter.string(cloves.scaled(by: 2)), "4–6 cloves")
    }

    func testScaleCountRoundsToWholeAndMarksApproximate() {
        let eggs = Quantity.parse(quantity: "3", unit: nil)!
        // 3 × 1.25 = 3.75 → ≈4 (can't have 3.75 eggs)
        XCTAssertEqual(QuantityFormatter.string(eggs.scaled(by: 1.25)), "≈4")
        // 3 × 2 = 6 exactly → no approximation mark
        XCTAssertEqual(QuantityFormatter.string(eggs.scaled(by: 2)), "6")
    }

    func testToTasteIngredientIsNotScaled() {
        let salt = Quantity.parse(quantity: "1", unit: "teaspoon")!
        // scalable:false → seasoning stays put even at 4×
        XCTAssertEqual(salt.scaled(by: 4, scalable: false).low, 1)
    }

    func testScaleByOneIsIdentity() {
        let q = Quantity.parse(quantity: "1 1/2", unit: "cup")!
        XCTAssertEqual(q.scaled(by: 1), q)
    }

    // MARK: Factor

    func testFactorFromYields() {
        XCTAssertEqual(RecipeScaler.factor(baseServings: 4, targetServings: 6), 1.5)
        XCTAssertEqual(RecipeScaler.factor(baseServings: 4, targetServings: 2), 0.5)
    }

    func testFactorGuardsMissingOrZeroYield() {
        // Unknown or zero base yield → factor 1 (show as written), never divide by zero.
        XCTAssertEqual(RecipeScaler.factor(baseServings: nil, targetServings: 6), 1)
        XCTAssertEqual(RecipeScaler.factor(baseServings: 0, targetServings: 6), 1)
        XCTAssertEqual(RecipeScaler.factor(baseServings: 4, targetServings: nil), 1)
    }

    func testDisplayStringScalesAndFormats() {
        let q = Quantity.parse(quantity: "1", unit: "cup")!
        let factor = RecipeScaler.factor(baseServings: 4, targetServings: 6)  // 1.5
        XCTAssertEqual(RecipeScaler.displayString(q, factor: factor), "1½ cups")
    }

    // MARK: Metric formatting (rounds to decimals, not culinary fractions)

    func testMetricMeasureFormatsAsRoundedDecimal() {
        let ml = Quantity.parse(quantity: "500", unit: "milliliter")!
        // 500 ml × 1.5 = 750 ml — rounded whole, no "¾"-style fractions for metric.
        XCTAssertEqual(QuantityFormatter.string(ml.scaled(by: 1.5)), "750 milliliters")
    }

    // MARK: Spoken form

    func testSpokenFormSpellsFractionsAndRanges() {
        let q = Quantity.parse(quantity: "1 1/2", unit: "cup")!
        XCTAssertEqual(QuantityFormatter.spoken(q), "1 and a half cups")
        let range = Quantity.parse(quantity: "2-3", unit: "clove")!
        XCTAssertEqual(QuantityFormatter.spoken(range), "2 to 3 cloves")
    }

    // MARK: Recipe yield parsing (base for the servings scaler)

    func testRecipeYieldExtractsCountAndNoun() {
        XCTAssertEqual(RecipeYield.parse("4 servings")?.count, 4)
        XCTAssertEqual(RecipeYield.parse("4 servings")?.noun, "servings")
        XCTAssertEqual(RecipeYield.parse("Serves 8")?.count, 8)
        XCTAssertEqual(RecipeYield.parse("Serves 8")?.noun, "servings")   // "serves" is filler
        XCTAssertEqual(RecipeYield.parse("36 cookies")?.count, 36)
        XCTAssertEqual(RecipeYield.parse("36 cookies")?.noun, "cookies")
        XCTAssertEqual(RecipeYield.parse("4-6 servings")?.count, 4)       // lower bound
    }

    func testRecipeYieldParsesABareNumber() {
        // The review screen's serving chips insert a bare number, so this is the contract
        // scaling depends on — the noun defaults to "servings".
        XCTAssertEqual(RecipeYield.parse("4")?.count, 4)
        XCTAssertEqual(RecipeYield.parse("4")?.noun, "servings")
    }

    func testRecipeYieldReturnsNilWithoutANumber() {
        XCTAssertNil(RecipeYield.parse("a dozen"))
        XCTAssertNil(RecipeYield.parse(""))
        XCTAssertNil(RecipeYield.parse(nil))
    }
}
