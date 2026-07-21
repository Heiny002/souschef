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

        // A written caption (Instagram/TikTok) is structured recipe text, so parse it with the
        // same parser as paste/scan — it handles "Ingredients:/Instructions:" layouts far better
        // than the spoken-word transcript extractor. Keep whichever candidate is richer.
        progress?("Reading the recipe…")
        var result = TranscriptExtractor().extract(transcript: fullText)
        if !captionText.isEmpty {
            let pasted = PastedTextExtractor().extract(text: Self.cleanCaptionForParsing(captionText))
            if Self.completeness(pasted) > Self.completeness(result) {
                result = pasted
            }
        }
        // Attach provenance + photo so a caption-parsed import still shows its Instagram badge,
        // source link and thumbnail (regardless of which extractor won).
        result.originalSourceURL = urlString
        if result.thumbnailURL == nil { result.thumbnailURL = metadata?.thumbnailURL }
        if result.title == nil { result.title = titleHint }

        guard result.confidence < ConfidenceThreshold.accept else { return result }

        // Step 4: Layer 6 — LLM validation / fallback
        guard let apiKey = Bundle.main.infoDictionary?["ANTHROPIC_API_KEY"] as? String,
              !apiKey.isEmpty else {
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
            // Each candidate's extraction is CACHED for Stage B.
            let genericQuery = buildGenericQuery(title: result.title ?? titleHint, keywords: keywords)
            var cachedExtractions: [ExtractionResult] = []
            if let query = genericQuery {
                progress?("Searching more broadly…")
                let generalSearchResults = await WebRecipeSearcher.search(query: query)
                for candidate in generalSearchResults {
                    guard let webResult = try? await extractFromWebPage(urlString: candidate.url) else { continue }
                    if webResult.isViable {
                        var substituteResult = webResult
                        substituteResult.isSubstitute = true
                        substituteResult.originalSourceURL = urlString
                        return substituteResult
                    }
                    cachedExtractions.append(webResult)
                }
            }

            // Stage B: Similar recipes for the failure UI, from the CACHED A2 extractions.
            // This stage only runs when no A2 candidate passed `isViable` — so re-fetching
            // the same URLs and applying the same bar (the old code) could never produce a
            // result and just re-downloaded up to 3 pages (H14). A partial extraction
            // (title + some ingredients) is still a useful preview.
            var alternatives: [ExtractionResult] = []
            for webResult in cachedExtractions
            where webResult.title != nil && !webResult.ingredients.isEmpty {
                var alt = webResult
                alt.isSubstitute = true
                alt.originalSourceURL = urlString
                alternatives.append(alt)
                if alternatives.count >= 2 { break }
            }
            result.alternatives = alternatives

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

    // MARK: - Caption parsing helpers

    /// Rank two candidate extractions: a viable one always beats a non-viable one, then
    /// prefer more ingredients, then more steps. Used to pick the caption parse over the
    /// transcript parse (or vice versa) for a social-video import.
    static func completeness(_ r: ExtractionResult) -> Int {
        (r.isViable ? 1000 : 0) + r.ingredients.count * 10 + r.steps.count * 5 + (r.title != nil ? 1 : 0)
    }

    /// Drop lines that are nothing but hashtags/mentions before structured parsing —
    /// Instagram/TikTok captions end in walls of them, and otherwise they'd become fake
    /// ingredients or steps. Blank lines are kept so paragraph structure survives.
    static func cleanCaptionForParsing(_ caption: String) -> String {
        caption.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return true }
            let tokens = trimmed.split(separator: " ")
            let tagLike = tokens.filter { $0.hasPrefix("#") || $0.hasPrefix("@") }.count
            return tagLike != tokens.count
        }.joined(separator: "\n")
    }

    // MARK: - Web Extraction Chain

    private func extractFromWebPage(urlString: String) async throws -> ExtractionResult {
        let html = try await fetcher.fetch(urlString: urlString)
        var result = extractFromHTML(html: html)
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

        // Layer 4: LLM fallback — stub (SC-030)

        // Return best available result (highest confidence)
        return [layer1, layer2, layer3].max(by: { $0.confidence < $1.confidence }) ?? layer3
    }

    /// Merge earlier-layer partial results into a later-layer result (fill gaps only).
    func merge(base: ExtractionResult, onto target: ExtractionResult) -> ExtractionResult {
        var result = target
        if result.title == nil { result.title = base.title }
        if result.recipeYield == nil { result.recipeYield = base.recipeYield }
        if result.prepTime == nil { result.prepTime = base.prepTime }
        if result.cookTime == nil { result.cookTime = base.cookTime }
        if result.totalTime == nil { result.totalTime = base.totalTime }
        if result.ingredients.isEmpty { result.ingredients = base.ingredients }
        if result.steps.isEmpty { result.steps = base.steps }
        if result.appliances.isEmpty { result.appliances = base.appliances }
        // Carry provenance/description too — otherwise the recipe photo (parsed from the
        // Schema.org `image` field into `thumbnailURL`) and the description are silently
        // dropped whenever a lower layer (Microdata/Heuristic, which don't parse an image)
        // produces the final result, and the saved recipe ends up with no photo.
        if result.thumbnailURL == nil { result.thumbnailURL = base.thumbnailURL }
        if result.description == nil { result.description = base.description }
        return result
    }

    /// Parse raw ingredients from an ExtractionResult using IngredientParser.
    func parseIngredients(from result: ExtractionResult) -> [ParsedIngredient] {
        result.ingredients.enumerated().map { idx, raw in
            parser.parse(raw: raw.text, section: raw.section)
        }
    }
}
