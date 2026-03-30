import SwiftUI
import SwiftData

@main
struct SousChefApp: App {
    let modelContainer: ModelContainer

    init() {
        let schema = Schema([Recipe.self, DinerProfile.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .automatic)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to initialize ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(modelContainer)
    }
}
