import Foundation
import os

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

    private static let logger = Logger(subsystem: "com.souschef.app", category: "SubstitutionLibrary")

    private func load() {
        // Prefer the "Data/" folder reference, fall back to the bundle root so a
        // resource-packaging change can't silently empty the substitution table.
        guard let url = Bundle.main.url(forResource: "substitutions", withExtension: "json", subdirectory: "Data")
                ?? Bundle.main.url(forResource: "substitutions", withExtension: "json") else {
            Self.logger.critical("substitutions.json not found in bundle — no substitutions available")
            assertionFailure("substitutions.json not found in bundle")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([SubstitutionEntry].self, from: data)
            entries = decoded
            for entry in decoded {
                lookup[entry.ingredient.lowercased()] = entry
            }
        } catch {
            Self.logger.critical("Failed to load substitutions.json: \(error.localizedDescription, privacy: .public)")
            assertionFailure("Failed to load substitutions.json: \(error)")
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
