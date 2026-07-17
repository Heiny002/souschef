import XCTest
import SwiftData
@testable import SousChef

/// H5 — recipe provenance is persisted and surfaced safely.
final class ProvenanceTests: XCTestCase {

    func testSourceTypeDerivation() {
        XCTAssertEqual(URLRouter.sourceType(forStoredURL: "https://www.tiktok.com/@u/video/123"), "tiktok")
        XCTAssertEqual(URLRouter.sourceType(forStoredURL: "https://youtu.be/abc"), "youtube")
        XCTAssertEqual(URLRouter.sourceType(forStoredURL: "https://www.instagram.com/reel/abc/"), "instagram")
        XCTAssertEqual(URLRouter.sourceType(forStoredURL: "https://cooking.nytimes.com/recipes/1"), "web")
        XCTAssertEqual(URLRouter.sourceType(forStoredURL: nil), "web")
        XCTAssertEqual(URLRouter.sourceType(forStoredURL: ""), "web")
    }

    func testSafeExternalURLAcceptsOnlyHTTPS() {
        XCTAssertNotNil(URLRouter.safeExternalURL("https://example.com/r"))
        XCTAssertNil(URLRouter.safeExternalURL("http://example.com/r"), "cleartext rejected")
        XCTAssertNil(URLRouter.safeExternalURL("javascript:alert(1)"))
        XCTAssertNil(URLRouter.safeExternalURL("file:///etc/passwd"))
        XCTAssertNil(URLRouter.safeExternalURL("https://"), "hostless rejected")
        XCTAssertNil(URLRouter.safeExternalURL(nil))
        XCTAssertNil(URLRouter.safeExternalURL(""))
    }

    func testStorageValues() {
        XCTAssertEqual(URLSourceType.tikTok.storageValue, "tiktok")
        XCTAssertEqual(URLSourceType.instagram.storageValue, "instagram")
        XCTAssertEqual(URLSourceType.youTube.storageValue, "youtube")
        XCTAssertEqual(URLSourceType.webPage.storageValue, "web")
    }

    @MainActor
    func testRecipePersistsProvenance() throws {
        let container = try ModelContainer(
            for: Recipe.self, DinerProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext

        let recipe = Recipe(title: "Tacos", sourceURL: "https://example.com/tacos", sourceType: "tiktok")
        recipe.thumbnailURL = "https://example.com/tacos.jpg"
        ctx.insert(recipe)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<Recipe>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.sourceURL, "https://example.com/tacos")
        XCTAssertEqual(fetched.first?.thumbnailURL, "https://example.com/tacos.jpg")
        XCTAssertEqual(fetched.first?.sourceType, "tiktok")
    }
}
