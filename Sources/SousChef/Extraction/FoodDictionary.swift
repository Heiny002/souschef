import Foundation

/// SC-041 / SC-051: Food entity dictionary — 100+ curated items with aliases, categories, allergens,
/// and computed dietary flags (FODMAP, glycemic, sodium, processed).
/// Loaded from bundled food-dictionary.json at app start.
struct FoodEntry: Decodable {
    let name: String
    let aliases: [String]
    let categories: [String]
    let commonAllergens: [String]

    // MARK: - SC-051 Dietary flags (computed from name/categories)

    /// High-FODMAP items that trigger IBS symptoms.
    var isHighFODMAP: Bool {
        let highFODMAP: Set<String> = [
            "garlic", "onion", "shallot", "wheat", "apple", "pear", "honey",
            "milk", "heavy cream", "yogurt", "soft cheese", "chickpeas", "lentils",
            "kidney beans", "black beans", "white beans", "cauliflower", "mushroom",
            "avocado", "mango", "watermelon", "peach", "plum", "cherry"
        ]
        return highFODMAP.contains(name) ||
               categories.contains("dairy") && (name.contains("cream") || name == "milk" || name == "yogurt")
    }

    /// High-glycemic-index items that spike blood sugar.
    var isHighGlycemic: Bool {
        let highGI: Set<String> = [
            "sugar", "brown sugar", "powdered sugar", "honey", "maple syrup",
            "corn syrup", "agave", "rice", "bread", "potato", "corn", "banana",
            "pasta", "oats", "chocolate", "beer"
        ]
        return highGI.contains(name) || categories.contains("sweetener")
    }

    /// High-sodium items (>300mg per typical serving).
    var isHighSodium: Bool {
        let highSodium: Set<String> = [
            "soy sauce", "fish sauce", "oyster sauce", "hoisin sauce", "miso",
            "salt", "anchovies", "capers", "olives", "pickles", "stock"
        ]
        return highSodium.contains(name)
    }

    /// Processed / ultra-processed items.
    var isProcessed: Bool {
        let processed: Set<String> = [
            "soy sauce", "fish sauce", "oyster sauce", "hoisin sauce", "ketchup",
            "mayonnaise", "sriracha", "bread", "pasta", "pork", "stock"
        ]
        return processed.contains(name) || categories.contains("condiment") || categories.contains("processed")
    }
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
