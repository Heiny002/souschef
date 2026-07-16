import SwiftUI
import SwiftData

/// SC-055: Compatibility View — per-ingredient diet compatibility overlay with substitution sheet
/// and Auto-adapt button that creates a modified recipe copy.
struct CompatibilityView: View {
    let recipe: Recipe
    let diners: [DinerProfile]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var dinerResults: [DinerCompatibility] = []
    @State private var selectedIngredient: IngredientWithResults?
    @State private var showAutoAdaptConfirm = false
    @State private var adaptPlan = AutoAdaptPlan(lines: [])
    @State private var adaptSummary: AdaptSummary?

    private let matcher = ProfileMatcher()
    private let substitutions = SubstitutionLibrary.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Color.scBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("Compatibility")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.scBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Color.scTextSecondary)
                }
                if canAutoAdapt {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Auto-Adapt") { showAutoAdaptConfirm = true }
                            .foregroundStyle(Color.scAccent)
                            .font(.scLabel)
                    }
                }
            }
            .onAppear { computeResults() }
            .sheet(item: $selectedIngredient) { item in
                SubstitutionSheet(item: item, diners: diners)
            }
            .confirmationDialog(
                "Create adapted recipe?",
                isPresented: $showAutoAdaptConfirm,
                titleVisibility: .visible
            ) {
                Button("Create Adapted Copy") { autoAdapt() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("A new copy will be created with safe substitutions applied where one exists that works for every diner. Ingredients that can't be safely substituted are kept and flagged — review before cooking.")
            }
            .alert(
                "Adapted Recipe Created",
                isPresented: Binding(
                    get: { adaptSummary != nil },
                    set: { if !$0 { adaptSummary = nil } }
                ),
                presenting: adaptSummary
            ) { _ in
                Button("Done") { adaptSummary = nil; dismiss() }
            } message: { summary in
                Text(summary.message)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if diners.isEmpty {
            emptyDinersState
        } else {
            ingredientList
        }
    }

    private var ingredientList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Diner legend
                dinerLegend
                    .padding(Spacing.md)

                Divider().overlay(Color.scBorder)

                // Ingredients
                ForEach(recipe.ingredients.sorted(by: { $0.order < $1.order })) { ingredient in
                    let results = dinerResultsFor(ingredient: ingredient)
                    IngredientCompatibilityRow(
                        ingredient: ingredient,
                        results: results,
                        diners: diners
                    )
                    .onTapGesture {
                        let worst = results.values.max(by: { $0.level < $1.level })
                        if let w = worst, w.level > .green {
                            selectedIngredient = IngredientWithResults(
                                ingredient: ingredient,
                                results: results
                            )
                        }
                    }
                    Divider().overlay(Color.scBorder).padding(.leading, Spacing.md)
                }
            }
        }
    }

    private var dinerLegend: some View {
        HStack(spacing: Spacing.md) {
            ForEach(diners) { diner in
                let worst = dinerResults.first(where: { $0.profile.id == diner.id })?.worstLevel ?? .green
                HStack(spacing: Spacing.xs) {
                    Circle()
                        .fill(colorFor(worst))
                        .frame(width: 8, height: 8)
                    Text(diner.name)
                        .font(.scCaption)
                        .foregroundStyle(Color.scTextPrimary)
                }
            }
            Spacer()
        }
    }

    private var emptyDinersState: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 48))
                .foregroundStyle(Color.scTextSecondary)
            Text("No diners configured")
                .font(.scHeadline)
                .foregroundStyle(Color.scTextPrimary)
            Text("Add household members in the Diners tab to check recipe compatibility.")
                .font(.scBody)
                .foregroundStyle(Color.scTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Spacing.xl)
    }

    // MARK: - Auto-Adapt

    /// Auto-Adapt is only offered when at least one red-flagged ingredient has a substitute
    /// that is safe (green) for every diner. A yellow-only recipe — or one whose red flags
    /// are all unsubstitutable (allergy/custom restriction, or no substitution data) — would
    /// otherwise produce an identical "(Adapted)" duplicate with nothing changed, so we hide
    /// the action instead (audit: low-severity yellow-only duplicate).
    private var canAutoAdapt: Bool {
        adaptPlan.hasSafeSubstitutions
    }

    private func autoAdapt() {
        let adapted = Recipe(
            title: recipe.title + " (Adapted)",
            sourceURL: recipe.sourceURL,
            sourceType: recipe.sourceType,
            extractionConfidence: recipe.extractionConfidence,
            extractionMethod: recipe.extractionMethod
        )
        adapted.recipeYield = recipe.recipeYield
        adapted.prepTime = recipe.prepTime
        adapted.cookTime = recipe.cookTime
        adapted.totalTime = recipe.totalTime
        adapted.appliances = recipe.appliances
        adapted.recipeDescription = recipe.recipeDescription
        // A machine-generated copy is NOT user-verified. Auto-Adapt cannot guarantee safety
        // (some flags are unfixable), so it must never mark the copy as trusted (C3/H2).
        adapted.userVerified = false

        var substituted: [String] = []
        var unfixable: [String] = []

        for line in adaptPlan.lines {
            let ingredient = line.ingredient
            if let sub = line.substitute {
                let parts = [ingredient.quantity, ingredient.unit, sub].compactMap { $0 }
                let newRawText = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                let newIngredient = Ingredient(item: sub,
                                               rawText: newRawText.isEmpty ? sub : newRawText,
                                               order: ingredient.order)
                newIngredient.quantity = ingredient.quantity
                newIngredient.unit = ingredient.unit
                newIngredient.preparation = ingredient.preparation
                newIngredient.section = ingredient.section
                adapted.ingredients.append(newIngredient)
                substituted.append("\(ingredient.item) → \(sub)")
            } else {
                let copy = Ingredient(item: ingredient.item, rawText: ingredient.rawText, order: ingredient.order)
                copy.quantity = ingredient.quantity
                copy.unit = ingredient.unit
                copy.preparation = ingredient.preparation
                copy.section = ingredient.section
                adapted.ingredients.append(copy)
                if line.unfixable { unfixable.append(ingredient.item) }
            }
        }

        for step in recipe.steps.sorted(by: { $0.order < $1.order }) {
            let copy = CookingStep(order: step.order, instruction: step.instruction, rawText: step.rawText)
            copy.duration = step.duration
            copy.temperature = step.temperature
            copy.timerLabel = step.timerLabel
            adapted.steps.append(copy)
        }

        modelContext.insert(adapted)

        // Re-validate the finished copy against every diner (C3): the summary tells the user
        // exactly what was and wasn't fixed, and warns about any diner still at risk.
        let revalidated = matcher.match(ingredients: adapted.ingredients, diners: diners)
        let stillUnsafe = revalidated
            .filter { $0.worstLevel == .red }
            .map { $0.profile.name }

        adaptSummary = AdaptSummary(
            substituted: substituted,
            unfixable: unfixable,
            stillUnsafeDiners: stillUnsafe
        )
    }

    // MARK: - Auto-Adapt planning

    private func buildPlan() -> AutoAdaptPlan {
        var lines: [AutoAdaptPlan.Line] = []
        for ingredient in recipe.ingredients.sorted(by: { $0.order < $1.order }) {
            let results = dinerResultsFor(ingredient: ingredient)
            let worst = results.values.map(\.level).max() ?? .green
            guard worst == .red else {
                lines.append(.init(ingredient: ingredient, worstLevel: worst, substitute: nil, unfixable: false))
                continue
            }
            let substitute = safeSubstitute(for: ingredient)
            lines.append(.init(ingredient: ingredient, worstLevel: worst,
                               substitute: substitute, unfixable: substitute == nil))
        }
        return AutoAdaptPlan(lines: lines)
    }

    /// A substitute for a red-flagged ingredient that is green for EVERY diner, or nil.
    /// Candidates are drawn from every diet that red-flags the ingredient (for any diner) and
    /// each is re-validated against all diners before acceptance — so a swap that fixes one
    /// diner but introduces another's allergen (flour → almond flour for a nut-allergic
    /// member) is rejected rather than applied and mislabelled "Adapted" (C3).
    private func safeSubstitute(for ingredient: Ingredient) -> String? {
        var dietIds: [String] = []
        for diner in diners {
            for id in matcher.redFlaggingDietIds(item: ingredient.item, rawText: ingredient.rawText, diner: diner)
            where !dietIds.contains(id) {
                dietIds.append(id)
            }
        }

        var candidates: [String] = []
        for dietId in dietIds {
            // nil (prohibited) and [] (no data) both mean "nothing to apply from this diet".
            guard let options = substitutions.options(for: ingredient.item, diet: dietId) else { continue }
            for opt in options where !candidates.contains(opt) { candidates.append(opt) }
        }

        return candidates.first { candidate in
            diners.allSatisfy { diner in
                matcher.evaluate(item: candidate, rawText: candidate, against: diner).level == .green
            }
        }
    }

    // MARK: - Helpers

    private func computeResults() {
        dinerResults = matcher.match(ingredients: recipe.ingredients, diners: diners)
        adaptPlan = buildPlan()
    }

    private func dinerResultsFor(ingredient: Ingredient) -> [UUID: IngredientCompatibility] {
        var out: [UUID: IngredientCompatibility] = [:]
        for dinerCompat in dinerResults {
            // Keyed by the ingredient's stable id, not rawText (which can repeat) — C1.
            if let c = dinerCompat.results[ingredient.id] {
                out[dinerCompat.profile.id] = c
            }
        }
        return out
    }

    func colorFor(_ level: CompatibilityLevel) -> Color {
        switch level {
        case .green:  return .green
        case .yellow: return .yellow
        case .red:    return .red
        }
    }
}

