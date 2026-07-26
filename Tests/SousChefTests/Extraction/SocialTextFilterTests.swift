import XCTest
@testable import SousChef

/// Real Instagram imports were producing a title of "69K likes, 410 comments - creator…",
/// ingredients like "The kind of appetizer that looks effortlessly impressive", and steps like
/// "Save this for your next summer dinner party". This filter is what keeps platform noise out
/// of the recipe.
final class SocialTextFilterTests: XCTestCase {

    // MARK: Titles

    func testEngagementMetadataTitlesAreRejected() {
        XCTAssertTrue(SocialTextFilter.isMetadataTitle(
            "69K likes, 410 comments - foodswings.by.jose on July 3, 2025: \"Peach burrata\""))
        XCTAssertTrue(SocialTextFilter.isMetadataTitle("1,234 likes - someone on Instagram"))
        XCTAssertTrue(SocialTextFilter.isMetadataTitle("Chef Jo on TikTok"))
        XCTAssertNil(SocialTextFilter.cleanTitle("69K likes, 410 comments - jose on July 3"))
    }

    func testRealRecipeTitlesSurvive() {
        XCTAssertFalse(SocialTextFilter.isMetadataTitle("Peach Burrata Toast"))
        XCTAssertEqual(SocialTextFilter.cleanTitle("  Peach Burrata Toast  "), "Peach Burrata Toast")
        // A dish that happens to contain a number must not trip the engagement regex.
        XCTAssertFalse(SocialTextFilter.isMetadataTitle("5 Ingredient Pasta"))
        XCTAssertNil(SocialTextFilter.cleanTitle("   "))
    }

    // MARK: Noise lines

    func testCallsToActionAreNoise() {
        XCTAssertTrue(SocialTextFilter.isNoiseLine("Save this for your next summer dinner party"))
        XCTAssertTrue(SocialTextFilter.isNoiseLine("💾 Save this for later"))
        XCTAssertTrue(SocialTextFilter.isNoiseLine("Follow for more easy recipes"))
        XCTAssertTrue(SocialTextFilter.isNoiseLine("Comment RECIPE and I'll send it"))
        XCTAssertTrue(SocialTextFilter.isNoiseLine("Full recipe in bio"))
    }

    func testMarketingNarrativeIsNoise() {
        XCTAssertTrue(SocialTextFilter.isNoiseLine(
            "The kind of appetizer that looks effortlessly impressive"))
        XCTAssertTrue(SocialTextFilter.isNoiseLine("POV: you need a last-minute app"))
    }

    func testHashtagWallsAndEmojiLinesAreNoise() {
        XCTAssertTrue(SocialTextFilter.isNoiseLine("#easyrecipes #easyapetizers #summerfood"))
        XCTAssertTrue(SocialTextFilter.isNoiseLine("@someone @another"))
        XCTAssertTrue(SocialTextFilter.isNoiseLine("🤍🍑✨"))
    }

    func testRecipeContentIsNeverNoise() {
        XCTAssertFalse(SocialTextFilter.isNoiseLine("2 tbsp olive oil"))
        XCTAssertFalse(SocialTextFilter.isNoiseLine("Bake for 18-20 minutes until golden"))
        XCTAssertFalse(SocialTextFilter.isNoiseLine("🤍🍑 Ingredients for 2 sides (1 loaf)"))
        XCTAssertFalse(SocialTextFilter.isNoiseLine("Season the steak with salt and pepper"))
        // A step that merely mentions a CTA word mid-sentence must survive.
        XCTAssertFalse(SocialTextFilter.isNoiseLine("Let the dough rest, then save the trimmings"))
    }

    func testCleanKeepsBlankLinesForStructure() {
        let caption = """
        Peach Burrata

        🤍🍑 Ingredients for 2 sides
        1 loaf sourdough
        #summer #recipes
        Save this for later
        """
        let cleaned = SocialTextFilter.clean(caption)
        XCTAssertTrue(cleaned.contains("Ingredients for 2 sides"))
        XCTAssertTrue(cleaned.contains("1 loaf sourdough"))
        XCTAssertFalse(cleaned.contains("#summer"))
        XCTAssertFalse(cleaned.contains("Save this"))
        XCTAssertTrue(cleaned.contains("\n\n"), "blank line preserved so headers still parse")
    }

    // MARK: The emoji-header regression

    func testEmojiDecoratedIngredientsHeaderIsRecognized() {
        // The root cause of the bad import: an emoji prefix stopped "Ingredients" from being
        // seen as a header, so the whole caption fell through to headerless parsing.
        let text = """
        Peach Burrata Toast

        🤍🍑 Ingredients for 2 sides (1 loaf)
        1 loaf sourdough
        2 peaches, sliced
        1 ball burrata

        Grill the bread until charred.
        Top with burrata and peaches.
        """
        let r = PastedTextExtractor().extract(text: text)
        XCTAssertEqual(r.title, "Peach Burrata Toast")
        XCTAssertEqual(r.ingredients.count, 3, "emoji header recognized → ingredients parse cleanly")
        XCTAssertEqual(r.ingredients.first?.text, "1 loaf sourdough")
        XCTAssertEqual(r.steps.count, 2)
        XCTAssertTrue(r.isViable)
    }
}
