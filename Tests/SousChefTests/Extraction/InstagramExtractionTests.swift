import XCTest
@testable import SousChef

/// The in-app Instagram caption path: pull the shortcode from the URL, parse Instagram's
/// JSON (both response shapes) into a caption, and feed that caption to the structured
/// parser so an obvious recipe caption actually extracts. Network calls aren't exercised —
/// only the pure parsing seams, which is where the logic lives.
final class InstagramExtractionTests: XCTestCase {

    // MARK: - Shortcode extraction

    func testShortcodeFromReelURL() {
        XCTAssertEqual(
            VideoMetadataFetcher.instagramShortcode(from: "https://www.instagram.com/reel/DaQXcT-R807/?igsh=abc"),
            "DaQXcT-R807")
        XCTAssertEqual(
            VideoMetadataFetcher.instagramShortcode(from: "https://instagram.com/p/ABC123/"),
            "ABC123")
        XCTAssertEqual(
            VideoMetadataFetcher.instagramShortcode(from: "https://www.instagram.com/tv/XYZ789/"),
            "XYZ789")
        // A bare profile URL has no shortcode.
        XCTAssertNil(VideoMetadataFetcher.instagramShortcode(from: "https://www.instagram.com/someuser/"))
    }

    // MARK: - JSON parsing (both shapes)

    func testParseNewerItemsShape() {
        let json: [String: Any] = [
            "items": [[
                "caption": ["text": "Honey Garlic Chicken\n\nIngredients\n2 chicken breasts\n3 tbsp honey"],
                "user": ["username": "chef_jo", "full_name": "Chef Jo"],
                "image_versions2": ["candidates": [["url": "https://example.com/thumb.jpg"]]],
            ]],
        ]
        let meta = VideoMetadataFetcher.parseInstagramJSON(json)
        XCTAssertEqual(meta?.authorName, "Chef Jo")
        XCTAssertEqual(meta?.authorURL, "https://www.instagram.com/chef_jo/")
        XCTAssertEqual(meta?.thumbnailURL, "https://example.com/thumb.jpg")
        XCTAssertEqual(meta?.caption?.hasPrefix("Honey Garlic Chicken"), true)
    }

    func testParseOlderGraphqlShape() {
        let json: [String: Any] = [
            "graphql": ["shortcode_media": [
                "edge_media_to_caption": ["edges": [["node": ["text": "Pasta\n\nIngredients\n200g pasta"]]]],
                "owner": ["username": "pasta_guy", "full_name": "Pasta Guy"],
                "display_url": "https://example.com/p.jpg",
            ]],
        ]
        let meta = VideoMetadataFetcher.parseInstagramJSON(json)
        XCTAssertEqual(meta?.authorURL, "https://www.instagram.com/pasta_guy/")
        XCTAssertEqual(meta?.thumbnailURL, "https://example.com/p.jpg")
        XCTAssertEqual(meta?.caption?.hasPrefix("Pasta"), true)
    }

    func testParseMissingOrEmptyReturnsNil() {
        XCTAssertNil(VideoMetadataFetcher.parseInstagramJSON([:]))
        XCTAssertNil(VideoMetadataFetcher.parseInstagramJSON(["items": []]))
        XCTAssertNil(VideoMetadataFetcher.parseInstagramJSON([
            "items": [["caption": ["text": ""]]],
        ]))
    }

    // MARK: - Caption → structured recipe

    func testCaptionCleaningStripsHashtagLines() {
        let caption = "Title\n\nIngredients\n2 eggs\n\nInstructions\nBeat the eggs.\n\n#food #recipe #yum"
        let cleaned = ExtractionPipeline.cleanCaptionForParsing(caption)
        XCTAssertFalse(cleaned.contains("#food"), "trailing hashtag wall must be dropped")
        XCTAssertTrue(cleaned.contains("Beat the eggs."), "real content must survive")
    }

    func testStructuredCaptionExtractsAsRecipe() {
        // The shape a real recipe reel caption takes — the whole point of routing captions
        // through PastedTextExtractor instead of the spoken-word extractor.
        let caption = """
        Honey Garlic Chicken 🍗

        Ingredients
        2 chicken breasts
        3 tbsp honey
        2 cloves garlic, minced

        Instructions
        Sear the chicken until golden.
        Add the honey and garlic.
        Simmer for 5 minutes.

        #chicken #dinner #easyrecipe
        """
        let r = PastedTextExtractor().extract(text: ExtractionPipeline.cleanCaptionForParsing(caption))
        XCTAssertEqual(r.title, "Honey Garlic Chicken 🍗")
        XCTAssertEqual(r.ingredients.count, 3)
        XCTAssertEqual(r.steps.count, 3, "hashtag line must not become a 4th step")
        XCTAssertTrue(r.isViable)
    }

    // MARK: - Candidate ranking

    func testCompletenessPrefersViableThenRicher() {
        var weak = ExtractionResult(extractionMethod: "transcript-nlp")
        weak.title = "Something"
        weak.ingredients = [RawIngredient(text: "1 egg")]   // no steps → not viable

        var strong = ExtractionResult(extractionMethod: "pasted-text")
        strong.title = "Something"
        strong.ingredients = [RawIngredient(text: "1 egg"), RawIngredient(text: "2 cups flour")]
        strong.steps = [RawStep(order: 1, text: "Mix."), RawStep(order: 2, text: "Bake.")]

        XCTAssertGreaterThan(
            ExtractionPipeline.completeness(strong),
            ExtractionPipeline.completeness(weak))
    }
}
