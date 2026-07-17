import XCTest
@testable import SousChef

/// Key-format validation used by the Settings screen. (Keychain round-trips are not
/// unit-tested — they depend on the test host's keychain entitlements and are exercised
/// by hand in the app.)
final class APIKeyStoreTests: XCTestCase {

    func testLooksValidAcceptsAnthropicKeys() {
        XCTAssertTrue(APIKeyProvider.looksValid("sk-ant-api03-abcdef1234567890"))
        XCTAssertTrue(APIKeyProvider.looksValid("  sk-ant-api03-abcdef1234567890  "), "trims whitespace")
    }

    func testLooksValidRejectsNonKeys() {
        XCTAssertFalse(APIKeyProvider.looksValid(""))
        XCTAssertFalse(APIKeyProvider.looksValid("hello"))
        XCTAssertFalse(APIKeyProvider.looksValid("sk-ant-"), "prefix alone is too short")
        XCTAssertFalse(APIKeyProvider.looksValid("sk-proj-openai-style-key-123456"))
    }
}
