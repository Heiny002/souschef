import Foundation

// MARK: - Units

/// A measurement system — drives how a scaled amount is formatted (imperial → culinary
/// fractions, metric → rounded decimals). `.neutral` covers counts/containers (eggs, cloves).
enum MeasurementSystem: String, Sendable, CaseIterable {
    case metric, imperial, neutral
}

/// What a unit measures — used to decide how an amount is formatted (counts round to whole
/// numbers; volume/mass follow their system's rules).
enum MeasurementDimension: String, Sendable {
    case volume, mass, count
}

/// A cooking unit of measure with the data needed to scale, format and pluralize it.
/// `dimension` drives count-vs-measure formatting, `system` drives metric-decimal-vs-imperial-
/// fraction formatting. `baseFactor` (value → the dimension's base unit: ml for volume, g for
/// mass, 1 for counts) is reference data for the Phase 3 unification with `IngredientConverter`,
/// which already owns unit CONVERSION (including density-based weight↔volume) — scaling
/// deliberately does not duplicate that here.
struct MeasurementUnit: Sendable, Equatable {
    let canonical: String            // normalized name — matches IngredientParser's output
    let dimension: MeasurementDimension
    let system: MeasurementSystem
    let baseFactor: Double
    let singular: String
    let plural: String

    /// Look up a unit by IngredientParser's normalized name ("cup", "tablespoon", "clove"…).
    static func named(_ normalized: String?) -> MeasurementUnit? {
        guard let normalized else { return nil }
        return UnitRegistry.byName[normalized.lowercased()]
    }
}

/// The known units. Volume/mass are convertible; count nouns are not.
enum UnitRegistry {
    // Convertible units. Volume base = milliliter, mass base = gram.
    static let convertible: [MeasurementUnit] = [
        // Volume — imperial
        u("teaspoon", "teaspoons", .volume, .imperial, 4.928922),
        u("tablespoon", "tablespoons", .volume, .imperial, 14.786765),
        u("fluid ounce", "fluid ounces", .volume, .imperial, 29.573530),
        u("cup", "cups", .volume, .imperial, 236.588200),
        u("pint", "pints", .volume, .imperial, 473.176500),
        u("quart", "quarts", .volume, .imperial, 946.352900),
        u("gallon", "gallons", .volume, .imperial, 3785.411800),
        // Volume — metric
        u("milliliter", "milliliters", .volume, .metric, 1),
        u("liter", "liters", .volume, .metric, 1000),
        // Mass — imperial
        u("ounce", "ounces", .mass, .imperial, 28.349520),
        u("pound", "pounds", .mass, .imperial, 453.592400),
        // Mass — metric
        u("gram", "grams", .mass, .metric, 1),
        u("kilogram", "kilograms", .mass, .metric, 1000),
    ]

    /// Container / count nouns. They scale (2 cloves × 2 = 4 cloves) but never convert.
    static let countNouns: [String] = [
        "clove", "can", "slice", "piece", "sprig", "pinch", "dash", "drop",
        "bunch", "stalk", "head", "package", "box", "bag", "stick", "fillet",
    ]

    static let byName: [String: MeasurementUnit] = {
        var map: [String: MeasurementUnit] = [:]
        for unit in convertible { map[unit.canonical] = unit }
        for noun in countNouns {
            map[noun] = MeasurementUnit(
                canonical: noun, dimension: .count, system: .neutral, baseFactor: 1,
                singular: noun, plural: noun + "s")
        }
        return map
    }()

    private static func u(_ canonical: String, _ plural: String,
                          _ dimension: MeasurementDimension, _ system: MeasurementSystem,
                          _ baseFactor: Double) -> MeasurementUnit {
        MeasurementUnit(canonical: canonical, dimension: dimension, system: system,
                        baseFactor: baseFactor, singular: canonical, plural: plural)
    }
}

// MARK: - Quantity

/// A numeric amount: a single value or a range (2–3), with an optional unit. A nil unit is a
/// bare count ("3 eggs"), where the noun lives on the ingredient itself. This is the structured
/// form that makes serving-size scaling pure arithmetic.
struct Quantity: Sendable, Equatable {
    var low: Double
    var high: Double?                 // nil = single value; non-nil = range upper bound
    var unit: MeasurementUnit?        // nil = bare count
    var isApproximate: Bool = false   // set when rounding lost precision (e.g. "≈4 eggs")

    var isRange: Bool { high != nil }
    var isCount: Bool { unit == nil || unit?.dimension == .count }

    // MARK: Parse

