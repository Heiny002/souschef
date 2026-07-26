import XCTest
@testable import SousChef

/// Multi-part recipes (steak + flatbread + spread + salad) should start with the part that
/// takes longest, so the slow component is underway while the quick ones get made — but only
/// when the margin is big enough to be worth overriding the author's order.
final class ComponentSequencerTests: XCTestCase {

    // MARK: Cook time extraction

    func testCookTimeTakesUpperBoundOfRange() {
        XCTAssertEqual(ComponentSequencer.cookTime(of: "Bake for 18-20 minutes"), 20 * 60)
        XCTAssertEqual(ComponentSequencer.cookTime(of: "Cook 18 to 20 minutes"), 20 * 60)
        XCTAssertEqual(ComponentSequencer.cookTime(of: "Sear for 10 minutes"), 10 * 60)
        XCTAssertEqual(ComponentSequencer.cookTime(of: "Rest 1 hour"), 3600)
        XCTAssertEqual(ComponentSequencer.cookTime(of: "Mix well"), 0)
    }

    func testCookTimeTakesLongestMentionInAStep() {
        XCTAssertEqual(ComponentSequencer.cookTime(of: "Rest 5 minutes, then bake 25 minutes"), 25 * 60)
    }

    // MARK: Grouping

    func testGroupsStepsByComponentPreservingFirstAppearance() {
        let steps: [(text: String, section: String?)] = [
            ("Season the steak", "Steak"),
            ("Mix the yogurt", "Yogurt spread"),
            ("Sear 10 minutes", "Steak"),
        ]
        let components = ComponentSequencer.components(from: steps)
        XCTAssertEqual(components.map(\.name), ["Steak", "Yogurt spread"])
        XCTAssertEqual(components[0].steps.count, 2)
        XCTAssertEqual(components[0].cookSeconds, 10 * 60)
    }

    // MARK: The rule

    func testLongestComponentLeadsWhenMarginIsLarge() {
        // The real case: flatbread 18–20 min vs steak 10 min → flatbread first.
        let steps: [(text: String, section: String?)] = [
            ("Season the steak with spices", "Steak"),
            ("Sear the steak for 10 minutes", "Steak"),
            ("Knead the dough", "Flatbread"),
            ("Bake the flatbreads for 18-20 minutes", "Flatbread"),
            ("Stir the yogurt and lemon", "Yogurt spread"),
        ]
        let result = ComponentSequencer.sequence(steps)
        XCTAssertEqual(result.first?.section, "Flatbread", "the 20-minute part must start first")
        XCTAssertEqual(result.map(\.section).prefix(2).map { $0 ?? "" }, ["Flatbread", "Flatbread"],
                       "a promoted component keeps its steps together")
        // Every step survives the reorder.
        XCTAssertEqual(result.count, steps.count)
        XCTAssertEqual(Set(result.map(\.text)), Set(steps.map(\.text)))
    }

    func testOriginalOrderKeptWhenTimesAreClose() {
        // 12 min vs 10 min → within the 4-minute threshold, so don't override the author.
        let steps: [(text: String, section: String?)] = [
            ("Sear the steak for 10 minutes", "Steak"),
            ("Warm the flatbread for 12 minutes", "Flatbread"),
        ]
        let result = ComponentSequencer.sequence(steps)
        XCTAssertEqual(result.first?.section, "Steak", "a 2-minute edge isn't worth reordering")
    }

    func testThresholdBoundaryIsExclusive() {
        let atThreshold = [
            ComponentSequencer.Component(name: "A", steps: ["a"], cookSeconds: 60),
            ComponentSequencer.Component(name: "B", steps: ["b"], cookSeconds: 60 + ComponentSequencer.tieThreshold),
        ]
        XCTAssertEqual(ComponentSequencer.reorder(atThreshold).map(\.name), ["A", "B"],
                       "exactly at the threshold counts as a tie")

        let overThreshold = [
            ComponentSequencer.Component(name: "A", steps: ["a"], cookSeconds: 60),
            ComponentSequencer.Component(name: "B", steps: ["b"], cookSeconds: 61 + ComponentSequencer.tieThreshold),
        ]
        XCTAssertEqual(ComponentSequencer.reorder(overThreshold).map(\.name), ["B", "A"],
                       "one second past the threshold reorders")
    }

    func testSingleComponentAndUnsectionedRecipesAreUntouched() {
        let single: [(text: String, section: String?)] = [
            ("Boil pasta 12 minutes", "Pasta"), ("Drain", "Pasta"),
        ]
        XCTAssertEqual(ComponentSequencer.sequence(single).map(\.text), single.map(\.text))

        let plain: [(text: String, section: String?)] = [
            ("Preheat the oven", nil), ("Bake 40 minutes", nil), ("Cool", nil),
        ]
        XCTAssertEqual(ComponentSequencer.sequence(plain).map(\.text), plain.map(\.text))
    }

    func testNoReorderWhenLongestIsAlreadyFirst() {
        let steps: [(text: String, section: String?)] = [
            ("Bake 40 minutes", "Cake"),
            ("Whip the cream for 2 minutes", "Topping"),
        ]
        XCTAssertEqual(ComponentSequencer.sequence(steps).map(\.section).map { $0 ?? "" },
                       ["Cake", "Topping"])
    }

    func testComponentsWithoutAnyTimingAreLeftAlone() {
        let steps: [(text: String, section: String?)] = [
            ("Mix the spread", "Spread"), ("Chop the onion", "Salad"),
        ]
        XCTAssertEqual(ComponentSequencer.sequence(steps).map(\.section).map { $0 ?? "" },
                       ["Spread", "Salad"])
    }
}
