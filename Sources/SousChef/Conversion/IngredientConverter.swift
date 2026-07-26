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

    static func display(_ ingredient: Ingredient, mode: UnitMode, scale: Double = 1) -> String {
        // Original units: keep the text exactly as authored at 1×; scale in place otherwise.
        guard mode != .original else {
            return scale == 1 ? ingredient.rawText : scaledOriginal(ingredient, factor: scale)
        }

        let qtyStr = ingredient.quantity ?? ""
        let rawUnit = (ingredient.unit ?? "").lowercased()
        let item = ingredient.item
        let prepSuffix = ingredient.preparation.map { ", \($0)" } ?? ""

        guard !qtyStr.isEmpty,
              let baseQty = parseQuantity(qtyStr),
              baseQty > 0,
              let srcUnit = canonicalUnit(rawUnit) else {
            // Nothing convertible — fall back to text, still scaled if a factor was applied.
            return scale == 1 ? ingredient.rawText : scaledOriginal(ingredient, factor: scale)
        }

        let qty = baseQty * scale   // scale first, then convert units
        let result: String?
        switch mode {
        case .original: result = nil
        case .metric:   result = toMetric(qty: qty, unit: srcUnit, item: item)
        case .imperial: result = toImperial(qty: qty, unit: srcUnit, item: item)
        case .volume:   result = toVolume(qty: qty, unit: srcUnit, item: item)
        case .pieces:   result = toPieces(qty: qty, unit: srcUnit, item: item)
        }

        guard let converted = result else {
            return scale == 1 ? ingredient.rawText : scaledOriginal(ingredient, factor: scale)
        }
        return "\(converted) \(item)\(prepSuffix)"
    }

    /// Scale an ingredient in its original units, rendered with the scaling engine's culinary
    /// fractions (½ cup, 1½ cups, ≈4 eggs). Amounts with no parseable quantity ("salt to taste")
    /// are returned unchanged. This is the recipe scaler's first consumer of the scaling engine.
    static func scaledOriginal(_ ingredient: Ingredient, factor: Double) -> String {
        guard let quantity = Quantity.parse(quantity: ingredient.quantity, unit: ingredient.unit) else {
            return ingredient.rawText
        }
        let scaled = quantity.scaled(by: factor)
        let numberAndUnit = QuantityFormatter.string(scaled)
        // Preserve a size word the measurement engine doesn't model as a unit (e.g. "large").
        let extraUnit = scaled.unit == nil
            ? (ingredient.unit.map { $0.isEmpty ? "" : " \($0)" } ?? "")
            : ""
        let prepSuffix = ingredient.preparation.map { ", \($0)" } ?? ""
        return "\(numberAndUnit)\(extraUnit) \(ingredient.item)\(prepSuffix)"
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
    //
    // Values are from King Arthur Baking's Ingredient Weight Chart, normalized to grams-per-cup
    // (chart rows given per ½ cup / ¼ cup / tbsp / tsp are scaled up: ¼ cup ×4, 2 tbsp ×8, etc.).
    // Generic catch-all keys ("flour", "sugar", "milk") sit alongside specific ones; the matcher
    // prefers the longest key contained in the ingredient name, so "almond flour" beats "flour".
    private static let densityTable: [(key: String, gPerCup: Double)] = [
        // Flours & starches
        ("all-purpose flour",        120),  ("00 flour",                 116),
        ("bread flour",              120),  ("cake flour",               120),
        ("pastry flour",             106),  ("whole wheat pastry flour",  96),
        ("whole wheat flour",        113),  ("self-rising flour",        113),
        ("self rising flour",        113),  ("almond flour",              96),
        ("almond meal",               84),  ("amaranth flour",           103),
        ("barley flour",              85),  ("brown rice flour",         128),
        ("buckwheat flour",          120),  ("chickpea flour",            85),
        ("coconut flour",            128),  ("durum flour",              124),
        ("hazelnut flour",            89),  ("masa harina",               93),
        ("oat flour",                 92),  ("potato flour",             184),
        ("pumpernickel flour",       106),  ("quinoa flour",             110),
        ("rice flour",               142),  ("rye flour",                106),
        ("semolina",                 163),  ("sorghum flour",            138),
        ("soy flour",                140),  ("spelt flour",               99),
        ("teff flour",               135),  ("cornmeal",                 156),
        ("polenta",                  163),  ("cornstarch",               112),
        ("corn starch",              112),  ("potato starch",            152),
        ("tapioca flour",            113),  ("tapioca starch",           113),
        ("flour",                    120),
        // Sugars
        ("granulated sugar",         198),  ("brown sugar",              213),
        ("powdered sugar",           113),  ("confectioners",            113),
        ("icing sugar",              113),  ("superfine sugar",          190),
        ("caster sugar",             190),  ("coconut sugar",            154),
        ("demerara",                 220),  ("turbinado",                180),
        ("raw sugar",                180),  ("maple sugar",              156),
        ("cinnamon sugar",           200),  ("sanding sugar",            228),
        ("sparkling sugar",          228),  ("sugar",                    198),
        // Dairy & liquids
        ("water",                    227),  ("buttermilk",               227),
        ("heavy cream",              227),  ("half and half",            227),
        ("sour cream",               227),  ("cream cheese",             227),
        ("mascarpone",               227),  ("ricotta",                  227),
        ("cottage cheese",           226),  ("evaporated milk",          226),
        ("sweetened condensed milk", 312),  ("coconut milk",             241),
        ("coconut cream",            284),  ("creme fraiche",            226),
        ("crème fraiche",            226),  ("mayonnaise",               226),
        ("milk",                     227),  ("cream",                    227),
        // Cheese (grated)
        ("parmesan",                 100),  ("feta",                     114),
        ("cheddar",                  113),  ("mozzarella",               113),
        // Fats & oils
        ("butter",                   227),  ("olive oil",                200),
        ("vegetable oil",            198),  ("canola oil",               198),
        ("coconut oil",              226),  ("lard",                     226),
        ("ghee",                     176),  ("shortening",               184),
        // Liquid sweeteners
        ("honey",                    336),  ("corn syrup",               312),
        ("molasses",                 340),  ("maple syrup",              312),
        ("agave",                    336),  ("boiled cider",             340),
        ("jam",                      340),  ("preserves",                340),
        ("jelly",                    340),  ("lemon curd",               226),
        ("marshmallow",              128),
        // Nut & seed butters / pastes
        ("peanut butter",            270),  ("almond butter",            272),
        ("tahini",                   256),  ("hazelnut spread",          320),
        ("nutella",                  298),  ("cookie butter",            288),
        ("almond paste",             259),  ("marzipan",                 290),
        // Nuts & seeds
        ("sliced almonds",            86),  ("slivered almonds",         114),
        ("almonds",                  142),  ("cashews",                  113),
        ("hazelnuts",                142),  ("macadamia",                149),
        ("peanuts",                  142),  ("pecans",                   105),
        ("pine nuts",                142),  ("pistachios",               120),
        ("walnuts",                  113),  ("sesame seeds",             142),
        ("chia seeds",               148),  ("flaxseed",                 140),
        ("flax meal",                100),  ("poppy seeds",              144),
        ("pumpkin seeds",            160),  ("sunflower seeds",          140),
        // Grains, oats & crumbs
        ("rolled oats",               89),  ("old-fashioned oats",        89),
        ("quick oats",                89),  ("steel cut oats",           140),
        ("oats",                      89),  ("oatmeal",                   89),
        ("oat bran",                 106),  ("quinoa",                   177),
        ("brown rice",               170),  ("rice",                     198),
        ("pearled barley",           213),  ("barley",                   213),
        ("bulgur",                   152),  ("cracked wheat",            149),
        ("wheat germ",               112),  ("wheat bran",                64),
        ("panko",                     50),  ("breadcrumbs",              112),
        ("bread crumbs",             112),  ("graham cracker",           100),
        ("cookie crumbs",             85),
        // Cocoa & chocolate
        ("cocoa",                     84),  ("cacao nibs",               120),
        ("white chocolate chips",    170),  ("mini chocolate chips",     177),
        ("chocolate chips",          170),  ("chocolate chunks",         170),
        ("chocolate",                170),
        // Fruit & vegetables (mashed / puréed / prepared)
        ("applesauce",               255),  ("apples",                   113),
        ("pumpkin puree",            227),  ("pumpkin purée",            227),
        ("mashed banana",            227),  ("banana",                   227),
        ("mashed sweet potato",      240),  ("mashed potato",            213),
        ("raisins",                  149),  ("dried cranberries",        114),
        ("dried cherries",           142),  ("currants",                 142),
        ("dates",                    149),  ("shredded coconut",          85),
        ("desiccated coconut",        85),  ("tomato paste",             232),
        ("tomato sauce",             228),  ("pizza sauce",              228),
        ("grated carrots",            99),  ("carrots",                  142),
        ("shredded zucchini",        135),  ("zucchini",                 135),
        ("onions",                   142),  ("onion",                    142),
        ("bell pepper",              142),  ("celery",                   142),
        ("mushrooms",                 78),  ("leeks",                     92),
        ("scallions",                 64),  ("green onions",              64),
        ("shallots",                 156),  ("olives",                   142),
        ("sun-dried tomatoes",       170),  ("sundried tomatoes",        170),
        ("peaches",                  170),  ("pears",                    163),
        ("pineapple",                170),  ("strawberries",             167),
        ("blueberries",              155),  ("raspberries",              120),
        // Juices
        ("lemon juice",              224),  ("lime juice",               227),
        // Misc baking
        ("vital wheat gluten",       144),  ("matcha",                    96),
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
        // Eggs — white/yolk listed before the whole egg so they match first
        (["egg white"],          33, "egg white"),
        (["egg yolk"],           14, "egg yolk"),
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

    static func gPerCup(for item: String) -> Double? {
        let lower = item.lowercased()
        // The most specific (longest) table key that appears in the ingredient name, so
        // "almond flour" resolves to 96, not the generic "flour" at 120, and "coconut milk"
        // to 241, not "milk" at 227. Generic catch-all keys ("flour", "sugar", "milk", "oats")
        // let bare ingredient names resolve too. No bidirectional/fragment fallback: a name we
        // can't place returns nil so the caller shows it unchanged, rather than a fragment like
        // "ice" matching "rice" (audit) and producing a confidently wrong weight.
        return densityTable
            .filter { lower.contains($0.key) }
            .max(by: { $0.key.count < $1.key.count })
            .map { $0.gPerCup }
    }

    // MARK: - Piece lookup

    static func pieceInfo(for item: String) -> (gPerPiece: Double, label: String)? {
        // Longest whole-word keyword wins, so "cherry tomato" (17 g) beats "tomato" (150 g) and
        // "sweet potato" (130 g) beats "potato" (150 g) regardless of table order — and whole-word
        // matching stops "eggplant" from matching "egg" (50 g), the exact audit failures.
        var best: (length: Int, gPerPiece: Double, label: String)?
        for entry in pieceTable {
            for keyword in entry.keywords where Self.matchesWholeWord(keyword, in: item) {
                if best == nil || keyword.count > best!.length {
                    best = (keyword.count, entry.gPerPiece, entry.label)
                }
            }
        }
        return best.map { (gPerPiece: $0.gPerPiece, label: $0.label) }
    }

    /// True when `phrase` (one or more words) appears in `text` as consecutive whole words,
    /// tolerating simple plurals of the (singular) keyword — "tomato" matches "cherry tomatoes",
    /// but "egg" does NOT match "eggplant".
    static func matchesWholeWord(_ phrase: String, in text: String) -> Bool {
        let words = tokenize(text)
        let needle = tokenize(phrase)
        guard !needle.isEmpty, needle.count <= words.count else { return false }
        for start in 0...(words.count - needle.count)
        where zip(words[start ..< start + needle.count], needle).allSatisfy({ wordEquals($0.0, $0.1) }) {
            return true
        }
        return false
    }

    private static func tokenize(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Item word equals the keyword, or a simple plural of it (egg→eggs, tomato→tomatoes,
    /// cherry→cherries). Keywords are authored singular, so we expand the keyword, never stem
    /// the item — which avoids mangling words like "molasses".
    private static func wordEquals(_ itemWord: String, _ keyWord: String) -> Bool {
        if itemWord == keyWord || itemWord == keyWord + "s" || itemWord == keyWord + "es" {
            return true
        }
        if keyWord.hasSuffix("y"), itemWord == String(keyWord.dropLast()) + "ies" { return true }
        return false
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
        // Align captures to the closure's (a, b, c) slots. Two-group patterns (fraction "3/4",
        // range "2-3") must fill (b, c), not (a, b): their closures read the LAST two slots, and
        // the old zero-fill of `c` made "3/4" compute 4/0 = ∞ and "2-3" a wrong midpoint —
        // caught by IngredientConverterTests when CI first ran them.
        let a = vals.count > 2 ? vals[0] : 0
        let b = vals.count > 2 ? vals[1] : vals[0]
        let c = vals.count > 2 ? vals[2] : vals[1]
        return combine(a, b, c)
    }
}
