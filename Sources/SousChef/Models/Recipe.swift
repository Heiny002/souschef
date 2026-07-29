import Foundation
import SwiftData

@Model
final class Recipe {
    @Attribute(.unique) var id: UUID
    var title: String
    var sourceURL: String?
    var sourceType: String       // "web", "tiktok", "instagram", "youtube", "manual"
    var thumbnailURL: String?    // recipe photo URL captured at import (optional → lightweight migration)
    var recipeYield: String?
    /// The serving count the recipe's amounts are written for, when the user has confirmed it
    /// (or it was parsed unambiguously). Replaces silently assuming "serves 4" for a recipe
    /// with no yield. Optional with a nil default → SwiftData lightweight migration.
    var confirmedServings: Int? = nil
    var prepTime: Int?           // seconds
    var cookTime: Int?           // seconds
    var totalTime: Int?          // seconds
    var appliances: [String]
    var recipeDescription: String?
    var extractionConfidence: Double
    var extractionMethod: String // e.g. "schema-org-jsonld", "heuristic", "llm"
    var userVerified: Bool
    var dateAdded: Date

    @Relationship(deleteRule: .cascade, inverse: \Ingredient.recipe)
    var ingredients: [Ingredient]

    @Relationship(deleteRule: .cascade, inverse: \CookingStep.recipe)
    var steps: [CookingStep]

    init(
        title: String,
        sourceURL: String? = nil,
        sourceType: String = "web",
        extractionConfidence: Double = 0.0,
        extractionMethod: String = "unknown"
    ) {
        self.id = UUID()
        self.title = title
        self.sourceURL = sourceURL
        self.sourceType = sourceType
        self.appliances = []
        self.extractionConfidence = extractionConfidence
        self.extractionMethod = extractionMethod
        self.userVerified = false
        self.dateAdded = Date()
        self.ingredients = []
        self.steps = []
    }
}

@Model
final class Ingredient {
    @Attribute(.unique) var id: UUID
    var quantity: String?
    var unit: String?
    var item: String
    var preparation: String?
    var section: String?
    var rawText: String
    var order: Int

    var recipe: Recipe?

    init(item: String, rawText: String, order: Int = 0) {
        self.id = UUID()
        self.item = item
        self.rawText = rawText
        self.order = order
    }
}

@Model
final class CookingStep {
    @Attribute(.unique) var id: UUID
    var order: Int
    var instruction: String
    var duration: Int?           // seconds
    var temperature: String?
    var timerLabel: String?
    var rawText: String
    /// Component of a multi-part recipe this step belongs to ("Flatbread", "Steak").
    /// Cook Mode shows it as a heading above the step. Inline default keeps SwiftData's
    /// lightweight migration working for recipes saved before this field existed.
    var section: String? = nil

    var recipe: Recipe?

    init(order: Int, instruction: String, rawText: String, section: String? = nil) {
        self.id = UUID()
        self.order = order
        self.instruction = instruction
        self.rawText = rawText
        self.section = section
    }
}
