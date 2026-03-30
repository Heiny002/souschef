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
                Text("A new recipe will be created with suggested substitutions applied for all flagged ingredients.")
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

    private var canAutoAdapt: Bool {
        dinerResults.contains { $0.worstLevel > .green }
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
        adapted.userVerified = true

        for ingredient in recipe.ingredients.sorted(by: { $0.order < $1.order }) {
            let results = dinerResultsFor(ingredient: ingredient)
            let worstLevel = results.values.max(by: { $0.level < $1.level })?.level ?? .green

            if worstLevel == .red,
               let worstDiet = results.values.first(where: { $0.level == .red })?.triggeringDiet?.lowercased() {
                // Find a substitution
                let sub = substitutions.options(for: ingredient.item, diet: worstDiet)
                let newItem = sub?.first ?? ingredient.item
                let newRawText = sub?.first.map { "\(ingredient.quantity ?? "") \(ingredient.unit ?? "") \($0)".trimmingCharacters(in: .whitespaces) } ?? ingredient.rawText
                let newIngredient = Ingredient(item: newItem, rawText: newRawText, order: ingredient.order)
                newIngredient.quantity = ingredient.quantity
                newIngredient.unit = ingredient.unit
                newIngredient.preparation = ingredient.preparation
                newIngredient.section = ingredient.section
                adapted.ingredients.append(newIngredient)
            } else {
                let copy = Ingredient(item: ingredient.item, rawText: ingredient.rawText, order: ingredient.order)
                copy.quantity = ingredient.quantity
                copy.unit = ingredient.unit
                copy.preparation = ingredient.preparation
                copy.section = ingredient.section
                adapted.ingredients.append(copy)
            }
        }

        for step in recipe.steps.sorted(by: { $0.order < $1.order }) {
            let copy = CookingStep(order: step.order, instruction: step.instruction, rawText: step.rawText)
            copy.duration = step.duration
            adapted.steps.append(copy)
        }

        modelContext.insert(adapted)
        dismiss()
    }

    // MARK: - Helpers

    private func computeResults() {
        dinerResults = matcher.match(ingredients: recipe.ingredients, diners: diners)
    }

    private func dinerResultsFor(ingredient: Ingredient) -> [UUID: IngredientCompatibility] {
        var out: [UUID: IngredientCompatibility] = [:]
        for dinerCompat in dinerResults {
            if let c = dinerCompat.results[ingredient.rawText] {
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
