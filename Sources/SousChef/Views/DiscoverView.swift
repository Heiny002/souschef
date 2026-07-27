import SwiftUI
import SwiftData

/// Recipe discovery: search the web by dish name, or by what's in the fridge, then import
/// the result through the same extraction → review flow as any other import.
///
/// The search finds real recipe PAGES (see PerplexitySearcher); picking one runs the existing
/// extraction chain against it, so quantities come from the actual recipe rather than from a
/// model's recollection.
struct DiscoverView: View {
    @Environment(\.modelContext) private var modelContext

    private enum Mode: String, CaseIterable, Identifiable {
        case dish = "Dish"
        case ingredients = "What can I make?"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .dish
    @State private var query = ""
    @State private var results: [PerplexitySearcher.Discovery] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var importing: PerplexitySearcher.Discovery?
    @State private var importedResult: ExtractionResult?
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.scBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    searchControls
                    Divider().overlay(Color.scBorder)
                    content
                }
            }
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.scBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(item: $importedResult) { result in
                ReviewView(result: result, screenTitle: "Review Recipe", showsCancelButton: true)
            }
        }
    }

    // MARK: - Search controls

    private var searchControls: some View {
        VStack(spacing: Spacing.sm) {
            Picker("Search by", selection: $mode) {
                ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { _, _ in
                results = []
                hasSearched = false
            }

            HStack(spacing: Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.scTextSecondary)
                TextField(placeholder, text: $query)
                    .font(.scBody)
                    .foregroundStyle(Color.scTextPrimary)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit(runSearch)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.scTextSecondary)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(Spacing.sm)
            .background(Color.scSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if mode == .ingredients {
                Text("Separate ingredients with commas — chicken, lemon, capers")
                    .font(.scCaption)
                    .foregroundStyle(Color.scTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Spacing.md)
    }

    private var placeholder: String {
        mode == .dish ? "Search for a recipe…" : "What's in your fridge?"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !PerplexitySearcher.isConfigured {
            notice(icon: "key",
                   title: "Search isn't set up yet",
                   message: "Add PERPLEXITY_API_KEY to Secrets.xcconfig and rebuild to enable recipe search.")
        } else if isSearching {
            VStack(spacing: Spacing.md) {
                ProgressView().tint(Color.scAccent)
                Text(mode == .dish ? "Searching for recipes…" : "Finding what you can make…")
                    .font(.scCaption)
                    .foregroundStyle(Color.scTextSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let importError {
            notice(icon: "exclamationmark.triangle", title: "Couldn't import that one",
                   message: importError)
        } else if results.isEmpty && hasSearched {
            notice(icon: "magnifyingglass", title: "No recipes found",
                   message: "Try different wording, or fewer ingredients.")
        } else if results.isEmpty {
            notice(icon: "sparkles", title: "Find something to cook",
                   message: mode == .dish
                       ? "Search for any dish and import the recipe straight into your library."
                       : "List what you have and see what you can make with it.")
        } else {
            resultsList
        }
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: Spacing.sm) {
                ForEach(results) { result in
                    resultCard(result)
                }
            }
            .padding(Spacing.md)
        }
    }

    private func resultCard(_ result: PerplexitySearcher.Discovery) -> some View {
        Button {
            importRecipe(result)
        } label: {
            HStack(alignment: .top, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(result.title)
                        .font(.scHeadline)
                        .foregroundStyle(Color.scTextPrimary)
                        .multilineTextAlignment(.leading)
                    if let summary = result.summary {
                        Text(summary)
                            .font(.scCaption)
                            .foregroundStyle(Color.scTextSecondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                    }
                    if let site = result.siteName {
                        Label(site, systemImage: "globe")
                            .font(.scCaption)
                            .foregroundStyle(Color.scAccent)
                    }
                }
                Spacer(minLength: 0)
                if importing?.id == result.id {
                    ProgressView().tint(Color.scAccent)
                } else {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundStyle(Color.scAccent)
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.scSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(importing != nil)
        .accessibilityHint("Import this recipe")
    }

    private func notice(icon: String, title: String, message: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(Color.scTextSecondary)
            Text(title)
                .font(.scHeadline)
                .foregroundStyle(Color.scTextPrimary)
            Text(message)
                .font(.scCaption)
                .foregroundStyle(Color.scTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSearching else { return }
        isSearching = true
        importError = nil

        let searchMode: PerplexitySearcher.Mode = mode == .dish
            ? .dish(trimmed)
            : .ingredients(trimmed.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })

        Task {
            let found = await PerplexitySearcher.search(searchMode)
            await MainActor.run {
                results = found
                isSearching = false
                hasSearched = true
            }
        }
    }

    /// Run the found page through the normal extraction chain, then hand it to the review
    /// screen — the same path as pasting a URL, so scaling/components/equipment all apply.
    private func importRecipe(_ discovery: PerplexitySearcher.Discovery) {
        guard importing == nil else { return }
        importing = discovery
        importError = nil

        Task {
            let pipeline = ExtractionPipeline()
            let extracted = try? await pipeline.extract(from: discovery.url)
            await MainActor.run {
                importing = nil
                guard var extracted, extracted.isViable else {
                    importError = "\"\(discovery.title)\" couldn't be read automatically. "
                        + "Try another result, or open it and paste the recipe text."
                    return
                }
                // Prefer the page's own title, but fall back to what search called it.
                if extracted.title == nil { extracted.title = discovery.title }
                importedResult = extracted
            }
        }
    }
}

/// `sheet(item:)` needs identity; an extraction is identified by where it came from.
/// Deliberately stable (no UUID fallback) — a changing id would make SwiftUI tear down and
/// re-present the review sheet on every redraw.
extension ExtractionResult: Identifiable {
    var id: String {
        recipePageURL ?? originalSourceURL ?? title ?? extractionMethod
    }
}
