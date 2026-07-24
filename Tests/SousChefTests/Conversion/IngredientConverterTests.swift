import XCTest
@testable import SousChef

/// The density table drives every cup↔weight conversion in the app, so wrong numbers become
/// wrong amounts on someone's counter. These tests pin the King Arthur-derived grams-per-cup
/// values and — just as important — the matcher's specificity, so a big table doesn't make
/// "almond flour" resolve to plain flour.
final class IngredientConverterTests: XCTestCase {

    // MARK: Authoritative per-cup weights (King Arthur, normalized to 1 cup)

    func testCommonDensitiesMatchChart() {
        XCTAssertEqual(IngredientConverter.gPerCup(for: "all-purpose flour"), 120)
        XCTAssertEqual(IngredientConverter.gPerCup(for: "granulated sugar"), 198)
        XCTAssertEqual(IngredientConverter.gPerCup(for: "butter"), 227)
        XCTAssertEqual(IngredientConverter.gPerCup(for: "brown sugar"), 213)
        XCTAssertEqual(IngredientConverter.gPerCup(for: "powdered sugar"), 113)
        XCTAssertEqual(IngredientConverter.gPerCup(for: "cocoa"), 84)          // ½ cup 42g ×2
        XCTAssertEqual(IngredientConverter.gPerCup(for: "honey"), 336)         // 1 tbsp 21g ×16
        XCTAssertEqual(IngredientConverter.gPerCup(for: "peanut butter"), 270) // ½ cup 135g ×2
        XCTAssertEqual(IngredientConverter.gPerCup(for: "cornstarch"), 112)    // ¼ cup 28g ×4
    }

    // MARK: Specificity — the longest matching key wins

    func testSpecificKeyBeatsGeneric() {
        // "almond flour" (96) must not fall through to the generic "flour" (120).
        XCTAssertEqual(IngredientConverter.gPerCup(for: "almond flour"), 96)
        XCTAssertEqual(IngredientConverter.gPerCup(for: "whole wheat flour"), 113)
        XCTAssertEqual(IngredientConverter.gPerCup(for: "coconut milk"), 241)  // not milk 227
        XCTAssertEqual(IngredientConverter.gPerCup(for: "brown rice flour"), 128)
        // "peanut butter" is denser than "butter" — the compound key must win.
        XCTAssertEqual(IngredientConverter.gPerCup(for: "peanut butter"), 270)
    }

    func testKeyEmbeddedInLongerIngredientName() {
        // Real recipe phrasings still resolve via the contained key.
        XCTAssertEqual(IngredientConverter.gPerCup(for: "2 cups sifted all-purpose flour"), 120)
        XCTAssertEqual(IngredientConverter.gPerCup(for: "light brown sugar, packed"), 213)
        XCTAssertEqual(IngredientConverter.gPerCup(for: "unsweetened cocoa powder"), 84)
    }

    // MARK: Bare words land on the generic entry, not an arbitrary long one

    func testBareWordsResolveToGenericEntry() {
        XCTAssertEqual(IngredientConverter.gPerCup(for: "flour"), 120)
        XCTAssertEqual(IngredientConverter.gPerCup(for: "sugar"), 198)
        XCTAssertEqual(IngredientConverter.gPerCup(for: "milk"), 227)
    }

    func testUnknownIngredientReturnsNil() {
        XCTAssertNil(IngredientConverter.gPerCup(for: "gasoline"))
        XCTAssertNil(IngredientConverter.gPerCup(for: "xyz"))
    }

    // MARK: Quantity parsing (used by every mode)

    func testParseQuantityHandlesMixedFractionsAndRanges() {
        XCTAssertEqual(IngredientConverter.parseQuantity("1 1/2"), 1.5)
        XCTAssertEqual(IngredientConverter.parseQuantity("3/4"), 0.75)
        XCTAssertEqual(IngredientConverter.parseQuantity("2-3"), 2.5)   // midpoint
        XCTAssertEqual(IngredientConverter.parseQuantity("2"), 2)
    }

    // MARK: End-to-end display (public API the UI calls)

    func testDisplayConvertsCupOfFlourToGrams() {
        let flour = Ingredient(item: "all-purpose flour", rawText: "1 cup all-purpose flour")
        flour.quantity = "1"
        flour.unit = "cup"
        XCTAssertEqual(IngredientConverter.display(flour, mode: .metric), "120g all-purpose flour")
    }

    func testDisplayOriginalIsUnchanged() {
        let ing = Ingredient(item: "sugar", rawText: "1 cup sugar")
        ing.quantity = "1"
        ing.unit = "cup"
        XCTAssertEqual(IngredientConverter.display(ing, mode: .original), "1 cup sugar")
    }
}
