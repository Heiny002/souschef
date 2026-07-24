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
