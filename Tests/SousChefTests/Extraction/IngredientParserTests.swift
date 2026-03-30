import XCTest
@testable import SousChef

final class IngredientParserTests: XCTestCase {
    let parser = IngredientParser()

    // MARK: - Basic quantity + unit + item

    func testSimpleIntegerQuantity() {
        let r = parser.parse(raw: "2 cups flour")
        XCTAssertEqual(r.quantity, "2")
        XCTAssertEqual(r.unit, "cup")
        XCTAssertEqual(r.item, "flour")
    }

    func testFractionQuantity() {
        let r = parser.parse(raw: "1/2 cup sugar")
        XCTAssertEqual(r.quantity, "1/2")
        XCTAssertEqual(r.unit, "cup")
        XCTAssertEqual(r.item, "sugar")
    }

    func testMixedNumberQuantity() {
        let r = parser.parse(raw: "1 1/2 cups milk")
        XCTAssertEqual(r.quantity, "1 1/2")
        XCTAssertEqual(r.unit, "cup")
        XCTAssertEqual(r.item, "milk")
    }

    func testUnicodeFractionHalf() {
        let r = parser.parse(raw: "½ cup butter")
        XCTAssertEqual(r.quantity, "1/2")
        XCTAssertEqual(r.unit, "cup")
        XCTAssertEqual(r.item, "butter")
    }

    func testUnicodeFractionThird() {
        let r = parser.parse(raw: "⅓ cup olive oil")
        XCTAssertEqual(r.quantity, "1/3")
        XCTAssertEqual(r.unit, "cup")
        XCTAssertEqual(r.item, "olive oil")
    }

    func testRangeQuantity() {
        let r = parser.parse(raw: "2-3 cloves garlic, minced")
        XCTAssertEqual(r.quantity, "2-3")
        XCTAssertEqual(r.unit, "clove")
        XCTAssertEqual(r.item, "garlic")
        XCTAssertEqual(r.preparation, "minced")
    }

    func testDecimalQuantity() {
        let r = parser.parse(raw: "0.5 kg chicken breast")
        XCTAssertEqual(r.quantity, "0.5")
        XCTAssertEqual(r.unit, "kilogram")
        XCTAssertEqual(r.item, "chicken breast")
    }

    // MARK: - Unit normalization

    func testTbspNormalization() {
        let r = parser.parse(raw: "2 tbsp olive oil")
        XCTAssertEqual(r.unit, "tablespoon")
    }

    func testTspNormalization() {
        let r = parser.parse(raw: "1 tsp vanilla extract")
        XCTAssertEqual(r.unit, "teaspoon")
    }

    func testLbNormalization() {
        let r = parser.parse(raw: "1 lb ground beef")
        XCTAssertEqual(r.unit, "pound")
    }

    func testOzNormalization() {
        let r = parser.parse(raw: "8 oz cream cheese")
        XCTAssertEqual(r.unit, "ounce")
    }

    func testGramNormalization() {
        let r = parser.parse(raw: "200 g dark chocolate")
        XCTAssertEqual(r.unit, "gram")
    }

    func testTablespoonPlural() {
        let r = parser.parse(raw: "3 tablespoons butter")
        XCTAssertEqual(r.unit, "tablespoon")
    }

    // MARK: - Preparation extraction

    func testCommaPreparation() {
        let r = parser.parse(raw: "2 cloves garlic, minced")
        XCTAssertEqual(r.item, "garlic")
        XCTAssertEqual(r.preparation, "minced")
    }

    func testMultiWordPreparation() {
        let r = parser.parse(raw: "1 onion, finely chopped")
        XCTAssertEqual(r.item, "onion")
        XCTAssertEqual(r.preparation, "finely chopped")
    }

    func testParentheticalNote() {
        let r = parser.parse(raw: "1 (14.5 oz) can diced tomatoes")
        XCTAssertEqual(r.unit, "can")
        XCTAssertTrue(r.item.contains("diced tomatoes"))
        XCTAssertNotNil(r.preparation)
    }

    func testParentheticalEquivalent() {
        let r = parser.parse(raw: "1/2 cup (1 stick) unsalted butter, softened")
        XCTAssertEqual(r.quantity, "1/2")
        XCTAssertEqual(r.unit, "cup")
        XCTAssertTrue(r.item.contains("butter"))
    }

    // MARK: - Items without quantity (exempt words)

    func testSaltAndPepper() {
        let r = parser.parse(raw: "salt and pepper to taste")
        XCTAssertNil(r.quantity)
        XCTAssertNil(r.unit)
        XCTAssertFalse(r.item.isEmpty)
    }

    func testSaltToTaste() {
        let r = parser.parse(raw: "salt to taste")
        XCTAssertNil(r.quantity)
        XCTAssertFalse(r.item.isEmpty)
    }

