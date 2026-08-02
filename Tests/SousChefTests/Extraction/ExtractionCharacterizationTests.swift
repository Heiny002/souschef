import CoreGraphics
import XCTest
@testable import SousChef

/// Characterization baseline for the extraction pipeline (think-tank migration branch 1).
///
/// These tests pin what the extractors do TODAY on representative fixtures — including
/// behavior that is known to be wrong. A pin marked CHARACTERIZATION-BUG documents a defect
/// scheduled for a later branch; when that branch lands, it flips the pin deliberately, and
/// the diff shows exactly what changed. Never "fix" one of those pins without the
/// corresponding code change — their whole value is that they fail loudly when behavior
/// drifts by accident.
final class ExtractionCharacterizationTests: XCTestCase {

    // MARK: - Fixtures

    /// A tidy food-blog page: complete JSON-LD, the modal schema-web import.
    private let jsonldFull = """
    <html><head><title>Blog</title>
    <script type="application/ld+json">
    {"@context":"https://schema.org","@type":"Recipe","name":"Lemon Butter Pasta",
     "recipeYield":"4 servings","prepTime":"PT10M","cookTime":"PT15M",
     "recipeIngredient":["8 oz spaghetti","4 tbsp butter","1 lemon","2 cloves garlic"],
     "recipeInstructions":[{"@type":"HowToStep","text":"Boil the spaghetti until al dente."},
                           {"@type":"HowToStep","text":"Melt butter with garlic."},
                           {"@type":"HowToStep","text":"Toss pasta with lemon and butter."}]}
    </script></head><body></body></html>
    """

    /// The same recipe wrapped in @graph, as WPRM/Yoast emit it.
    private let jsonldGraph = """
    <html><head>
    <script type="application/ld+json">
    {"@context":"https://schema.org","@graph":[
      {"@type":"WebPage","name":"Some Page"},
      {"@type":"Recipe","name":"Graph Wrapped Soup",
       "recipeIngredient":["1 onion","2 carrots","4 cups stock"],
       "recipeInstructions":[{"@type":"HowToStep","text":"Chop the vegetables."},
                             {"@type":"HowToStep","text":"Simmer in stock for 20 minutes."}]}]}
    </script></head><body></body></html>
    """

    /// Multi-part recipe using HowToSection — the shape web-sections (branch 4) must improve.
    private let jsonldSections = """
    <html><head>
    <script type="application/ld+json">
    {"@context":"https://schema.org","@type":"Recipe","name":"Steak With Chimichurri",
     "recipeIngredient":["1 lb flank steak","1 bunch parsley","3 cloves garlic"],
     "recipeInstructions":[
       {"@type":"HowToSection","name":"Steak","itemListElement":[
         {"@type":"HowToStep","text":"Season the steak generously."},
         {"@type":"HowToStep","text":"Sear 4 minutes per side."}]},
       {"@type":"HowToSection","name":"Chimichurri","itemListElement":[
         {"@type":"HowToStep","text":"Blend parsley, garlic, and oil."}]}]}
    </script></head><body></body></html>
    """

    /// Instructions as one blob string — common on older plugins.
    private let jsonldSingleString = """
    <html><head>
    <script type="application/ld+json">
    {"@context":"https://schema.org","@type":"Recipe","name":"Blob Brownies",
     "recipeIngredient":["1 cup flour","2 eggs","1 cup cocoa"],
     "recipeInstructions":"Mix the dry ingredients. Beat in the eggs. Bake at 350 for 25 minutes."}
    </script></head><body></body></html>
    """

    /// The merge-staleness fixture: JSON-LD knows the ingredients, microdata knows the steps,
    /// NEITHER alone is complete. Between them the page contains a full recipe.
    private let splitAcrossLayers = """
    <html><head><title>Split Recipe Page</title>
    <script type="application/ld+json">
    {"@context":"https://schema.org","@type":"Recipe","name":"Split Souffle",
     "recipeIngredient":["4 eggs","1 cup gruyere","2 tbsp flour"]}
    </script></head>
    <body itemscope itemtype="https://schema.org/Recipe">
      <span itemprop="name">Split Souffle</span>
      <div itemprop="recipeInstructions"><span itemprop="text">Whisk the egg whites to stiff peaks.</span></div>
      <div itemprop="recipeInstructions"><span itemprop="text">Fold in cheese and bake.</span></div>
    </body></html>
    """

    /// Complete microdata, no JSON-LD.
    private let microdataOnly = """
    <html><head><title>Old Blog</title></head>
    <body itemscope itemtype="https://schema.org/Recipe">
      <h1 itemprop="name">Microdata Chili</h1>
      <li itemprop="recipeIngredient">1 lb ground beef</li>
      <li itemprop="recipeIngredient">1 can kidney beans</li>
      <li itemprop="recipeIngredient">2 tbsp chili powder</li>
      <div itemprop="recipeInstructions"><span itemprop="text">Brown the beef.</span></div>
      <div itemprop="recipeInstructions"><span itemprop="text">Simmer with beans and spices.</span></div>
    </body></html>
    """

