import SwiftUI
import SwiftData

/// SC-023: Recipe Library — grid/list of saved recipes with search and sort.
struct RecipeLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var recipes: [Recipe]

    @State private var searchText = ""
    @State private var sortOrder = SortOption.dateAdded
    @State private var showImportSheet = false
    @State private var pendingDelete: Recipe?

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
                VStack(spacing: 0) {
                    buildStamp
                    content
                }
            }
            .navigationTitle("Library")
            .toolbarBackground(Color.scBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { toolbarItems }
            .searchable(text: $searchText, prompt: "Search recipes")
            .sheet(isPresented: $showImportSheet) {
                ImportView()
            }
            .confirmationDialog(
                "Delete this recipe?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { recipe in
                Button("Delete", role: .destructive) { delete(recipe) }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { recipe in
                Text("\"\(recipe.title)\" will be permanently removed.")
            }
        }
    }

    private func delete(_ recipe: Recipe) {
        modelContext.delete(recipe)   // cascade rules remove its ingredients & steps
        pendingDelete = nil
    }

    // MARK: - Build stamp (testing aid)

    /// Shows when the running binary was compiled, so it's obvious at a glance whether
    /// this install includes the latest changes. Remove (or gate behind DEBUG) once the
    /// testing phase is over.
    private var buildStamp: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 9))
            Text(BuildInfo.stamp)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.scTextSecondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(Color.scSurface)
        .accessibilityLabel("App built \(BuildInfo.stamp)")
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
                    .contextMenu {
                        Button(role: .destructive) {
                            pendingDelete = recipe
                        } label: {
                            Label("Delete Recipe", systemImage: "trash")
                        }
                    }
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
            .accessibilityLabel("Sort recipes")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showImportSheet = true
            } label: {
                Image(systemName: "plus")
                    .foregroundStyle(Color.scAccent)
            }
            .accessibilityLabel("Import recipe")
        }
    }
}

// MARK: - Build info

/// Identifies which CODE VERSION this install was built from.
///
/// The "Stamp commit info" build phase writes CommitInfo.json (last git commit date +
/// short hash of the checkout) into the bundle on every build. That's what the stamp
/// shows — "Updated <commit date> · <hash>" — so it answers "am I running the latest
/// code?" regardless of when the binary happened to be compiled. Rebuilding without
/// pulling keeps the old commit date, correctly revealing a stale checkout.
///
/// Fallback (no git available / script failed): the binary's compile time, labelled
/// "Build …" so it can't be mistaken for a code-version date.
enum BuildInfo {
    private struct CommitInfo: Decodable {
        let commitDate: String
        let commitHash: String
    }

    static let stamp: String = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        if let url = Bundle.main.url(forResource: "CommitInfo", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let info = try? JSONDecoder().decode(CommitInfo.self, from: data),
           let date = ISO8601DateFormatter().date(from: info.commitDate) {
            let hash = info.commitHash.isEmpty ? "" : " · \(info.commitHash)"
            return "Updated \(formatter.string(from: date))\(hash)"
        }

        if let url = Bundle.main.executableURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let date = attrs[.modificationDate] as? Date {
            return "Build \(formatter.string(from: date))"
        }
        return "Version unavailable"
    }()
}

// MARK: - Source display

/// Human-facing label + SF Symbol for a recipe's stored `sourceType`.
enum RecipeSourceStyle {
    static func label(_ sourceType: String) -> String {
        switch sourceType.lowercased() {
        case "tiktok":    return "TikTok"
        case "instagram": return "Instagram"
        case "youtube":   return "YouTube"
        case "manual":    return "Manual"
        default:          return "Web"
        }
    }

    static func symbol(_ sourceType: String) -> String {
        switch sourceType.lowercased() {
        case "tiktok", "instagram", "youtube": return "play.rectangle.fill"
        case "manual":                          return "square.and.pencil"
        default:                                return "globe"
        }
    }
}

// MARK: - Recipe Card