    // MARK: - Word numbers

    func testWordNumberOne() {
        let r = parser.parse(raw: "one egg")
        XCTAssertEqual(r.quantity, "1")
        XCTAssertEqual(r.item, "egg")
    }

    func testWordNumberA() {
        let r = parser.parse(raw: "a pinch of salt")
        XCTAssertEqual(r.quantity, "1")
        XCTAssertEqual(r.unit, "pinch")
    }

    func testWordNumberHandful() {
        let r = parser.parse(raw: "handful of fresh basil")
        XCTAssertEqual(r.quantity, "1")
        XCTAssertFalse(r.item.isEmpty)
    }

    // MARK: - Complex real-world strings

    func testCanWithContent() {
        let r = parser.parse(raw: "1 (14.5 oz) can diced tomatoes, drained")
        XCTAssertEqual(r.quantity, "1")
        XCTAssertNotNil(r.unit)
        XCTAssertFalse(r.item.isEmpty)
    }

    func testStickOfButter() {
        let r = parser.parse(raw: "1/2 cup (1 stick) unsalted butter, softened")
        XCTAssertEqual(r.quantity, "1/2")
        XCTAssertEqual(r.unit, "cup")
    }

    func testGarlicCloves() {
        let r = parser.parse(raw: "3-4 cloves garlic, minced")
        XCTAssertEqual(r.quantity, "3-4")
        XCTAssertEqual(r.unit, "clove")
        XCTAssertEqual(r.item, "garlic")
        XCTAssertEqual(r.preparation, "minced")
    }

    func testFreshHerbs() {
        let r = parser.parse(raw: "handful of fresh basil")
        XCTAssertEqual(r.quantity, "1")
        XCTAssertFalse(r.item.isEmpty)
    }

    func testBunchScallions() {
        let r = parser.parse(raw: "1 bunch scallions, thinly sliced")
        XCTAssertEqual(r.quantity, "1")
        XCTAssertEqual(r.unit, "bunch")
        XCTAssertEqual(r.item, "scallions")
        XCTAssertEqual(r.preparation, "thinly sliced")
    }

    func testSprigThyme() {
        let r = parser.parse(raw: "2 sprigs fresh thyme")
        XCTAssertEqual(r.quantity, "2")
        XCTAssertEqual(r.unit, "sprig")
        XCTAssertTrue(r.item.contains("thyme"))
    }

    func testPinchSalt() {
        let r = parser.parse(raw: "pinch of salt")
        XCTAssertEqual(r.unit, "pinch")
    }

    func testDashHotSauce() {
        let r = parser.parse(raw: "2 dashes hot sauce")
        XCTAssertEqual(r.quantity, "2")
        XCTAssertEqual(r.unit, "dash")
        XCTAssertTrue(r.item.contains("hot sauce"))
    }

    // MARK: - Raw text preservation

    func testRawTextPreserved() {
        let raw = "2 cups all-purpose flour, sifted"
        let r = parser.parse(raw: raw)
        XCTAssertEqual(r.rawText, raw)
    }

    func testItemNotEmpty() {
        // Even weird strings should return a non-empty item
        let r = parser.parse(raw: "some weird ingredient")
        XCTAssertFalse(r.item.isEmpty)
    }

    // MARK: - Section pass-through

    func testSectionPreserved() {
        let r = parser.parse(raw: "2 cups flour", section: "For the cake")
        XCTAssertEqual(r.section, "For the cake")
    }

    // MARK: - Edge cases

    func testEmptyString() {
        let r = parser.parse(raw: "")
        XCTAssertNil(r.quantity)
        XCTAssertNil(r.unit)
    }

    func testNumberOnly() {
        let r = parser.parse(raw: "3 eggs")
        XCTAssertEqual(r.quantity, "3")
        XCTAssertNil(r.unit)
        XCTAssertEqual(r.item, "eggs")
    }

    func testLargeCan() {
        let r = parser.parse(raw: "2 cans (15 oz each) chickpeas, rinsed")
        XCTAssertEqual(r.quantity, "2")
        XCTAssertEqual(r.unit, "can")
        XCTAssertTrue(r.item.contains("chickpeas"))
    }

    func testTwoWordUnit() {
        // "fl oz" is a two-word unit
        let r = parser.parse(raw: "4 fl oz heavy cream")
        XCTAssertEqual(r.quantity, "4")
        XCTAssertEqual(r.unit, "fluid ounce")
        XCTAssertTrue(r.item.contains("cream"))
    }

    func testGramWithNoSpace() {
        let r = parser.parse(raw: "250 g butter")
        XCTAssertEqual(r.quantity, "250")
        XCTAssertEqual(r.unit, "gram")
        XCTAssertEqual(r.item, "butter")
    }
}