    /// No structured data at all — heuristic class-fragment territory.
    private let heuristicBlog = """
    <html><head><title>Grandma's Casserole Recipe</title></head><body>
    <h1>Grandma's Casserole</h1>
    <ul class="recipe-ingredients">
      <li>2 cups cooked rice</li>
      <li>1 can cream of mushroom soup</li>
      <li>2 cups shredded chicken</li>
    </ul>
    <ol class="instructions">
      <li>Mix everything in a casserole dish.</li>
      <li>Bake at 375 for 30 minutes.</li>
    </ol>
    </body></html>
    """

    /// A two-component pasted caption where the SECOND component appears after the first
    /// component's steps — the step-region break silently discards it today.
    private let twoComponentCaption = """
    Carbonara Night

    Ingredients:
    200g spaghetti
    2 eggs

    Steps:
    1. Boil the spaghetti.
    2. Whisk the eggs with cheese.

    Ingredients for the sauce:
    100g guanciale

    Steps:
    1. Crisp the guanciale.
    """

    // MARK: - Schema.org JSON-LD

    func testTidyJSONLDPageParsesCompletelyAtHighConfidence() async {
        let r = await ExtractionPipeline().extractFromHTML(html: jsonldFull)
        XCTAssertEqual(r.title, "Lemon Butter Pasta")
        XCTAssertEqual(r.ingredients.count, 4)
        XCTAssertEqual(r.steps.count, 3)
        XCTAssertEqual(r.recipeYield, "4 servings")
        XCTAssertEqual(r.prepTime, 600)
        XCTAssertEqual(r.cookTime, 900)
        XCTAssertEqual(r.confidence, 0.9, accuracy: 0.001)
        XCTAssertTrue(r.extractionMethod.contains("schema"), "method was \(r.extractionMethod)")
    }

    func testGraphWrappedRecipeIsFound() async {
        let r = await ExtractionPipeline().extractFromHTML(html: jsonldGraph)
        XCTAssertEqual(r.title, "Graph Wrapped Soup")
        XCTAssertEqual(r.ingredients.count, 3)
        XCTAssertEqual(r.steps.count, 2)
        XCTAssertEqual(r.confidence, 0.9, accuracy: 0.001)
    }

    func testHowToSectionNamesAreCapturedOntoSteps() async {
        let r = await ExtractionPipeline().extractFromHTML(html: jsonldSections)
        XCTAssertEqual(r.steps.map(\.text),
                       ["Season the steak generously.", "Sear 4 minutes per side.",
                        "Blend parsley, garlic, and oil."])
        XCTAssertEqual(r.steps.map(\.order), [1, 2, 3])
        // The HowToSection "name" fields now ride onto each child step, so multi-part web
        // recipes get the same part tabs and sequencing that social recipes get.
        XCTAssertEqual(r.steps.map(\.section), ["Steak", "Steak", "Chimichurri"])
    }

    func testIngredientGroupHeadersBecomeSectionsAndAreNotIngredients() async {
        let html = """
        <html><head>
        <script type="application/ld+json">
        {"@context":"https://schema.org","@type":"Recipe","name":"Layered Dip",
         "recipeIngredient":["For the base:","1 can refried beans","1 cup sour cream",
                             "For the topping:","1 cup cheese","2 tbsp salsa"],
         "recipeInstructions":[{"@type":"HowToStep","text":"Spread the base."},
                               {"@type":"HowToStep","text":"Add the topping."}]}
        </script></head></html>
        """
        let r = await ExtractionPipeline().extractFromHTML(html: html)
        // The two "For the …:" lines are headings, not ingredients — dropped from the list,
        // applied as sections to what follows.
        XCTAssertEqual(r.ingredients.map(\.text),
                       ["1 can refried beans", "1 cup sour cream", "1 cup cheese", "2 tbsp salsa"])
        XCTAssertEqual(r.ingredients.map(\.section),
                       ["For the base", "For the base", "For the topping", "For the topping"])
    }

    func testWebComponentSequencingLeadsWithSlowestPart() {
        // The web path now runs ComponentSequencer: a dough that rests+bakes 30 min should
        // lead a filling that cooks 5, even when authored second.
        var r = ExtractionResult(extractionMethod: "schema-org-jsonld")
        r.title = "Tart"
        r.ingredients = [RawIngredient(text: "1 cup flour", section: "Crust")]
        r.steps = [
            RawStep(order: 1, text: "Cook the filling 5 minutes.", section: "Filling"),
            RawStep(order: 2, text: "Rest the dough 20 minutes then bake 20 minutes.", section: "Crust"),
        ]
        let out = ExtractionPipeline.applyComponentSequencing(to: r)
        XCTAssertEqual(out.steps.first?.section, "Crust", "slowest component leads")
    }

