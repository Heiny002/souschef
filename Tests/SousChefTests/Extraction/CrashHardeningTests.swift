import XCTest
@testable import SousChef

/// Tier-1 crash & input-hardening fixes from the audit:
/// - C5: extractJSON off-by-one on bare JSON,
/// - H9: IngredientAnnotator UTF-16 crash + stale-offset garbling,
/// - SSRF: WebPageFetcher scheme/host validation.
final class CrashHardeningTests: XCTestCase {

    // MARK: - C5: JSON object extraction

    func testExtractBareJSONObjectDoesNotCrash() {
        // The response ends exactly with "}" — the format both prompts request. The old
        // closed range `...end.upperBound` trapped here.
        XCTAssertEqual(JSONResponseParser.extractObject(from: "{\"title\":\"x\"}"), "{\"title\":\"x\"}")
    }

    func testExtractJSONStripsFencesAndProse() {
        XCTAssertEqual(JSONResponseParser.extractObject(from: "```json\n{\"a\":1}\n```"), "{\"a\":1}")
        XCTAssertEqual(JSONResponseParser.extractObject(from: "Here you go: {\"a\":1} — done"), "{\"a\":1}")
    }

    func testExtractJSONWithNoObjectReturnsInput() {
        XCTAssertEqual(JSONResponseParser.extractObject(from: "no json here"), "no json here")
        // Malformed "}{" ordering must not form an invalid range.
        XCTAssertEqual(JSONResponseParser.extractObject(from: "}{"), "}{")
    }

    // MARK: - H9: IngredientAnnotator

    private func ingredient(_ item: String, qty: String?, unit: String?) -> Ingredient {
        let ing = Ingredient(item: item, rawText: item, order: 0)
        ing.quantity = qty
        ing.unit = unit
        return ing
    }

    func testAnnotationPlacesMeasurementsCorrectly() {
        let out = IngredientAnnotator.annotate(
            ["Add the olive oil and garlic."],
            with: [ingredient("olive oil", qty: "2", unit: "tbsp"),
                   ingredient("garlic", qty: "1", unit: "clove")]
        )
        // Both measurements land immediately after their names, in order — no stale-offset
        // garbling like "olive oil (2 tbsp) a (1 clove)nd garlic".
        XCTAssertEqual(out.first, "Add the olive oil (2 tbsp) and garlic (1 clove).")
    }

    func testAnnotationWithEmojiDoesNotCrashOrMisplace() {
        // Emoji before the match: NSRange (UTF-16) offsets used to overshoot Character
        // indices and trap. Must place the measurement correctly and not crash.
        let out = IngredientAnnotator.annotate(
            ["🔥 Sear the beef until browned."],
            with: [ingredient("beef", qty: "500", unit: "g")]
        )
        XCTAssertEqual(out.first, "🔥 Sear the beef (500 g) until browned.")
    }

    func testAnnotationDoesNotDoubleCountNestedNames() {
        // "oil" must not annotate inside an already-matched "olive oil".
        let out = IngredientAnnotator.annotate(
            ["Warm the olive oil."],
            with: [ingredient("olive oil", qty: "2", unit: "tbsp"),
                   ingredient("oil", qty: "99", unit: "cups")]
        )
        XCTAssertEqual(out.first, "Warm the olive oil (2 tbsp).")
    }

    func testAnnotationMatchesHeadNounOfMultiWordItems() {
        // The flatbread reel that exposed this: steps shorten "self-raising flour" to
        // "flour" and "Greek yogurt" to "yogurt". Only "baking powder" — the one name the
        // step used verbatim — was annotated before head-noun matching existed.
        let out = IngredientAnnotator.annotate(
            ["Mix flour, yogurt, baking powder, and salt until you have a nice dough."],
            with: [ingredient("self-raising flour", qty: "1", unit: "cup"),
                   ingredient("greek yogurt", qty: "1", unit: "cup"),
                   ingredient("baking powder", qty: "1/2", unit: "tsp"),
                   ingredient("salt", qty: nil, unit: nil)]  // no amount → stays bare
        )
        XCTAssertEqual(out.first,
                       "Mix flour (1 cup), yogurt (1 cup), baking powder (1/2 tsp), "
                       + "and salt until you have a nice dough.")
    }

