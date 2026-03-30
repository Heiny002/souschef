import Foundation
import SwiftData

@Model
final class DinerProfile {
    var id: UUID
    var name: String
    var diets: [String]
    var customRestrictions: [String]
    var allergies: [String]
    var dateCreated: Date

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.diets = []
        self.customRestrictions = []
        self.allergies = []
        self.dateCreated = Date()
    }
}