    /// Build from IngredientParser's string outputs. Returns nil when there's no numeric
    /// quantity to work with (e.g. "salt to taste").
    static func parse(quantity: String?, unit unitString: String?) -> Quantity? {
        guard let raw = quantity?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let (low, high) = parseValue(raw) else { return nil }
        return Quantity(low: low, high: high, unit: MeasurementUnit.named(unitString))
    }

    /// "2", "1 1/2", "1/2", "2-3", "0.5" → (low, high?).
    static func parseValue(_ s: String) -> (Double, Double?)? {
        if let dash = s.range(of: "-") {
            let lhs = String(s[..<dash.lowerBound])
            let rhs = String(s[dash.upperBound...])
            if let lo = parseScalar(lhs), let hi = parseScalar(rhs) { return (lo, hi) }
        }
        if let v = parseScalar(s) { return (v, nil) }
        return nil
    }

    private static func parseScalar(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let parts = t.split(separator: " ")
        // Mixed number "1 1/2"
        if parts.count == 2, let whole = Double(parts[0]), let frac = fraction(String(parts[1])) {
            return whole + frac
        }
        if let f = fraction(t) { return f }
        return Double(t)
    }

    private static func fraction(_ s: String) -> Double? {
        let p = s.split(separator: "/")
        guard p.count == 2, let n = Double(p[0]), let d = Double(p[1]), d != 0 else { return nil }
        return n / d
    }

    // MARK: Scale

    /// Multiply by a factor. `scalable == false` (a "to taste" / non-linear ingredient) returns
    /// the quantity unchanged, so seasoning and leavening aren't blindly multiplied.
    func scaled(by factor: Double, scalable: Bool = true) -> Quantity {
        guard scalable, factor > 0, factor != 1 else { return self }
        var q = self
        q.low = low * factor
        q.high = high.map { $0 * factor }
        return q
    }
}

// MARK: - Formatting

/// Renders a `Quantity` for the screen and for text-to-speech. Imperial amounts get culinary
/// fractions (1½ cups); metric amounts round to sensible precision (237 ml); counts round to
/// whole numbers (≈4 eggs). Formatting is where numbers become human — the model stays exact.
enum QuantityFormatter {

    /// On-screen form, e.g. "1½ cups", "2–3 cloves", "≈4", "500 ml".
    static func string(_ q: Quantity, includeUnit: Bool = true) -> String {
        let (loStr, loVal, loApprox) = component(q.low, unit: q.unit)
        let approxMark = (q.isApproximate || loApprox) ? "≈" : ""
        guard let high = q.high else {
            let word = includeUnit ? unitWord(q.unit, value: loVal) : ""
            return join(approxMark + loStr, word)
        }
        let (hiStr, hiVal, hiApprox) = component(high, unit: q.unit)
        let mark = (q.isApproximate || loApprox || hiApprox) ? "≈" : ""
        let word = includeUnit ? unitWord(q.unit, value: hiVal) : ""
        return join("\(mark)\(loStr)–\(hiStr)", word)
    }

    /// Text-to-speech form, e.g. "one and a half cups", "two to three cloves". Spells out
    /// fractions and the en-dash range so the voice guide reads naturally.
    static func spoken(_ q: Quantity) -> String {
        let (loStr, loVal, _) = component(q.low, unit: q.unit, spoken: true)
        guard let high = q.high else {
            return join(loStr, unitWord(q.unit, value: loVal)).trimmingCharacters(in: .whitespaces)
        }
        let (hiStr, hiVal, _) = component(high, unit: q.unit, spoken: true)
        return join("\(loStr) to \(hiStr)", unitWord(q.unit, value: hiVal))
    }

    // MARK: One value → (string, snappedValue, approximate)

    private static func component(_ value: Double, unit: MeasurementUnit?,
                                  spoken: Bool = false) -> (String, Double, Bool) {
        // Counts round to whole numbers (you can't add 3.75 eggs).
        if unit == nil || unit?.dimension == .count {
            let rounded = max(1, value.rounded())
            let approx = abs(rounded - value) > 0.1
            return (String(Int(rounded)), rounded, approx)
        }
        // Metric measures read as rounded decimals, never culinary fractions ("237 ml").
        if unit?.system == .metric {
            let rounded = value >= 10 ? value.rounded() : (value * 10).rounded() / 10
            let text = rounded == rounded.rounded() ? String(Int(rounded)) : trimDecimal(rounded)
            return (text, rounded, false)
        }
        // Imperial measures use culinary fractions ("1½", "¾").
        let (text, snapped) = spoken ? spokenFraction(value) : niceFraction(value)
        return (text, snapped, false)
    }

