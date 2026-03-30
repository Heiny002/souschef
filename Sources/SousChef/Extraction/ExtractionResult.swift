import Foundation

/// A partially or fully extracted recipe from one layer of the extraction chain.
struct ExtractionResult {
    var title: String?
    var recipeYield: String?
    var prepTime: Int?     // seconds
    var cookTime: Int?     // seconds
    var totalTime: Int?    // seconds
    var ingredients: [RawIngredient]
    var steps: [RawStep]
    var appliances: [String]
    var description: String?
    var confidence: Double  // 0.0 – 1.0
    var extractionMethod: String

    init(extractionMethod: String) {
        self.ingredients = []
        self.steps = []
        self.appliances = []
        self.confidence = 0.0
        self.extractionMethod = extractionMethod
    }

    /// Whether this result has enough data to be considered a recipe.
    var isViable: Bool {
        title != nil && ingredients.count >= 1 && steps.count >= 1
    }
}

struct RawIngredient {
    var text: String
    var section: String?
}

struct RawStep {
    var order: Int
    var text: String
}

/// Confidence thresholds for the extraction chain.
enum ConfidenceThreshold {
    /// Accept result and stop chain.
    static let accept: Double = 0.7
    /// Continue to next layer.
    static let reject: Double = 0.5
}
