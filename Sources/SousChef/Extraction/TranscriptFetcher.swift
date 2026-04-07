import Foundation

/// SC-032: Client for the transcript extraction backend.
/// POST /extract-transcript → { caption, transcript, onScreenText, blogURL, duration }
/// MVP: The server runs Python FastAPI + yt-dlp + Whisper.
/// Fallback: Supadata API at supadataEndpoint.
struct VideoTranscript {
    let caption: String?
    let transcript: String?
    let onScreenText: [String]
    let blogURL: String?
    let durationSeconds: Int?

    /// Combined text for NLP extraction (caption + transcript)
    var combinedText: String {
        [caption, transcript].compactMap { $0 }.joined(separator: "\n\n")
    }
}

actor TranscriptFetcher {
    private let serverURL: String
    private let session: URLSession

    /// Shared instance using the default server endpoint.
    static let shared = TranscriptFetcher(serverURL: "http://localhost:8000")

    init(serverURL: String) {
        self.serverURL = serverURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60  // Whisper transcription can take ~30s
        self.session = URLSession(configuration: config)
    }

    func fetchTranscript(videoURL: String) async throws -> VideoTranscript {
        guard let url = URL(string: "\(serverURL)/extract-transcript") else {
            throw TranscriptError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["url": videoURL])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptError.networkError
        }
        guard (200...299).contains(http.statusCode) else {
            throw TranscriptError.serverError(statusCode: http.statusCode)
        }

        return try parseResponse(data: data)
    }

    private func parseResponse(data: Data) throws -> VideoTranscript {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptError.malformedResponse
        }
        return VideoTranscript(
            caption:       dict["caption"]     as? String,
            transcript:    dict["transcript"]  as? String,
            onScreenText:  dict["onScreenText"] as? [String] ?? [],
            blogURL:       dict["blogURL"]      as? String,
            durationSeconds: dict["duration"]  as? Int
        )
    }
}

enum TranscriptError: LocalizedError {
    case invalidConfiguration
    case networkError
    case serverError(statusCode: Int)
    case malformedResponse
    case videoUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:      return "Transcript server is not configured."
        case .networkError:              return "Network error fetching transcript."
        case .serverError(let code):     return "Transcript server returned HTTP \(code)."
        case .malformedResponse:         return "Could not parse transcript response."
        case .videoUnavailable:          return "This video is unavailable or private."
        }
    }
}
