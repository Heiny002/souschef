import XCTest
@testable import SousChef

final class SousChefTests: XCTestCase {
    /// The "Stamp commit info" build phase must bake CommitInfo.json into the app bundle
    /// on every build, and BuildInfo must render it as an "Updated …" version stamp.
    /// A failure here means the script phase didn't run — the Library would silently fall
    /// back to showing compile time instead of the code's last-updated date.
    func testCommitStampBakedIntoBundle() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "CommitInfo", withExtension: "json"),
            "CommitInfo.json missing from bundle — stamp build phase didn't run"
        )
        let data = try Data(contentsOf: url)
        let info = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: String])

        let commitDate = try XCTUnwrap(info["commitDate"])
        XCTAssertNotNil(ISO8601DateFormatter().date(from: commitDate),
                        "commitDate not ISO8601: \(commitDate)")
        XCTAssertFalse(info["commitHash"]?.isEmpty ?? true)

        XCTAssertTrue(BuildInfo.stamp.hasPrefix("Updated"),
                      "stamp fell back instead of using commit info: \(BuildInfo.stamp)")
    }
}
