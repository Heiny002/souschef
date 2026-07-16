import XCTest
@testable import SousChef

final class TimerDetectorTests: XCTestCase {

    // MARK: - Range separators (regression: en-dash was silently unmatched)

    func testRangeWithHyphen() {
        let t = TimerDetector.detect(in: "Marinate the chicken for 10-15 minutes.")
        XCTAssertNotNil(t)
        XCTAssertEqual(t?.seconds, 750)   // midpoint 12.5 min
    }

    func testRangeWithEnDash() {
        let t = TimerDetector.detect(in: "Marinate the chicken for 10–15 minutes.")
        XCTAssertNotNil(t, "En-dash ranges must produce a timer")
        XCTAssertEqual(t?.seconds, 750)
    }

    func testRangeWithEmDash() {
        let t = TimerDetector.detect(in: "Rest for 5—7 minutes.")
        XCTAssertNotNil(t)
        XCTAssertEqual(t?.seconds, 360)   // midpoint 6 min
    }

    func testRangeWithToWord() {
        let t = TimerDetector.detect(in: "Bake for 25 to 30 minutes.")
        XCTAssertNotNil(t)
        XCTAssertEqual(t?.seconds, 1650)  // midpoint 27.5 min
    }

    // MARK: - Single durations

    func testSingleMinutes() {
        let t = TimerDetector.detect(in: "Simmer for 20 minutes.")
        XCTAssertEqual(t?.seconds, 1200)
    }

    func testHours() {
        let t = TimerDetector.detect(in: "Refrigerate for 2 hours.")
        XCTAssertEqual(t?.seconds, 7200)
    }

    func testNoTimeMentioned() {
        XCTAssertNil(TimerDetector.detect(in: "Season with salt and pepper to taste."))
    }

    func testPerSideDetected() {
        let t = TimerDetector.detect(in: "Sear for 3-4 minutes per side.")
        XCTAssertNotNil(t)
        XCTAssertTrue(t?.isPerSide ?? false)
    }

    // MARK: - Overflow hardening (untrusted scraped durations)

    func testHugeDurationDoesNotCrashAndIsRejected() {
        // Previously trapped in `Int(v * 60)` before the >= 10 guard could run.
        XCTAssertNil(TimerDetector.detect(in: "Cook for 99999999999999999999 minutes."))
        XCTAssertNil(TimerDetector.detect(in: "Bake for 999999999999999999999 hours."))
        XCTAssertNil(TimerDetector.detect(in: "Rest for 5000000000-6000000000 minutes."))
    }

    func testDurationAtTheCeilingStillWorks() {
        // 24h is the ceiling; a normal long braise is still accepted.
        let t = TimerDetector.detect(in: "Braise for 6 hours.")
        XCTAssertEqual(t?.seconds, 21_600)
    }
}
