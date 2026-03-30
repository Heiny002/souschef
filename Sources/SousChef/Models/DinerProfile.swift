import Foundation
import SwiftData

@Model
final class DinerProfile {
    var id: UUID
    var name: String
    var diets: [String]
    var customRestrictions: [String]   // UI label: "Ingredients to Avoid"
    var allergies: [String]            // UI label: "Restricted Ingredients/Allergies"
    var favoriteFoods: [String]
    var dateCreated: Date

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.diets = []
        self.customRestrictions = []
        self.allergies = []
        self.favoriteFoods = []
        self.dateCreated = Date()
    }
}
