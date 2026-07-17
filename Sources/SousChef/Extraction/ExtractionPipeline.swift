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
    /// The optional `progress` callback receives status text for UI updates during multi-step extraction.
    func extract(from urlString: String, progress: (@Sendable (String) -> Void)? = nil) async throws -> ExtractionResult {
        let sourceType = URLRouter.classify(urlString)

        switch sourceType {
        case .webPage:
            return try await extractFromWebPage(urlString: urlString)
        case .tikTok, .instagram, .youTube:
            return await extractFromVideo(urlString: urlString, progress: progress)
        }
    }

    // MARK: - Video Extraction Chain

    private func extractFromVideo(urlString: String, progress: (@Sendable (String) -> Void)? = nil) async -> ExtractionResult {
        let metadataFetcher = VideoMetadataFetcher()

        // Step 1: oEmbed for caption / title (free, no auth)
        let metadata = try? await metadataFetcher.fetch(videoURL: urlString)
        let captionText = metadata?.caption ?? ""
        let titleHint = metadata?.title

        // Step 2: Try transcript endpoint (may be unavailable / server down)
        var videoTranscript: VideoTranscript?
        if let vt = try? await TranscriptFetcher.shared.fetchTranscript(videoURL: urlString) {
            videoTranscript = vt
        }

        // Step 2.5: SC-074 — Bio Link Resolution (deterministic, zero LLM tokens)
        let allCaptionText = [videoTranscript?.caption, captionText]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let signal = CaptionAnalyzer.analyze(allCaptionText)

        switch signal {
        case .directURL(let recipeURL):
            progress?("Following recipe link…")
            if let webResult = try? await extractFromWebPage(urlString: recipeURL),
               webResult.isViable {
                return webResult
            }

        case .linkInBio:
            progress?("Finding creator's blog…")
            if let resolvedURL = await BioLinkResolver.shared.resolve(
                authorName: metadata?.authorName,
                authorURL: metadata?.authorURL,
                serverBlogURL: videoTranscript?.blogURL
            ) {
                let keywords = CaptionAnalyzer.extractKeywords(
                    from: allCaptionText, using: FoodDictionary.shared)

                // If resolver returned a specific page (not just a domain root), try it
                // directly first — aggregators often link straight to the recipe post.
                if let resolvedPath = URL(string: resolvedURL)?.path, resolvedPath.count > 1 {
                    progress?("Extracting recipe…")
                    if let webResult = try? await extractFromWebPage(urlString: resolvedURL),
                       webResult.isViable {
                        return webResult
                    }
                }

                // Search the blog root by keywords (handles both root URLs and post URLs
                // returned by aggregator scoring — always strips to scheme+host).
                let blogRoot: String
                if let url = URL(string: resolvedURL),
                   let scheme = url.scheme, let host = url.host,
                   (url.path.count > 1) {
                    blogRoot = "\(scheme)://\(host)"
                } else {
                    blogRoot = resolvedURL
                }

                if !keywords.isEmpty {
                    progress?("Searching for recipe…")
                    if let recipePageURL = await BlogRecipeSearch.search(
                        blogURL: blogRoot, keywords: keywords) {
                        progress?("Extracting recipe…")
                        if let webResult = try? await extractFromWebPage(urlString: recipePageURL),
                           webResult.isViable {
                            return webResult
                        }
                    }
                }
            }

        case .none:
            break
        }

        // Step 3: Layer 5 — rule-based NLP on transcript (existing, unchanged)
        let transcriptText = videoTranscript?.combinedText
        let fullText = [transcriptText, captionText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")

        guard !fullText.isEmpty else {
            var empty = ExtractionResult(extractionMethod: "video-no-transcript")
            empty.title = titleHint
            empty.confidence = 0.1
            return empty
        }

        progress?("Analyzing transcript…")
        var result = TranscriptExtractor().extract(transcript: fullText)
        if result.title == nil { result.title = titleHint }

        guard result.confidence < ConfidenceThreshold.accept else { return result }

        // Step 4: Layer 6 — LLM validation / fallback
        guard let apiKey = APIKeyProvider.anthropicKey else {
            return result
        }
        let validator = TranscriptLLMValidator(apiKey: apiKey)
        result = (try? await validator.validate(transcript: fullText, partial: result)) ?? result

        // Step 5: SC-076 — Web search chain: profile discovery → targeted → general → collect similar
        if !result.isViable || result.confidence < ConfidenceThreshold.reject {
            let keywords = CaptionAnalyzer.extractKeywords(from: allCaptionText, using: FoodDictionary.shared)
            let rawHandle = authorHandle(from: metadata?.authorURL)
            // searchAuthorName starts as handle (e.g. "@kalememaybe"), may be upgraded to
            // real name (e.g. "Carina Wolff") by Stage 0 profile discovery below.
            var searchAuthorName = metadata?.authorName ?? rawHandle

            // Stage 0: Creator profile discovery via web search for the handle.
            // Finds Linktree/aggregator pages and blogs when direct profile access is login-gated.
            // Navigates aggregators for keyword-matched recipe links, extracts real name.
            if let handle = rawHandle?.trimmingCharacters(in: CharacterSet(charactersIn: "@")),
               !handle.isEmpty, !keywords.isEmpty {
                progress?("Looking up creator profile…")
                let profile = await CreatorProfileSearcher.discover(handle: handle, keywords: keywords)

                // 0a: Recipe URLs scored from aggregator pages (e.g. Linktree link for this dish)
                for recipeURL in profile.recipePageURLs {
                    if let webResult = try? await extractFromWebPage(urlString: recipeURL),
                       webResult.isViable {
                        var r = webResult
                        r.originalSourceURL = urlString
                        return r  // found the creator's actual recipe — not a substitute
                    }
                }

                // 0b: BlogRecipeSearch on discovered blog/substack URLs
                for blogURL in profile.blogURLs {
                    if let recipePageURL = await BlogRecipeSearch.search(blogURL: blogURL, keywords: keywords),
                       let webResult = try? await extractFromWebPage(urlString: recipePageURL),
                       webResult.isViable {
                        var r = webResult
                        r.originalSourceURL = urlString
                        return r  // found the creator's actual recipe
                    }
                }

                // 0c: Upgrade A1 query with real name if discovered
                if let realName = profile.realName {
                    searchAuthorName = realName
                }
            }

            // Stage A1: Creator-targeted search — "[@handle / Real Name] dishname recipe"
            // Best chance of finding the exact recipe the creator posted about.
            let specificQuery = buildSpecificQuery(
                authorName: searchAuthorName,
                title: result.title ?? titleHint,
                keywords: keywords
            )
            if let query = specificQuery {
                progress?("Searching for recipe…")
                let searchResults = await WebRecipeSearcher.search(query: query)
                for candidate in searchResults {
                    if let webResult = try? await extractFromWebPage(urlString: candidate.url),
                       webResult.isViable {
                        var substituteResult = webResult
                        substituteResult.isSubstitute = true
                        substituteResult.originalSourceURL = urlString
                        return substituteResult
                    }
                }
            }

            // Stage A2: General dish search — "dishname recipe" (no creator constraint)
            // Second attempt to find THE specific recipe before accepting defeat.
            // Reuse these results for Stage B to avoid a redundant search call.
            let genericQuery = buildGenericQuery(title: result.title ?? titleHint, keywords: keywords)
            var generalSearchResults: [WebRecipeSearcher.SearchResult] = []
            if let query = genericQuery {
                progress?("Searching more broadly…")
                generalSearchResults = await WebRecipeSearcher.search(query: query)
                for candidate in generalSearchResults {
                    if let webResult = try? await extractFromWebPage(urlString: candidate.url),
                       webResult.isViable {
                        var substituteResult = webResult
                        substituteResult.isSubstitute = true
                        substituteResult.originalSourceURL = urlString
                        return substituteResult
                    }
                }
            }

            // Stage B: Collect up to 2 similar recipes from general results for the failure UI.
            // Re-extract from the same candidates (already fetched above) — no extra network call.
            if !generalSearchResults.isEmpty {
                progress?("Finding similar recipes…")
                var alternatives: [ExtractionResult] = []
                for candidate in generalSearchResults {
                    if let webResult = try? await extractFromWebPage(urlString: candidate.url),
                       webResult.isViable {
                        var alt = webResult
                        alt.isSubstitute = true
                        alt.originalSourceURL = urlString
                        alternatives.append(alt)
                        if alternatives.count >= 2 { break }
                    }
                }
                result.alternatives = alternatives
            }

            // Annotate the failed result for the failure UI
            result.captionPreview = allCaptionText.isEmpty ? nil : String(allCaptionText.prefix(200))
            result.authorHint = searchAuthorName
            result.thumbnailURL = metadata?.thumbnailURL
        }

        return result
    }

    /// Extract Instagram/TikTok handle from a profile URL (e.g. instagram.com/username/).
    private func authorHandle(from urlString: String?) -> String? {
        guard let urlString,
              let url = URL(string: urlString),
              let host = url.host?.lowercased() else { return nil }
        let path = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let handle = path.first, handle.count >= 2 else { return nil }
        // Exclude known non-username path segments
        let reserved = Set(["reel", "p", "explore", "accounts", "login", "direct", "stories", "tv"])
        return reserved.contains(handle.lowercased()) ? nil : "@\(handle)"
    }

    /// Build a targeted search query using the creator's name/handle + dish keywords.
    /// Goal: find the specific recipe from this creator's blog/site.
    private func buildSpecificQuery(authorName: String?, title: String?, keywords: [String]) -> String? {
        let dishSignal = buildGenericQuery(title: title, keywords: keywords) ?? ""
        guard !dishSignal.isEmpty else { return nil }

        if let authorName, !authorName.isEmpty {
            // e.g. "@jenneatsgoood roasted pepper pasta recipe"
            return "\(authorName) \(dishSignal)"
        }
        return dishSignal
    }

    /// Build a generic recipe search query from available title/keyword signals.
    private func buildGenericQuery(title: String?, keywords: [String]) -> String? {
        if let title, !title.isEmpty {
            let lower = title.lowercased()
            let isUselessTitle = lower.contains("instagram") || lower.contains("tiktok") ||
                                 (lower.contains("•") && lower.contains("reel"))
            if !isUselessTitle {
                return title.hasSuffix("recipe") ? title : "\(title) recipe"
            }
        }
        if !keywords.isEmpty {
            return "\(keywords.joined(separator: " ")) recipe"
        }
        return nil
    }

    // MARK: - Web Extraction Chain

    private func extractFromWebPage(urlString: String) async throws -> ExtractionResult {
        let html = try await fetcher.fetch(urlString: urlString)
        var result = extractFromHTML(html: html)

        // Layer 4: LLM fallback (H13). The deterministic layers (1–3) run synchronously in
        // extractFromHTML; the LLM call is async, so it lives here. Only invoked when those
        // layers came up short AND a key is configured, and only adopted if it's more
        // confident — so a well-structured page never pays for an LLM round-trip.
        if result.confidence < ConfidenceThreshold.reject, let apiKey = APIKeyProvider.anthropicKey {
            if let llm = try? await LLMExtractor(apiKey: apiKey).extract(html: html),
               llm.confidence > result.confidence {
                result = llm
            }
        }

        result.recipePageURL = urlString
        return result
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

        // Layer 4 (LLM fallback) runs in the async `extractFromWebPage` when a key is
        // configured — this synchronous chain only covers the deterministic layers.

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