    func testSingleStringInstructionsSplitIntoAtomicSteps() async {
        let r = await ExtractionPipeline().extractFromHTML(html: jsonldSingleString)
        // A one-string instruction blob is now split on sentence boundaries so Cook Mode
        // shows discrete steps instead of a wall of text.
        XCTAssertEqual(r.steps.map(\.text),
                       ["Mix the dry ingredients.", "Beat in the eggs.",
                        "Bake at 350 for 25 minutes."])
        XCTAssertEqual(r.confidence, 0.9, accuracy: 0.001,
                       "3 ingredients + 3 steps now reaches the full tier")
    }

    func testBlobSplitDoesNotBreakOnDecimalsOrNumbering() {
        XCTAssertEqual(
            SchemaOrgExtractor.splitInstructionBlob("Add 1.5 cups flour and stir well."),
            ["Add 1.5 cups flour and stir well."], "a decimal is not a sentence boundary")
        XCTAssertEqual(
            SchemaOrgExtractor.splitInstructionBlob("1. Preheat the oven. 2. Grease the pan."),
            ["Preheat the oven.", "Grease the pan."], "leading numbering is stripped")
    }

    func testJSONLDWithTrailingCommaStillParses() async {
        let html = """
        <html><head>
        <script type="application/ld+json">
        {"@context":"https://schema.org","@type":"Recipe","name":"Comma Cookies",
         "recipeIngredient":["1 cup flour","2 eggs","1 cup sugar",],
         "recipeInstructions":[{"@type":"HowToStep","text":"Mix."},
                               {"@type":"HowToStep","text":"Bake."},]}
        </script></head></html>
        """
        let r = await ExtractionPipeline().extractFromHTML(html: html)
        XCTAssertEqual(r.title, "Comma Cookies")
        XCTAssertEqual(r.ingredients.count, 3)
        XCTAssertEqual(r.steps.count, 2)
    }

    func testProtocolRelativeImageResolvesToHTTPS() {
        XCTAssertEqual(SchemaOrgExtractor.normalizedImageURL("//cdn.example.com/x.jpg"),
                       "https://cdn.example.com/x.jpg")
        XCTAssertEqual(SchemaOrgExtractor.normalizedImageURL("https://a.com/y.jpg"),
                       "https://a.com/y.jpg")
        XCTAssertNil(SchemaOrgExtractor.normalizedImageURL(""))
    }

    // MARK: - Layer merging

    func testRecipeSplitAcrossLayersIsAssembledAtFullConfidence() async {
        let r = await ExtractionPipeline().extractFromHTML(html: splitAcrossLayers)
        // JSON-LD has title + 3 ingredients, microdata has title + 2 steps. Confidence used
        // to be computed before merge() and never revisited, so the assembled full recipe
        // scored 0.2 and came back with NO steps. Now the merged layer is rescored with its
        // own tier formula and the complete recipe wins.
        XCTAssertEqual(r.confidence, 0.9, accuracy: 0.001)
        XCTAssertEqual(r.steps.count, 2, "steps were \(r.steps.map(\.text))")
        XCTAssertEqual(r.ingredients.count, 3)
        XCTAssertEqual(r.title, "Split Souffle")
    }

    func testRescueGateIncludesExactlyTheRejectBoundary() {
        // HeuristicExtractor's weak tier scores exactly `reject` (0.5); a strict `<` made
        // the web LLM rescue unreachable for precisely the marginal pages it exists for.
        XCTAssertTrue(ConfidenceThreshold.needsRescue(0.5))
        XCTAssertTrue(ConfidenceThreshold.needsRescue(0.2))
        XCTAssertFalse(ConfidenceThreshold.needsRescue(0.51))
        XCTAssertFalse(ConfidenceThreshold.needsRescue(0.8))
    }

    func testMicrodataOnlyPageParsesAtHighConfidence() async {
        let r = await ExtractionPipeline().extractFromHTML(html: microdataOnly)
        XCTAssertEqual(r.title, "Microdata Chili")
        XCTAssertEqual(r.ingredients.count, 3)
        XCTAssertEqual(r.steps.count, 2)
        XCTAssertEqual(r.confidence, 0.9, accuracy: 0.001)
    }

    func testHeuristicBlogPageParsesFromClassFragments() async {
        let r = await ExtractionPipeline().extractFromHTML(html: heuristicBlog)
        XCTAssertEqual(r.ingredients.count, 3)
        XCTAssertEqual(r.steps.count, 2)
        XCTAssertEqual(r.confidence, 0.8, accuracy: 0.001,
                       "class-fragment matches land in the heuristic strong tier")
    }

    // MARK: - Pasted text