// MARK: - Ingredient Row

private struct IngredientCompatibilityRow: View {
    let ingredient: Ingredient
    let results: [UUID: IngredientCompatibility]
    let diners: [DinerProfile]

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            Text(ingredient.rawText)
                .font(.scBody)
                .foregroundStyle(Color.scTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                ForEach(diners) { diner in
                    let level = results[diner.id]?.level ?? .green
                    Circle()
                        .fill(colorFor(level))
                        .frame(width: 10, height: 10)
                }
            }

            if results.values.contains(where: { $0.level > .green }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scTextSecondary)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
    }

    func colorFor(_ level: CompatibilityLevel) -> Color {
        switch level {
        case .green:  return .green
        case .yellow: return .yellow
        case .red:    return .red
        }
    }
}

// MARK: - Substitution Sheet

struct IngredientWithResults: Identifiable {
    let id = UUID()
    let ingredient: Ingredient
    let results: [UUID: IngredientCompatibility]
}

// MARK: - Auto-Adapt model

/// A planned adaptation: one line per recipe ingredient, with a safe substitute where one
/// exists that works for every diner, and a flag for red ingredients that couldn't be fixed.
struct AutoAdaptPlan {
    struct Line {
        let ingredient: Ingredient
        let worstLevel: CompatibilityLevel
        /// A substitute that is green for every diner, or nil to keep the original.
        let substitute: String?
        /// True when the ingredient is red-flagged but no safe substitute exists.
        let unfixable: Bool
    }

