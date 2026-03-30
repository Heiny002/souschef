import Foundation

/// SC-022: Detects kitchen appliances and tools from recipe text.
/// Dictionary of ~150 terms matched against ingredient + instruction text.
enum ApplianceDetector {

    static func detect(in strings: [String]) -> [String] {
        let combined = strings.joined(separator: " ").lowercased()
        var found = Set<String>()

        // Check temperature patterns first (implies oven)
        let ovenPattern = try? NSRegularExpression(pattern: #"\d{2,3}\s*°?\s*[fFcC](?:\s|$|,|\.|degree)"#)
        let range = NSRange(combined.startIndex..., in: combined)
        if ovenPattern?.firstMatch(in: combined, range: range) != nil {
            found.insert("oven")
        }
        // "preheat" also implies oven
        if combined.contains("preheat") { found.insert("oven") }
        // "bake" strongly implies oven
        if combined.contains("bake") || combined.contains("baking sheet") || combined.contains("roast") {
            found.insert("oven")
        }

        // Check each entry in the dictionary
        for entry in dictionary {
            for keyword in entry.keywords {
                if combined.contains(keyword) {
                    found.insert(entry.name)
                    break
                }
            }
        }

        return found.sorted()
    }

    // MARK: - Dictionary

    private struct Entry {
        let name: String
        let keywords: [String]
    }

    private static let dictionary: [Entry] = [
        // Stovetop
        Entry(name: "stovetop", keywords: ["stovetop", "stove top", "burner", "gas stove", "electric stove", "induction"]),
        Entry(name: "skillet", keywords: ["skillet", "frying pan", "fry pan", "cast iron pan"]),
        Entry(name: "saucepan", keywords: ["saucepan", "sauce pan", "small pot"]),
        Entry(name: "stockpot", keywords: ["stockpot", "stock pot", "large pot", "dutch oven"]),
        Entry(name: "wok", keywords: ["wok"]),
        Entry(name: "griddle", keywords: ["griddle"]),
        Entry(name: "grill", keywords: ["grill", "barbecue", "bbq", "charcoal grill", "gas grill", "grill pan"]),

        // Oven appliances
        Entry(name: "oven", keywords: ["oven", "baking dish", "roasting pan", "bake at", "roasting rack"]),
        Entry(name: "broiler", keywords: ["broil", "broiler"]),
        Entry(name: "toaster oven", keywords: ["toaster oven"]),
        Entry(name: "air fryer", keywords: ["air fryer", "air-fryer", "airfryer"]),

        // Countertop appliances
        Entry(name: "blender", keywords: ["blender", "blend until smooth", "blend", "vitamix", "blendtec"]),
        Entry(name: "immersion blender", keywords: ["immersion blender", "stick blender", "hand blender"]),
        Entry(name: "food processor", keywords: ["food processor", "pulse until"]),
        Entry(name: "stand mixer", keywords: ["stand mixer", "kitchenaid", "kitchen aid", "mixer bowl", "paddle attachment", "dough hook", "whisk attachment"]),
        Entry(name: "hand mixer", keywords: ["hand mixer", "electric mixer", "beat with mixer"]),
        Entry(name: "instant pot", keywords: ["instant pot", "pressure cooker", "pressure cook", "high pressure", "natural release", "quick release"]),
        Entry(name: "slow cooker", keywords: ["slow cooker", "crockpot", "crock pot", "low and slow", "cook on low"]),
        Entry(name: "rice cooker", keywords: ["rice cooker"]),
        Entry(name: "bread machine", keywords: ["bread machine", "bread maker"]),
        Entry(name: "waffle iron", keywords: ["waffle iron", "waffle maker"]),
        Entry(name: "panini press", keywords: ["panini press", "panini maker", "sandwich press"]),
        Entry(name: "ice cream maker", keywords: ["ice cream maker", "ice cream machine", "churn"]),
        Entry(name: "dehydrator", keywords: ["dehydrator", "dehydrate"]),
        Entry(name: "sous vide", keywords: ["sous vide", "immersion circulator"]),
        Entry(name: "deep fryer", keywords: ["deep fryer", "deep fry", "deep-fry", "hot oil"]),

        // Small tools
        Entry(name: "microwave", keywords: ["microwave", "microwave-safe", "microwaveable"]),
        Entry(name: "toaster", keywords: ["toaster", "toast until"]),
        Entry(name: "juicer", keywords: ["juicer", "juice extractor", "citrus juicer"]),
        Entry(name: "coffee grinder", keywords: ["coffee grinder", "spice grinder"]),
        Entry(name: "mandoline", keywords: ["mandoline", "mandolin slicer"]),
        Entry(name: "spiralizer", keywords: ["spiralizer", "spiralize"]),
        Entry(name: "meat grinder", keywords: ["meat grinder", "grind the meat"]),
        Entry(name: "mortar and pestle", keywords: ["mortar and pestle", "mortar & pestle"]),
        Entry(name: "thermometer", keywords: ["instant-read thermometer", "meat thermometer", "candy thermometer", "internal temperature"]),
        Entry(name: "kitchen scale", keywords: ["kitchen scale", "weigh", "grams"]),
        Entry(name: "rolling pin", keywords: ["rolling pin", "roll out"]),
        Entry(name: "pastry cutter", keywords: ["pastry cutter", "pastry blender", "cut in butter"]),
        Entry(name: "zester", keywords: ["zester", "microplane", "zest of"]),
        Entry(name: "piping bag", keywords: ["piping bag", "pastry bag", "pipe the"]),
        Entry(name: "kitchen torch", keywords: ["kitchen torch", "blow torch", "brûlée"]),
        Entry(name: "steamer", keywords: ["steamer", "steam basket", "bamboo steamer", "steam the"]),
        Entry(name: "double boiler", keywords: ["double boiler", "bain marie", "bowl over simmering water"]),
        Entry(name: "colander", keywords: ["colander", "drain the", "strain through"]),
        Entry(name: "salad spinner", keywords: ["salad spinner"]),
        Entry(name: "can opener", keywords: ["can opener"]),
        Entry(name: "box grater", keywords: ["box grater", "cheese grater", "grate the"]),
        Entry(name: "peeler", keywords: ["peeler", "vegetable peeler", "peel the"]),
    ]
}
