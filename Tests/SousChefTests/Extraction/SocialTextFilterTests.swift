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

    // MARK: Trailing tag runs — the reported bug

    func testTrailingHashtagRunIsStrippedFromRealContent() {
        // The bug: the old rule dropped a line only when EVERY token was a tag, so a real
        // instruction with tags appended survived with the tags attached.
        XCTAssertEqual(SocialTextFilter.stripTrailingTags("Bake 20 minutes #easyrecipes #dinner"),
                       "Bake 20 minutes")
        XCTAssertEqual(SocialTextFilter.cleanLine("2 tbsp olive oil #foodie"), "2 tbsp olive oil")
    }

    func testHashCharacterInRecipeSenseIsNotStripped() {
        // "#" and "@" carry real culinary meaning — pounds, can sizes, oven temperatures.
        for line in ["1 # ground beef", "Use a #10 can of tomatoes",
                     "Bake @ 350F for 20 min", "Roast @425F until browned"] {
            XCTAssertEqual(SocialTextFilter.stripTrailingTags(line), line, "must not alter: \(line)")
        }
    }

    func testInteriorTagIsNotStripped() {
        // Only a run reaching the end of the line is safe to remove; an interior token would
        // leave a grammatical hole.
        let line = "Simmer #covered until the sauce thickens"
        XCTAssertEqual(SocialTextFilter.stripTrailingTags(line), line)
    }

    func testHashtagsMayStartWithDigitsButMentionsMayNot() {
        // "#30minutemeals" is a real hashtag; "@425F" is an oven temperature. The asymmetry
        // is deliberate.
        XCTAssertTrue(SocialTextFilter.isTagToken("#30minutemeals"))
        XCTAssertFalse(SocialTextFilter.isTagToken("@425F"))
        XCTAssertFalse(SocialTextFilter.isTagToken("#10"), "no letters — a can size, not a tag")
        XCTAssertFalse(SocialTextFilter.isTagToken("#"), "a bare marker is never a tag")
        XCTAssertFalse(SocialTextFilter.isTagToken("@"))
        XCTAssertTrue(SocialTextFilter.isTagToken("@chefjo"))
    }

    func testTrailingPunctuationAndEmojiOnTagsStillCount() {
        XCTAssertEqual(SocialTextFilter.stripTrailingTags("Serve warm #dinner. #easy🍑"),
                       "Serve warm")
    }

    func testURLContainingHashIsNotTreatedAsATag() {
        // The token starts with "h", not "#", so it's safe by construction — pinned because
        // fragment URLs do appear in captions.
        let line = "Full method at https://site.com/recipe#ingredients"
        XCTAssertEqual(SocialTextFilter.stripTrailingTags(line), line)
    }

    // MARK: Line-level cleaning

    func testCTALineWithLeadingHashtagIsStillDropped() {
        // Leading tags used to mask the CTA from a prefix match.
        XCTAssertNil(SocialTextFilter.cleanLine("#easyrecipes Save this for later"))
    }

    func testLongLineStartingWithACTAPhraseSurvives() {
        // "full recipe" is a CTA prefix, but this is a real ingredient line — an unbounded
        // prefix match was deleting content like this wholesale.
        let line = "Full recipe: 2 cups flour, 1 tsp salt, 3 eggs, whisk and bake at 350 for 25 minutes"
        XCTAssertNotNil(SocialTextFilter.cleanLine(line))
    }

    func testPureTagWallDropsTheLineWithoutLeavingABlank() {
        // An injected blank line would change paragraph/header detection downstream.
        XCTAssertEqual(SocialTextFilter.clean("a\n#food #yum\nb"), "a\nb")
    }

    func testCleanIsIdempotent() {
        let messy = "Peach Toast\n\nBake 20 min #easy\n#food #yum\nSave this for later\n"
        let once = SocialTextFilter.clean(messy)
        XCTAssertEqual(SocialTextFilter.clean(once), once,
                       "the pipeline cleans, then PastedTextExtractor cleans again")
    }

    // MARK: Entry cleaning (the output-side guard)

    func testCleanEntryTrimsTagsAndDropsPureNoise() {
        XCTAssertEqual(SocialTextFilter.cleanEntry("Bake 20 min #dinner"), "Bake 20 min")
        XCTAssertNil(SocialTextFilter.cleanEntry("#a #b"))
        XCTAssertNil(SocialTextFilter.cleanEntry("   "))
        // A multi-line step (bulleted spice list) keeps its bullets, loses the tag.
        XCTAssertEqual(SocialTextFilter.cleanEntry("Season the steak\n• 1 tsp paprika\n#food"),
                       "Season the steak\n• 1 tsp paprika")
    }

    // MARK: Result sanitizing (last line of defence)

    func testSanitizeStripsNoiseFromAFinishedExtraction() {
        var r = ExtractionResult(extractionMethod: "test")
        r.title = "Peach Toast"
        r.ingredients = [RawIngredient(text: "2 peaches @traderjoes"),
                         RawIngredient(text: "#sponsored")]
        r.steps = [RawStep(order: 1, text: "Grill the bread #summer"),
                   RawStep(order: 2, text: "#easyrecipes #dinner")]
        let clean = SocialTextFilter.sanitize(r)
        XCTAssertEqual(clean.ingredients.map(\.text), ["2 peaches"])
        XCTAssertEqual(clean.steps.map(\.text), ["Grill the bread"])
        XCTAssertEqual(clean.steps.map(\.order), [1], "orders re-numbered after a drop")
    }

    func testSanitizeLeavesACleanRecipeUntouched() {
        // Web-extracted (Schema.org) recipes also pass through this — it must be a no-op.
        var r = ExtractionResult(extractionMethod: "schema-org-jsonld")
        r.title = "Banana Bread"
        r.ingredients = [RawIngredient(text: "3 ripe bananas, mashed")]
        r.steps = [RawStep(order: 1, text: "Preheat oven to 350F.")]
        let clean = SocialTextFilter.sanitize(r)
        XCTAssertEqual(clean.title, "Banana Bread")
        XCTAssertEqual(clean.ingredients.map(\.text), ["3 ripe bananas, mashed"])
        XCTAssertEqual(clean.steps.map(\.text), ["Preheat oven to 350F."])
    }

    // MARK: Extractor-level regressions

    func testTranscriptExtractorNeverEmitsAHashtagStep() {
        // TranscriptExtractor's fallback promotes any sentence over 20 chars to a step, and it
        // received the RAW caption — the largest leak in the pipeline.
        let text = "Grill the bread until it is nicely charred. #easyrecipes #summerfood #dinnerideas"
        let r = TranscriptExtractor().extract(transcript: text)
        XCTAssertFalse(r.steps.contains { $0.text.contains("#") },
                       "steps: \(r.steps.map(\.text))")
    }

    func testTranscriptValidatorFiltersHashtagsFromModelJSON() {
        // This path wrote model JSON straight into the recipe with no filtering at all.
        let partial = ExtractionResult(extractionMethod: "test")
        // Doubled delimiters: the payload contains `"#`, which would close a single-# raw
        // string early and leave the remainder to be parsed as code.
        let json = ##"{"title": "Toast", "ingredients": ["2 peaches"], "steps": ["Bake it.", "#easyrecipes #dinner"]}"##
        let r = TranscriptLLMValidator.result(fromModelText: json, partial: partial, primary: true)
        XCTAssertEqual(r?.steps.map(\.text), ["Bake it."])
    }

    func testTranscriptValidatorRejectsEngagementTitle() {
        let partial = ExtractionResult(extractionMethod: "test")
        let json = #"{"title": "69K likes, 410 comments - jose on July 3", "ingredients": [], "steps": []}"#
        let r = TranscriptLLMValidator.result(fromModelText: json, partial: partial, primary: true)
        XCTAssertNil(r?.title, "engagement metadata must not become the recipe name")
    }

    // MARK: Engagement prefix on the caption itself

    func testStripsEngagementPrefixFromCaption() {
        // Instagram's og:description IS the caption on several fetch routes, and it's
        // prefixed with engagement counts — which became the recipe's title.
        let og = "69K likes, 417 comments - foodswings.by.jose on July 3, 2025: \"Peach burrata toast\n1 loaf sourdough\nGrill the bread.\""
        let caption = SocialTextFilter.stripEngagementPrefix(og)
        XCTAssertTrue(caption.hasPrefix("Peach burrata toast"))
        XCTAssertFalse(caption.contains("69K likes"))
        XCTAssertTrue(caption.contains("1 loaf sourdough"), "the rest of the caption survives")
    }

    func testOrdinaryCaptionIsNotTruncatedByPrefixStripping() {
        // A caption with a colon or quote but no engagement preamble must be left alone.
        let caption = "Grandma's pasta: the only recipe you need\n2 cups flour"
        XCTAssertEqual(SocialTextFilter.stripEngagementPrefix(caption), caption)
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