    func testSecondComponentAfterStepsIsRecovered() {
        let r = PastedTextExtractor().extract(text: twoComponentCaption)
        // The sauce component (its ingredient AND its step) is now recovered and tagged with
        // a section, instead of vanishing when the step region hit the second header.
        let allText = (r.ingredients.map(\.text) + r.steps.map(\.text)).joined(separator: " ")
        XCTAssertTrue(allText.localizedCaseInsensitiveContains("guanciale"),
                      "the sauce component must be recovered, not discarded")
        XCTAssertEqual(r.ingredients.first(where: { $0.text.localizedCaseInsensitiveContains("guanciale") })?.section,
                       "sauce")
        XCTAssertTrue(r.steps.contains { $0.text.localizedCaseInsensitiveContains("crisp") },
                      "the sauce's step is recovered too")
    }

    // MARK: - Noise filtering

    func testLongInstructionOpeningWithNarrativePhraseSurvives() {
        // Narrative openers used to condemn lines of ANY length; the maxCTAWords cap now
        // covers them too, so a 16-word real instruction opening with "when you" survives.
        let line = "When you flip the pancake wait for bubbles to form across the surface before turning it"
        XCTAssertFalse(SocialTextFilter.isNoiseLine(line))
        // Short narrative lines are still condemned.
        XCTAssertTrue(SocialTextFilter.isNoiseLine("When you need a last-minute app"))
    }

    func testCulinaryDropASurvivesAsInstruction() {
        // "drop a " used to be an unconditional CTA prefix that deleted real serving
        // instructions; it now checks WHAT is being dropped.
        XCTAssertFalse(SocialTextFilter.isNoiseLine("Drop a dollop of sour cream on top"))
        XCTAssertFalse(SocialTextFilter.isNoiseLine("Drop a spoonful of batter per pancake"))
    }

    func testEngagementDropAStaysCondemned() {
        // The narrowed "drop a " must still catch actual engagement bait.
        XCTAssertTrue(SocialTextFilter.isNoiseLine("Drop a comment below if you try it"))
        XCTAssertTrue(SocialTextFilter.isNoiseLine("drop a like if you want part 2"))
        XCTAssertTrue(SocialTextFilter.isNoiseLine("Drop a 🔥 if you'd make this"))
        XCTAssertTrue(SocialTextFilter.isNoiseLine("Drop a comment, and I'll DM the recipe"))
    }

    // MARK: - LLM input-substance gate (invariant I5)

    func testTruncatedHookIsNotWorthStructuring() {
        // The exact live failure: a cut-off og-preview that the model padded into a
        // fabricated no-quantity recipe. Too short, no digits, no structure.
        XCTAssertFalse(ExtractionPipeline.captionWorthStructuring(
            "I promise you these are so easy to make, S..."))
        XCTAssertFalse(ExtractionPipeline.captionWorthStructuring("Miso chicken bowls!"))
        XCTAssertFalse(ExtractionPipeline.captionWorthStructuring(""))
    }

    func testRealCaptionsAreWorthStructuring() {
        // Quantities present → worth a call even as a single paragraph.
        XCTAssertTrue(ExtractionPipeline.captionWorthStructuring(
            "Miso chicken bowls! Marinate 2 lbs chicken thighs in 3 tbsp miso overnight, then grill and serve over rice."))
        // No digits, but long multi-line structure (a dictated-style recipe) → worth a call.
        XCTAssertTrue(ExtractionPipeline.captionWorthStructuring(
            "Miso chicken bowls\nMarinate the chicken in miso paste\nGrill until charred\nServe over rice with avocado\nTop with sesame"))
    }

    func testLongNarrativeWithoutStructureIsNotWorthStructuring() {
        // Long but one line and zero digits: marketing prose, not a recipe.
        let hook = String(repeating: "This is the coziest bowl you will ever make and you have to try it ", count: 3)
        XCTAssertFalse(ExtractionPipeline.captionWorthStructuring(hook))
    }

    // MARK: - OCR wrap merging (marker-styled lists)

    func testWrappedBulletedIngredientsAndNumberedStepsMerge() {
        // The exact slide shape from a live TikTok photo post: bulleted ingredient sections
        // ("For Dish Base" style), then an ordered list under "Instructions:". OCR breaks a
        // long item onto a second, unmarked line — which must rejoin its item, not become a
        // new ingredient or step.
        let text = """
        Creamy Tomato Bowl

        For Dish Base
        • 2 cups cherry tomatoes,
        halved and lightly salted
        • 1 cup orzo

        For Topping/Serving
        • fresh basil

        Instructions:
        1. Roast the tomatoes until
        they burst.
        2. Stir in the orzo.
        """
        let r = PastedTextExtractor().extract(text: text)
        XCTAssertEqual(r.title, "Creamy Tomato Bowl")
        // Note: the comma after "tomatoes" is gone — line-level cleaning strips trailing
        // separators (the "Serve warm ·" dangler rule) before the wrap merge rejoins the
        // fragment. Harmless: the item reads correctly and parses to the same quantity/item.
        XCTAssertEqual(r.ingredients.map(\.text),
                       ["2 cups cherry tomatoes halved and lightly salted",
                        "1 cup orzo", "fresh basil"])
        XCTAssertEqual(r.ingredients.map(\.section),
                       ["For Dish Base", "For Dish Base", "For Topping/Serving"])
        XCTAssertEqual(r.steps.map(\.text),
                       ["Roast the tomatoes until they burst.", "Stir in the orzo."])
    }

