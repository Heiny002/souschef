import Foundation

/// SC-041: Food entity dictionary — 100+ curated items with aliases, categories, allergens.
/// Loaded from bundled food-dictionary.json at app start.
struct FoodEntry: Decodable {
    let name: String
    let aliases: [String]
    let categories: [String]
    let commonAllergens: [String]
}

final class FoodDictionary: @unchecked Sendable {
    static let shared = FoodDictionary()

    private var entries: [FoodEntry] = []
    /// Flat lookup: all known names + aliases → canonical FoodEntry
    private var lookup: [String: FoodEntry] = [:]

    private init() {
        load()
    }

    // MARK: - Lookup

    /// Exact match on name or any alias (case-insensitive).
    func find(name: String) -> FoodEntry? {
        lookup[name.lowercased()]
    }

    /// Fuzzy match using Levenshtein distance — threshold 0.85 similarity.
    func fuzzyFind(name: String) -> FoodEntry? {
        let lowered = name.lowercased()
        if let exact = lookup[lowered] { return exact }

        // Find closest match
        var bestEntry: FoodEntry?
        var bestScore: Double = 0.0

        for (key, entry) in lookup {
            let score = similarity(lowered, key)
            if score > bestScore && score >= 0.85 {
                bestScore = score
                bestEntry = entry
            }
        }
        return bestEntry
    }

    /// All entries in a given category.
    func entries(inCategory category: String) -> [FoodEntry] {
        entries.filter { $0.categories.contains(category.lowercased()) }
    }

    // MARK: - Loading

    private func load() {
        guard let url = Bundle.main.url(forResource: "food-dictionary", withExtension: "json",
                                        subdirectory: "Data"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([FoodEntry].self, from: data) else {
            return
        }
        entries = decoded
        for entry in decoded {
            lookup[entry.name.lowercased()] = entry
            for alias in entry.aliases {
                lookup[alias.lowercased()] = entry
            }
        }
    }

    // MARK: - Levenshtein similarity

    private func similarity(_ a: String, _ b: String) -> Double {
        let la = Array(a), lb = Array(b)
        let m = la.count, n = lb.count
        guard m > 0 && n > 0 else { return 0.0 }
        // Bail early if length difference is too large
        if abs(m - n) > max(m, n) / 3 { return 0.0 }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        for i in 1...m {
            for j in 1...n {
                if la[i-1] == lb[j-1] {
                    dp[i][j] = dp[i-1][j-1]
                } else {
                    dp[i][j] = 1 + min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1])
                }
            }
        }
        let distance = dp[m][n]
        let maxLen = max(m, n)
        return 1.0 - Double(distance) / Double(maxLen)
    }
}
