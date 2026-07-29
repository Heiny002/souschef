import Foundation

/// Option A: LLM structuring for social-media captions (Instagram / TikTok / YouTube).
///
/// Social captions are the hard case for rule-based parsing: the recipe is tangled with
/// marketing narrative, emojis, hashtags, @mentions, calls-to-action ("save this!"), and
/// nutrition lines; ingredients run together under sub-labels ("Steak:", "Yogurt spread:");
/// steps are numbered inline ("1.Season the beef…"). `PastedTextExtractor` hits a ceiling
/// here — it can produce a *viable-but-wrong* split (a nutrition line counted as an
/// ingredient, ingredient groups counted as steps), which no amount of heuristics reliably
/// untangles.
///
/// This is how ReciMe / OrganizEat-class apps do it: hand the raw caption to a small,
/// cheap model (Claude Haiku, ~a fraction of a cent per import) with a structured-output
/// prompt. It is gated on an `ANTHROPIC_API_KEY` being present; when absent (or the call
/// fails), the pipeline falls back to the deterministic `PastedTextExtractor`, so imports
/// still work offline / without a key.
///
/// Future: swap `callClaude` for Apple's on-device Foundation Models on capable devices —
/// free, private, zero download size — keeping this hosted path as the fallback.
actor LLMCaptionStructurer {
    static let method = "llm-caption"
    private static let maxCaptionLength = 6_000   // captions are short; bound the prompt

    private let apiKey: String
    private let session: URLSession

    init(apiKey: String) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    /// Structure a raw caption into a recipe. Returns a viable result on success (confidence
    /// 0.75, above the accept threshold so the chain stops), or throws on network / parse
    /// failure so the caller can fall back to deterministic parsing.
    func structure(caption: String, titleHint: String?) async throws -> ExtractionResult {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMCaptionError.emptyCaption }

        let prompt = Self.buildPrompt(caption: String(trimmed.prefix(Self.maxCaptionLength)))
        let requestBody: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 2048,
            "messages": [["role": "user", "content": prompt]]
        ]

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw LLMCaptionError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LLMCaptionError.apiError
        }

        // Peel the API envelope, then hand the model's text to the pure parser (testable
        // without a network call).
        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = outer["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw LLMCaptionError.malformedResponse
        }

        guard var result = Self.recipe(fromModelText: text, groundedIn: caption) else {
            throw LLMCaptionError.malformedResponse
        }
        if result.title == nil { result.title = titleHint }
        result.confidence = result.isViable ? 0.75 : 0.2
        return result
    }

    // MARK: - Prompt

    /// The prompt is a static so the desktop tool (`tools/ig_extract.py`) can mirror it
    /// verbatim — the two must stay in lockstep to debug caption quality without a rebuild.
    static func buildPrompt(caption: String) -> String {
        """
        You are extracting a cooking recipe from a social-media video caption \
        (Instagram / TikTok / YouTube). Captions are messy: they mix the recipe with \
        marketing narrative, emojis, hashtags, @mentions, calls-to-action \
        ("follow for more", "save this"), and nutrition / serving-size lines. Ingredients \
        are often grouped under sub-labels like "Steak:" or "For the sauce:", and steps are \
        often numbered inline ("1.Season the beef…").

        Extract ONLY the actual recipe. Rules:
        - Exclude hashtags, @mentions, emojis, marketing / call-to-action lines, and \
        nutrition-fact lines (calories, macros).
        - Put each ingredient on its own entry, keeping its quantity and unit \
        ("2 tbsp olive oil"). If ingredients are grouped under a sub-label, set "section" to \
        that label without the trailing colon (e.g. "Steak", "For the sauce"); otherwise \
        "section" is null.
        - Steps: one action per entry, in order, with NO leading number or bullet.
        - Each step's "section" is the component it belongs to, matching the ingredient \
        sections ("Steak", "Flatbread"); null when the recipe has no separate components.
        - When a step applies three or more items at once — a spice blend, a set of \
        seasonings, several add-ins — put them in that step's "items" array (each with its \
        own quantity) instead of cramming them into the sentence in parentheses. Write the \
        step text so it reads naturally without them ("Season the steak with olive oil and \
        spices, then mix well"). Use null for "items" when there's no such list.
        - Do NOT invent quantities, ingredients, or steps that aren't in the caption.
        - NEVER return a hashtag line, an @mention, or a call to action ("save this", \
        "follow for more") as a step or an ingredient.
        - Title: if the caption names the dish, use that. If it does NOT, WRITE a short \
        descriptive title from the actual ingredients and method (e.g. "Peach Burrata Toast", \
        "Steak and Flatbread Wraps") — 2 to 5 words, no emoji, no hashtags, no creator handle, \
        and never engagement text like "69K likes, 417 comments". Only use null when the \
        caption isn't a recipe at all.
        - If the caption is not a recipe, return {"title": null, "ingredients": [], "steps": []}.

        Return ONLY valid JSON (no prose, no code fences) matching this schema:
        {
          "title": "string or null",
          "recipeYield": "string or null",
          "prepTimeMinutes": number or null,
          "cookTimeMinutes": number or null,
          "ingredients": [{"text": "string", "section": "string or null"}],
          "steps": [{"text": "string", "section": "string or null", "items": ["string"] or null}],
          "equipment": ["string"]
        }

        "equipment": special appliances or tools the recipe requires that a cook might not \
        own — air fryer, sous vide circulator, pressure cooker / Instant Pot, slow cooker, \
        stand mixer, food processor, smoker, mandoline, kitchen torch, thermometer. Include \
        an item only if the recipe genuinely needs it. Skip everyday things (bowl, knife, \
        spoon, pan, oven, stovetop). Empty array when nothing special is needed.

        Caption:
        \(caption)
        """
    }

    // MARK: - Response Parsing (pure, testable)

    /// Parse the model's text response (possibly fenced / prose-wrapped) into a result.
    /// Returns nil only when no JSON object can be recovered.
    nonisolated static func recipe(fromModelText text: String, groundedIn input: String? = nil) -> ExtractionResult? {
        let jsonText = JSONResponseParser.extractObject(from: text)
        guard let jsonData = jsonText.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        var result = ExtractionResult(extractionMethod: method)
        result.producedBy = .llmStructured
        // A model that ignores the prompt must not be able to smuggle engagement text into
        // the title — the filter is the backstop, the prompt is the request.
        result.title = SocialTextFilter.cleanTitle((dict["title"] as? String)?.nonEmpty)
        result.recipeYield = (dict["recipeYield"] as? String)?.nonEmpty
        if let prepMins = dict["prepTimeMinutes"] as? Int { result.prepTime = prepMins * 60 }
        if let cookMins = dict["cookTimeMinutes"] as? Int { result.cookTime = cookMins * 60 }

        // Ingredients tolerate both shapes: [{"text","section"}] (requested) and ["…"]
        // (in case the model simplifies), so a schema drift doesn't drop the whole list.
        if let raw = dict["ingredients"] as? [Any] {
            // cleanEntry rather than a plain isNoiseLine reject: "2 peaches @traderjoes" isn't
            // noise, but it shouldn't keep the mention either — it's kept and cleaned.
            result.ingredients = raw.compactMap { item -> RawIngredient? in
                // includePhrases:false — LLM output isn't social noise; the phrase filter here
                // deletes real instructions that open with a marketing-sounding phrase.
                if let obj = item as? [String: Any] {
                    guard let raw = (obj["text"] as? String)?.nonEmpty,
                          let text = SocialTextFilter.cleanEntry(raw, includePhrases: false) else { return nil }
                    return RawIngredient(text: text, section: (obj["section"] as? String)?.nonEmpty)
                }
                if let raw = (item as? String)?.nonEmpty,
                   let text = SocialTextFilter.cleanEntry(raw, includePhrases: false) {
                    return RawIngredient(text: text, section: nil)
                }
                return nil
            }
        }

        // Steps tolerate both shapes: [{"text","section","items"}] (requested) and ["…"].
        // An "items" list is rendered as a bulleted block under the sentence — spice blends
        // and multi-item additions read far better as a list than as inline parentheses.
        if let rawSteps = dict["steps"] as? [Any] {
            var steps: [RawStep] = []
            for item in rawSteps {
                if let obj = item as? [String: Any] {
                    // Strip hashtag walls / trailing tags the model let through, but NOT the
                    // CTA/narrative phrase filter (includePhrases:false) — it deletes real
                    // steps that open "When you're ready to serve…".
                    guard let rawText = (obj["text"] as? String)?.nonEmpty,
                          let text = SocialTextFilter.cleanEntry(rawText, includePhrases: false) else { continue }
                    let bullets = ((obj["items"] as? [Any]) ?? [])
                        .compactMap { ($0 as? String)?.nonEmpty }
                        .compactMap { SocialTextFilter.cleanEntry($0, includePhrases: false) }
                    let body = bullets.isEmpty
                        ? text
                        : text + "\n" + bullets.map { "• \($0)" }.joined(separator: "\n")
                    steps.append(RawStep(order: steps.count + 1, text: body,
                                         section: (obj["section"] as? String)?.nonEmpty))
                } else if let rawText = (item as? String)?.nonEmpty,
                          let text = SocialTextFilter.cleanEntry(rawText, includePhrases: false) {
                    steps.append(RawStep(order: steps.count + 1, text: text))
                }
            }
            result.steps = steps
        }

        // Anti-hallucination: when the source caption is known, drop any ingredient whose
        // quantity the caption never contained — the model invented it. Number-free
        // ingredients ("salt to taste") always pass. Steps are left intact: a fabricated
        // timer is far less harmful than losing a real instruction.
        if let input {
            let inputNumbers = SocialTextFilter.numericTokens(input)
            result.ingredients = result.ingredients.filter {
                SocialTextFilter.numbersGrounded($0.text, in: inputNumbers)
            }
        }

        // Union the model's explicit equipment list with keyword detection: the model catches
        // equipment implied by technique, detection catches what the model omits.
        var equipment = (dict["equipment"] as? [Any])?.compactMap { ($0 as? String)?.nonEmpty } ?? []
        for detected in ApplianceDetector.detectSpecialEquipment(
            in: result.ingredients.map { $0.text } + result.steps.map { $0.text })
        where !equipment.contains(where: { $0.caseInsensitiveCompare(detected) == .orderedSame }) {
            equipment.append(detected)
        }
        result.equipment = equipment

        result.appliances = ApplianceDetector.detect(
            in: result.ingredients.map { $0.text } + result.steps.map { $0.text }
        )
        return result
    }
}

enum LLMCaptionError: LocalizedError {
    case emptyCaption
    case invalidConfiguration
    case apiError
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .emptyCaption:         return "No caption to structure."
        case .invalidConfiguration: return "LLM caption structurer is not configured."
        case .apiError:             return "Claude API returned an error."
        case .malformedResponse:    return "Could not parse LLM response as a recipe."
        }
    }
}

private extension String {
    /// nil when the string is empty after trimming — keeps `""`/whitespace out of results.
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
