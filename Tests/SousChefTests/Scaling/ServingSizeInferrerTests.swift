import XCTest
@testable import SousChef

/// When a recipe never says how many it serves, scaling has no base to work from. The review
/// screen asks the user — and offers this protein-led estimate so answering is one tap.
final class ServingSizeInferrerTests: XCTestCase {

    private let parser = IngredientParser()

    private func infer(_ lines: [String]) -> Int? {
        ServingSizeInferrer.infer(from: lines.map { parser.parse(raw: $0) })
    }

    func testDiscreteProteinsCountPerPerson() {
        XCTAssertEqual(infer(["2 chicken breasts", "1 cup rice"]), 2)
        XCTAssertEqual(infer(["4 ribeye steaks", "salt"]), 4)
        XCTAssertEqual(infer(["3 salmon fillets"]), 3)
    }

    func testBulkProteinUsesWeightPerPerson() {
        // 1 lb ground beef ≈ 454 g ÷ 170 g ≈ 2.7 → 3
        XCTAssertEqual(infer(["1 lb ground beef", "1 onion"]), 3)
        // 1 kg chicken ≈ 1000 g ÷ 170 ≈ 5.9 → 6
        XCTAssertEqual(infer(["1 kg chicken thighs"]), 6)
    }

    func testEggsCountAsTwoPerPerson() {
        XCTAssertEqual(infer(["4 eggs", "2 tbsp butter"]), 2)
    }

    func testNoProteinSignalReturnsNil() {
        // Nothing to reason from — the UI asks rather than inventing a number.
        XCTAssertNil(infer(["2 cups flour", "1 cup sugar", "1 tsp vanilla"]))
        XCTAssertNil(infer([]))
    }

    func testEstimateIsClampedToSaneRange() {
        // A catering-size quantity shouldn't propose an absurd serving count.
        let huge = infer(["50 lbs ground beef"])
        XCTAssertNotNil(huge)
        XCTAssertLessThanOrEqual(huge ?? 0, 12)
        XCTAssertGreaterThanOrEqual(huge ?? 0, 1)
    }

    func testLargestProteinSignalWins() {
        // Two proteins → portion for the one that feeds more people.
        XCTAssertEqual(infer(["6 chicken breasts", "2 eggs"]), 6)
    }
}
