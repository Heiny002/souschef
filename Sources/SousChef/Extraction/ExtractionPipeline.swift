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

        // Layer 2: Microdata — stub (SC-020)
        // Layer 3: Heuristic HTML — stub (SC-021)
        // Layer 4: LLM fallback — stub (SC-030)

        // Return best available result
        return layer1
    }

    /// Parse raw ingredients from an ExtractionResult using IngredientParser.
    func parseIngredients(from result: ExtractionResult) -> [ParsedIngredient] {
        result.ingredients.enumerated().map { idx, raw in
            parser.parse(raw: raw.text, section: raw.section)
        }
    }
}
