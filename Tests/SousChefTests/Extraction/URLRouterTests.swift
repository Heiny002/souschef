import XCTest
@testable import SousChef

final class URLRouterTests: XCTestCase {

    // MARK: - TikTok

    func testTikTokMainDomain() {
        XCTAssertEqual(URLRouter.classify("https://www.tiktok.com/@user/video/123"), .tikTok)
    }

    func testTikTokShortLink() {
        XCTAssertEqual(URLRouter.classify("https://vm.tiktok.com/AbCdEfG/"), .tikTok)
    }

    func testTikTokMobileDomain() {
        XCTAssertEqual(URLRouter.classify("https://m.tiktok.com/@user/video/456"), .tikTok)
    }

    func testTikTokNaked() {
        XCTAssertEqual(URLRouter.classify("https://tiktok.com/@chef/video/789"), .tikTok)
    }

    // MARK: - Instagram

    func testInstagramReel() {
        XCTAssertEqual(URLRouter.classify("https://www.instagram.com/reel/AbCdEfGhIj/"), .instagram)
    }

    func testInstagramReelsPlural() {
        XCTAssertEqual(URLRouter.classify("https://www.instagram.com/reels/AbCd/"), .instagram)
    }

    func testInstagramPost() {
        XCTAssertEqual(URLRouter.classify("https://www.instagram.com/p/AbCdEfGhIj/"), .instagram)
    }

    func testInstagramTV() {
        XCTAssertEqual(URLRouter.classify("https://www.instagram.com/tv/AbCdEfGhIj/"), .instagram)
    }

    func testInstagramProfileNotVideo() {
        // Profile page — no recipe content, treat as web
        XCTAssertEqual(URLRouter.classify("https://www.instagram.com/somechef/"), .webPage)
    }

    // MARK: - YouTube

    func testYouTubeWatch() {
        XCTAssertEqual(URLRouter.classify("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), .youTube)
    }

    func testYouTubeShortLink() {
        XCTAssertEqual(URLRouter.classify("https://youtu.be/dQw4w9WgXcQ"), .youTube)
    }

    func testYouTubeShorts() {
        XCTAssertEqual(URLRouter.classify("https://www.youtube.com/shorts/AbCdEfGhIjK"), .youTube)
    }

    func testYouTubeMobile() {
        XCTAssertEqual(URLRouter.classify("https://m.youtube.com/watch?v=AbCdEfGhIjK"), .youTube)
    }

    // MARK: - Web Page (default)

    func testAllRecipes() {
        XCTAssertEqual(URLRouter.classify("https://www.allrecipes.com/recipe/10813/best-chocolate-chip-cookies/"), .webPage)
    }

    func testFoodNetwork() {
        XCTAssertEqual(URLRouter.classify("https://www.foodnetwork.com/recipes/ina-garten/pasta-with-shrimp"), .webPage)
    }

    func testPersonalBlog() {
        XCTAssertEqual(URLRouter.classify("https://myblog.com/my-best-pasta-recipe"), .webPage)
    }

    func testSeriousEats() {
        XCTAssertEqual(URLRouter.classify("https://www.seriouseats.com/the-best-pizza-dough-recipe"), .webPage)
    }

    func testNYTCooking() {
        XCTAssertEqual(URLRouter.classify("https://cooking.nytimes.com/recipes/1020196"), .webPage)
    }

    func testEmptyString() {
        XCTAssertEqual(URLRouter.classify(""), .webPage)
    }

    func testInvalidURL() {
        XCTAssertEqual(URLRouter.classify("not a url"), .webPage)
    }

    func testUnknownDomain() {
        XCTAssertEqual(URLRouter.classify("https://some-random-cooking-site.example.com/recipe"), .webPage)
    }
}