    let lines: [Line]

    /// At least one ingredient will actually change — otherwise adapting is a no-op.
    var hasSafeSubstitutions: Bool { lines.contains { $0.substitute != nil } }
}

/// Post-adaptation summary shown to the user, so the copy never silently over-promises.
struct AdaptSummary {
    let substituted: [String]        // "flour → gluten-free flour"
    let unfixable: [String]          // ingredient names kept because no safe swap existed
    let stillUnsafeDiners: [String]  // diners for whom the adapted copy is still RED

    var message: String {
        var parts: [String] = []
        if substituted.isEmpty {
            parts.append("No ingredients could be safely substituted.")
        } else {
            let list = substituted.map { "• \($0)" }.joined(separator: "\n")
            parts.append("Substituted \(substituted.count) ingredient\(substituted.count == 1 ? "" : "s"):\n\(list)")
        }
        if !unfixable.isEmpty {
            let list = unfixable.map { "• \($0)" }.joined(separator: "\n")
            parts.append("Could not safely substitute:\n\(list)")
        }
        if !stillUnsafeDiners.isEmpty {
            parts.append("⚠️ Still not safe for: \(stillUnsafeDiners.joined(separator: ", ")). Review before cooking.")
        }
        return parts.joined(separator: "\n\n")
    }
}

