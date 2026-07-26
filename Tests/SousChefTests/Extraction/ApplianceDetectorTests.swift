import XCTest
@testable import SousChef

/// Special equipment decides whether a cook can make a recipe at all, so it's surfaced at
/// import. That only works if detection finds the real machines without drowning them in
/// drawer contents — the old keyword list matched "grams" as a kitchen scale and "peel the"
/// as a peeler.
final class ApplianceDetectorTests: XCTestCase {

    func testDetectsModernAppliances() {
        XCTAssertTrue(ApplianceDetector.detect(in: ["Cook in the air fryer at 400F for 12 min"])
            .contains("air fryer"))
        XCTAssertTrue(ApplianceDetector.detect(in: ["Sous vide the steak at 130F"])
            .contains("sous vide"))
        XCTAssertTrue(ApplianceDetector.detect(in: ["Pressure cook for 8 minutes"])
            .contains("pressure cooker"))
        XCTAssertTrue(ApplianceDetector.detect(in: ["Add to the Instant Pot"])
            .contains("instant pot"))
        XCTAssertTrue(ApplianceDetector.detect(in: ["Smoke the brisket for 6 hours"])
            .contains("smoker"))
    }

    func testSpecialEquipmentFiltersOutEverydayTools() {
        let text = ["Peel and grate the carrots, strain through a colander",
                    "Air fry at 380F for 10 minutes"]
        let special = ApplianceDetector.detectSpecialEquipment(in: text)
        XCTAssertTrue(special.contains("air fryer"), "the machine that matters is surfaced")
        XCTAssertFalse(special.contains("colander"), "drawer contents are not special equipment")
        XCTAssertFalse(special.contains("peeler"))
    }

    func testOverBroadKeywordsNoLongerFalsePositive() {
        // "grams" used to imply a kitchen scale on every metric recipe (audit finding).
        let detected = ApplianceDetector.detect(in: ["Add 200 grams of flour to the bowl"])
        XCTAssertFalse(detected.contains("kitchen scale"))
        // A plain instruction shouldn't conjure tools out of common verbs.
        let plain = ApplianceDetector.detect(in: ["Peel the potatoes and drain the pasta"])
        XCTAssertFalse(plain.contains("peeler"))
        XCTAssertFalse(plain.contains("colander"))
    }

    func testExplicitToolsStillDetected() {
        XCTAssertTrue(ApplianceDetector.detect(in: ["Use a vegetable peeler"]).contains("peeler"))
        XCTAssertTrue(ApplianceDetector.detect(in: ["Weigh the flour on a kitchen scale"])
            .contains("kitchen scale"))
    }

    func testOvenInferredFromTemperature() {
        XCTAssertTrue(ApplianceDetector.detect(in: ["Bake at 350F for 20 minutes"]).contains("oven"))
    }

    func testNoEquipmentForASimpleNoCookRecipe() {
        XCTAssertTrue(ApplianceDetector.detectSpecialEquipment(
            in: ["Combine the yogurt and lemon juice", "Season with salt"]).isEmpty)
    }
}
