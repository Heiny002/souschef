import XCTest
import SwiftData
@testable import SousChef

/// H6 was, at root, a model container that couldn't open — silently at runtime. This guards
/// the schema the app ships: if the @Model definitions ever regress into something SwiftData
/// can't build (a bad relationship, an unrepresentable type), this fails in CI instead of only
/// showing up as a launch-time fallback on a device.
final class PersistenceTests: XCTestCase {

    private var schema: Schema {
        Schema([Recipe.self, DinerProfile.self])
    }

    @MainActor
    func testEditSnapshotRoundTripsAnExistingRecipe() throws {
        // Editing a library recipe reuses the review form, so the recipe must survive the
        // trip into ExtractionResult and back with its content and component sections intact.
        let recipe = Recipe(title: "Steak Wraps", sourceURL: "https://example.com/x",
                            sourceType: "instagram")
        recipe.recipeYield = "4 servings"
        let ing = Ingredient(item: "flank steak", rawText: "1 lb flank steak", order: 0)
        ing.section = "Steak"
        recipe.ingredients = [ing]
        recipe.steps = [
            CookingStep(order: 1, instruction: "Bake the flatbreads.", rawText: "", section: "Flatbread"),
            CookingStep(order: 2, instruction: "Sear the steak.", rawText: "", section: "Steak"),
        ]

        let snapshot = ReviewView.result(from: recipe)
        XCTAssertEqual(snapshot.title, "Steak Wraps")
        XCTAssertEqual(snapshot.recipeYield, "4 servings")
        XCTAssertEqual(snapshot.ingredients.first?.text, "1 lb flank steak")
        XCTAssertEqual(snapshot.ingredients.first?.section, "Steak")
        XCTAssertEqual(snapshot.steps.map(\.section), ["Flatbread", "Steak"])
        XCTAssertEqual(snapshot.steps.first?.text, "Bake the flatbreads.")
    }

    func testSchemaBuildsInMemoryContainer() throws {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        XCTAssertNoThrow(try ModelContainer(for: schema, configurations: [config]))
    }

    @MainActor
    func testCanInsertAndFetchARecipeWithChildren() throws {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext

        let recipe = Recipe(title: "Test Bake", sourceType: "web")
        let ingredient = Ingredient(item: "flour", rawText: "2 cups flour", order: 0)
        let step = CookingStep(order: 1, instruction: "Mix.", rawText: "Mix.")
        recipe.ingredients.append(ingredient)
        recipe.steps.append(step)
        context.insert(recipe)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Recipe>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.ingredients.count, 1)
        XCTAssertEqual(fetched.first?.steps.count, 1)
    }
}
