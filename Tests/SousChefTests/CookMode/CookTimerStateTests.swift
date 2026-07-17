import XCTest
@testable import SousChef

/// C4 — the Cook Mode countdown must be wall-clock anchored: locking the phone or
/// backgrounding the app can never lose time, and expiry is detected however late the
/// next reconcile happens. Injected `now:` values simulate suspension gaps.
@MainActor
final class CookTimerStateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Keep CI free of notification-permission prompts.
        CookTimerState.notificationsSuppressed = true
    }

    private func makeTimer(seconds: Int, perSide: Bool = false) -> DetectedTimer {
        DetectedTimer(label: "\(seconds / 60) minutes", seconds: seconds, isPerSide: perSide)
    }

    func testReconcileAccountsForLockedTime() {
        let state = CookTimerState()
        let t0 = Date()
        state.configure(from: makeTimer(seconds: 600))
        state.start(now: t0)

        // Phone locked for 2 minutes: the old decrement-per-tick timer would still show
        // ~10:00 here. Wall-clock reconcile must show 8:00.
        state.reconcile(now: t0.addingTimeInterval(120))
        XCTAssertEqual(state.secondsRemaining, 480)
        XCTAssertTrue(state.isRunning)
        XCTAssertFalse(state.didComplete)
    }

    func testCompletesAfterLongSuspension() {
        let state = CookTimerState()
        let t0 = Date()
        state.configure(from: makeTimer(seconds: 600))
        state.start(now: t0)

        // App suspended straight past expiry — first reconcile after unlock must complete.
        state.reconcile(now: t0.addingTimeInterval(700))
        XCTAssertTrue(state.didComplete)
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.secondsRemaining, 0)
    }

    func testPauseCapturesWallClockRemaining() {
        let state = CookTimerState()
        let t0 = Date()
        state.configure(from: makeTimer(seconds: 600))
        state.start(now: t0)

        state.pause(now: t0.addingTimeInterval(30))
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.secondsRemaining, 570)

        // Resume runs from a fresh anchor.
        let t1 = t0.addingTimeInterval(100)
        state.start(now: t1)
        state.reconcile(now: t1.addingTimeInterval(10))
        XCTAssertEqual(state.secondsRemaining, 560)
    }

    func testStopCancelsPendingSideAdvance() {
        // Audit medium: the per-side rollover closure fired 1.5s after completion even if
        // the user had stopped/reconfigured in the gap, clobbering the new state.
        let state = CookTimerState()
        let t0 = Date()
        state.configure(from: makeTimer(seconds: 60, perSide: true))
        XCTAssertEqual(state.totalSides, 2)
        state.start(now: t0)
        state.reconcile(now: t0.addingTimeInterval(61))   // side 1 completes, rollover queued
        XCTAssertTrue(state.didComplete)

        state.stop()   // user dismisses the timer before the 1.5s rollover fires

        let exp = expectation(description: "past the rollover delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { exp.fulfill() }
        wait(for: [exp], timeout: 5.0)

        // The stale closure must NOT have resurrected the timer.
        XCTAssertFalse(state.isConfigured)
        XCTAssertEqual(state.secondsRemaining, 0)
        XCTAssertEqual(state.sideNumber, 1)
        XCTAssertFalse(state.didComplete)
    }
}
