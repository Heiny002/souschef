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
}
