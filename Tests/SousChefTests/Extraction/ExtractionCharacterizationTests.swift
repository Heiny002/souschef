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

    func testHowToSectionStepsAreFlattenedAndSectionNamesAreLost() async {
        let r = await ExtractionPipeline().extractFromHTML(html: jsonldSections)
        XCTAssertEqual(r.steps.map(\.text),
                       ["Season the steak generously.", "Sear 4 minutes per side.",
                        "Blend parsley, garlic, and oil."])
        XCTAssertEqual(r.steps.map(\.order), [1, 2, 3])
        // CHARACTERIZATION-BUG (web-sections branch): the HowToSection "name" fields —
        // "Steak", "Chimichurri" — are read past and dropped, so multi-part web recipes
        // never get the part tabs that social recipes get.
        XCTAssertTrue(r.steps.allSatisfy { $0.section == nil })
    }

    func testSingleStringInstructionsBecomeOneBlobStep() async {
        let r = await ExtractionPipeline().extractFromHTML(html: jsonldSingleString)
        // CHARACTERIZATION-BUG (schema-hardening branch): three sentences arrive as ONE step,
        // which Cook Mode then reads as a single wall of text.
        XCTAssertEqual(r.steps.count, 1)
        XCTAssertEqual(r.confidence, 0.6, accuracy: 0.001,
                       "3 ingredients + 1 step lands in the partial tier")
    }

    // MARK: - Layer merging

    func testRecipeSplitAcrossLayersIsReturnedIncomplete() async {
        let r = await ExtractionPipeline().extractFromHTML(html: splitAcrossLayers)
        // CHARACTERIZATION-BUG (p0-correctness): the page contains a complete recipe —
        // JSON-LD has title + 3 ingredients, microdata has title + 2 steps, and merge()
        // combines them — but confidence is computed BEFORE the merge and never revisited,
        // so every layer scores 0.2 and the pipeline returns the JSON-LD result with NO
        // STEPS even though it assembled the full recipe internally.
        XCTAssertEqual(r.confidence, 0.2, accuracy: 0.001)
        XCTAssertTrue(r.steps.isEmpty, "steps were \(r.steps.map(\.text))")
        XCTAssertEqual(r.ingredients.count, 3)
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

    func testSecondComponentAfterStepsIsSilentlyDiscarded() {
        let r = PastedTextExtractor().extract(text: twoComponentCaption)
        XCTAssertEqual(r.ingredients.map(\.text), ["200g spaghetti", "2 eggs"])
        XCTAssertEqual(r.steps.count, 2)
        // CHARACTERIZATION-BUG (paste-scan-depth branch): the step region stops at the next
        // ingredient header and everything after — the entire sauce component — vanishes
        // without a trace. The guanciale never reaches the recipe.
        let allText = (r.ingredients.map(\.text) + r.steps.map(\.text)).joined(separator: " ")
        XCTAssertFalse(allText.localizedCaseInsensitiveContains("guanciale"))
    }

    // MARK: - Noise filtering

    func testLongInstructionOpeningWithNarrativePhraseIsCondemned() {
        // CHARACTERIZATION-BUG (p0-correctness): CTA phrases only condemn lines up to
        // maxCTAWords, but narrative openers have no such cap — this 16-word real
        // instruction is deleted because it happens to open with "when you".
        let line = "When you flip the pancake wait for bubbles to form across the surface before turning it"
        XCTAssertTrue(SocialTextFilter.isNoiseLine(line))
    }

    func testCulinaryDropAIsCondemnedAsCTA() {
        // CHARACTERIZATION-BUG (p0-correctness): "drop a " is an unconditional CTA prefix,
        // so a real serving instruction is deleted alongside "drop a comment".
        XCTAssertTrue(SocialTextFilter.isNoiseLine("Drop a dollop of sour cream on top"))
    }

    func testEngagementDropAStaysCondemned() {
        // Correct today and must stay correct after the p0 fix narrows "drop a ".
        XCTAssertTrue(SocialTextFilter.isNoiseLine("Drop a comment below if you try it"))
        XCTAssertTrue(SocialTextFilter.isNoiseLine("drop a like if you want part 2"))
    }

    // MARK: - Ingredient parsing

    func testDanglingDashParsesAsGarbageQuantity() {
        // CHARACTERIZATION-BUG (p0-correctness): "1-" passes the numeric-range check because
        // the empty right-hand side vacuously satisfies allSatisfy, so the quantity becomes
        // the literal string "1-", which downstream Quantity.parse cannot scale.
        let p = IngredientParser().parse(raw: "1- cup sugar")
        XCTAssertEqual(p.quantity, "1-")
    }

    func testRealRangesStillParse() {
        XCTAssertEqual(IngredientParser().parse(raw: "2-3 cloves garlic").quantity, "2-3")
        XCTAssertEqual(IngredientParser().parse(raw: "2–3 cloves garlic").quantity, "2-3",
                       "en dash normalizes to ASCII")
    }
}
