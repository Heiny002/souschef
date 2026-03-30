import Foundation

// MARK: - UnitMode

enum UnitMode: String, CaseIterable, Identifiable {
    case original = "Original"
    case metric   = "Grams"
    case imperial = "Oz / Lbs"
    case volume   = "Cups"
    case pieces   = "Pieces"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .original: return "doc.text"
        case .metric:   return "scalemass"
        case .imperial: return "scalemass.fill"
        case .volume:   return "cup.and.saucer"
        case .pieces:   return "number.circle"
        }
    }
}

// MARK: - IngredientConverter

/// Converts ingredient quantities between unit systems.
/// Falls back to rawText whenever conversion is impossible or ambiguous.
enum IngredientConverter {

    // MARK: - Public entry point

    static func display(_ ingredient: Ingredient, mode: UnitMode) -> String {
        guard mode != .original else { return ingredient.rawText }

        let qtyStr = ingredient.quantity ?? ""
        let rawUnit = (ingredient.unit ?? "").lowercased()
        let item = ingredient.item
        let prepSuffix = ingredient.preparation.map { ", \($0)" } ?? ""

        guard !qtyStr.isEmpty,
              let qty = parseQuantity(qtyStr),
              qty > 0,
              let srcUnit = canonicalUnit(rawUnit) else {
            return ingredient.rawText
        }

        let result: String?
        switch mode {
        case .original: result = nil
        case .metric:   result = toMetric(qty: qty, unit: srcUnit, item: item)
        case .imperial: result = toImperial(qty: qty, unit: srcUnit, item: item)
        case .volume:   result = toVolume(qty: qty, unit: srcUnit, item: item)
        case .pieces:   result = toPieces(qty: qty, unit: srcUnit, item: item)
        }

        guard let converted = result else { return ingredient.rawText }
        return "\(converted) \(item)\(prepSuffix)"
    }

    // MARK: - Quantity string → Double

    static func parseQuantity(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)

