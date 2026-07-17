import XCTest
@testable import SousChef

/// Extraction parser-correctness fixes from the audit: H10 (MicroStepSplitter),
/// H16 (Microdata times), H17 (title splitting), plus the duration / quantity /
/// entity / yield mediums.
final class ParserFixesTests: XCTestCase {

    // MARK: - H10: MicroStepSplitter must never drop or fabricate content

    func testSplitAbortsWhenAnyPartIsFiltered() {
        // "the softened butter cut into cubes" is >4 words. The old code dropped it and
        // split anyway — deleting the butter from the recipe. Now the split aborts.
        let input = "Add the flour, sugar, salt, and the softened butter cut into cubes."
        XCTAssertEqual(MicroStepSplitter.split(input), [input])
    }

    func testSplitAbortsOnTrailingVerbClause() {
        // Old behaviour fabricated "Add cook until fragrant." and "Add about 2 minutes."
        // (the latter even started a bogus timer) — all spoken aloud. The whole sentence
        // must come through intact instead.
        let input = "Add the onion, garlic, and cook until fragrant, about 2 minutes."
        XCTAssertEqual(MicroStepSplitter.split(input), [input])
    }

    func testCleanCompoundStillSplits() {
        let result = MicroStepSplitter.split("Dice the carrots, celery, and onion.")
        XCTAssertEqual(result, ["Dice the carrots.", "Dice celery.", "Dice onion."])
    }

    // MARK: - H16: Microdata times survive content-only markup

    func testMicrodataTimeFromContentAttribute() {
        // The very common markup: no datetime attribute, ISO duration in `content`.
        // SwiftSoup attr() returns "" not nil, so the old ?? chain returned "" and the
        // time was silently dropped.
        let html = """
        <div itemscope itemtype="https://schema.org/Recipe">
          <span itemprop="name">Test Bake</span>
          <time itemprop="prepTime" content="PT15M">15 minutes</time>
          <time itemprop="cookTime" content="PT1H30M">1 hr 30 min</time>
          <li itemprop="recipeIngredient">1 cup flour</li>
          <li itemprop="recipeInstructions">Mix and bake until golden brown.</li>
        </div>
        """
        let result = MicrodataExtractor().extract(html: html)
        XCTAssertEqual(result.prepTime, 15 * 60)
        XCTAssertEqual(result.cookTime, 90 * 60)
    }

    // MARK: - H17: hyphenated titles survive the site-name strip

    func testHyphenatedTitleNotTruncated() {
        let html = "<html><head><title>Bang-Bang Shrimp | Food Blog</title></head><body><p>x</p></body></html>"
        let result = HeuristicExtractor().extract(html: html)
        XCTAssertEqual(result.title, "Bang-Bang Shrimp")
    }

    func testSpacedHyphenSeparatorStillStripsSiteName() {
        let html = "<html><head><title>Slow-Cooker Beef Stew - MySite</title></head><body><p>x</p></body></html>"
        let result = HeuristicExtractor().extract(html: html)
        XCTAssertEqual(result.title, "Slow-Cooker Beef Stew")
    }

    // MARK: - ISO 8601 durations

    func testISODecimalComponents() {
        XCTAssertEqual(ISO8601DurationParser.seconds(from: "PT1.5H"), 5400)
        XCTAssertEqual(ISO8601DurationParser.seconds(from: "PT2.5M"), 150)
        XCTAssertEqual(ISO8601DurationParser.seconds(from: "PT1H30M"), 5400)
        XCTAssertNil(ISO8601DurationParser.seconds(from: "PT99999999H"), "absurd durations rejected")
    }

    // MARK: - Labeled prose durations (compound values)

    func testCompoundDurationNotTruncated() {
        XCTAssertEqual(DurationTextParser.seconds(in: "Total time: 1 hr 30 min", after: "total time"), 5400)
        XCTAssertEqual(DurationTextParser.seconds(in: "cook time 2 hours and 15 minutes", after: "cook time"), 8100)
        XCTAssertEqual(DurationTextParser.seconds(in: "Prep time: 20 minutes", after: "prep time"), 1200)
        XCTAssertEqual(DurationTextParser.seconds(in: "simmer for 1.5 hours", after: "simmer"), 5400)
        XCTAssertNil(DurationTextParser.seconds(in: "no times here", after: "prep time"))
    }

    // MARK: - En-dash quantity ranges

    func testEnDashRangeParsesLikeASCII() {
        let parser = IngredientParser()
        let ascii = parser.parse(raw: "2-3 cloves garlic")
        let enDash = parser.parse(raw: "2–3 cloves garlic")
        XCTAssertEqual(enDash.quantity, ascii.quantity)
        XCTAssertNotNil(enDash.quantity)
        XCTAssertEqual(enDash.item, ascii.item)
    }

    // MARK: - Schema.org: numeric yield, hex entities, explicit tools

    private func schemaHTML(_ json: String) -> String {
        "<html><head><script type=\"application/ld+json\">\(json)</script></head><body></body></html>"
    }

    func testNumericRecipeYield() {
        let json = """
        {"@type": "Recipe", "name": "Soup", "recipeYield": 4,
         "recipeIngredient": ["1 onion", "2 carrots", "1 leek"],
         "recipeInstructions": ["Chop everything.", "Simmer for 30 minutes."]}
        """
        let result = SchemaOrgExtractor().extract(html: schemaHTML(json))
        XCTAssertEqual(result.recipeYield, "4")
    }

    func testHexEntitiesDecoded() {
        let json = """
        {"@type": "Recipe", "name": "Mom&#x27;s Saut&#xe9;ed Greens",
         "recipeIngredient": ["1 bunch greens", "2 tbsp oil", "&#189; tsp salt"],
         "recipeInstructions": ["Cook the greens until wilted."]}
        """
        let result = SchemaOrgExtractor().extract(html: schemaHTML(json))
        XCTAssertEqual(result.title, "Mom's Sautéed Greens")
        XCTAssertEqual(result.ingredients.last?.text, "½ tsp salt")
    }

    func testExplicitToolsSurviveDetection() {
        let json = """
        {"@type": "Recipe", "name": "Candy",
         "tool": ["Candy thermometer", "Stand mixer"],
         "recipeIngredient": ["2 cups sugar", "1 cup cream", "1 tbsp butter"],
         "recipeInstructions": ["Boil the sugar.", "Beat until thick."]}
        """
        let result = SchemaOrgExtractor().extract(html: schemaHTML(json))
        XCTAssertTrue(result.appliances.contains("Candy thermometer"), "explicit tool lost: \(result.appliances)")
        XCTAssertTrue(result.appliances.contains("Stand mixer"), "explicit tool lost: \(result.appliances)")
    }

    // MARK: - Heuristic ingredients starting with a unicode fraction

    func testUnicodeFractionLeadingIngredientMatched() {
        let html = """
        <html><head><title>Cake - Site</title></head><body>
        <ul>
          <li>½ cup butter, softened</li>
          <li>2 cups flour</li>
          <li>¾ tsp salt</li>
          <li>1 cup sugar</li>
        </ul>
        </body></html>
        """
        let result = HeuristicExtractor().extract(html: html)
        XCTAssertTrue(
            result.ingredients.contains(where: { $0.text.hasPrefix("½ cup butter") }),
            "½-leading ingredient missed: \(result.ingredients.map(\.text))"
        )
    }
}
