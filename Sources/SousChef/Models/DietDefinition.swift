import Foundation
import os

/// SC-050: Diet definitions — decoded from bundled diets.json.
/// 17 built-in diets with restriction lists, hidden triggers, and optional macro targets.
struct MacroTargets: Decodable {
    let maxCarbsGrams: Int?
    let minFatPercent: Int?
    let minProteinPercent: Int?
    let maxSodiumMg: Int?
    let targetFiberGrams: Int?
}

struct DietDefinition: Decodable, Identifiable {
    let id: String
    let name: String
    let restrictedCategories: [String]
    let restrictedIngredients: [String]
    let hiddenRestrictions: [String]
    let allowedCategories: [String]
    let conditionalNotes: String
    let isElimination: Bool
    let macroTargets: MacroTargets?
}

// MARK: - DietLibrary

final class DietLibrary: @unchecked Sendable {
    static let shared = DietLibrary()

    private(set) var diets: [DietDefinition] = []
    /// Fast lookup by id
    private var byId: [String: DietDefinition] = [:]

    private init() { load() }

    func diet(id: String) -> DietDefinition? { byId[id] }

    private func load() {
        // The JSON lives under a "Data/" folder reference in the bundle, but fall
        // back to the bundle root so a resource-packaging change can't silently
        // disable the entire diet/allergy safety feature (see docs/AUDIT.md).
        guard let url = Bundle.main.url(forResource: "diets", withExtension: "json", subdirectory: "Data")
                ?? Bundle.main.url(forResource: "diets", withExtension: "json") else {
            Self.logger.critical("diets.json not found in bundle — diet checks are inert")
            assertionFailure("diets.json not found in bundle — diet/allergy checks will be inert")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([DietDefinition].self, from: data)
            diets = decoded
            for d in decoded { byId[d.id] = d }
        } catch {
            Self.logger.critical("Failed to load diets.json: \(error.localizedDescription, privacy: .public)")
            assertionFailure("Failed to load diets.json: \(error)")
        }
    }

    private static let logger = Logger(subsystem: "com.souschef.app", category: "DietLibrary")

    /// True once the diet dataset has loaded. A safety surface must never claim
    /// "Compatible" when this is false.
    var isLoaded: Bool { !diets.isEmpty }
}