        // Mixed number "1 1/2"
        if let v = matchDouble(t, pattern: #"^(\d+)\s+(\d+)/(\d+)$"#, combine: { w, n, d in w + n/d }) {
            return v
        }
        // Simple fraction "3/4"
        if let v = matchDouble(t, pattern: #"^(\d+)/(\d+)$"#, combine: { _, n, d in n/d }) {
            return v
        }
        // Range "2-3" → midpoint
        if let v = matchDouble(t, pattern: #"^(\d+(?:\.\d+)?)-(\d+(?:\.\d+)?)$"#, combine: { _, lo, hi in (lo+hi)/2 }) {
            return v
        }
        return Double(t)
    }

    // MARK: - Canonical unit

    enum CanonicalUnit {
        case gram, kilogram, ounce, pound
        case milliliter, liter, teaspoon, tablespoon, cup, fluidOunce, pint, quart
        case count

        var isWeight: Bool {
            switch self { case .gram, .kilogram, .ounce, .pound: return true; default: return false }
        }
        var isVolume: Bool {
            switch self {
            case .milliliter, .liter, .teaspoon, .tablespoon, .cup, .fluidOunce, .pint, .quart:
                return true
            default: return false
            }
        }

        func toGrams(_ qty: Double) -> Double? {
            switch self {
            case .gram:      return qty
            case .kilogram:  return qty * 1000
            case .ounce:     return qty * 28.3495
            case .pound:     return qty * 453.592
            default:         return nil
            }
        }

        func toMilliliters(_ qty: Double) -> Double? {
            switch self {
            case .milliliter:  return qty
            case .liter:       return qty * 1000
            case .teaspoon:    return qty * 4.92892
            case .tablespoon:  return qty * 14.7868
            case .cup:         return qty * 236.588
            case .fluidOunce:  return qty * 29.5735
            case .pint:        return qty * 473.176
            case .quart:       return qty * 946.353
            default:           return nil
            }
        }
    }

    static func canonicalUnit(_ raw: String) -> CanonicalUnit? {
        switch raw {
        // Weight
        case "g", "gr", "gram", "grams":                          return .gram
        case "kg", "kilogram", "kilograms":                        return .kilogram
        case "oz", "ounce", "ounces":                              return .ounce
        case "lb", "lbs", "pound", "pounds":                       return .pound
        // Volume
        case "ml", "milliliter", "milliliters",
             "millilitre", "millilitres", "cc":                    return .milliliter
        case "l", "liter", "liters", "litre", "litres":            return .liter
        case "tsp", "t", "teaspoon", "teaspoons":                  return .teaspoon
        case "tbsp", "tbs", "tablespoon", "tablespoons":           return .tablespoon
        case "cup", "cups", "c":                                   return .cup
        case "fl oz", "fluid ounce", "fluid ounces", "fl. oz":    return .fluidOunce
        case "pint", "pints", "pt":                                return .pint
        case "quart", "quarts", "qt":                              return .quart
        // Count (no unit, or size/piece descriptors)
        case "", "piece", "pieces", "whole", "large", "medium",
             "small", "clove", "cloves", "slice", "slices",
             "sprig", "sprigs", "stalk", "stalks", "strip",
             "strips", "can", "cans", "head", "heads",
             "bunch", "link", "links", "fillet", "fillets",
             "rasher", "rashers":                                   return .count
        default: return nil
        }
    }

    // MARK: - Density table  (g per cup — keyed by ingredient name fragment)

    private static let densityTable: [(key: String, gPerCup: Double)] = [
        // Flours
        ("almond flour",       96),  ("bread flour",       127),
        ("cake flour",        114),  ("corn flour",        130),
        ("oat flour",         104),  ("rice flour",        158),
        ("whole wheat flour", 120),  ("flour",             120),
        ("cornstarch",        128),  ("cocoa powder",       85),
        ("baking soda",       230),  ("baking powder",     230),
        // Sugars
        ("powdered sugar",    120),  ("brown sugar",       220),
        ("granulated sugar",  200),  ("coconut sugar",     200),
        ("sugar",             200),
        // Grains & seeds
        ("oats",               90),  ("quinoa",            185),
        ("breadcrumbs",       108),  ("couscous",          180),
        ("rice",              190),
        // Dairy & fats
        ("butter",            227),  ("cream cheese",      232),
        ("sour cream",        230),  ("heavy cream",       238),
        ("half and half",     242),  ("milk",              240),
        ("yogurt",            245),  ("olive oil",         216),
        ("vegetable oil",     218),  ("coconut oil",       218),
        ("canola oil",        218),
        // Sweeteners
        ("maple syrup",       312),  ("honey",             340),
        ("corn syrup",        312),  ("molasses",          328),
        // Liquids
        ("water",             240),  ("broth",             240),
        ("stock",             240),  ("vinegar",           240),
        ("soy sauce",         240),  ("wine",              240),
        ("lemon juice",       244),  ("orange juice",      248),
        ("tomato sauce",      245),
        // Nuts & dried fruit
        ("walnuts",           117),  ("almonds",           143),
        ("cashews",           137),  ("peanuts",           146),
        ("pecans",            109),  ("raisins",           165),
        ("chocolate chips",   170),
        // Cheeses (shredded/grated)
        ("parmesan",          100),  ("cheddar",           113),
        ("mozzarella",        120),
        // Nut butters
        ("peanut butter",     258),  ("almond butter",     258),
        ("tahini",            240),
        // Pasta (dry)
        ("pasta",             100),
    ]

    // MARK: - Piece-weight table  (g per one piece)

    private static let pieceTable: [(keywords: [String], gPerPiece: Double, label: String)] = [
        // Poultry
        (["chicken thigh"],     160, "chicken thigh"),
        (["chicken breast"],    200, "chicken breast"),
        (["chicken leg", "drumstick"],   250, "chicken leg"),
        (["chicken wing"],       90, "chicken wing"),
        (["chicken"],           170, "chicken piece"),
        (["turkey breast"],     400, "turkey breast"),
        // Eggs
        (["egg"],                50, "egg"),
        // Aromatics
        (["garlic"],              5, "garlic clove"),
        (["shallot"],            30, "shallot"),
        (["onion"],             110, "onion"),
        // Vegetables
        (["tomato"],            150, "tomato"),
        (["cherry tomato"],      17, "cherry tomato"),
        (["potato"],            150, "potato"),
        (["sweet potato"],      130, "sweet potato"),
        (["carrot"],             61, "carrot"),
        (["celery"],             40, "celery stalk"),
        (["bell pepper"],       150, "bell pepper"),
        (["pepper"],            150, "pepper"),
        (["cucumber"],          200, "cucumber"),
        (["zucchini", "courgette"], 200, "zucchini"),
        (["mushroom"],           18, "mushroom"),
        (["avocado"],           150, "avocado"),
        (["broccoli floret"],    11, "floret"),
        (["jalapeño", "jalapeno"], 14, "jalapeño"),
        (["chilli", "chili"],    15, "chilli"),
        // Fruit
        (["banana"],            120, "banana"),
        (["apple"],             180, "apple"),
        (["lemon"],              80, "lemon"),
        (["lime"],               67, "lime"),
        (["orange"],            130, "orange"),
        (["strawberry"],         12, "strawberry"),
        (["date"],                7, "date"),
        (["fig"],                40, "fig"),
        // Bread & tortillas
        (["tortilla"],           45, "tortilla"),
        (["bread slice", "slice of bread"],  28, "slice of bread"),
        (["burger bun", "bun"],  43, "bun"),
        // Meat
        (["sausage"],            80, "sausage"),
        (["bacon strip", "bacon rasher", "strip of bacon"],  28, "strip of bacon"),
        (["anchovy"],             4, "anchovy"),
        // Fish
        (["salmon fillet", "fish fillet", "fillet"],  150, "fillet"),
    ]

    // MARK: - Density lookup

    private static func gPerCup(for item: String) -> Double? {
        let lower = item.lowercased()
        // Longest matching key wins
        return densityTable
            .filter { lower.contains($0.key) || $0.key.contains(lower) }
            .max(by: { $0.key.count < $1.key.count })
            .map { $0.gPerCup }
    }

    // MARK: - Piece lookup

    private static func pieceInfo(for item: String) -> (gPerPiece: Double, label: String)? {
        let lower = item.lowercased()
        for entry in pieceTable {
            if entry.keywords.contains(where: { lower.contains($0) || $0.contains(lower) }) {
                return (entry.gPerPiece, entry.label)
            }
        }
        return nil
    }

    // MARK: - Intermediate conversions

    /// Convert any source unit to grams.
    private static func inGrams(qty: Double, unit: CanonicalUnit, item: String) -> Double? {
        if let g = unit.toGrams(qty) { return g }
        if let ml = unit.toMilliliters(qty), let density = gPerCup(for: item) {
            return ml * density / 236.588
        }
        if unit == .count, let piece = pieceInfo(for: item) {
            return qty * piece.gPerPiece
        }
        return nil
    }

    /// Convert any source unit to milliliters.
    private static func inMilliliters(qty: Double, unit: CanonicalUnit, item: String) -> Double? {
        if let ml = unit.toMilliliters(qty) { return ml }
        if let g = inGrams(qty: qty, unit: unit, item: item), let density = gPerCup(for: item) {
            return g / density * 236.588
        }
        return nil
    }

    // MARK: - Conversion targets

    static func toMetric(qty: Double, unit: CanonicalUnit, item: String) -> String? {
        guard let g = inGrams(qty: qty, unit: unit, item: item) else { return nil }
        if g >= 1000 { return "\(formatDecimal(g / 1000))kg" }
        return "\(formatDecimal(g))g"
    }

    static func toImperial(qty: Double, unit: CanonicalUnit, item: String) -> String? {
        // Already imperial weight — just reformat
        if unit == .ounce { return "\(formatFraction(qty)) oz" }
        if unit == .pound {
            let lbs = Int(qty)
            let remOz = (qty - Double(lbs)) * 16
            return remOz < 0.25 ? "\(lbs) lb" : "\(lbs) lb \(formatFraction(remOz)) oz"
        }

        guard let g = inGrams(qty: qty, unit: unit, item: item) else { return nil }
        let oz = g / 28.3495
        if oz < 1   { return "\(formatFraction(oz)) oz" }
        if oz < 16  { return "\(formatFraction(oz)) oz" }
        let lbs = oz / 16
        let wholeLbs = Int(lbs)
        let remOz = (lbs - Double(wholeLbs)) * 16
        return remOz < 0.25 ? "\(wholeLbs) lb" : "\(wholeLbs) lb \(formatFraction(remOz)) oz"
    }

    static func toVolume(qty: Double, unit: CanonicalUnit, item: String) -> String? {
        guard let ml = inMilliliters(qty: qty, unit: unit, item: item) else { return nil }
        return formatVolume(ml: ml)
    }

    /// Returns a count string like "~8" or "~1". Returns nil if ingredient is already a count
    /// or if no piece-weight data exists.
    static func toPieces(qty: Double, unit: CanonicalUnit, item: String) -> String? {
        guard unit != .count else { return nil }   // Already expressed as pieces
        guard let g = inGrams(qty: qty, unit: unit, item: item),
              let piece = pieceInfo(for: item) else { return nil }
        let count = (g / piece.gPerPiece).rounded()
        guard count >= 1 else { return nil }
        return "~\(Int(count))"
    }

    // MARK: - Formatting

    static func formatVolume(ml: Double) -> String {
        let cups = ml / 236.588
        let tbsp = ml / 14.7868
        let tsp  = ml / 4.92892

        if tsp < 0.4 { return "pinch" }
        if cups >= 0.125 {
            return "\(formatFraction(cups)) \(abs(cups - 1) < 0.05 ? "cup" : "cups")"
        }
        if tbsp >= 0.5 { return "\(formatFraction(tbsp)) tbsp" }
        return "\(formatFraction(tsp)) tsp"
    }

    /// Format a Double as a cooking-friendly decimal (no trailing zeros).
    static func formatDecimal(_ v: Double) -> String {
        let rounded = (v * 10).rounded() / 10
        if rounded == rounded.rounded() { return "\(Int(rounded))" }
        return String(format: "%.1f", rounded)
    }

    /// Format a Double as a vulgar fraction string using common cooking fractions.
    static func formatFraction(_ v: Double) -> String {
        let fracs: [(Double, String)] = [
            (0.125, "⅛"), (0.25, "¼"), (0.333, "⅓"),
            (0.5,   "½"), (0.667, "⅔"), (0.75, "¾"),
            (0.875, "⅞"),
        ]
        let whole = Int(v)
        let frac = v - Double(whole)

        guard frac > 0.06 else {
            return whole > 0 ? "\(whole)" : "0"
        }
        // Snap to nearest cooking fraction
        let snapped = fracs.min { abs($0.0 - frac) < abs($1.0 - frac) }
        let fracStr = snapped?.1 ?? String(format: "%.1f", frac)
        return whole > 0 ? "\(whole) \(fracStr)" : fracStr
    }

    // MARK: - Regex helper

    private static func matchDouble(
        _ s: String,
        pattern: String,
        combine: (Double, Double, Double) -> Double
    ) -> Double? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else {
            return nil
        }
        let vals: [Double] = (1...m.numberOfRanges - 1).compactMap { i in
            guard let r = Range(m.range(at: i), in: s) else { return nil }
            return Double(s[r])
        }
        guard vals.count >= 2 else { return nil }
        let a = vals[0], b = vals[1], c = vals.count > 2 ? vals[2] : 0
        return combine(a, b, c)
    }
}