    func testAnnotationSkipsBulletedMentionsThatCarryTheirAmount() {
        // The steak step that exposed this: the parser's bulleted spice list already
        // carries each amount, and the annotator was appending it again —
        // "• 1/2 tbsp paprika (1/2 tbsp)". The sentence-level mentions (no amount
        // nearby) must still be annotated; "400F for 10 minutes" further along the
        // line must not suppress them.
        let out = IngredientAnnotator.annotate(
            ["Season steak with olive oil and spices, then air fry at 400F for 10 minutes.\n"
             + "• 1/2 tbsp paprika\n• 1/2 tbsp garlic powder"],
            with: [ingredient("garlic powder", qty: "1/2", unit: "tbsp"),
                   ingredient("olive oil", qty: "1", unit: "tsp"),
                   ingredient("paprika", qty: "1/2", unit: "tbsp"),
                   ingredient("steak", qty: "1.25", unit: "lb")]
        )
        XCTAssertEqual(out.first,
                       "Season steak (1.25 lb) with olive oil (1 tsp) and spices, "
                       + "then air fry at 400F for 10 minutes.\n"
                       + "• 1/2 tbsp paprika\n• 1/2 tbsp garlic powder")
    }

    func testAnnotationSkipsInlineMentionsThatCarryTheirAmount() {
        // "add 2 tbsp of soy sauce" already tells the cook the amount.
        let out = IngredientAnnotator.annotate(
            ["Add 2 tbsp of soy sauce and stir."],
            with: [ingredient("soy sauce", qty: "2", unit: "tbsp")]
        )
        XCTAssertEqual(out.first, "Add 2 tbsp of soy sauce and stir.")
    }

    func testAnnotationHeadNounRespectsShortWordGuard() {
        // "olive oil" must NOT gain an "oil" head-noun variant (≤3 chars) — a bare "oil"
        // mention could belong to a different fat entirely.
        let out = IngredientAnnotator.annotate(
            ["Rub with oil before grilling."],
            with: [ingredient("olive oil", qty: "2", unit: "tbsp")]
        )
        XCTAssertEqual(out.first, "Rub with oil before grilling.")
    }

    // MARK: - SSRF: WebPageFetcher.isAllowed

    private func allowed(_ s: String) -> Bool {
        guard let url = URL(string: s) else { return false }
        return WebPageFetcher.isAllowed(url)
    }

    func testAllowsPublicHTTPS() {
        XCTAssertTrue(allowed("https://www.seriouseats.com/recipe"))
        XCTAssertTrue(allowed("https://8.8.8.8/page"))
    }

    func testRejectsNonHTTPSAndInternalHosts() {
        XCTAssertFalse(allowed("http://www.seriouseats.com/recipe"), "cleartext http rejected")
        XCTAssertFalse(allowed("ftp://example.com/x"))
        XCTAssertFalse(allowed("https://localhost/x"))
        XCTAssertFalse(allowed("https://127.0.0.1:8000/search"))
        XCTAssertFalse(allowed("https://10.0.0.5/x"))
        XCTAssertFalse(allowed("https://192.168.1.1/x"))
        XCTAssertFalse(allowed("https://169.254.169.254/latest/meta-data"), "cloud metadata endpoint")
        XCTAssertFalse(allowed("https://router.internal/admin"))
        XCTAssertFalse(allowed("https://[::1]/x"))
        XCTAssertFalse(allowed("https://example.com:8443/x"), "non-standard port")
    }

    // MARK: - Fetch hardening (think-tank branch 15)

    func testHTTPUpgradedToHTTPS() {
        XCTAssertEqual(WebPageFetcher.upgradedToHTTPS("http://blog.example.com/recipe"),
                       "https://blog.example.com/recipe")
        XCTAssertEqual(WebPageFetcher.upgradedToHTTPS("http://blog.example.com:80/recipe"),
                       "https://blog.example.com/recipe", "explicit :80 is dropped")
        XCTAssertEqual(WebPageFetcher.upgradedToHTTPS("https://blog.example.com/recipe"),
                       "https://blog.example.com/recipe", "https unchanged")
    }

    func testChallengePageDetected() {
        XCTAssertTrue(WebPageFetcher.isChallengePage(
            "<html><head><title>Just a moment...</title></head><body>Checking your browser</body></html>"))
        XCTAssertTrue(WebPageFetcher.isChallengePage(
            "<html><body>Attention Required! | Cloudflare</body></html>"))
        XCTAssertFalse(WebPageFetcher.isChallengePage(
            "<html><body><h1>Grandma's Cornbread</h1><ul><li>1 cup cornmeal</li></ul></body></html>"))
    }
}
