import Foundation

/// Protocol all extraction layers implement.
protocol RecipeExtractor {
    func extract(html: String) -> ExtractionResult
    var method: String { get }
}

extension SchemaOrgExtractor: RecipeExtractor {
    var method: String { "schema-org-jsonld" }
}

/// Chain-of-responsibility orchestrator for web recipe extraction.
/// Layers: Layer 1 (JSON-LD) → Layer 2 (Microdata) → Layer 3 (Heuristic) → Layer 4 (LLM fallback)
actor ExtractionPipeline {
    private let fetcher: WebPageFetcher
    private let parser = IngredientParser()

    init(fetcher: WebPageFetcher = WebPageFetcher()) {
        self.fetcher = fetcher
    }

    /// Extract a recipe from a URL. Returns the best result found across all layers.
    func extract(from urlString: String) async throws -> ExtractionResult {
        let sourceType = URLRouter.classify(urlString)

        switch sourceType {
        case .webPage:
            return try await extractFromWebPage(urlString: urlString)
        case .tikTok, .instagram, .youTube:
            // Video extraction — stub for Week 3 stories
            return ExtractionResult(extractionMethod: "video-pending")
        }
    }

    // MARK: - Web Extraction Chain

    private func extractFromWebPage(urlString: String) async throws -> ExtractionResult {
        let html = try await fetcher.fetch(urlString: urlString)
        return extractFromHTML(html: html)
    }

    /// Run the extraction chain on pre-fetched HTML (useful for testing).
    func extractFromHTML(html: String) -> ExtractionResult {
        // Layer 1: Schema.org JSON-LD
        let layer1 = SchemaOrgExtractor().extract(html: html)
        if layer1.confidence >= ConfidenceThreshold.accept {
            return layer1
        }

        // Layer 2: Microdata
        var layer2 = MicrodataExtractor().extract(html: html)
        layer2 = merge(base: layer1, onto: layer2)
        if layer2.confidence >= ConfidenceThreshold.accept {
            return layer2
        }

        // Layer 3: Heuristic HTML
        var layer3 = HeuristicExtractor().extract(html: html)
        layer3 = merge(base: layer2, onto: layer3)
        if layer3.confidence >= ConfidenceThreshold.reject {
            return layer3
        }

        // Layer 4: LLM fallback — stub (SC-030)

        // Return best available result (highest confidence)
        return [layer1, layer2, layer3].max(by: { $0.confidence < $1.confidence }) ?? layer3
    }

    /// Merge earlier-layer partial results into a later-layer result (fill gaps only).
    private func merge(base: ExtractionResult, onto target: ExtractionResult) -> ExtractionResult {
        var result = target
        if result.title == nil { result.title = base.title }
        if result.recipeYield == nil { result.recipeYield = base.recipeYield }
        if result.prepTime == nil { result.prepTime = base.prepTime }
        if result.cookTime == nil { result.cookTime = base.cookTime }
        if result.totalTime == nil { result.totalTime = base.totalTime }
        if result.ingredients.isEmpty { result.ingredients = base.ingredients }
        if result.steps.isEmpty { result.steps = base.steps }
        if result.appliances.isEmpty { result.appliances = base.appliances }
        return result
    }

    /// Parse raw ingredients from an ExtractionResult using IngredientParser.
    func parseIngredients(from result: ExtractionResult) -> [ParsedIngredient] {
        result.ingredients.enumerated().map { idx, raw in
            parser.parse(raw: raw.text, section: raw.section)
        }
    }
}
