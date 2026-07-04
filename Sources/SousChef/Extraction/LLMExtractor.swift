import Foundation
import SwiftSoup

/// Layer 4: LLM fallback extractor for web pages.
/// Only triggered when Layers 1-3 produce confidence < 0.5.
/// Strips HTML to plain text, sends to Claude Haiku with structured JSON output schema.
/// Fixed confidence 0.6 — always requires user review.
actor LLMExtractor {
    private static let method = "llm-fallback"
    private static let maxTextLength = 16_000   // ~4k tokens

    private let apiKey: String
    private let session: URLSession

    init(apiKey: String) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    func extract(html: String) async throws -> ExtractionResult {
        var result = ExtractionResult(extractionMethod: Self.method)
        result.confidence = 0.0

        let plainText = stripToPlainText(html: html)
        guard !plainText.isEmpty else { return result }

        let truncated = String(plainText.prefix(Self.maxTextLength))
        let parsed = try await callClaude(text: truncated)
        result = parsed
        result.extractionMethod = Self.method
        result.confidence = result.isViable ? 0.6 : 0.2
        return result
    }

    // MARK: - HTML → Plain Text

    private func stripToPlainText(html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html) else { return "" }
        // Remove scripts, styles, nav, footer
        _ = try? doc.select("script, style, nav, footer, header, aside, .ad, .advertisement").remove()
        return (try? doc.text()) ?? ""
    }

    // MARK: - Claude API Call

    private func callClaude(text: String) async throws -> ExtractionResult {
        let prompt = """
        Extract the recipe from this webpage text. Return ONLY valid JSON matching this schema:
        {
          "title": "string",
          "recipeYield": "string or null",
          "prepTimeMinutes": number or null,
          "cookTimeMinutes": number or null,
          "ingredients": ["raw ingredient string", ...],
          "steps": ["step text", ...]
        }
        If this is not a recipe page, return {"title": null, "ingredients": [], "steps": []}.

        Webpage text:
        \(text)
        """

        let requestBody: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 2048,
            "messages": [["role": "user", "content": prompt]]
        ]

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw LLMExtractorError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LLMExtractorError.apiError
        }

        return try parseResponse(data: data)
    }

    private func parseResponse(data: Data) throws -> ExtractionResult {
        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = outer["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw LLMExtractorError.malformedResponse
        }

        // Extract JSON from potentially markdown-wrapped response
        let jsonText = extractJSON(from: text)
        guard let jsonData = jsonText.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw LLMExtractorError.malformedResponse
        }

        var result = ExtractionResult(extractionMethod: Self.method)
        result.title = dict["title"] as? String
        result.recipeYield = dict["recipeYield"] as? String

        if let prepMins = dict["prepTimeMinutes"] as? Int { result.prepTime = prepMins * 60 }
        if let cookMins = dict["cookTimeMinutes"] as? Int { result.cookTime = cookMins * 60 }

        if let rawIngredients = dict["ingredients"] as? [String] {
            result.ingredients = rawIngredients.map { RawIngredient(text: $0) }
        }
        if let rawSteps = dict["steps"] as? [String] {
            result.steps = rawSteps.enumerated().map { idx, text in RawStep(order: idx + 1, text: text) }
        }

        // Appliance detection from extracted content
        let textForAppliances = result.ingredients.map { $0.text } + result.steps.map { $0.text }
        result.appliances = ApplianceDetector.detect(in: textForAppliances)

        return result
    }

    private func extractJSON(from text: String) -> String {
        // Strip ```json ... ``` markdown fences if present
        if let start = text.range(of: "{"), let end = text.range(of: "}", options: .backwards) {
            return String(text[start.lowerBound...end.upperBound])
        }
        return text
    }
}

enum LLMExtractorError: LocalizedError {
    case invalidConfiguration
    case apiError
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "LLM extractor is not configured."
        case .apiError:             return "Claude API returned an error."
        case .malformedResponse:    return "Could not parse LLM response as JSON."
        }
    }
}
