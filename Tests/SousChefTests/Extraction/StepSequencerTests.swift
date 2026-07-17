import XCTest
@testable import SousChef

final class StepSequencerTests: XCTestCase {

    // MARK: - The reported case: preheat before a marinade wait

    func testPreheatMovesIntoMarinadeDowntime() {
        let steps = [
            "Make the marinade.",
            "Preheat the oven to 425°F.",
            "Add the chicken and toss to coat.",
            "Let it marinate for 10–15 minutes.",
            "Bake for 25 minutes.",
        ]
        let result = StepSequencer.reorder(steps)
        XCTAssertEqual(result, [
            "Make the marinade.",
            "Add the chicken and toss to coat.",
            "Preheat the oven to 425°F.",
            "Let it marinate for 10–15 minutes.",
            "Bake for 25 minutes.",
        ])
        // Preheat now sits immediately before the marinade wait so they overlap.
        XCTAssertEqual(result.firstIndex(of: "Preheat the oven to 425°F."),
                       result.firstIndex(where: { $0.contains("marinate") })! - 1)
    }

    func testPreheatWithDegreesWordAndHyphen() {
        let steps = [
            "Preheat oven to 400 degrees.",
            "Whisk the marinade ingredients together.",
            "Marinate the chicken for 30 minutes.",
            "Roast until cooked through.",
        ]
        let result = StepSequencer.reorder(steps)
        XCTAssertEqual(result, [
            "Whisk the marinade ingredients together.",
            "Preheat oven to 400 degrees.",
            "Marinate the chicken for 30 minutes.",
            "Roast until cooked through.",
        ])
    }

    // MARK: - No-ops (conservative behaviour)

    func testNoReorderWhenAlreadyAdjacent() {
        let steps = [
            "Make the marinade.",
            "Preheat the oven to 425°F.",
            "Marinate the chicken for 15 minutes.",
        ]
        XCTAssertEqual(StepSequencer.reorder(steps), steps)
    }

    func testNoReorderWhenNoPreheat() {
        let steps = [
            "Make the marinade.",
            "Marinate the chicken for 15 minutes.",
            "Grill over high heat.",
        ]
        XCTAssertEqual(StepSequencer.reorder(steps), steps)
    }

    func testNoReorderWhenNoDowntime() {
        let steps = [
            "Preheat the oven to 425°F.",
            "Toss the vegetables with oil.",
            "Bake for 25 minutes.",
        ]
        XCTAssertEqual(StepSequencer.reorder(steps), steps)
    }

    func testPreheatAfterDowntimeLeftAlone() {
        // Trailing "rest before serving" must not drag the preheat downward.
        let steps = [
            "Preheat the oven to 425°F.",
            "Bake for 25 minutes.",
            "Let the chicken rest for 10 minutes before serving.",
        ]
        XCTAssertEqual(StepSequencer.reorder(steps), steps)
    }

    func testShortRestDoesNotQualify() {
        // A 30-second rest is not enough downtime to justify moving a preheat.
        let steps = [
            "Preheat the oven to 425°F.",
            "Stir the sauce.",
            "Let stand for 30 seconds.",
            "Serve.",
        ]
        XCTAssertEqual(StepSequencer.reorder(steps), steps)
    }

    // MARK: - H11: never move a preheat past an intermediate oven step

    func testParBakeKeepsPreheatBeforeFirstBake() {
        // The crust bakes BETWEEN the preheat and the chill — moving the preheat after
        // the crust bake would bake it in a cold oven (the exact audit hazard).
        let steps = [
            "Preheat the oven to 375°F.",
            "Bake the crust for 10 minutes.",
            "Chill the filling for 30 minutes.",
            "Bake the pie for 25 minutes.",
        ]
        XCTAssertEqual(StepSequencer.reorder(steps), steps)
    }

    func testToastCountsAsOvenUse() {
        let steps = [
            "Preheat the oven to 350°F.",
            "Toast the nuts in the oven until fragrant.",
            "Chill the dough for 20 minutes.",
            "Bake the cookies for 12 minutes.",
        ]
        XCTAssertEqual(StepSequencer.reorder(steps), steps)
        XCTAssertTrue(StepSequencer.isOvenUse("Toast the nuts until fragrant."))
        XCTAssertTrue(StepSequencer.isOvenUse("Place the dish in the oven."))
    }

    // MARK: - Long downtime must not become an oven-on window

    func testOvernightMarinadeDoesNotAttractThePreheat() {
        // Moving the preheat to the start of an 8-hour marinade would leave the oven
        // running all night (audit medium) — long waits don't qualify for overlap.
        let steps = [
            "Preheat the oven to 425°F.",
            "Whisk the marinade.",
            "Marinate the chicken for 8 hours.",
            "Roast for 45 minutes.",
        ]
        XCTAssertEqual(StepSequencer.reorder(steps), steps)
        XCTAssertFalse(StepSequencer.isPassiveDowntime("Marinate the chicken for 8 hours."))
    }

    // MARK: - Classification helpers

    func testIsPassiveDowntime() {
        XCTAssertTrue(StepSequencer.isPassiveDowntime("Marinate for 10–15 minutes."))
        XCTAssertTrue(StepSequencer.isPassiveDowntime("Refrigerate for at least 30 minutes or up to 24 hours."))
        XCTAssertTrue(StepSequencer.isPassiveDowntime("Let the dough rise for 1 hour."))
        // "make the marinade" has the keyword but no timer → not downtime.
        XCTAssertFalse(StepSequencer.isPassiveDowntime("Make the marinade."))
        // Active cooking that happens to contain "rest" is not downtime.
        XCTAssertFalse(StepSequencer.isPassiveDowntime("Add the rest of the broth and simmer for 20 minutes."))
    }

    func testIsPreheat() {
        XCTAssertTrue(StepSequencer.isPreheat("Preheat the oven to 425°F."))
        XCTAssertTrue(StepSequencer.isPreheat("Preheat oven to 400 degrees."))
        XCTAssertTrue(StepSequencer.isPreheat("Heat the oven to 220°C."))
        XCTAssertFalse(StepSequencer.isPreheat("Heat the oil in a large skillet."))
        XCTAssertFalse(StepSequencer.isPreheat("Bring a pot of water to a boil."))
    }
}
