import Foundation

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
        guard let url = Bundle.main.url(forResource: "diets", withExtension: "json",
                                        subdirectory: "Data"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([DietDefinition].self, from: data) else {
            return
        }
        diets = decoded
        for d in decoded { byId[d.id] = d }
    }
}
