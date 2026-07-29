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

    /// The Anthropic key injected via Secrets.xcconfig → Info.plist, or nil when absent/empty.
    /// Gates every optional LLM step (caption structuring, web-page fallback, transcript validation).
    static var anthropicAPIKey: String? {
        (Bundle.main.infoDictionary?["ANTHROPIC_API_KEY"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Extract a recipe from a URL. Returns the best result found across all layers.
    /// The optional `progress` callback receives status text for UI updates during multi-step extraction.
    func extract(from urlString: String, progress: (@Sendable (String) -> Void)? = nil) async throws -> ExtractionResult {
        let sourceType = URLRouter.classify(urlString)

        switch sourceType {
        case .webPage:
            return try await extractFromWebPage(urlString: urlString)
        case .tikTok, .instagram, .youTube:
            // Sanitize at this single boundary rather than inside extractFromVideo, which has
            // several early returns (bio-link and web-search paths). One pass here covers every
            // one of them — including the LLM path, which is deliberately sent the raw caption.
            return SocialTextFilter.sanitize(
                await extractFromVideo(urlString: urlString, progress: progress))
        }
    }

    // MARK: - Video Extraction Chain

    private func extractFromVideo(urlString: String, progress: (@Sendable (String) -> Void)? = nil) async -> ExtractionResult {
        let metadataFetcher = VideoMetadataFetcher()

        // Testing aid: record which Instagram route returned what, surfaced on the failure
        // screen so we can see where extraction breaks without an Xcode rebuild.
        var debugTrace: [String] = []

        // Step 1: oEmbed for caption / title (free, no auth)
        let metadata = try? await metadataFetcher.fetch(videoURL: urlString)
        var captionText = metadata?.caption ?? ""
        // Instagram/TikTok page titles are engagement metadata ("69K likes, 410 comments -
        // creator on July 3: …"), never recipe names. Drop them so they can't become the
        // recipe's title further down when the extractors don't find a real one.
        let titleHint = SocialTextFilter.cleanTitle(metadata?.title)
        debugTrace.append("metadata caption: \(captionText.isEmpty ? "—" : "\(captionText.count) chars")")

        // Step 1b: Instagram fallbacks when the logged-out URLSession routes came back empty.
        if captionText.isEmpty, URLRouter.classify(urlString) == .instagram {
            let shortcode = VideoMetadataFetcher.instagramShortcode(from: urlString)
            let connected = await InstagramAuth.isConnected()
            debugTrace.append("shortcode: \(shortcode ?? "nil")")
            debugTrace.append("IG connected: \(connected)")

            // Best route: authenticated GraphQL using the user's in-app Instagram session
            // (see InstagramConnectView). Returns the full caption past the login wall.
            if let shortcode {
                let authCaption = await InstagramAuth.fetchCaption(shortcode: shortcode)
                debugTrace.append("auth GraphQL: \(authCaption.map { "\($0.count) chars" } ?? "nil")")
                if let authCaption { captionText = authCaption }
            }

            // Logged-out real-browser fallback: an off-screen WKWebView reads the caption
            // from link-preview metadata. Works for some public posts; may be partial.
            if captionText.isEmpty, let url = URL(string: urlString) {
                progress?("Opening the post…")
                let webCaption = await InstagramWebViewExtractor.caption(from: url)
                debugTrace.append("WKWebView: \(webCaption.map { "\($0.count) chars" } ?? "nil")")
                if let webCaption { captionText = webCaption }
            }
        }

        // Captions from Instagram/TikTok arrive HTML-encoded — decode so bullets, dashes,
        // and ampersands don't show as &#x2022; / &#x2013; / &amp; downstream.
        captionText = captionText.decodedHTMLEntities
        // Several routes hand back og:description as the caption, which Instagram prefixes
        // with "69K likes, 417 comments - user on July 3: …". Without stripping it the
        // preamble becomes the caption's first line and then the recipe's title.
        captionText = SocialTextFilter.stripEngagementPrefix(captionText)

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
        // Clean the caption ONCE and reuse it: previously this was computed inline for the
        // paste-style parse and thrown away, which is why the transcript parse below was still
        // seeing raw hashtag walls and turning them into steps.
        // NOTE: `allCaptionText` above deliberately keeps the RAW caption — "link in bio" is
        // both a CTA phrase this strips AND the signal CaptionAnalyzer needs to trigger
        // bio-link resolution, so cleaning it would silently disable that whole branch.
        let transcriptText = videoTranscript?.combinedText
        let cleanedCaption = captionText.isEmpty ? "" : Self.cleanCaptionForParsing(captionText)
        let fullText = [transcriptText, cleanedCaption]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")

        guard !fullText.isEmpty else {
            var empty = ExtractionResult(extractionMethod: "video-no-transcript")
            empty.title = titleHint
            empty.confidence = 0.1
            return empty
        }

        // The Anthropic key (if the developer added Secrets.xcconfig) powers two optional
        // steps below: LLM caption structuring and the transcript validator.
        let apiKey = Self.anthropicAPIKey

        // A written caption (Instagram/TikTok) is structured recipe text, so parse it with the
        // same parser as paste/scan — it handles "Ingredients:/Instructions:" layouts far better
        // than the spoken-word transcript extractor. Keep whichever candidate is richer.
        progress?("Reading the recipe…")
        var result = TranscriptExtractor().extract(transcript: fullText)
        var captionParse: (result: ExtractionResult, audit: PastedTextExtractor.ParseAudit)?
        if !cleanedCaption.isEmpty {
            captionParse = PastedTextExtractor().extractWithAudit(text: cleanedCaption)
            let pasted = captionParse!.result
            // Ties go to the paste-style parse. It reads written structure ("Ingredients:",
            // bullets) far better than the spoken-word extractor, so on equal completeness it
            // is the better recipe — and the old strictly-greater test meant a tie silently
            // kept the transcript parse instead.
            if Self.completeness(pasted) >= Self.completeness(result) {
                result = pasted
            }
        }

        // Step 3.2: carousel slides. Many recipe carousels put the ingredients and method IN
        // the images and leave the caption as a one-line hook, so the parse above finds nothing
        // usable. Read the slides with on-device OCR and re-parse. Gated on the caption having
        // failed, because it costs a download plus OCR per slide — a caption that already
        // produced a recipe is both cheaper and more reliable than text lifted off a photo.
        var carouselText = ""
        if !result.isViable, URLRouter.classify(urlString) == .instagram,
           let shortcode = VideoMetadataFetcher.instagramShortcode(from: urlString) {
            carouselText = await CarouselTextExtractor.extractText(shortcode: shortcode,
                                                                  progress: progress)
            if !carouselText.isEmpty {
                progress?("Reading the recipe…")
                let fromSlides = PastedTextExtractor().extract(text: carouselText)
                if Self.completeness(fromSlides) > Self.completeness(result) {
                    result = fromSlides
                }
                debugTrace.append("carousel OCR: \(carouselText.count) chars → "
                                  + "\(fromSlides.ingredients.count) ingredients, \(fromSlides.steps.count) steps")
            }
        }

        // Step 3.5: LLM caption structuring (Option A). Rule-based parsing hits a ceiling on
        // messy social captions — run-on ingredient groups under sub-labels, inline-numbered
        // steps, marketing narrative and hashtags — and can produce a viable-but-wrong split.
        // When a key is present, let Claude structure the RAW caption (how ReciMe / OrganizEat-
        // class apps do it). Take it only when it's at least as complete as the deterministic
        // parse, so an off-day LLM response can't regress a caption the parser already nailed.
        // No key / failure → deterministic result stands (offline-safe fallback).
        // Slide OCR is fed here too when the caption had nothing: text lifted off images comes
        // back ragged (line breaks mid-sentence, headers split from their lists), which is
        // exactly the mess the structurer handles better than the rule-based parser.
        let usingCaption = captionText.count >= 40
        let textToStructure = usingCaption ? captionText : carouselText
        if let apiKey, textToStructure.count >= 40 {
            // Skip-gate (think-tank branch 3): a clean "Ingredients:/Steps:" caption the
            // deterministic parser already nailed doesn't need a paid call — the structurer's
            // output was usually discarded by the completeness guard below anyway. The gate
            // only applies to the CAPTION parse: carousel OCR text comes back ragged and
            // legitimately needs the structurer, so it is never skipped.
            if usingCaption, let captionParse,
               Self.shouldSkipStructurer(deterministic: captionParse.result,
                                         audit: captionParse.audit,
                                         caption: captionText) {
                debugTrace.append("LLM structurer: skipped — deterministic caption parse is trustworthy")
            } else {
                progress?("Structuring the recipe…")
                let structurer = LLMCaptionStructurer(apiKey: apiKey)
                if let llm = try? await structurer.structure(caption: textToStructure, titleHint: titleHint),
                   llm.isViable, Self.completeness(llm) >= Self.completeness(result) {
                    result = llm
                    debugTrace.append("LLM structurer: \(llm.ingredients.count) ingredients, \(llm.steps.count) steps")
                } else {
                    debugTrace.append("LLM structurer: kept deterministic parse")
                }
            }
        }

        // Multi-part recipes: lead with the longest-running component so the slow part is
        // underway while the quick parts get made. Done here, before review, so the cook sees
        // (and can rearrange) the suggested order on the review screen.
        result = Self.applyComponentSequencing(to: result)

        // Attach provenance + photo so a caption-parsed import still shows its Instagram badge,
        // source link and thumbnail (regardless of which extractor won).
        result.originalSourceURL = urlString
        if result.thumbnailURL == nil { result.thumbnailURL = metadata?.thumbnailURL }
        if result.title == nil { result.title = titleHint }

        guard result.confidence < ConfidenceThreshold.accept else { return result }

        // Step 4: Layer 6 — LLM validation / fallback (transcript-oriented). The caption
        // structurer above already ran when a key was present; this backstops transcript-only
        // imports and captions the structurer couldn't lift over the accept threshold.
        guard let apiKey else { return result }
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

        // Testing aid: attach the fetch trace + parse outcome so the failure screen shows
        // exactly where extraction broke (which route got the caption, what parsed out).
        debugTrace.append("final caption: \(captionText.isEmpty ? "—" : "\(captionText.count) chars")")
        debugTrace.append("parsed: \(result.ingredients.count) ingredients, \(result.steps.count) steps, viable=\(result.isViable)")
        result.debugInfo = debugTrace.joined(separator: "\n")

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

    /// Drop social noise (hashtag walls, "Save this for later", marketing narrative) before
    /// structured parsing — otherwise it becomes fake ingredients and steps. Blank lines are
    /// kept so paragraph structure, and therefore header detection, survives.
    static func cleanCaptionForParsing(_ caption: String) -> String {
        SocialTextFilter.clean(caption)
    }

    // MARK: - Structurer skip-gate

    /// Deterministic-first applied to the structurer: skip the paid Claude call ONLY when
    /// every signal says the caption parse is trustworthy. The failure direction is always
    /// spending a call, never silently losing content — each condition guards a concrete
    /// way the deterministic parser is known to quietly produce a wrong-but-viable recipe.
    static func shouldSkipStructurer(
        deterministic result: ExtractionResult,
        audit: PastedTextExtractor.ParseAudit,
        caption: String
    ) -> Bool {
        // 1. Viable and confidently in the accept band (the parser's full tier is 0.75).
        guard result.isViable, result.confidence >= ConfidenceThreshold.accept else { return false }

        // 2–3. Exactly one explicit ingredients header and one steps header, both used, and
        // nothing discarded by the step-region stop — a second "Ingredients…" header means a
        // multi-component caption this parser silently truncates.
        guard audit.usedExplicitHeaders,
              audit.ingredientHeaderCount == 1,
              audit.stepHeaderCount == 1,
              audit.linesDiscardedAfterSteps == 0 else { return false }

        // 4. No run of ≥2 consecutive ingredient-shaped step lines — the signature of a
        // second component's list appended to the steps under an unrecognized header.
        var run = 0
        for step in result.steps {
            if startsWithQuantity(step.text),
               step.text.split(whereSeparator: \.isWhitespace).count <= 8 {
                run += 1
                if run >= 2 { return false }
            } else {
                run = 0
            }
        }

        // 5. The ingredient list must look like one: ≥60% quantity-led, and no entry shaped
        // like a numbered step ("1. Boil the pasta" misrouted into the ingredients).
        let quantityLed = result.ingredients.filter { startsWithQuantity($0.text) }.count
        guard quantityLed * 10 >= result.ingredients.count * 6 else { return false }
        guard !result.ingredients.contains(where: {
            $0.text.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
        }) else { return false }

        // 6. No truncation evidence — an og:description cut mid-recipe ends in an ellipsis,
        // and the missing tail is exactly what the structurer (fed the raw caption) or a
        // richer fetch route might still recover.
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("…") || trimmed.hasSuffix("...") { return false }

        return true
    }

    /// First token is a digit, unicode fraction, or small word-number — the shape a real
    /// ingredient line leads with.
    private static func startsWithQuantity(_ text: String) -> Bool {
        guard let first = text.split(whereSeparator: \.isWhitespace).first else { return false }
        if let c = first.first, c.isNumber || "½¼¾⅓⅔⅛⅜⅝⅞⅕⅙".contains(c) { return true }
        let wordNumbers: Set<String> = ["a", "an", "one", "two", "three", "four", "five",
                                        "six", "seven", "eight", "nine", "ten", "half"]
        return wordNumbers.contains(
            first.lowercased().trimmingCharacters(in: .punctuationCharacters))
    }

    // MARK: - Web Extraction Chain

    private func extractFromWebPage(urlString: String) async throws -> ExtractionResult {
        let html = try await fetcher.fetch(urlString: urlString)
        var result = extractFromHTML(html: html)

        // Layer 4: LLM fallback (H13). When the deterministic layers (1–3) stay below the reject
        // threshold and a key is configured, ask Claude to extract from the stripped page text —
        // this rescues blogs / custom sites with no usable structured data. Keep it only if it's
        // more confident, and carry over any fields the deterministic layers did find (photo,
        // description, times). No key / failure → the deterministic result stands.
        if ConfidenceThreshold.needsRescue(result.confidence), let apiKey = Self.anthropicAPIKey {
            if let llm = try? await LLMExtractor(apiKey: apiKey).extract(html: html),
               llm.confidence > result.confidence {
                result = merge(base: result, onto: llm)
            }
        }

        result.recipePageURL = urlString
        // Multi-part web recipes (HowToSection / "For the sauce:" groups) get the same
        // longest-component-first ordering the video path applies, so the cook sees the
        // suggested part order on the review screen for web imports too.
        return Self.applyComponentSequencing(to: result)
    }

    /// Reorder a multi-part recipe so the longest-running component leads. No-op for a
    /// single-component recipe. Shared by the video and web paths so both get part ordering.
    static func applyComponentSequencing(to result: ExtractionResult) -> ExtractionResult {
        guard result.steps.contains(where: { !($0.section ?? "").isEmpty }) else { return result }
        var out = result
        let sequenced = ComponentSequencer.sequence(
            result.steps.map { (text: $0.text, section: $0.section) })
        out.steps = sequenced.enumerated().map { idx, step in
            RawStep(order: idx + 1, text: step.text, section: step.section)
        }
        return out
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
        layer2.confidence = rescored(layer2, full: 0.9, partial: 0.6)
        if layer2.confidence >= ConfidenceThreshold.accept {
            return layer2
        }

        // Layer 3: Heuristic HTML. Deliberately NOT rescored: layer3's merged content is
        // mostly layer2's, and rescoring it with heuristic tier values (0.8/0.5) would let
        // this early return claim that content at a LOWER confidence than layer2 already
        // holds — the final max() below arbitrates that case correctly instead.
        var layer3 = HeuristicExtractor().extract(html: html)
        layer3 = merge(base: layer2, onto: layer3)
        if layer3.confidence >= ConfidenceThreshold.reject {
            return layer3
        }

        // Layer 4 (LLM fallback) runs in the async web path — see extractFromWebPage — because
        // the Claude call is async and this synchronous entry point is also used directly by tests.

        // Return best available result (highest confidence)
        return [layer1, layer2, layer3].max(by: { $0.confidence < $1.confidence }) ?? layer3
    }

    /// Each extractor scores its confidence on its OWN fields, before the pipeline merges
    /// layers — so a result completed by merge() kept its pre-merge score, and a page whose
    /// recipe was split across JSON-LD and microdata could carry a full recipe at 0.2,
    /// triggering false LLM rescues and review flags. Re-apply the layer's tier formula to
    /// the merged field set, never lowering the extractor's own judgement. (Applied to
    /// layer2 only: both contributing layers there are structured-data grade, so structured
    /// tier values are honest for the merged whole.)
    private func rescored(_ r: ExtractionResult, full: Double, partial: Double) -> Double {
        guard r.title != nil else { return r.confidence }
        if r.ingredients.count >= 3 && r.steps.count >= 2 { return max(r.confidence, full) }
        if r.ingredients.count >= 1 && r.steps.count >= 1 { return max(r.confidence, partial) }
        return r.confidence
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