struct RecipeCard: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Recipe photo (when we captured one at import)
            if let image = URLRouter.safeExternalURL(recipe.thumbnailURL) {
                AsyncImage(url: image) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        Color.scBorder
                    }
                }
                .frame(height: 84)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

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
        Label(RecipeSourceStyle.label(recipe.sourceType), systemImage: RecipeSourceStyle.symbol(recipe.sourceType))
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
    @Query private var allDiners: [DinerProfile]
    @State private var showCookMode = false
    @State private var showCompatibility = false
    @State private var unitMode: UnitMode = .original
    @State private var showDeleteConfirm = false

    var body: some View {
        ZStack {
            Color.scBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    // Hero photo (when captured at import)
                    if let image = URLRouter.safeExternalURL(recipe.thumbnailURL) {
                        AsyncImage(url: image) { phase in
                            if let img = phase.image {
                                img.resizable().scaledToFill()
                            } else {
                                Color.scSurface
                            }
                        }
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

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
                        // Source attribution + link back to the original.
                        if let link = URLRouter.safeExternalURL(recipe.sourceURL) {
                            Link(destination: link) {
                                Label("View original on \(RecipeSourceStyle.label(recipe.sourceType))",
                                      systemImage: RecipeSourceStyle.symbol(recipe.sourceType))
                                    .font(.scCaption)
                                    .foregroundStyle(Color.scAccent)
                            }
                            .padding(.top, Spacing.xs)
                        }
                    }

                    Divider().overlay(Color.scBorder)

                    // Ingredients
                    if !recipe.ingredients.isEmpty {
                        ingredientsSectionHeader
                        ForEach(recipe.ingredients.sorted(by: { $0.order < $1.order })) { ingredient in
                            Text(IngredientConverter.display(ingredient, mode: unitMode))
                                .font(.scBody)
                                .foregroundStyle(Color.scTextPrimary)
                                .padding(.vertical, Spacing.xs)
                                .animation(.easeInOut(duration: 0.2), value: unitMode)
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
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !allDiners.isEmpty {
                    Button {
                        showCompatibility = true
                    } label: {
                        Image(systemName: "person.2.badge.checkmark")
                            .foregroundStyle(Color.scAccent)
                    }
                }
                if !recipe.steps.isEmpty {
                    Button {
                        showCookMode = true
                    } label: {
                        Label("Cook", systemImage: "flame.fill")
                            .foregroundStyle(Color.scAccent)
                    }
                }
                Menu {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete Recipe", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Color.scTextPrimary)
                }
                .accessibilityLabel("More actions")
            }
        }
        .confirmationDialog(
            "Delete this recipe?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                modelContext.delete(recipe)   // cascade removes ingredients & steps
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("\"\(recipe.title)\" will be permanently removed.")
        }
        .fullScreenCover(isPresented: $showCookMode) {
            CookModeView(recipe: recipe)
        }
        .sheet(isPresented: $showCompatibility) {
            CompatibilityView(recipe: recipe, diners: allDiners)
        }
    }

    /// Ingredients header with inline unit-mode picker.
    private var ingredientsSectionHeader: some View {
        HStack(alignment: .center) {
            Label("Ingredients", systemImage: "list.bullet")
                .font(.scLabel)
                .foregroundStyle(Color.scAccent)
            Spacer()
            Menu {
                ForEach(UnitMode.allCases) { mode in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { unitMode = mode }
                    } label: {
                        Label(mode.rawValue, systemImage: mode.icon)
                        if unitMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: unitMode.icon)
                        .font(.system(size: 11))
                    Text(unitMode.rawValue)
                        .font(.scCaption)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                }
                .foregroundStyle(unitMode == .original ? Color.scTextSecondary : Color.scAccent)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 5)
                .background(Color.scSurface)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(
                        unitMode == .original ? Color.scBorder : Color.scAccent.opacity(0.5),
                        lineWidth: 1
                    )
                )
            }
        }
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
