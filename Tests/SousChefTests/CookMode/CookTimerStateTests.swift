import XCTest
@testable import SousChef

/// C4 + stackable timers — every Cook Mode countdown must be wall-clock anchored (locking
/// the phone or backgrounding the app can never lose time, and expiry is detected however
/// late the next reconcile happens), and multiple timers must run concurrently and
/// independently. Injected `now:` values simulate suspension gaps.
@MainActor
final class CookTimerStackTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Keep CI free of notification-permission prompts.
        CookTimerStack.notificationsSuppressed = true
    }

    private func makeTimer(seconds: Int, perSide: Bool = false) -> DetectedTimer {
        DetectedTimer(label: "\(seconds / 60) minutes", seconds: seconds, isPerSide: perSide)
    }

    func testReconcileAccountsForLockedTime() {
        let stack = CookTimerStack()
        let t0 = Date()
        let id = stack.add(makeTimer(seconds: 600), stepIndex: 2,
                           stepInstruction: "Simmer for 10 minutes.", now: t0)

        // Phone locked for 2 minutes: the old decrement-per-tick timer would still show
        // ~10:00 here. Wall-clock reconcile must show 8:00.
        stack.reconcile(now: t0.addingTimeInterval(120))
        let timer = try! XCTUnwrap(stack.timer(id: id))
        XCTAssertEqual(timer.secondsRemaining, 480)
        XCTAssertTrue(timer.isRunning)
        XCTAssertFalse(timer.didComplete)
    }

    func testTwoTimersRunConcurrently() {
        // The whole point of stacking: step 4's simmer keeps counting while step 5's
        // sear timer starts a minute later, and one reconcile updates both.
        let stack = CookTimerStack()
        let t0 = Date()
        let simmer = stack.add(makeTimer(seconds: 600), stepIndex: 3,
                               stepInstruction: "Simmer the sauce for 10 minutes.", now: t0)
        let sear = stack.add(makeTimer(seconds: 300), stepIndex: 4,
                             stepInstruction: "Sear the steak for 5 minutes.",
                             now: t0.addingTimeInterval(60))

        stack.reconcile(now: t0.addingTimeInterval(120))
        XCTAssertEqual(stack.timer(id: simmer)?.secondsRemaining, 480)
        XCTAssertEqual(stack.timer(id: sear)?.secondsRemaining, 240)
        XCTAssertEqual(stack.runningTimers.count, 2)

        // The shorter one completes; the longer one keeps running untouched.
        stack.reconcile(now: t0.addingTimeInterval(361))
        XCTAssertEqual(stack.timer(id: sear)?.didComplete, true)
        XCTAssertEqual(stack.timer(id: simmer)?.isRunning, true)
        XCTAssertEqual(stack.timer(id: simmer)?.secondsRemaining, 239)
    }

    func testCompletesAfterLongSuspensionAndPublishesGuidance() {
        let stack = CookTimerStack()
        let t0 = Date()
        let id = stack.add(makeTimer(seconds: 600), stepIndex: 0,
                           stepInstruction: "Boil for 10 minutes.", now: t0)

        // App suspended straight past expiry — first reconcile after unlock must complete
        // and surface the timer for the "what to do next" overlay.
        stack.reconcile(now: t0.addingTimeInterval(700))
        let timer = try! XCTUnwrap(stack.timer(id: id))
        XCTAssertTrue(timer.didComplete)
        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(timer.secondsRemaining, 0)
        XCTAssertEqual(stack.justCompleted?.id, id)
    }

    func testPauseCapturesWallClockRemaining() {
        let stack = CookTimerStack()
        let t0 = Date()
        let id = stack.add(makeTimer(seconds: 600), stepIndex: 0,
                           stepInstruction: "Rest for 10 minutes.", now: t0)

        stack.pause(id: id, now: t0.addingTimeInterval(30))
        XCTAssertEqual(stack.timer(id: id)?.isRunning, false)
        XCTAssertEqual(stack.timer(id: id)?.secondsRemaining, 570)

        // Resume runs from a fresh anchor.
        let t1 = t0.addingTimeInterval(100)
        stack.start(id: id, now: t1)
        stack.reconcile(now: t1.addingTimeInterval(10))
        XCTAssertEqual(stack.timer(id: id)?.secondsRemaining, 560)
    }

    func testPerSideNeverAutoAdvances() {
        // Flipping is a user action: side 1 completing must park on the completion state
        // (guidance overlay) and only startNextSide moves to side 2.
        let stack = CookTimerStack()
        let t0 = Date()
        let id = stack.add(makeTimer(seconds: 420, perSide: true), stepIndex: 1,
                           stepInstruction: "Grill the chicken for 7 minutes per side.", now: t0)
        XCTAssertEqual(stack.timer(id: id)?.totalSides, 2)

        stack.reconcile(now: t0.addingTimeInterval(421))
        var timer = try! XCTUnwrap(stack.timer(id: id))
        XCTAssertTrue(timer.didComplete)
        XCTAssertEqual(timer.sideNumber, 1, "side must not roll over without user action")
        XCTAssertEqual(stack.justCompleted?.id, id)

        let t1 = t0.addingTimeInterval(500)   // user flips 79s later, then starts side 2
        stack.startNextSide(id: id, now: t1)
        timer = try! XCTUnwrap(stack.timer(id: id))
        XCTAssertEqual(timer.sideNumber, 2)
        XCTAssertTrue(timer.isRunning)
        XCTAssertFalse(timer.didComplete)
        XCTAssertNil(stack.justCompleted, "starting the next side dismisses the overlay")

        stack.reconcile(now: t1.addingTimeInterval(421))
        XCTAssertEqual(stack.timer(id: id)?.didComplete, true)
        XCTAssertEqual(stack.timer(id: id)?.sideNumber, 2)
    }

    func testRemoveClearsTimerAndOverlay() {
        let stack = CookTimerStack()
        let t0 = Date()
        let id = stack.add(makeTimer(seconds: 60), stepIndex: 0,
                           stepInstruction: "Toast for 1 minute.", now: t0)
        stack.reconcile(now: t0.addingTimeInterval(61))
        XCTAssertNotNil(stack.justCompleted)

        stack.remove(id: id)
        XCTAssertNil(stack.timer(id: id))
        XCTAssertNil(stack.justCompleted, "removing a timer clears its pending overlay")
        XCTAssertFalse(stack.hasTimers)
    }

    func testStopAllClearsEverything() {
        let stack = CookTimerStack()
        let t0 = Date()
        stack.add(makeTimer(seconds: 600), stepIndex: 0, stepInstruction: "A", now: t0)
        stack.add(makeTimer(seconds: 300), stepIndex: 1, stepInstruction: "B", now: t0)
        XCTAssertEqual(stack.timers.count, 2)

        stack.stopAll()
        XCTAssertFalse(stack.hasTimers)
        XCTAssertNil(stack.justCompleted)
    }

    func testTimerLookupByStep() {
        let stack = CookTimerStack()
        let t0 = Date()
        stack.add(makeTimer(seconds: 600), stepIndex: 4,
                  stepInstruction: "Bake for 10 minutes.", now: t0)
        XCTAssertNotNil(stack.timer(forStep: 4))
        XCTAssertNil(stack.timer(forStep: 5))
    }

    // MARK: - Completion guidance subject extraction

    func testSubjectExtraction() {
        XCTAssertEqual(
            TimerSubjectExtractor.subject(in: "Grill the chicken for 7 minutes per side."),
            "chicken")
        XCTAssertEqual(
            TimerSubjectExtractor.subject(in: "Sear the pork chops for 4 minutes each side."),
            "pork chops")
        XCTAssertEqual(
            TimerSubjectExtractor.subject(in: "Cook salmon fillets 3–4 minutes per side."),
            "salmon fillets")
        // Pronouns and bare durations are not useful subjects.
        XCTAssertNil(TimerSubjectExtractor.subject(in: "Cook it for 5 minutes."))
        XCTAssertNil(TimerSubjectExtractor.subject(in: "Simmer for 10 minutes."))
        XCTAssertNil(TimerSubjectExtractor.subject(in: "Cook 2 minutes per side."))
    }
}
