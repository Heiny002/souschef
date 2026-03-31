import Foundation

/// A partially or fully extracted recipe from one layer of the extraction chain.
struct ExtractionResult: Sendable {
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
    var isSubstitute: Bool = false       // true when result came from web search fallback
    var originalSourceURL: String?       // the video URL the user originally submitted
    var thumbnailURL: String?            // recipe photo URL (from Schema.org image field or oEmbed)
    var alternatives: [ExtractionResult] = []  // similar recipes collected when primary extraction fails
    var captionPreview: String?          // snippet of searched text shown in failure UI
    var authorHint: String?              // creator name/handle for failure UI copy

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

struct RawIngredient: Sendable {
    var text: String
    var section: String?
}

struct RawStep: Sendable {
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
