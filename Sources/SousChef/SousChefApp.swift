import SwiftUI
import SwiftData

@main
struct SousChefApp: App {
    let modelContainer: ModelContainer

    init() {
        let schema = Schema([Recipe.self, DinerProfile.self])
        // Attempt CloudKit-backed storage; fall back to local-only if CloudKit
        // is unavailable (e.g. no signed development team in simulator builds).
        let cloudConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .automatic)
        let localConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        if let cloud = try? ModelContainer(for: schema, configurations: [cloudConfig]) {
            modelContainer = cloud
        } else if let local = try? ModelContainer(for: schema, configurations: [localConfig]) {
            modelContainer = local
        } else {
            fatalError("Failed to initialize ModelContainer")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(modelContainer)
    }
}