    func testUnmarkedListsKeepLinePerItem() {
        // Plain caption lists carry no bullets — every line is its own item, unchanged.
        let text = """
        Simple Salad

        Ingredients:
        2 cups spinach
        1 avocado
        juice of 1 lemon

        Steps:
        Toss everything together.
        Season and serve.
        """
        let r = PastedTextExtractor().extract(text: text)
        XCTAssertEqual(r.ingredients.count, 3)
        XCTAssertEqual(r.steps.count, 2)
    }

    // MARK: - Two-column OCR assembly

    /// Vision-normalized box: origin bottom-left, so higher on the page = larger y.
    private func box(x: CGFloat, y: CGFloat, w: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: 0.04)
    }

    func testTwoColumnSlideReadsColumnByColumn() {
        // Ingredients left, method right — a plain row sort interleaves L1 R1 L2 R2…
        var lines: [(box: CGRect, text: String)] = []
        for (i, t) in ["1 cup flour", "2 eggs", "1 tsp salt", "1 cup milk"].enumerated() {
            lines.append((box(x: 0.05, y: 0.8 - CGFloat(i) * 0.1, w: 0.40), t))
        }
        for (i, t) in ["Method", "Whisk the eggs", "Fold in flour", "Rest the batter"].enumerated() {
            lines.append((box(x: 0.55, y: 0.8 - CGFloat(i) * 0.1, w: 0.40), t))
        }
        let out = ImageTextRecognizer.assembleLines(lines.shuffled())
        XCTAssertEqual(out,
                       "1 cup flour\n2 eggs\n1 tsp salt\n1 cup milk\n\n"
                       + "Method\nWhisk the eggs\nFold in flour\nRest the batter")
        XCTAssertFalse(out.hasPrefix("1 cup flour\nMethod"), "columns must not interleave")
    }

    func testSpanningTitleSitsAboveTheColumns() {
        var lines: [(box: CGRect, text: String)] = [(box(x: 0.1, y: 0.95, w: 0.8), "PANCAKES")]
        for (i, t) in ["1 cup flour", "2 eggs", "1 tsp salt"].enumerated() {
            lines.append((box(x: 0.05, y: 0.8 - CGFloat(i) * 0.1, w: 0.40), t))
        }
        for (i, t) in ["Whisk the eggs", "Fold in flour", "Cook until golden"].enumerated() {
            lines.append((box(x: 0.55, y: 0.8 - CGFloat(i) * 0.1, w: 0.40), t))
        }
        let out = ImageTextRecognizer.assembleLines(lines)
        XCTAssertTrue(out.hasPrefix("PANCAKES\n\n1 cup flour"),
                      "the full-width title leads, then the left column: \(out)")
    }

    func testSingleColumnSlideKeepsPlainRowOrder() {
        let lines: [(box: CGRect, text: String)] = (0..<8).map { i in
            (box(x: 0.1, y: 0.9 - CGFloat(i) * 0.1, w: 0.5), "line\(i)")
        }
        XCTAssertEqual(ImageTextRecognizer.assembleLines(lines),
                       (0..<8).map { "line\($0)" }.joined(separator: "\n"),
                       "no gutter → behavior unchanged")
    }

    // MARK: - Instagram logged-out sidecar (embed gql_data)

    func testSidecarImageURLsFromGQLData() throws {
        let json = """
        {"shortcode_media":{"edge_sidecar_to_children":{"edges":[
          {"node":{"display_url":"https://cdn.ig/small1.jpg",
                   "display_resources":[
                     {"src":"https://cdn.ig/1-640.jpg","config_width":640,"config_height":800},
                     {"src":"https://cdn.ig/1-1080.jpg","config_width":1080,"config_height":1350}]}},
          {"node":{"display_url":"https://cdn.ig/2-display.jpg"}}
        ]}}}
        """
        let gql = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let urls = InstagramAuth.sidecarImageURLs(fromGQLData: gql)
        XCTAssertEqual(urls.map(\.absoluteString),
                       ["https://cdn.ig/1-1080.jpg", "https://cdn.ig/2-display.jpg"],
                       "largest display_resources entry wins; display_url is the fallback")
    }

    func testSidecarEmptyForNonCarouselGQL() throws {
        let gql = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(#"{"shortcode_media":{"id":"1"}}"#.utf8)) as? [String: Any])
        XCTAssertTrue(InstagramAuth.sidecarImageURLs(fromGQLData: gql).isEmpty)
    }

    // MARK: - Carousel recipe collections

    func testCarouselWithSeveralSelfContainedRecipesIsACollection() {
        // The real shape: hook slide, then each recipe complete on its own slide
        // (food-photo slides never reach detection — the OCR triage drops them).
        let slides = [
            "my 3 favorite fall soups, save these!",
            "Roasted Tomato Soup\n\nIngredients:\n2 lbs tomatoes\n1 onion\n\nSteps:\n1. Roast the tomatoes.\n2. Blend until smooth.",
            "Lentil Soup\n\nIngredients:\n1 cup lentils\n4 cups stock\n\nSteps:\n1. Simmer for 25 minutes.",
        ]
        let recipes = ExtractionPipeline.collectionResults(fromSlideTexts: slides)
        XCTAssertEqual(recipes?.count, 2)
        XCTAssertEqual(recipes?.first?.title, "Roasted Tomato Soup")
        XCTAssertEqual(recipes?.last?.title, "Lentil Soup")
        XCTAssertEqual(recipes?.first?.ingredients.count, 2)
        XCTAssertEqual(recipes?.first?.steps.count, 2)
    }

    func testOneRecipeSpreadAcrossSlidesIsNotACollection() {
        // Ingredients on one slide, method on the next: no slide is viable alone, so this
        // correctly stays on the join-and-parse path instead of shredding one recipe in two.
        let slides = [
            "Cozy Miso Ramen",
            "Ingredients:\n2 packs ramen\n4 cups broth\n2 tbsp miso",
            "Steps:\n1. Whisk miso into the broth.\n2. Add the noodles.",
        ]
        XCTAssertNil(ExtractionPipeline.collectionResults(fromSlideTexts: slides))
    }

    func testSingleSlideIsNeverACollection() {
        let slide = "Toast\n\nIngredients:\n2 slices bread\n\nSteps:\n1. Toast the bread."
        XCTAssertNil(ExtractionPipeline.collectionResults(fromSlideTexts: [slide]))
        XCTAssertNil(ExtractionPipeline.collectionResults(fromSlideTexts: []))
    }

    // MARK: - DM-funnel detection (think-tank branch 13)

    func testDMFunnelCaptionsAreDetected() {
        XCTAssertTrue(CaptionAnalyzer.isDMFunnel("Comment RECIPE and I'll DM you the full thing!"))
        XCTAssertTrue(CaptionAnalyzer.isDMFunnel("DM me for the recipe 💌"))
        XCTAssertTrue(CaptionAnalyzer.isDMFunnel("Comment 'pasta' and I'll send it over"))
        XCTAssertTrue(CaptionAnalyzer.isDMFunnel("I'll send you the recipe if you comment below"))
    }

    func testOrdinaryCaptionsAreNotDMFunnels() {
        XCTAssertFalse(CaptionAnalyzer.isDMFunnel("Add the garlic and cook for 5 minutes."))
        XCTAssertFalse(CaptionAnalyzer.isDMFunnel("Comment below and let me know how it turned out!"))
        XCTAssertFalse(CaptionAnalyzer.isDMFunnel(""))
    }

    // MARK: - Source-aware sanitize + numeric grounding (think-tank branch 11)

    func testWebResultKeepsPhraseOpeningInstruction() {
        var r = ExtractionResult(extractionMethod: "heuristic-html")
        r.producedBy = .web
        r.title = "Steak"
        r.ingredients = [RawIngredient(text: "1 lb steak")]
        r.steps = [RawStep(order: 1, text: "When you're ready to serve, slice against the grain.")]
        let out = SocialTextFilter.sanitize(r)
        XCTAssertEqual(out.steps.first?.text, "When you're ready to serve, slice against the grain.",
                       "a web instruction opening with a phrase must survive (invariant I2)")
    }

    func testSocialResultStillDropsCTAStep() {
        var r = ExtractionResult(extractionMethod: "pasted-text")   // default .social
        r.title = "Steak"
        r.ingredients = [RawIngredient(text: "1 lb steak")]
        r.steps = [RawStep(order: 1, text: "Sear the steak."),
                   RawStep(order: 2, text: "Follow for more easy recipes")]
        let out = SocialTextFilter.sanitize(r)
        XCTAssertEqual(out.steps.map(\.text), ["Sear the steak."], "social CTA is still filtered")
    }

    func testWebSanitizeStillStripsTrailingTags() {
        var r = ExtractionResult(extractionMethod: "heuristic-html")
        r.producedBy = .web
        r.title = "X"
        r.ingredients = [RawIngredient(text: "2 eggs")]
        r.steps = [RawStep(order: 1, text: "Bake 20 minutes #easy #dinner")]
        let out = SocialTextFilter.sanitize(r)
        XCTAssertEqual(out.steps.first?.text, "Bake 20 minutes", "tag stripping runs for every source")
    }

    func testNumericGroundingDropsFabricatedQuantities() {
        let caption = "Toast 2 slices of bread. Bake at 350."
        let json = #"{"title":"Toast","ingredients":[{"text":"2 slices bread"},{"text":"1 cup sugar"}],"steps":["Toast it."]}"#
        let r = LLMCaptionStructurer.recipe(fromModelText: json, groundedIn: caption)
        XCTAssertEqual(r?.ingredients.map(\.text), ["2 slices bread"],
                       "'1 cup sugar' — a quantity the caption never had — is dropped")
    }

    func testNumericGroundingKeepsGroundedAndNumberFreeItems() {
        let caption = "Add 2 cups flour and a pinch of salt."
        let json = #"{"title":"Dough","ingredients":[{"text":"2 cups flour"},{"text":"salt to taste"}],"steps":["Mix."]}"#
        let r = LLMCaptionStructurer.recipe(fromModelText: json, groundedIn: caption)
        XCTAssertEqual(r?.ingredients.count, 2, "grounded number and number-free item both kept")
    }

    // MARK: - Truncation honesty (think-tank branch 10)

    func testEntityDecoderHandlesEllipsisForms() {
        XCTAssertEqual(HTMLEntities.decode("Bake until golden&hellip;"), "Bake until golden…")
        XCTAssertEqual(HTMLEntities.decode("Bake&#8230;"), "Bake…")
        XCTAssertEqual(HTMLEntities.decode("Bake&#x2026;"), "Bake…")
        XCTAssertEqual(HTMLEntities.decode("salt &amp; pepper"), "salt & pepper")
    }

    func testTruncationDetectedThroughEngagementPrefixAndEntities() {
        // og:description wraps the caption in quotes and HTML-encodes the ellipsis; the
        // detector must strip the preamble and decode before it can see the "…".
        let caption = #"69K likes, 417 comments - chef on July 3: "Best pasta. Add the garlic, then&hellip;""#
        XCTAssertTrue(TruncationDetector.isLikelyTruncated(caption))
        XCTAssertTrue(TruncationDetector.isLikelyTruncated("Step one. Step two..."))
    }

    func testCompleteCaptionIsNotFlaggedTruncated() {
        XCTAssertFalse(TruncationDetector.isLikelyTruncated("Mix, then bake at 350 for 20 minutes."))
        XCTAssertFalse(TruncationDetector.isLikelyTruncated(""))
    }

    // MARK: - Plain-web text pass (think-tank branch 8)

    func testDOMTextExtractorPreservesLineBreaks() {
        let html = """
        <html><body><article>
        <h1>Title</h1>
        <p>1 cup flour<br>2 eggs<br>1 tsp salt</p>
        <p>Mix everything.</p>
        <p>Bake at 350.</p>
        </article></body></html>
        """
        let text = DOMTextExtractor.extractText(html: html)
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertTrue(lines.contains("1 cup flour"), "a <br> is a line break")
        XCTAssertTrue(lines.contains("2 eggs"))
        XCTAssertTrue(lines.contains("Mix everything."))
        XCTAssertTrue(lines.contains("Bake at 350."))
    }

    func testParagraphBlogParsesViaTextPassWithThumbnail() async {
        // No JSON-LD, no microdata, no recipe-plugin classes — the layers 1–3 find nothing,
        // but the block-preserved text pass parses it and carries the og:image through.
        let html = """
        <html><head><title>Aunt May's Cornbread</title>
        <meta property="og:image" content="https://blog.example.com/cornbread.jpg"></head>
        <body><article>
        <h1>Aunt May's Cornbread</h1>
        <p>Ingredients:</p>
        <p>1 cup cornmeal<br>1 cup flour<br>2 eggs<br>1 cup milk</p>
        <p>Instructions:</p>
        <p>Mix the dry ingredients.<br>Whisk in the eggs and milk.<br>Bake at 400 for 20 minutes.</p>
        </article></body></html>
        """
        let r = await ExtractionPipeline().extractFromHTML(html: html)
        XCTAssertTrue(r.isViable, "paragraph blog should parse without the LLM")
        XCTAssertEqual(r.ingredients.count, 4)
        XCTAssertEqual(r.steps.count, 3)
        XCTAssertEqual(r.thumbnailURL, "https://blog.example.com/cornbread.jpg",
                       "og:image survives the text-pass merge")
    }

    // MARK: - Structurer skip-gate (think-tank branch 3)

    /// The modal clean recipe post: unique headers, quantity-led ingredients, no mess.
    private let cleanCaption = """
    Garlic Butter Shrimp

    Ingredients:
    1 lb shrimp
    4 tbsp butter
    4 cloves garlic

    Steps:
    1. Melt the butter with the garlic.
    2. Cook the shrimp until pink.
    """

    func testCleanCaptionSkipsTheStructurer() {
        let (r, audit) = PastedTextExtractor().extractWithAudit(text: cleanCaption)
        XCTAssertGreaterThanOrEqual(r.confidence, ConfidenceThreshold.accept)
        XCTAssertEqual(audit.ingredientHeaderCount, 1)
        XCTAssertEqual(audit.stepHeaderCount, 1)
        XCTAssertEqual(audit.linesDiscardedAfterSteps, 0)
        XCTAssertTrue(ExtractionPipeline.shouldSkipStructurer(
            deterministic: r, audit: audit, caption: cleanCaption))
    }

    func testMultiComponentCaptionStillCallsTheStructurer() {
        // Two ingredient headers + a silently discarded second component: exactly the
        // caption shape the deterministic parser mishandles, so tokens are worth spending.
        let (r, audit) = PastedTextExtractor().extractWithAudit(text: twoComponentCaption)
        XCTAssertEqual(audit.ingredientHeaderCount, 2)
        XCTAssertGreaterThan(audit.linesDiscardedAfterSteps, 0)
        XCTAssertFalse(ExtractionPipeline.shouldSkipStructurer(
            deterministic: r, audit: audit, caption: twoComponentCaption))
    }

    func testHeaderlessCaptionStillCallsTheStructurer() {
        let caption = """
        Best pasta ever

        200g spaghetti
        2 tbsp butter
        1 cup parmesan
        Boil the pasta until al dente.
        Toss with butter and cheese.
        """
        let (r, audit) = PastedTextExtractor().extractWithAudit(text: caption)
        XCTAssertFalse(audit.usedExplicitHeaders)
        XCTAssertFalse(ExtractionPipeline.shouldSkipStructurer(
            deterministic: r, audit: audit, caption: caption))
    }

    func testTruncatedCaptionStillCallsTheStructurer() {
        // An og:description cut mid-recipe ends in an ellipsis — the raw caption handed to
        // the structurer may hold more than the preview the deterministic parser saw.
        let truncated = cleanCaption + "…"
        let (r, audit) = PastedTextExtractor().extractWithAudit(text: truncated)
        XCTAssertFalse(ExtractionPipeline.shouldSkipStructurer(
            deterministic: r, audit: audit, caption: truncated))
    }

    func testUnquantifiedIngredientListStillCallsTheStructurer() {
        // Headers are right but no ingredient carries a quantity — the "list" may really be
        // narrative or a bare shopping list, which the structurer sorts out better.
        let caption = """
        Pantry Pasta

        Ingredients:
        spaghetti
        butter
        parmesan cheese

        Steps:
        1. Boil the pasta.
        2. Toss with butter and cheese.
        """
        let (r, audit) = PastedTextExtractor().extractWithAudit(text: caption)
        XCTAssertFalse(ExtractionPipeline.shouldSkipStructurer(
            deterministic: r, audit: audit, caption: caption))
    }

    // MARK: - Ingredient parsing

    func testDanglingDashRecoversTheNumberNotGarbage() {
        // "1-" used to become the unscalable quantity string "1-". The range grammar now
        // recovers the leading number and drops the dangling dash: a clean "1 cup sugar".
        let p = IngredientParser().parse(raw: "1- cup sugar")
        XCTAssertEqual(p.quantity, "1")
        XCTAssertNotEqual(p.quantity, "1-", "the unscalable garbage form must never return")
        XCTAssertEqual(p.unit, "cup")
        XCTAssertEqual(p.item, "sugar")
    }

    func testRealRangesStillParse() {
        XCTAssertEqual(IngredientParser().parse(raw: "2-3 cloves garlic").quantity, "2-3")
        XCTAssertEqual(IngredientParser().parse(raw: "2–3 cloves garlic").quantity, "2-3",
                       "en dash normalizes to ASCII")
    }

    // MARK: - Creator comments ("recipe in the comments" rung)

    func testCreatorCommentFilterKeepsOnlyOwnerTexts() {
        // pks arrive as Int on some routes and String on others — both must compare equal
        // to the owner. Other users' comments (including recipe-looking ones) are dropped,
        // as are blank creator comments.
        let comments: [[String: Any]] = [
            ["user": ["pk": 123], "text": "INGREDIENTS:\n1 cup flour\n1 cup greek yogurt"],
            ["user": ["pk": "456"], "text": "Ingredients: 2 cups sugar (not the creator!)"],
            ["user": ["pk": "123"], "text": "Bake at 350F for 20 minutes."],
            ["user": ["pk": 123], "text": "   "],
            ["text": "no user field"],
        ]
        XCTAssertEqual(
            InstagramAuth.creatorCommentTexts(fromComments: comments, ownerPK: "123"),
            ["INGREDIENTS:\n1 cup flour\n1 cup greek yogurt", "Bake at 350F for 20 minutes."]
        )
    }

    func testPKStringNormalizesNumbersAndStrings() {
        XCTAssertEqual(InstagramAuth.pkString(123), "123")
        XCTAssertEqual(InstagramAuth.pkString("123"), "123")
        XCTAssertEqual(InstagramAuth.pkString(NSNumber(value: Int64(9_007_199_254_740_995))),
                       "9007199254740995", "64-bit pks must not round-trip through Double")
        XCTAssertNil(InstagramAuth.pkString(nil))
        XCTAssertNil(InstagramAuth.pkString(""))
    }
}
