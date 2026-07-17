import Foundation

/// Backend service endpoint configuration (H12).
///
/// The transcript/search server is a FastAPI instance that exists only on a developer
/// machine — on a user's phone nothing listens on localhost, and every call was silently
/// swallowed by `try?`, degrading video imports with no signal. The base URL now comes
/// from Info.plist (`RECIPE_BACKEND_URL`, injectable via xcconfig like the API key) and
/// falls back to localhost ONLY in DEBUG builds. A release build without a configured
/// backend disables these layers explicitly instead of dialing a dead socket.
enum BackendConfig {
    static var baseURL: String? {
        if let configured = Bundle.main.infoDictionary?["RECIPE_BACKEND_URL"] as? String,
           !configured.isEmpty {
            return configured
        }
        #if DEBUG
        return "http://localhost:8000"   // local dev server (simulator only)
        #else
        return nil
        #endif
    }
}

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
    private let serverURL: String?
    private let session: URLSession

    /// Shared instance using the configured backend (nil in release builds without one).
    static let shared = TranscriptFetcher(serverURL: BackendConfig.baseURL)

    init(serverURL: String?) {
        self.serverURL = serverURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60  // Whisper transcription can take ~30s
        self.session = URLSession(configuration: config)
    }

    func fetchTranscript(videoURL: String) async throws -> VideoTranscript {
        guard let serverURL, let url = URL(string: "\(serverURL)/extract-transcript") else {
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
