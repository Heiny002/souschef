import Foundation

/// SC-042: Layer 6 — LLM validation and fallback for video transcript extraction.
/// Mode A (validation): Layer 5 confidence 0.5–0.7 → send extracted data + transcript,
///   LLM fills gaps only.
/// Mode B (primary): Layer 5 confidence < 0.5 → full LLM extraction from transcript.
actor TranscriptLLMValidator {
    private static let method = "transcript-llm"
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    func validate(transcript: String, partial: ExtractionResult) async throws -> ExtractionResult {
        let mode: Mode = partial.confidence >= 0.5 ? .validation : .primary
        return try await callClaude(transcript: transcript, partial: partial, mode: mode)
    }

    // MARK: - Modes

    private enum Mode { case validation, primary }

    private func callClaude(transcript: String, partial: ExtractionResult, mode: Mode) async throws -> ExtractionResult {
        let prompt = mode == .validation
            ? validationPrompt(transcript: transcript, partial: partial)
            : primaryPrompt(transcript: transcript)

        let requestBody: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 2048,
            "messages": [["role": "user", "content": prompt]]
        ]

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw TranscriptLLMError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw TranscriptLLMError.apiError
        }

        var result = try parseResponse(data: data, mode: mode, partial: partial)
        result.extractionMethod = Self.method
        result.confidence = result.isViable ? 0.7 : 0.3
        return result
    }

    // MARK: - Prompts

    private func validationPrompt(transcript: String, partial: ExtractionResult) -> String {
        let existingIngredients = partial.ingredients.map { "- \($0.text)" }.joined(separator: "\n")
        let existingSteps = partial.steps.map { "\($0.order). \($0.text)" }.joined(separator: "\n")

        return """
        I extracted a recipe from a cooking video transcript but may have missed some details.
        Please review and fill in ONLY what's missing. Return valid JSON only.

        What I extracted so far:
        Title: \(partial.title ?? "unknown")
        Ingredients:
        \(existingIngredients.isEmpty ? "(none found)" : existingIngredients)
        Steps:
        \(existingSteps.isEmpty ? "(none found)" : existingSteps)

        Full transcript:
        \(transcript.prefix(8000))

        Return JSON:
        {
          "title": "string or null (null if already correct)",
          "recipeYield": "string or null",
          "additionalIngredients": ["ingredient I missed", ...],
          "allSteps": ["complete ordered step list", ...]
        }
        """
    }

    private func primaryPrompt(transcript: String) -> String {
        return """
        Extract the complete recipe from this cooking video transcript. Return ONLY valid JSON.

        {
          "title": "string or null",
          "recipeYield": "string or null",
          "prepTimeMinutes": number or null,
          "cookTimeMinutes": number or null,
          "ingredients": ["raw ingredient string with quantity", ...],
          "steps": ["step text in order", ...]
        }

        Transcript:
        \(transcript.prefix(8000))
        """
    }

    // MARK: - Response Parsing

    private func parseResponse(data: Data, mode: Mode, partial: ExtractionResult) throws -> ExtractionResult {
        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = outer["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw TranscriptLLMError.malformedResponse
        }

        let jsonText = extractJSON(from: text)
        guard let jsonData = jsonText.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw TranscriptLLMError.malformedResponse
        }

        var result = partial
        result.extractionMethod = Self.method

        if mode == .primary {
            result.title = (dict["title"] as? String) ?? partial.title
            result.recipeYield = (dict["recipeYield"] as? String) ?? partial.recipeYield
            if let prepMins = dict["prepTimeMinutes"] as? Int { result.prepTime = prepMins * 60 }
            if let cookMins = dict["cookTimeMinutes"] as? Int { result.cookTime = cookMins * 60 }
            if let rawIngredients = dict["ingredients"] as? [String] {
                result.ingredients = rawIngredients.map { RawIngredient(text: $0) }
            }
            if let rawSteps = dict["steps"] as? [String] {
                result.steps = rawSteps.enumerated().map { idx, text in RawStep(order: idx + 1, text: text) }
            }
        } else {
            // Validation mode: merge LLM additions with existing
            if let t = dict["title"] as? String, partial.title == nil { result.title = t }
            if let y = dict["recipeYield"] as? String { result.recipeYield = y }
            if let additional = dict["additionalIngredients"] as? [String] {
                result.ingredients += additional.map { RawIngredient(text: $0) }
            }
            if let allSteps = dict["allSteps"] as? [String], allSteps.count > partial.steps.count {
                result.steps = allSteps.enumerated().map { idx, text in RawStep(order: idx + 1, text: text) }
            }
        }

        result.appliances = ApplianceDetector.detect(
            in: result.ingredients.map { $0.text } + result.steps.map { $0.text }
        )
        return result
    }

    private func extractJSON(from text: String) -> String {
        if let start = text.range(of: "{"), let end = text.range(of: "}", options: .backwards) {
            return String(text[start.lowerBound...end.upperBound])
        }
        return text
    }
}

enum TranscriptLLMError: LocalizedError {
    case invalidConfiguration
    case apiError
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "LLM validator is not configured."
        case .apiError:             return "Claude API returned an error."
        case .malformedResponse:    return "Could not parse LLM response."
        }
    }
}
