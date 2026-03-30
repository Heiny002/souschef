import SwiftUI
import SwiftData

/// SC-023: Recipe Library — grid/list of saved recipes with search and sort.
struct RecipeLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var recipes: [Recipe]

    @State private var searchText = ""
    @State private var sortOrder = SortOption.dateAdded
    @State private var showImportSheet = false

    enum SortOption: String, CaseIterable {
        case dateAdded = "Date Added"
        case title = "Title"
        case sourceType = "Source"
    }

    var filteredRecipes: [Recipe] {
        var result = recipes
        if !searchText.isEmpty {
            result = result.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
        switch sortOrder {
        case .dateAdded:  result.sort { $0.dateAdded > $1.dateAdded }
        case .title:      result.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .sourceType: result.sort { $0.sourceType < $1.sourceType }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.scBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("Library")
            .toolbarBackground(Color.scBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { toolbarItems }
            .searchable(text: $searchText, prompt: "Search recipes")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if filteredRecipes.isEmpty {
            emptyState
        } else {
            recipeGrid
        }
    }

    private var recipeGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.md) {
                ForEach(filteredRecipes) { recipe in
                    NavigationLink(destination: RecipeDetailView(recipe: recipe)) {
                        RecipeCard(recipe: recipe)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Spacing.md)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "book.closed")
                .font(.system(size: 56))
                .foregroundStyle(Color.scTextSecondary)
            Text(searchText.isEmpty ? "No recipes yet" : "No results for \"\(searchText)\"")
                .font(.scHeadline)
                .foregroundStyle(Color.scTextPrimary)
            if searchText.isEmpty {
                Text("Paste a recipe URL to get started")
                    .font(.scBody)
                    .foregroundStyle(Color.scTextSecondary)
                Button {
                    showImportSheet = true
                } label: {
                    Label("Import Recipe", systemImage: "link.badge.plus")
                        .font(.scLabel)
                        .padding(.horizontal, Spacing.lg)
                        .padding(.vertical, Spacing.sm)
                        .background(Color.scAccent)
                        .foregroundStyle(Color.scBackground)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(Spacing.xl)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort by", selection: $sortOrder) {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .foregroundStyle(Color.scTextPrimary)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showImportSheet = true
            } label: {
                Image(systemName: "plus")
                    .foregroundStyle(Color.scAccent)
            }
        }
    }
}

// MARK: - Recipe Card

struct RecipeCard: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Source badge + confidence dot
            HStack {
                sourceTypeBadge
                Spacer()
                confidenceDot
            }

            Spacer()

            // Title
            Text(recipe.title)
                .font(.scTitle)
                .foregroundStyle(Color.scTextPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            // Metadata
            HStack(spacing: Spacing.sm) {
                if let total = recipe.totalTime {
                    Label(formatDuration(total), systemImage: "clock")
                        .font(.scCaption)
                        .foregroundStyle(Color.scTextSecondary)
                }
                if recipe.userVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.scCaption)
                        .foregroundStyle(Color.scAccent)
                }
            }
        }
        .padding(Spacing.md)
        .frame(minHeight: 140)
        .background(Color.scSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.scBorder, lineWidth: 1)
        )
    }

    private var sourceTypeBadge: some View {
        Text(recipe.sourceType.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.scTextSecondary)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2)
            .background(Color.scBorder)
            .clipShape(Capsule())
    }

    private var confidenceDot: some View {
        Circle()
            .fill(confidenceColor)
            .frame(width: 8, height: 8)
    }

    private var confidenceColor: Color {
        switch recipe.extractionConfidence {
        case 0.7...: return .green
        case 0.4..<0.7: return .yellow
        default: return .red
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

// MARK: - Recipe Detail (stub for now — filled in with Cook Mode story)

struct RecipeDetailView: View {
    let recipe: Recipe
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.scBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    // Header
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(recipe.title)
                            .font(.scDisplay)
                            .foregroundStyle(Color.scTextPrimary)
                        HStack(spacing: Spacing.md) {
                            if let total = recipe.totalTime {
                                Label(formatDuration(total), systemImage: "clock")
                                    .font(.scCaption)
                                    .foregroundStyle(Color.scTextSecondary)
                            }
                            if let yield = recipe.recipeYield {
                                Label(yield, systemImage: "person.2")
                                    .font(.scCaption)
                                    .foregroundStyle(Color.scTextSecondary)
                            }
                        }
                    }

                    Divider().overlay(Color.scBorder)

                    // Ingredients
                    if !recipe.ingredients.isEmpty {
                        sectionHeader("Ingredients", icon: "list.bullet")
                        ForEach(recipe.ingredients.sorted(by: { $0.order < $1.order })) { ingredient in
                            Text(ingredient.rawText)
                                .font(.scBody)
                                .foregroundStyle(Color.scTextPrimary)
                                .padding(.vertical, Spacing.xs)
                        }
                    }

                    Divider().overlay(Color.scBorder)

                    // Steps
                    if !recipe.steps.isEmpty {
                        sectionHeader("Instructions", icon: "checklist")
                        ForEach(recipe.steps.sorted(by: { $0.order < $1.order })) { step in
                            HStack(alignment: .top, spacing: Spacing.md) {
                                Text("\(step.order)")
                                    .font(.scLabel)
                                    .foregroundStyle(Color.scAccent)
                                    .frame(width: 24, alignment: .leading)
                                Text(step.instruction)
                                    .font(.scBody)
                                    .foregroundStyle(Color.scTextPrimary)
                            }
                            .padding(.vertical, Spacing.xs)
                        }
                    }

                    // Appliances
                    if !recipe.appliances.isEmpty {
                        Divider().overlay(Color.scBorder)
                        sectionHeader("Appliances", icon: "stove")
                        FlowLayout(spacing: Spacing.xs) {
                            ForEach(recipe.appliances, id: \.self) { appliance in
                                Text(appliance)
                                    .font(.scCaption)
                                    .padding(.horizontal, Spacing.sm)
                                    .padding(.vertical, Spacing.xs)
                                    .background(Color.scSurface)
                                    .clipShape(Capsule())
                                    .foregroundStyle(Color.scTextSecondary)
                            }
                        }
                    }
                }
                .padding(Spacing.md)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.scBackground, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.scLabel)
            .foregroundStyle(Color.scAccent)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

// MARK: - FlowLayout helper

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        y += rowHeight
        return CGSize(width: maxWidth, height: y)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Preview

#Preview("Recipe Library — Populated") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Recipe.self, DinerProfile.self, configurations: config)
    let ctx = container.mainContext

    // Seed with sample recipes
    let r1 = Recipe(title: "Chocolate Chip Cookies", sourceType: "web",
                    extractionConfidence: 0.9, extractionMethod: "schema-org-jsonld")
    r1.totalTime = 26 * 60; r1.userVerified = true
    let r2 = Recipe(title: "Pasta Carbonara", sourceType: "web",
                    extractionConfidence: 0.7, extractionMethod: "microdata")
    r2.totalTime = 20 * 60
    let r3 = Recipe(title: "Quick Stir Fry", sourceType: "tiktok",
                    extractionConfidence: 0.6, extractionMethod: "transcript-nlp")
    r3.totalTime = 15 * 60
    ctx.insert(r1); ctx.insert(r2); ctx.insert(r3)

    return RecipeLibraryView()
        .modelContainer(container)
        .preferredColorScheme(.dark)
}

#Preview("Recipe Library — Empty") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Recipe.self, DinerProfile.self, configurations: config)
    return RecipeLibraryView()
        .modelContainer(container)
        .preferredColorScheme(.dark)
}
