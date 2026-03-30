import Foundation

/// SC-054: Diet-aware substitution dictionary — 300+ entries keyed by ingredient.
/// Organized by restriction reason (not generic swaps).
struct SubstitutionEntry: Decodable {
    let ingredient: String
    let substitutions: [ReasonedSubstitution]
}

struct ReasonedSubstitution: Decodable {
    let reason: String
    /// nil means the ingredient is simply not allowed on this diet (no substitute).
    let options: [String]?
}

// MARK: - SubstitutionLibrary

final class SubstitutionLibrary: @unchecked Sendable {
    static let shared = SubstitutionLibrary()

    private var entries: [SubstitutionEntry] = []
    /// Flat lookup: ingredient name (lowercased) → SubstitutionEntry
    private var lookup: [String: SubstitutionEntry] = [:]

    private init() { load() }

    /// Find substitutions for an ingredient and a specific diet.
    /// Returns the options array (nil = not allowed, empty array = no match found).
    func options(for ingredient: String, diet dietId: String) -> [String]? {
        let key = ingredient.lowercased()
        guard let entry = lookup[key] ?? fuzzyLookup(key) else { return [] }
        guard let match = entry.substitutions.first(where: { $0.reason == dietId || $0.reason == mapDietId(dietId) }) else {
            return []
        }
        return match.options
    }

    /// All substitutions for a given ingredient.
    func entry(for ingredient: String) -> SubstitutionEntry? {
        let key = ingredient.lowercased()
        return lookup[key] ?? fuzzyLookup(key)
    }

    // MARK: - Private

    private func load() {
        guard let url = Bundle.main.url(forResource: "substitutions", withExtension: "json",
                                        subdirectory: "Data"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SubstitutionEntry].self, from: data) else {
            return
        }
        entries = decoded
        for entry in decoded {
            lookup[entry.ingredient.lowercased()] = entry
        }
    }

    /// Simple word-overlap fallback for compound ingredient names.
    private func fuzzyLookup(_ key: String) -> SubstitutionEntry? {
        let words = key.split(separator: " ").map(String.init)
        for word in words.reversed() {
            if let found = lookup[word] { return found }
        }
        return nil
    }

    /// Map diet id to the reason string used in substitutions.json.
    private func mapDietId(_ id: String) -> String {
        switch id {
        case "gluten-free":        return "gluten-free"
        case "dairy-free":         return "dairy-free"
        case "nut-free":           return "nut-free"
        case "low-sodium":         return "low-sodium"
        case "diabetic-friendly":  return "diabetic-friendly"
        default: return id
        }
    }
}