private struct SubstitutionSheet: View {
    let item: IngredientWithResults
    let diners: [DinerProfile]
    @Environment(\.dismiss) private var dismiss

    private let subLibrary = SubstitutionLibrary.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Color.scBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        // Restriction reasons
                        let flags = item.results.values.filter { $0.level > .green }
                        ForEach(Array(flags.enumerated()), id: \.offset) { _, compat in
                            if let reason = compat.reason {
                                HStack(alignment: .top, spacing: Spacing.sm) {
                                    Circle()
                                        .fill(compat.level == .red ? Color.red : Color.yellow)
                                        .frame(width: 10, height: 10)
                                        .padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(compat.triggeringDiet ?? "")
                                            .font(.scLabel)
                                            .foregroundStyle(Color.scTextPrimary)
                                        Text(reason)
                                            .font(.scCaption)
                                            .foregroundStyle(Color.scTextSecondary)
                                    }
                                }
                            }
                        }

                        Divider().overlay(Color.scBorder)

                        // Substitutions per relevant diet
                        let dietIds = diners.flatMap { $0.diets }
                        let subEntry = subLibrary.entry(for: item.ingredient.item)

                        if let sub = subEntry {
                            let relevantSubs = sub.substitutions.filter { s in
                                dietIds.contains(s.reason)
                            }
                            if !relevantSubs.isEmpty {
                                Text("Suggested Substitutes")
                                    .font(.scLabel)
                                    .foregroundStyle(Color.scAccent)
                                ForEach(relevantSubs, id: \.reason) { sub in
                                    VStack(alignment: .leading, spacing: Spacing.xs) {
                                        Text(DietLibrary.shared.diet(id: sub.reason)?.name ?? sub.reason)
                                            .font(.scCaption)
                                            .foregroundStyle(Color.scTextSecondary)
                                        if let opts = sub.options {
                                            ForEach(opts, id: \.self) { opt in
                                                HStack(spacing: Spacing.sm) {
                                                    Image(systemName: "arrow.right")
                                                        .font(.system(size: 12))
                                                        .foregroundStyle(Color.scAccent)
                                                    Text(opt)
                                                        .font(.scBody)
                                                        .foregroundStyle(Color.scTextPrimary)
                                                }
                                            }
                                        } else {
                                            Text("No substitute — ingredient not allowed on this diet.")
                                                .font(.scBody)
                                                .foregroundStyle(Color.scTextSecondary)
                                                .italic()
                                        }
                                    }
                                }
                            } else {
                                Text("No substitutions found for this ingredient.")
                                    .font(.scBody)
                                    .foregroundStyle(Color.scTextSecondary)
                            }
                        } else {
                            Text("No substitutions found for this ingredient.")
                                .font(.scBody)
                                .foregroundStyle(Color.scTextSecondary)
                        }
                    }
                    .padding(Spacing.md)
                }
            }
            .navigationTitle(item.ingredient.item.capitalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.scBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.scAccent)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Preview

#Preview("Compatibility View") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Recipe.self, DinerProfile.self, configurations: config)
    let ctx = container.mainContext

    let recipe = Recipe(title: "Pasta Carbonara", extractionConfidence: 0.9, extractionMethod: "schema-org")
    recipe.ingredients = [
        Ingredient(item: "pasta", rawText: "400g spaghetti", order: 1),
        Ingredient(item: "bacon", rawText: "200g bacon or guanciale", order: 2),
        Ingredient(item: "egg", rawText: "4 large eggs", order: 3),
        Ingredient(item: "parmesan", rawText: "100g Parmesan, grated", order: 4),
        Ingredient(item: "black pepper", rawText: "freshly ground black pepper", order: 5),
    ]

    let p1 = DinerProfile(name: "Alex")
    p1.diets = ["vegan"]
    let p2 = DinerProfile(name: "Sam")
    p2.diets = ["gluten-free"]
    ctx.insert(recipe); ctx.insert(p1); ctx.insert(p2)

    return CompatibilityView(recipe: recipe, diners: [p1, p2])
        .modelContainer(container)
        .preferredColorScheme(.dark)
}
