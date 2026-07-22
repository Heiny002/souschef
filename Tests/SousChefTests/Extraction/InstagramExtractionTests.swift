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

    // MARK: - Embed page parsing (the InstaFix technique)

    /// Build an embed-page fixture the way Instagram serves it: the gql_data JSON is
    /// escaped inside a JS string. Serializing then JSON-string-encoding produces the
    /// exact escaping, so the test never drifts from real escaping rules.
    private func embedHTMLFixture(caption: String) throws -> String {
        let gql: [String: Any] = [
            "shortcode_media": [
                "edge_media_to_caption": ["edges": [["node": ["text": caption]]]],
                "owner": ["username": "chef_jo", "full_name": "Chef Jo"],
                "display_url": "https://example.com/thumb.jpg",
            ],
        ]
        let context: [String: Any] = ["gql_data": gql, "hostname": "www.instagram.com"]
        // sortedKeys pins "gql_data" before "hostname", matching the real page's layout
        // (and keeping the hostname-cut fallback candidate exercised deterministically).
        let contextJSON = String(
            data: try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]),
            encoding: .utf8)!
        let escapedData = try JSONSerialization.data(
            withJSONObject: contextJSON, options: [.fragmentsAllowed])
        var escaped = String(data: escapedData, encoding: .utf8)!
        escaped.removeFirst()   // strip the wrapping quotes added by string-encoding
        escaped.removeLast()
        return "<html><body><script>s.handle(\"\(escaped)\")</script></body></html>"
    }

    func testExtractGQLDataFromEscapedEmbedHTML() throws {
        let html = try embedHTMLFixture(caption: "Pasta night\n\nIngredients\n200g pasta")
        let gql = VideoMetadataFetcher.extractEmbedGQLData(fromEmbedHTML: html)
        let meta = gql.flatMap { VideoMetadataFetcher.parseInstagramJSON(["graphql": $0]) }
        XCTAssertEqual(meta?.caption?.hasPrefix("Pasta night"), true)
        XCTAssertEqual(meta?.authorURL, "https://www.instagram.com/chef_jo/")
        XCTAssertEqual(meta?.thumbnailURL, "https://example.com/thumb.jpg")
    }

    func testExtractGQLDataSurvivesBracesInCaption() throws {
        // Braces inside the caption break naive brace-matching; the hostname-cut
        // fallback candidate must recover it.
        let html = try embedHTMLFixture(caption: "Use {about} 2 cups flour } extra brace")
        let gql = VideoMetadataFetcher.extractEmbedGQLData(fromEmbedHTML: html)
        let meta = gql.flatMap { VideoMetadataFetcher.parseInstagramJSON(["graphql": $0]) }
        XCTAssertEqual(meta?.caption, "Use {about} 2 cups flour } extra brace")
    }

    func testExtractCaptionFromRenderedEmbedHTML() {
        let html = """
        <div class="Caption"><a class="CaptionUsername" href="#">chef_jo</a> \
        Honey Garlic Chicken<br />Ingredients<br />2 chicken breasts<br />3 tbsp honey\
        <div class="CaptionComments"><a href="#">View all 12 comments</a></div></div>
        """
        let caption = VideoMetadataFetcher.extractEmbedCaption(fromEmbedHTML: html)
        XCTAssertEqual(caption?.hasPrefix("Honey Garlic Chicken"), true)
        XCTAssertEqual(caption?.contains("2 chicken breasts"), true)
        XCTAssertEqual(caption?.contains("chef_jo"), false, "username anchor must be stripped")
        XCTAssertEqual(caption?.contains("comments"), false, "comments block must be stripped")
        // <br> became newlines so the recipe parser sees list structure.
        XCTAssertEqual(caption?.contains("\n"), true)
    }

    func testParseGraphQLResponseXDTShape() {
        let json: [String: Any] = [
            "data": ["xdt_shortcode_media": [
                "edge_media_to_caption": ["edges": [["node": ["text": "Tacos\n1 lb beef"]]]],
                "owner": ["username": "taco_t", "full_name": "Taco Tuesday"],
                "display_url": "https://example.com/taco.jpg",
            ]],
        ]
        let meta = VideoMetadataFetcher.parseInstagramGraphQLResponse(json)
        XCTAssertEqual(meta?.caption?.hasPrefix("Tacos"), true)
        XCTAssertEqual(meta?.authorURL, "https://www.instagram.com/taco_t/")
        XCTAssertNil(VideoMetadataFetcher.parseInstagramGraphQLResponse(["data": [:]]))
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

    // MARK: - WKWebView caption parsing

    func testCleanOGDescriptionStripsEngagementPrefix() {
        let og = #"1,234 likes, 56 comments - chef_jo on July 20, 2026: "Honey Garlic Chicken — 2 chicken breasts, 3 tbsp honey""#
        let caption = InstagramCaptionParser.cleanOGDescription(og)
        XCTAssertEqual(caption?.hasPrefix("Honey Garlic Chicken"), true)
        XCTAssertEqual(caption?.contains("likes"), false)
        XCTAssertEqual(caption?.hasSuffix("\""), false, "trailing quote trimmed")
    }

    func testCleanOGDescriptionWithoutPrefixKeepsWholeCaption() {
        let caption = InstagramCaptionParser.cleanOGDescription("Just a plain caption with a recipe")
        XCTAssertEqual(caption, "Just a plain caption with a recipe")
    }

    func testOGDescriptionBoilerplateRejected() {
        XCTAssertNil(InstagramCaptionParser.cleanOGDescription("See Instagram photos and videos from chef_jo"))
        XCTAssertNil(InstagramCaptionParser.cleanOGDescription("Log in to Instagram"))
        XCTAssertNil(InstagramCaptionParser.cleanOGDescription("short"))
    }

    func testParsePrefersJSONLDOverOG() throws {
        let ld = try String(
            data: JSONSerialization.data(withJSONObject: [
                "@type": "VideoObject",
                "caption": "Full recipe from JSON-LD: 2 cups flour, 1 tsp salt",
            ]),
            encoding: .utf8)!
        let jsResult = try String(
            data: JSONSerialization.data(withJSONObject: ["og": "Some og text here", "ld": ld]),
            encoding: .utf8)!
        XCTAssertEqual(
            InstagramCaptionParser.parse(jsResult: jsResult),
            "Full recipe from JSON-LD: 2 cups flour, 1 tsp salt")
    }

    func testParseFallsBackToOGWhenNoLD() throws {
        let jsResult = try String(
            data: JSONSerialization.data(withJSONObject: [
                "og": #"10 likes - user: "Caption via og description here""#,
                "ld": "",
            ]),
            encoding: .utf8)!
        XCTAssertEqual(InstagramCaptionParser.parse(jsResult: jsResult), "Caption via og description here")
    }

    func testParseJSONLDGraphShape() throws {
        let ld = try String(
            data: JSONSerialization.data(withJSONObject: [
                "@graph": [["@type": "ImageObject"], ["@type": "VideoObject", "articleBody": "Recipe body text from graph node"]],
            ]),
            encoding: .utf8)!
        XCTAssertEqual(
            InstagramCaptionParser.captionFromLDJSON(ld),
            "Recipe body text from graph node")
    }

    func testParseNilAndGarbage() {
        XCTAssertNil(InstagramCaptionParser.parse(jsResult: nil))
        XCTAssertNil(InstagramCaptionParser.parse(jsResult: "not json"))
        XCTAssertNil(InstagramCaptionParser.parse(jsResult: #"{"og":"","ld":""}"#))
    }

    // MARK: - Authenticated GraphQL variables

    func testGraphQLVariablesAreValidJSONWithShortcode() throws {
        let vars = InstagramAuth.graphQLVariables(shortcode: "DaQXcT-R807")
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(vars.utf8)) as? [String: Any])
        XCTAssertEqual(obj["shortcode"] as? String, "DaQXcT-R807")
        // Comment/like counts zeroed — we only want the caption.
        XCTAssertEqual(obj["fetch_comment_count"] as? Int, 0)
        XCTAssertEqual(obj["has_threaded_comments"] as? Bool, true)
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
