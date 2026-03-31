import SwiftUI

/// Overlay sheet presenting a similar recipe found via web search.
/// Shows photo, title, first 5 ingredients, and three actions:
///   • Use This Recipe — accept and open in ReviewView
///   • Try Next Similar — cycle to the next alternative
///   • Paste a Link — dismiss sheet so user can type a direct URL
struct SimilarRecipePreviewSheet: View {
    let alternatives: [ExtractionResult]
    let onAccept: (ExtractionResult) -> Void
    let onPasteLink: () -> Void
    let onDismiss: () -> Void

    @State private var currentIndex: Int = 0

    private var current: ExtractionResult? {
        guard currentIndex < alternatives.count else { return nil }
        return alternatives[currentIndex]
    }

    var body: some View {
        ZStack {
            Color.scBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                // Drag handle
                Capsule()
                    .fill(Color.scBorder)
                    .frame(width: 36, height: 4)
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, Spacing.md)

                if let recipe = current {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: Spacing.lg) {
                            headerLabel
                            thumbnailSection(recipe: recipe)
                            recipeInfoSection(recipe: recipe)
                            ingredientsPreview(recipe: recipe)
                            actionButtons(recipe: recipe)
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.bottom, Spacing.xl)
                    }
                } else {
                    noAlternativesView
                }
            }
        }
    }

    // MARK: - Subviews

    private var headerLabel: some View {
        HStack {
            Label("Similar Recipe Found", systemImage: "magnifyingglass")
                .font(.scCaption)
                .foregroundStyle(Color.scAccent)
            Spacer()
            if alternatives.count > 1 {
                Text("\(currentIndex + 1) of \(alternatives.count)")
                    .font(.scCaption)
                    .foregroundStyle(Color.scTextSecondary)
            }
        }
    }

    @ViewBuilder
    private func thumbnailSection(recipe: ExtractionResult) -> some View {
        if let thumbnailURL = recipe.thumbnailURL, let url = URL(string: thumbnailURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                case .failure, .empty:
                    placeholderThumbnail
                @unknown default:
                    placeholderThumbnail
                }
            }
        } else {
            placeholderThumbnail
        }
    }

    private var placeholderThumbnail: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.scSurface)
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .overlay(
                Image(systemName: "fork.knife")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.scBorder)
            )
    }

    @ViewBuilder
    private func recipeInfoSection(recipe: ExtractionResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let title = recipe.title {
                Text(title)
                    .font(.scTitle)
                    .foregroundStyle(Color.scTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Spacing.md) {
                if let totalTime = recipe.totalTime, totalTime > 0 {
                    Label(formatDuration(totalTime), systemImage: "clock")
                        .font(.scCaption)
                        .foregroundStyle(Color.scTextSecondary)
                }
                if let yield = recipe.recipeYield {
                    Label(yield, systemImage: "person.2")
                        .font(.scCaption)
                        .foregroundStyle(Color.scTextSecondary)
                }
                if !recipe.ingredients.isEmpty {
                    Label("\(recipe.ingredients.count) ingredients", systemImage: "list.bullet")
                        .font(.scCaption)
                        .foregroundStyle(Color.scTextSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func ingredientsPreview(recipe: ExtractionResult) -> some View {
        let preview = Array(recipe.ingredients.prefix(5))
        if !preview.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("INGREDIENTS PREVIEW")
                    .font(.scCaption)
                    .foregroundStyle(Color.scTextSecondary)
                    .tracking(1)
                ForEach(preview.indices, id: \.self) { idx in
                    HStack(alignment: .top, spacing: Spacing.sm) {
                        Circle()
                            .fill(Color.scAccent)
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                        Text(preview[idx].text)
                            .font(.scBody)
                            .foregroundStyle(Color.scTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if recipe.ingredients.count > 5 {
                    Text("+ \(recipe.ingredients.count - 5) more ingredients")
                        .font(.scCaption)
                        .foregroundStyle(Color.scTextSecondary)
                        .padding(.leading, Spacing.md)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.md)
            .background(Color.scSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private func actionButtons(recipe: ExtractionResult) -> some View {
        VStack(spacing: Spacing.sm) {
            // Primary: accept this recipe
            Button {
                onAccept(recipe)
            } label: {
                Label("Use This Recipe", systemImage: "checkmark.circle.fill")
                    .font(.scLabel)
                    .frame(maxWidth: .infinity)
                    .padding(Spacing.md)
                    .background(Color.scAccent)
                    .foregroundStyle(Color.scBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            // Secondary: next alternative (shown only if there is one)
            if currentIndex + 1 < alternatives.count {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentIndex += 1
                    }
                } label: {
                    Label("Try Next Similar", systemImage: "arrow.right.circle")
                        .font(.scLabel)
                        .frame(maxWidth: .infinity)
                        .padding(Spacing.md)
                        .background(Color.scSurface)
                        .foregroundStyle(Color.scTextPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12).stroke(Color.scBorder, lineWidth: 1)
                        )
                }
            }

            // Tertiary: paste a direct link instead
            Button {
                onPasteLink()
            } label: {
                Text("Paste Direct Recipe Link")
                    .font(.scCaption)
                    .foregroundStyle(Color.scTextSecondary)
                    .padding(.vertical, Spacing.xs)
            }
        }
    }

    private var noAlternativesView: some View {
        VStack(spacing: Spacing.md) {
            Spacer()
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 48))
                .foregroundStyle(Color.scBorder)
            Text("No similar recipes found")
                .font(.scHeadline)
                .foregroundStyle(Color.scTextPrimary)
            Button("Paste a Recipe Link") { onPasteLink() }
                .font(.scBody)
                .foregroundStyle(Color.scAccent)
            Spacer()
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }
}

#Preview("Similar Recipe Sheet") {
    var sample = ExtractionResult(extractionMethod: "schema-org-jsonld")
    sample.title = "Roasted Red Pepper Pasta with Burrata"
    sample.recipeYield = "4 servings"
    sample.totalTime = 1800
    sample.ingredients = [
        RawIngredient(text: "2 red bell peppers, roasted"),
        RawIngredient(text: "200g pasta of choice"),
        RawIngredient(text: "1 ball burrata"),
        RawIngredient(text: "3 cloves garlic, minced"),
        RawIngredient(text: "2 tbsp olive oil"),
        RawIngredient(text: "Salt and pepper to taste"),
    ]
    sample.isSubstitute = true
    return SimilarRecipePreviewSheet(
        alternatives: [sample],
        onAccept: { _ in },
        onPasteLink: { },
        onDismiss: { }
    )
    .preferredColorScheme(.dark)
}
