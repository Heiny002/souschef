import XCTest
@testable import SousChef

/// Think-tank branch 6 (youtube-descriptions). The live watch-page fetch can't run in CI,
/// so these pin the pure pieces it depends on: video-id parsing, videoDetails extraction
/// from a watch-page fixture, quote-aware brace matching, description cleaning, and the
/// sponsor-aware direct-URL picker.
final class YouTubeExtractionTests: XCTestCase {

    // MARK: - Video id

    func testVideoIDAcrossURLForms() {
        XCTAssertEqual(VideoMetadataFetcher.youtubeVideoID(
            from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(VideoMetadataFetcher.youtubeVideoID(
            from: "https://youtu.be/dQw4w9WgXcQ?t=10"), "dQw4w9WgXcQ")
        XCTAssertEqual(VideoMetadataFetcher.youtubeVideoID(
            from: "https://www.youtube.com/shorts/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(VideoMetadataFetcher.youtubeVideoID(
            from: "https://www.youtube.com/watch?list=x&v=dQw4w9WgXcQ&t=5"), "dQw4w9WgXcQ")
        XCTAssertNil(VideoMetadataFetcher.youtubeVideoID(from: "https://example.com/nope"))
    }

    // MARK: - videoDetails extraction

    func testVideoDetailsFromWatchPageHTML() {
        // A shortDescription with an embedded brace and escaped quote, to exercise the
        // quote/escape-aware brace matcher.
        let html = #"""
        <html><body><script>
        var ytInitialPlayerResponse = {"responseContext":{},"videoDetails":{
          "videoId":"abc","title":"Best Pancakes",
          "shortDescription":"Fluffy pancakes {the easy way}. He said \"whisk well\".\n2 cups flour\n1 cup milk",
          "author":"Chef Demo",
          "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/a.jpg"},{"url":"https://i.ytimg.com/hq.jpg"}]}
        }};var other = 1;
        </script></body></html>
        """#
        let details = VideoMetadataFetcher.youtubeVideoDetails(fromWatchPageHTML: html)
        XCTAssertEqual(details?.title, "Best Pancakes")
        XCTAssertEqual(details?.author, "Chef Demo")
        XCTAssertEqual(details?.thumbnailURL, "https://i.ytimg.com/hq.jpg", "last (largest) thumb")
        XCTAssertTrue(details?.description.contains("2 cups flour") ?? false)
        XCTAssertTrue(details?.description.contains("{the easy way}") ?? false,
                      "a brace inside the string must not truncate the object")
    }

    func testVideoDetailsNilWhenNoPlayerResponse() {
        XCTAssertNil(VideoMetadataFetcher.youtubeVideoDetails(
            fromWatchPageHTML: "<html><body>no player response here</body></html>"))
    }

    func testBalancedJSONObjectStopsAtMatchingBrace() {
        let text = "prefix ytInitialPlayerResponse = {\"a\":{\"b\":1},\"c\":\"}}}\"} trailing junk"
        let obj = VideoMetadataFetcher.balancedJSONObject(in: text, after: "ytInitialPlayerResponse")
        XCTAssertEqual(obj, "{\"a\":{\"b\":1},\"c\":\"}}}\"}",
                       "braces inside a string value are not counted")
    }

    // MARK: - Description cleaning

    func testDescriptionCleanerStripsTimestampsAndBoilerplate() {
        let raw = """
        My best pancake recipe.

        Ingredients:
        2 cups flour
        1 cup milk

        0:00 Intro
        1:30 Mixing
        12:05 Cooking

        My gear: https://amzn.to/xyz
        Follow me on Instagram
        Sponsored by PanCo
        Get 10% off at https://bit.ly/deal
        """
        let cleaned = YouTubeDescriptionCleaner.clean(raw)
        XCTAssertTrue(cleaned.contains("2 cups flour"))
        XCTAssertTrue(cleaned.contains("Ingredients:"))
        XCTAssertFalse(cleaned.contains("0:00"))
        XCTAssertFalse(cleaned.contains("12:05"))
        XCTAssertFalse(cleaned.localizedCaseInsensitiveContains("amzn.to"))
        XCTAssertFalse(cleaned.localizedCaseInsensitiveContains("sponsored"))
        XCTAssertFalse(cleaned.localizedCaseInsensitiveContains("follow me"))
        XCTAssertFalse(cleaned.contains("bit.ly"))
    }

    // MARK: - Direct-URL picker (sponsor-aware)

    func testDirectURLSkipsSponsorLinksAndPrefersRecipeLine() {
        let caption = """
        Loved this one!
        My gear: https://amzn.to/abc
        Support me: https://patreon.com/chef
        Full recipe: https://mysite.com/pancakes
        """
        guard case let .directURL(url) = CaptionAnalyzer.analyze(caption) else {
            return XCTFail("expected a direct URL signal")
        }
        XCTAssertEqual(url, "https://mysite.com/pancakes")
    }

    func testDirectURLReturnsNilWhenOnlySponsorLinks() {
        // A caption with nothing but affiliate links should not surface one as the recipe.
        let caption = "Grab my pans: https://amzn.to/abc and https://bit.ly/xyz"
        if case .directURL = CaptionAnalyzer.analyze(caption) {
            XCTFail("affiliate-only caption must not yield a direct recipe URL")
        }
    }
}
