import XCTest
@testable import SousChef

/// The LLM caption structurer's network call can't run in a unit test, but its response
/// parsing is pure (`recipe(fromModelText:)`) — and that's where the real risk lives:
/// tolerating the model's JSON shape drift, code fences, section labels, and non-recipe
/// replies without crashing or fabricating a recipe.
final class LLMCaptionStructurerTests: XCTestCase {

    func testParsesSectionedIngredientsAndSteps() {
        let json = """
        {
          "title": "Steak Wraps",
          "recipeYield": "4 wraps",
          "prepTimeMinutes": 15,
          "cookTimeMinutes": 10,
          "ingredients": [
            {"text": "1 lb flank steak", "section": "Steak"},
            {"text": "2 tbsp soy sauce", "section": "Steak"},
            {"text": "1 cup greek yogurt", "section": "Yogurt spread"}
          ],
          "steps": ["Season the steak.", "Grill 4 minutes per side.", "Assemble the wraps."]
        }
        """
        let r = LLMCaptionStructurer.recipe(fromModelText: json)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.title, "Steak Wraps")
        XCTAssertEqual(r?.recipeYield, "4 wraps")
        XCTAssertEqual(r?.prepTime, 15 * 60)
        XCTAssertEqual(r?.cookTime, 10 * 60)
        XCTAssertEqual(r?.ingredients.count, 3)
        XCTAssertEqual(r?.ingredients.first?.text, "1 lb flank steak")
        XCTAssertEqual(r?.ingredients.first?.section, "Steak")
        XCTAssertEqual(r?.ingredients.last?.section, "Yogurt spread")
        XCTAssertEqual(r?.steps.count, 3)
        XCTAssertEqual(r?.steps.first?.text, "Season the steak.")
        XCTAssertEqual(r?.steps.first?.order, 1)
        XCTAssertEqual(r?.isViable, true)
    }

    func testToleratesPlainStringIngredients() {
        // If the model simplifies ingredients to bare strings, we must not drop the list.
        let json = """
        {"title": "Toast", "ingredients": ["2 slices bread", "butter"], "steps": ["Toast it."]}
        """
        let r = LLMCaptionStructurer.recipe(fromModelText: json)
        XCTAssertEqual(r?.ingredients.count, 2)
        XCTAssertEqual(r?.ingredients.first?.text, "2 slices bread")
        XCTAssertNil(r?.ingredients.first?.section)
        XCTAssertEqual(r?.isViable, true)
    }

    func testUnwrapsCodeFencedJSON() {
        // Models sometimes wrap JSON in ```json fences despite instructions not to.
        let text = """
        Here you go:
        ```json
        {"title": "Guac", "ingredients": [{"text": "2 avocados", "section": null}], "steps": ["Mash."]}
        ```
        """
        let r = LLMCaptionStructurer.recipe(fromModelText: text)
        XCTAssertEqual(r?.title, "Guac")
        XCTAssertEqual(r?.ingredients.count, 1)
        XCTAssertEqual(r?.steps.count, 1)
        XCTAssertEqual(r?.isViable, true)
    }

    func testNonRecipeReplyIsNotViable() {
        let json = #"{"title": null, "ingredients": [], "steps": []}"#
        let r = LLMCaptionStructurer.recipe(fromModelText: json)
        XCTAssertNotNil(r, "a well-formed empty result still parses")
        XCTAssertNil(r?.title)
        XCTAssertTrue(r?.ingredients.isEmpty ?? false)
        XCTAssertEqual(r?.isViable, false)
    }

    func testEmptyStringsAreDroppedNotKept() {
        let json = """
        {"title": "  ", "ingredients": [{"text": "", "section": ""}, {"text": "1 egg"}], "steps": ["", "Fry it."]}
        """
        let r = LLMCaptionStructurer.recipe(fromModelText: json)
        XCTAssertNil(r?.title, "whitespace-only title becomes nil")
        XCTAssertEqual(r?.ingredients.count, 1, "blank ingredient dropped")
        XCTAssertEqual(r?.ingredients.first?.text, "1 egg")
        XCTAssertEqual(r?.steps.count, 1, "blank step dropped")
        XCTAssertEqual(r?.steps.first?.text, "Fry it.")
    }

    func testMalformedResponseReturnsNil() {
        XCTAssertNil(LLMCaptionStructurer.recipe(fromModelText: "sorry, I can't help with that"))
    }

    func testStepSectionsAndBulletedItems() {
        // Multi-component recipe: each step carries its component, and a spice blend comes
        // back as an "items" list rendered as bullets rather than inline parentheses.
        let json = """
        {
          "title": "Steak Wraps",
          "ingredients": [{"text": "1 lb flank steak", "section": "Steak"}],
          "steps": [
            {"text": "Season the steak with olive oil and spices, then mix well.",
             "section": "Steak",
             "items": ["olive oil (1 tsp)", "paprika (1/2 tbsp)", "garlic powder (1/2 tbsp)"]},
            {"text": "Bake the flatbreads for 18-20 minutes.", "section": "Flatbread", "items": null}
          ]
        }
        """
        let r = LLMCaptionStructurer.recipe(fromModelText: json)
        XCTAssertEqual(r?.steps.count, 2)
        XCTAssertEqual(r?.steps.first?.section, "Steak")
        XCTAssertEqual(r?.steps.last?.section, "Flatbread")

        let first = r?.steps.first?.text ?? ""
        XCTAssertTrue(first.hasPrefix("Season the steak"), "sentence stays intact")
        XCTAssertTrue(first.contains("\n• olive oil (1 tsp)"), "items become bullets")
        XCTAssertTrue(first.contains("\n• paprika (1/2 tbsp)"))
        XCTAssertEqual(r?.steps.last?.text, "Bake the flatbreads for 18-20 minutes.",
                       "null items adds no bullets")
    }

    func testStepItemsBulletsAreFilteredForTags() {
        // The bullets were the one path with no filtering — a tag here was concatenated into
        // the step body unchecked.
        let json = """
        {
          "title": "Steak", "ingredients": [{"text": "1 lb flank steak"}],
          "steps": [{"text": "Season the steak.", "section": null,
                     "items": ["1 tsp paprika", "#spiceblend"]}]
        }
        """
        let body = LLMCaptionStructurer.recipe(fromModelText: json)?.steps.first?.text ?? ""
        XCTAssertTrue(body.contains("• 1 tsp paprika"))
        XCTAssertFalse(body.contains("#"), "body: \(body)")
    }

    func testStepWithTrailingHashtagIsCleanedNotDropped() {
        // Previously isNoiseLine returned false for this, so it was stored verbatim WITH tags.
        let json = #"{"title": "X", "ingredients": [{"text": "2 peaches @traderjoes"}], "steps": [{"text": "Bake 20 minutes #easyrecipes"}]}"#
        let r = LLMCaptionStructurer.recipe(fromModelText: json)
        XCTAssertEqual(r?.steps.map(\.text), ["Bake 20 minutes"])
        XCTAssertEqual(r?.ingredients.map(\.text), ["2 peaches"])
    }

    func testPlainStringStepsStillParse() {
        // Older/simplified shape must keep working — steps as bare strings, no section.
        let json = #"{"title": "Toast", "ingredients": [{"text": "bread"}], "steps": ["Toast it."]}"#
        let r = LLMCaptionStructurer.recipe(fromModelText: json)
        XCTAssertEqual(r?.steps.count, 1)
        XCTAssertEqual(r?.steps.first?.text, "Toast it.")
        XCTAssertNil(r?.steps.first?.section)
    }

    func testStepOrderingIsSequential() {
        let json = #"{"title": "X", "ingredients": [{"text": "a"}], "steps": ["one", "two", "three"]}"#
        let r = LLMCaptionStructurer.recipe(fromModelText: json)
        XCTAssertEqual(r?.steps.map { $0.order }, [1, 2, 3])
    }
}
