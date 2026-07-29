import Foundation

/// Where a result's text came from — governs how aggressively the output-side noise filter
/// runs. Social captions carry CTAs and hashtags; web pages and structured LLM output do not,
/// so the phrase filter must not run on them (it deletes real instructions there).
enum ContentSource: Sendable {
    case social         // Instagram/TikTok/YouTube caption or transcript
    case web            // a recipe web page (Schema.org / microdata / heuristic / text pass)
    case llmStructured  // structured by the LLM caption structurer
}

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
    /// Special equipment the cook might not own (air fryer, sous vide, pressure cooker) —
    /// the subset of `appliances` worth flagging before they start.
    var equipment: [String] = []
    var description: String?
    var confidence: Double  // 0.0 – 1.0
    var extractionMethod: String
    var isSubstitute: Bool = false       // true when result came from web search fallback
    var originalSourceURL: String?       // the video URL the user originally submitted
    var recipePageURL: String?           // the web page this recipe was extracted from
    var thumbnailURL: String?            // recipe photo URL (from Schema.org image field or oEmbed)
    var alternatives: [ExtractionResult] = []  // similar recipes collected when primary extraction fails
    var captionPreview: String?          // snippet of searched text shown in failure UI
    var authorHint: String?              // creator name/handle for failure UI copy
    var debugInfo: String?               // testing aid: which fetch routes ran + what they returned
    var wasTruncated: Bool = false       // caption arrived cut off (trailing "…"); show a banner
    var producedBy: ContentSource = .social  // gates output-side phrase filtering (invariant I2)
    var creatorSharesByDM: Bool = false  // caption funnels the recipe via DM; honest failure copy

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
    /// Component of a multi-part recipe this step belongs to ("Flatbread", "Steak") —
    /// set by the LLM structurer; nil for single-component recipes.
    var section: String?
}

/// Confidence thresholds for the extraction chain.
enum ConfidenceThreshold {
    /// Accept result and stop chain.
    static let accept: Double = 0.7
    /// Continue to next layer.
    static let reject: Double = 0.5

    /// True when a deterministic web result is weak enough to justify the LLM rescue.
    /// Inclusive of `reject` itself: HeuristicExtractor's weak tier scores exactly 0.5,
    /// and those marginal pages are precisely what the rescue exists for — a strict `<`
    /// made it unreachable for them.
    static func needsRescue(_ confidence: Double) -> Bool { confidence <= reject }
}
