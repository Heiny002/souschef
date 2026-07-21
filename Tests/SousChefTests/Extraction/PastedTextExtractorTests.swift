import XCTest
@testable import SousChef

/// The pasted-text importer must turn recipes copied from anywhere — with or without
/// section headers, with bullets or numbers, subsections or a single paragraph — into a
/// title + ingredients + steps that ReviewView can present for editing.
final class PastedTextExtractorTests: XCTestCase {

    private let extractor = PastedTextExtractor()

    func testStructuredWithHeadersAndBullets() {
        let text = """
        Grandma's Banana Bread

        Serves 8 | Prep: 15 min | Bake: 60 min

        Ingredients
        - 3 ripe bananas, mashed
        - 1/2 cup butter, melted
        - 1 cup sugar
        - 2 cups flour
        - 1 tsp baking soda

        Instructions
        1. Preheat oven to 350F.
        2. Mix mashed bananas with melted butter.
        3. Stir in sugar, then fold in flour and baking soda.
        4. Pour into a greased loaf pan and bake for 60 minutes.
        """
        let r = extractor.extract(text: text)
        XCTAssertEqual(r.title, "Grandma's Banana Bread")
        XCTAssertEqual(r.ingredients.count, 5)
        XCTAssertEqual(r.ingredients.first?.text, "3 ripe bananas, mashed")
        XCTAssertEqual(r.steps.count, 4)
        XCTAssertEqual(r.steps.first?.text, "Preheat oven to 350F.")   // "1. " stripped
        XCTAssertEqual(r.recipeYield, "8")
        XCTAssertTrue(r.isViable)
    }

    func testAllCapsHeadersWithParagraphSteps() {
        let text = """
        CHICKEN TIKKA MASALA

        INGREDIENTS:
        2 lbs chicken breast, cubed
        1 cup yogurt
        2 tbsp garam masala

        DIRECTIONS:
        Marinate chicken in yogurt for 1 hour. Sear until browned, then set aside. Simmer 20 minutes and serve over rice.
        """
        let r = extractor.extract(text: text)
        XCTAssertEqual(r.title, "CHICKEN TIKKA MASALA")
        XCTAssertEqual(r.ingredients.count, 3)
        // A single paragraph of directions is exploded into discrete steps.
        XCTAssertGreaterThanOrEqual(r.steps.count, 3)
        XCTAssertEqual(r.steps.first?.text, "Marinate chicken in yogurt for 1 hour.")
    }

    func testSubsectionsWithoutIngredientHeader() {
        // No "Ingredients" header — just "For the …:" subsections before "Method:".
        let text = """
        Pancakes

        For the batter:
        1 cup flour
        1 egg
        3/4 cup milk

        For the topping:
        maple syrup
        butter

        Method:
        Whisk the dry ingredients. Add egg and milk. Cook on a hot griddle, then flip.
        """
        let r = extractor.extract(text: text)
        XCTAssertEqual(r.title, "Pancakes")
        XCTAssertEqual(r.ingredients.count, 5)
        XCTAssertEqual(r.ingredients.first?.section, "For the batter")
        XCTAssertEqual(r.ingredients.last?.section, "For the topping")
        XCTAssertFalse(r.steps.isEmpty)
    }

    func testHeaderlessHeuristicKeepsUnquantifiedIngredient() {
        // No headers at all: leading list is ingredients (incl. "salt to taste", which has
        // no quantity), the sentence paragraph becomes the steps.
        let text = """
        Quick Guac
        2 avocados
        1/4 red onion, minced
        1 lime, juiced
        salt to taste
        Mash the avocados in a bowl. Add onion and lime juice. Season with salt and mix well.
        """
        let r = extractor.extract(text: text)
        XCTAssertEqual(r.title, "Quick Guac")
        XCTAssertEqual(r.ingredients.count, 4)
        XCTAssertEqual(r.ingredients.last?.text, "salt to taste")
        XCTAssertEqual(r.steps.count, 3)
    }

    func testNonRecipeTextYieldsNothingUseful() {
        let text = "just some notes about my day, nothing to see here at all really"
        let r = extractor.extract(text: text)
        // A single line with no ingredient/step shape must not fabricate a recipe.
        XCTAssertTrue(r.ingredients.isEmpty)
        XCTAssertTrue(r.steps.isEmpty)
        XCTAssertFalse(r.isViable)
    }

    func testInlineNumberedStepsOnOneLine() {
        let text = """
        Toast

        Ingredients
        2 slices bread

        Steps
        1. Toast the bread. 2. Butter it. 3. Enjoy.
        """
        let r = extractor.extract(text: text)
        XCTAssertEqual(r.steps.count, 3)
        XCTAssertEqual(r.steps[1].text, "Butter it.")
    }
}
