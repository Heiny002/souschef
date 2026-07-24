import SwiftUI
import SwiftData
import os

@main
struct SousChefApp: App {
    let modelContainer: ModelContainer

    private static let logger = Logger(subsystem: "com.souschef.app", category: "persistence")

    // MARK: - Storage configuration
    //
    // Storage is local-only today. iCloud sync is intentionally OFF because it has two hard
    // prerequisites that aren't met yet — turning it on before both are done makes the
    // CloudKit store fail to open on every launch (previously swallowed by `try?`, so sync
    // looked "on" but silently wasn't):
    //
    //   1. CloudKit-conformant schema. NSPersistentCloudKitContainer forbids `@Attribute(.unique)`
    //      and requires every attribute to be optional or defaulted and every relationship to be
    //      optional. Recipe/Ingredient/CookingStep currently use `.unique` ids and non-optional
    //      to-many relationships (`ingredients`, `steps`). Making those changes is folded into the
    //      Phase 3 data-model migration.
    //   2. The iCloud capability (CloudKit service) enabled on the App ID for the shipping bundle
    //      id, with a matching provisioning profile, plus the CloudKit + aps-environment keys in
    //      SousChef.entitlements.
    //
    // To enable sync once both are done: flip `useCloudKit` to true. Everything below already
    // degrades gracefully if CloudKit is unavailable at runtime.
    private static let useCloudKit = false

    init() {
        modelContainer = Self.makeContainer()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(modelContainer)
    }

    // MARK: - Container construction

    /// Builds the model container with graceful degradation instead of the old
    /// `try?/try?/fatalError` ladder (audit H6): every failure is logged with its reason, and a
    /// store that can't open falls back one level rather than crash-looping the app on launch.
    private static func makeContainer() -> ModelContainer {
        let schema = Schema([Recipe.self, DinerProfile.self])
        let database: ModelConfiguration.CloudKitDatabase = useCloudKit ? .automatic : .none

        // 1. Preferred on-disk store (CloudKit-backed when enabled).
        let primary = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: database)
        do {
            return try ModelContainer(for: schema, configurations: [primary])
        } catch {
            logger.error("Primary store failed to open: \(error.localizedDescription, privacy: .public)")
        }

        // 2. If CloudKit was requested, retry the same data on disk without it — an iCloud
        //    problem (no account, entitlement, or network) must not cost the user local access.
        if useCloudKit {
            let localOnly = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
            if let container = try? ModelContainer(for: schema, configurations: [localOnly]) {
                logger.notice("CloudKit unavailable; running local-only this session.")
                return container
            }
        }

        // 3. Last resort: an in-memory store so the app still launches (degraded) instead of
        //    crash-looping on a corrupt file or a failed migration. Nothing persists this
        //    session, but the user isn't locked out and can re-import.
        logger.fault("On-disk store could not be opened; falling back to in-memory. Data will not persist this session.")
        let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        if let container = try? ModelContainer(for: schema, configurations: [inMemory]) {
            return container
        }

        // Unreachable unless the schema itself is invalid — a programming error in the @Model
        // definitions, not user state or a migration. Fail loudly with the schema in the message.
        fatalError("Could not initialize any ModelContainer for schema: \(schema)")
    }
}
