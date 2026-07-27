import XCTest
@testable import SousChef

/// Search results become import targets, so the risky part is what we accept as a "recipe
/// page": a search-results URL or a homepage wastes the user's tap and fails extraction.
/// The network call can't run here, but the response parsing and URL filtering are pure.
final class PerplexitySearcherTests: XCTestCase {

    private func payload(content: String, citations: [String] = []) -> Data {
        let json: [String: Any] = [
            "choices": [["message": ["content": content]]],
            "citations": citations,
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    // MARK: Line parsing

    func testParsesPipeDelimitedResults() {
        let content = """
        Chicken Piccata | https://www.seriouseats.com/chicken-piccata | Lemony, capery, fast.
        Easy Piccata | https://cooking.nytimes.com/recipes/piccata | A weeknight version.
        """
        let results = PerplexitySearcher.parse(data: payload(content: content))
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.title, "Chicken Piccata")
        XCTAssertEqual(results.first?.url, "https://www.seriouseats.com/chicken-piccata")
        XCTAssertEqual(results.first?.summary, "Lemony, capery, fast.")
        XCTAssertEqual(results.first?.siteName, "seriouseats.com")
    }

    func testStripsNumberingAndMarkdownFromTitles() {
        let content = "1. **Chicken Piccata** | https://example.com/recipes/piccata | Good."
        let results = PerplexitySearcher.parse(data: payload(content: content))
        XCTAssertEqual(results.first?.title, "Chicken Piccata")
    }

    func testFallsBackToCitationsWhenFormatIgnored() {
        // The model sometimes answers in prose; the cited URLs are still real results.
        let results = PerplexitySearcher.parse(
            data: payload(content: "Here are some great recipes you might enjoy!",
                          citations: ["https://example.com/recipes/piccata",
                                      "https://food52.com/recipes/chicken"]))
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.url, "https://example.com/recipes/piccata")
    }

    func testDeduplicatesByURL() {
        let content = """
        Piccata | https://example.com/recipes/piccata | One.
        Piccata Again | https://example.com/recipes/piccata | Duplicate.
        """
        XCTAssertEqual(PerplexitySearcher.parse(data: payload(content: content)).count, 1)
    }

    func testRespectsLimit() {
        let content = (1...10).map {
            "Recipe \($0) | https://example.com/recipes/\($0) | Description."
        }.joined(separator: "\n")
        XCTAssertEqual(PerplexitySearcher.parse(data: payload(content: content), limit: 3).count, 3)
    }

    func testMalformedPayloadYieldsNoResults() {
        XCTAssertTrue(PerplexitySearcher.parse(data: Data("not json".utf8)).isEmpty)
        XCTAssertTrue(PerplexitySearcher.parse(data: payload(content: "")).isEmpty)
    }

    // MARK: URL filtering

    func testRejectsNonRecipePageURLs() {
        // Homepages, search pages and platforms the page extractor can't read.
        XCTAssertFalse(PerplexitySearcher.isUsableRecipeURL("https://www.allrecipes.com"))
        XCTAssertFalse(PerplexitySearcher.isUsableRecipeURL("https://www.google.com/search?q=piccata"))
        XCTAssertFalse(PerplexitySearcher.isUsableRecipeURL("https://www.pinterest.com/pin/123"))
        XCTAssertFalse(PerplexitySearcher.isUsableRecipeURL("https://www.instagram.com/reel/abc"))
        XCTAssertFalse(PerplexitySearcher.isUsableRecipeURL("http://example.com/recipe"), "http is rejected")
        XCTAssertFalse(PerplexitySearcher.isUsableRecipeURL("not a url"))
    }

    func testAcceptsRealRecipePages() {
        XCTAssertTrue(PerplexitySearcher.isUsableRecipeURL("https://www.seriouseats.com/chicken-piccata"))
        XCTAssertTrue(PerplexitySearcher.isUsableRecipeURL("https://cooking.nytimes.com/recipes/1234"))
    }

    func testBlockedURLsAreFilteredOutOfResults() {
        let content = """
        Good One | https://www.seriouseats.com/piccata | Real page.
        Pin | https://www.pinterest.com/pin/999 | Not extractable.
        """
        let results = PerplexitySearcher.parse(data: payload(content: content))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.siteName, "seriouseats.com")
    }
}
