import SwiftUI
import SwiftData

/// SC-017: User confirmation view before saving an extracted recipe.
/// Shows all extracted fields, highlights WARN/FAIL items, lets user edit before saving.
struct ReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let extractionResult: ExtractionResult
    let onSave: ((Recipe) -> Void)?
    let onRetry: (() -> Void)?
    let screenTitle: String
    let showsCancelButton: Bool

    @State private var title: String
    @State private var recipeYield: String
    @State private var ingredients: [EditableIngredient]
    @State private var steps: [EditableStep]
    @State private var validationReport: ValidationReport?

    private let parser = IngredientParser()
    private let validator = RecipeValidator()

    /// A blank recipe to hand to ReviewView for from-scratch manual entry — one empty
    /// ingredient and step so the fields are visible; the user adds more with the buttons.
    static func blankManualResult() -> ExtractionResult {
        var result = ExtractionResult(extractionMethod: "manual")
        result.ingredients = [RawIngredient(text: "")]
        result.steps = [RawStep(order: 1, text: "")]
        return result
    }

    private var isManual: Bool { extractionResult.extractionMethod == "manual" }

    init(
        result: ExtractionResult,
        onSave: ((Recipe) -> Void)? = nil,
        onRetry: (() -> Void)? = nil,
        screenTitle: String = "Review Recipe",
        showsCancelButton: Bool = false
    ) {
        self.extractionResult = result
        self.onSave = onSave
        self.onRetry = onRetry
        self.screenTitle = screenTitle
        self.showsCancelButton = showsCancelButton
        _title = State(initialValue: result.title ?? "")
        _recipeYield = State(initialValue: result.recipeYield ?? "")
        _ingredients = State(initialValue: result.ingredients.map { EditableIngredient(raw: $0) })
        _steps = State(initialValue: result.steps.map { EditableStep(raw: $0) })
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.scBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        if extractionResult.isSubstitute {
                            substituteBanner
                        }
                        if !isManual {
                            confidenceHeader
                        }
                        titleSection
                        yieldSection
                        ingredientsSection
                        stepsSection
                        if let report = validationReport {
                            validationSection(report: report)
                        }
                        actionButtons
                    }
                    .padding(Spacing.md)
                }
            }
            .navigationTitle(screenTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.scBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if showsCancelButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(Color.scTextSecondary)
                    }
                }
            }
            .onAppear { runValidation() }
        }
    }

    // MARK: - Sections

    private var confidenceHeader: some View {
        HStack(spacing: Spacing.sm) {
            Circle()
                .fill(confidenceColor)
                .frame(width: 10, height: 10)
            Text("\(extractionResult.extractionMethod) · \(Int(extractionResult.confidence * 100))% confidence")
                .font(.scCaption)
                .foregroundStyle(Color.scTextSecondary)
            Spacer()
        }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("Title", systemImage: "fork.knife")
                .font(.scLabel)
                .foregroundStyle(Color.scAccent)
            TextField("Recipe title", text: $title)
                .font(.scTitle)
                .foregroundStyle(Color.scTextPrimary)
                .padding(Spacing.sm)
                .background(Color.scSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var yieldSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("Serves", systemImage: "person.2")
                .font(.scLabel)
                .foregroundStyle(Color.scAccent)
            TextField("e.g. 4 servings", text: $recipeYield)
                .font(.scBody)
                .foregroundStyle(Color.scTextPrimary)
                .padding(Spacing.sm)
                .background(Color.scSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label("Ingredients (\(ingredients.count))", systemImage: "list.bullet")
                .font(.scLabel)
                .foregroundStyle(Color.scAccent)
            ForEach($ingredients) { $ingredient in
                HStack(spacing: Spacing.sm) {
                    TextField("Ingredient", text: $ingredient.text)
                        .font(.scBody)
                        .foregroundStyle(Color.scTextPrimary)
                        .padding(Spacing.sm)
                        .background(ingredientBackground(for: ingredient))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(ingredientBorder(for: ingredient), lineWidth: 1)
                        )
                    deleteButton { removeIngredient(ingredient.id) }
                        .accessibilityLabel("Remove ingredient")
                }
            }
            addButton("Add ingredient") {
                ingredients.append(EditableIngredient(raw: RawIngredient(text: "")))
            }
        }
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label("Steps (\(steps.count))", systemImage: "checklist")
                .font(.scLabel)
                .foregroundStyle(Color.scAccent)
            ForEach($steps) { $step in
                stepRow($step)
            }
            addButton("Add step") {
                steps.append(EditableStep(raw: RawStep(order: steps.count + 1, text: "")))
            }
        }
    }

    private func stepRow(_ step: Binding<EditableStep>) -> some View {
        // Numbering derives from position, so it stays correct after inserts/deletes;
        // binding by identity (not index) keeps SwiftUI from reusing a deleted row's field.
        let number = (steps.firstIndex { $0.id == step.wrappedValue.id } ?? 0) + 1
        return HStack(alignment: .top, spacing: Spacing.sm) {
            Text("\(number)")
                .font(.scLabel)
                .foregroundStyle(Color.scAccent)
                .frame(width: 24, alignment: .leading)
                .padding(.top, Spacing.sm)
            TextField("Step", text: step.text, axis: .vertical)
                .font(.scBody)
                .foregroundStyle(Color.scTextPrimary)
                .padding(Spacing.sm)
                .background(Color.scSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            deleteButton { removeStep(step.wrappedValue.id) }
                .accessibilityLabel("Remove step")
                .padding(.top, Spacing.sm)
        }
    }

    private func deleteButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.scTextSecondary.opacity(0.7))
        }
        .buttonStyle(.plain)
    }

    private func addButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle")
                .font(.scLabel)
                .foregroundStyle(Color.scAccent)
                .padding(.vertical, Spacing.xs)
        }
    }

    private func removeIngredient(_ id: UUID) {
        ingredients.removeAll { $0.id == id }
        runValidation()
    }

    private func removeStep(_ id: UUID) {
        steps.removeAll { $0.id == id }
    }

    private func validationSection(report: ValidationReport) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if report.hasFailed {
                ForEach(report.failures, id: \.name) { check in
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(check.message)
                            .font(.scCaption)
                            .foregroundStyle(Color.scTextPrimary)
                    }
                    .padding(Spacing.sm)
                    .background(Color.red.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            if report.hasWarnings {
                ForEach(report.warnings, id: \.name) { check in
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(check.message)
                            .font(.scCaption)
                            .foregroundStyle(Color.scTextPrimary)
                    }
                    .padding(Spacing.sm)
                    .background(Color.yellow.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: Spacing.sm) {
            Button {
                saveRecipe()
            } label: {
                Label("Save to Library", systemImage: "bookmark.fill")
                    .font(.scLabel)
                    .frame(maxWidth: .infinity)
                    .padding(Spacing.md)
                    .background(Color.scAccent)
                    .foregroundStyle(Color.scBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)

            if let onRetry {
                Button {
                    onRetry()
                    dismiss()
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .font(.scLabel)
                        .frame(maxWidth: .infinity)
                        .padding(Spacing.md)
                        .background(Color.scSurface)
                        .foregroundStyle(Color.scTextSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(.top, Spacing.lg)
    }

    // MARK: - Helpers

    private var substituteBanner: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20))
                .foregroundStyle(Color.scAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Similar Recipe")
                    .font(.scLabel)
                    .foregroundStyle(Color.scTextPrimary)
                Text("We couldn't find the exact recipe from this video. Here's a similar one we found online.")
                    .font(.scCaption)
                    .foregroundStyle(Color.scTextSecondary)
            }
        }
        .padding(Spacing.md)
        .background(Color.scAccent.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.scAccent.opacity(0.3), lineWidth: 1)
        )
    }

    private var confidenceColor: Color {
        switch extractionResult.confidence {
        case 0.7...: return .green
        case 0.4..<0.7: return .yellow
        default: return .red
        }
    }

    private func ingredientBackground(for ingredient: EditableIngredient) -> Color {
        switch ingredient.validationSeverity {
        case .fail: return Color.red.opacity(0.12)
        case .warn: return Color.yellow.opacity(0.10)
        default: return Color.scSurface
        }
    }

    private func ingredientBorder(for ingredient: EditableIngredient) -> Color {
        switch ingredient.validationSeverity {
        case .fail: return Color.red.opacity(0.4)
        case .warn: return Color.yellow.opacity(0.4)
        default: return Color.clear
        }
    }

    private func runValidation() {
        let parsedIngredients = ingredients.map { parser.parse(raw: $0.text) }
        // Rebuild a result with current edits for validation
        var editedResult = extractionResult
        editedResult.title = title.isEmpty ? nil : title
        editedResult.ingredients = ingredients.map { RawIngredient(text: $0.text) }
        editedResult.steps = steps.enumerated().map { idx, s in RawStep(order: idx + 1, text: s.text) }
        let report = validator.validate(result: editedResult, ingredients: parsedIngredients)
        validationReport = report

        // Tag each ingredient with its validation state
        for (idx, parsed) in parsedIngredients.enumerated() {
            guard idx < ingredients.count else { continue }
            // A row the user hasn't filled in yet (blank) is neutral, not a failure —
            // otherwise a fresh manual recipe or a just-added row flashes red.
            if ingredients[idx].text.trimmingCharacters(in: .whitespaces).isEmpty {
                ingredients[idx].validationSeverity = .pass
                continue
            }
            let hasQuantity = parsed.quantity != nil
            let hasItem = !parsed.item.isEmpty
            if !hasQuantity && !hasItem {
                ingredients[idx].validationSeverity = .fail
            } else if !hasQuantity {
                let isExempt = ParsedIngredient.quantityExempt.contains(parsed.item.lowercased()) ||
                               ParsedIngredient.quantityExempt.contains {
                                   parsed.item.lowercased().hasPrefix($0)
                               }
                ingredients[idx].validationSeverity = isExempt ? .pass : .warn
            } else {
                ingredients[idx].validationSeverity = .pass
            }
        }
    }

    private func saveRecipe() {
        // Persist provenance (was previously dropped — both branches of a no-op ternary were nil).
        // The link to open is the actual recipe page when we have it, else the submitted URL;
        // the platform badge is decided by what the user originally submitted (a TikTok import
        // keeps its TikTok identity even when the recipe text came from a linked blog page).
        let storedURL = extractionResult.recipePageURL ?? extractionResult.originalSourceURL
        let platformURL = extractionResult.originalSourceURL ?? extractionResult.recipePageURL

        let recipe = Recipe(
            title: title.trimmingCharacters(in: .whitespaces),
            sourceURL: storedURL,
            sourceType: resolvedSourceType(platformURL: platformURL),
            extractionConfidence: extractionResult.confidence,
            extractionMethod: extractionResult.extractionMethod
        )
        recipe.thumbnailURL = extractionResult.thumbnailURL
        recipe.recipeYield = recipeYield.isEmpty ? nil : recipeYield
        recipe.recipeDescription = extractionResult.description
        recipe.appliances = extractionResult.appliances
        recipe.prepTime = extractionResult.prepTime
        recipe.cookTime = extractionResult.cookTime
        recipe.totalTime = extractionResult.totalTime
        recipe.userVerified = true

        // Parse and create ingredients — blank rows (e.g. an unused starter/added row)
        // are dropped so they don't persist as empty entries.
        recipe.ingredients = ingredients
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .enumerated().map { idx, editable in
                let parsed = parser.parse(raw: editable.text)
                let ingredient = Ingredient(item: parsed.item, rawText: editable.text, order: idx)
                ingredient.quantity = parsed.quantity
                ingredient.unit = parsed.unit
                ingredient.preparation = parsed.preparation
                ingredient.section = parsed.section
                return ingredient
            }

        // Create steps (blank rows dropped, order re-numbered from what remains).
        recipe.steps = steps
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .enumerated().map { idx, editable in
                CookingStep(order: idx + 1, instruction: editable.text, rawText: editable.text)
            }

        modelContext.insert(recipe)
        onSave?(recipe)
        dismiss()
    }

    /// Recipes imported from a URL keep their platform badge (web/tiktok/…). Recipes with
    /// no URL are badged by how they were created, so the Library shows an honest source.
    private func resolvedSourceType(platformURL: String?) -> String {
        if let platformURL, !platformURL.isEmpty {
            return URLRouter.sourceType(forStoredURL: platformURL)
        }
        switch extractionResult.extractionMethod {
        case "manual":       return "manual"
        case "photo-ocr":    return "photo"
        case "pasted-text":  return "pasted"
        default:             return "web"
        }
    }
}

// MARK: - Supporting Types

struct EditableIngredient: Identifiable {
    let id = UUID()
    var text: String
    var validationSeverity: ValidationSeverity = .pass

    init(raw: RawIngredient) {
        self.text = raw.text
    }
}

struct EditableStep: Identifiable {
    let id = UUID()
    var text: String

    init(raw: RawStep) {
        self.text = raw.text
    }
}

// MARK: - Preview

#Preview("ReviewView — Good Extraction") {
    let result: ExtractionResult = {
        var r = ExtractionResult(extractionMethod: "schema-org-jsonld")
        r.title = "Classic Chocolate Chip Cookies"
        r.recipeYield = "36 cookies"
        r.prepTime = 15 * 60
        r.cookTime = 11 * 60
        r.confidence = 0.9
        r.ingredients = [
            RawIngredient(text: "2 1/4 cups all-purpose flour"),
            RawIngredient(text: "1 tsp baking soda"),
            RawIngredient(text: "1 tsp salt"),
            RawIngredient(text: "1 cup (2 sticks) butter, softened"),
            RawIngredient(text: "3/4 cup granulated sugar"),
            RawIngredient(text: "3/4 cup packed brown sugar"),
            RawIngredient(text: "2 large eggs"),
            RawIngredient(text: "2 tsp vanilla extract"),
            RawIngredient(text: "2 cups chocolate chips"),
        ]
        r.steps = [
            RawStep(order: 1, text: "Preheat oven to 375°F."),
            RawStep(order: 2, text: "Combine flour, baking soda and salt in bowl."),
            RawStep(order: 3, text: "Beat butter and sugars in large mixer bowl until creamy."),
            RawStep(order: 4, text: "Add eggs and vanilla extract; beat well."),
            RawStep(order: 5, text: "Gradually blend in flour mixture. Stir in chocolate chips."),
            RawStep(order: 6, text: "Drop rounded tablespoon of dough onto ungreased baking sheets."),
            RawStep(order: 7, text: "Bake for 9 to 11 minutes or until golden brown."),
        ]
        return r
    }()

    ReviewView(result: result)
        .preferredColorScheme(.dark)
}