    // MARK: Culinary fractions

    private static let fractionTable: [(value: Double, glyph: String, words: String)] = [
        (0, "", ""), (0.125, "⅛", "an eighth"), (0.25, "¼", "a quarter"),
        (1.0 / 3, "⅓", "a third"), (0.375, "⅜", "three eighths"), (0.5, "½", "a half"),
        (0.625, "⅝", "five eighths"), (2.0 / 3, "⅔", "two thirds"), (0.75, "¾", "three quarters"),
        (0.875, "⅞", "seven eighths"), (1, "", ""),
    ]

    private static func snap(_ value: Double) -> (whole: Int, entry: (value: Double, glyph: String, words: String)) {
        let whole = floor(value)
        let frac = value - whole
        var best = fractionTable[0]
        var bestDist = abs(frac - best.value)
        for entry in fractionTable where abs(frac - entry.value) < bestDist {
            best = entry; bestDist = abs(frac - entry.value)
        }
        if best.value >= 1 { return (Int(whole) + 1, fractionTable[0]) }  // snapped up
        // Never round a real, positive amount down to nothing. Scaling 1 tsp to a small
        // fraction and showing "0 teaspoons" is wrong and useless — snap up to the smallest
        // culinary fraction (⅛) instead so the cook still adds a pinch.
        if Int(whole) == 0, best.glyph.isEmpty, value > 0 {
            return (0, fractionTable[1])   // ⅛
        }
        return (Int(whole), best)
    }

    private static func niceFraction(_ value: Double) -> (String, Double) {
        let (whole, entry) = snap(value)
        let snapped = Double(whole) + entry.value
        if entry.glyph.isEmpty { return (String(whole), snapped) }
        if whole == 0 { return (entry.glyph, snapped) }
        return ("\(whole)\(entry.glyph)", snapped)
    }

    private static func spokenFraction(_ value: Double) -> (String, Double) {
        let (whole, entry) = snap(value)
        let snapped = Double(whole) + entry.value
        if entry.words.isEmpty { return (String(whole), snapped) }
        if whole == 0 { return (entry.words, snapped) }
        return ("\(whole) and \(entry.words)", snapped)
    }

    // MARK: Units + helpers

    private static func unitWord(_ unit: MeasurementUnit?, value: Double) -> String {
        guard let unit else { return "" }              // bare count: noun is the ingredient
        return value > 1 ? unit.plural : unit.singular
    }

    private static func join(_ number: String, _ word: String) -> String {
        word.isEmpty ? number : "\(number) \(word)"
    }

    private static func trimDecimal(_ v: Double) -> String {
        String(format: "%.1f", v)
    }
}

// MARK: - Recipe scaling

/// Computes the factor to scale a recipe from its base yield to a target serving count, and
/// scales a parsed ingredient's quantity. The LLM never does this math — it only supplies the
/// structured amounts and the `scalable` flag; this type applies the arithmetic deterministically.
enum RecipeScaler {
    /// Factor to go from `baseServings` to `targetServings`. Guards against zero/missing yields
    /// (returns 1 — show the recipe as written rather than dividing by zero).
    static func factor(baseServings: Double?, targetServings: Double?) -> Double {
        guard let base = baseServings, base > 0,
              let target = targetServings, target > 0 else { return 1 }
        return target / base
    }

    /// Scale a quantity and format it for display in one call.
    static func displayString(_ quantity: Quantity, factor: Double, scalable: Bool = true) -> String {
        QuantityFormatter.string(quantity.scaled(by: factor, scalable: scalable))
    }
}

// MARK: - Recipe yield

/// Extracts a numeric base count and its noun from a recipe's free-text yield, so the servings
/// scaler has something to compute a factor against. Recipes state yield every which way —
/// "4 servings", "Serves 8", "36 cookies", "4-6 servings" — so this is best-effort: the first
/// integer is the count, and the noun is the last non-filler word (defaulting to "servings").
enum RecipeYield {
    static func parse(_ text: String?) -> (count: Int, noun: String)? {
        guard let text,
              let range = text.range(of: #"\d+"#, options: .regularExpression),
              let count = Int(text[range]), count > 0 else { return nil }
        let filler: Set<String> = [
            "serves", "serving", "servings", "makes", "yields", "yield", "about", "approximately",
        ]
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        let noun = words.last(where: { !filler.contains($0) }) ?? "servings"
        return (count, noun)
    }
}
