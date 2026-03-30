import Foundation

/// SC-031: Fetches video caption/title metadata via oEmbed endpoints.
/// No auth required. Returns caption text for recipe extraction.
struct VideoMetadata {
    let title: String?
    let authorName: String?
    let caption: String?      // Often contains recipe outline
    let thumbnailURL: String?
}

actor VideoMetadataFetcher {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)
    }

    func fetch(videoURL: String) async throws -> VideoMetadata {
        let sourceType = URLRouter.classify(videoURL)
        switch sourceType {
        case .tikTok:
            return try await fetchOEmbed(endpoint: "https://www.tiktok.com/oembed", videoURL: videoURL)
        case .youTube:
            return try await fetchOEmbed(endpoint: "https://www.youtube.com/oembed", videoURL: videoURL)
        case .instagram:
            return try await fetchOEmbed(endpoint: "https://api.instagram.com/oembed", videoURL: videoURL)
        case .webPage:
            throw VideoMetadataError.unsupportedSource
        }
    }

    // MARK: - Private

    private func fetchOEmbed(endpoint: String, videoURL: String) async throws -> VideoMetadata {
        let encodedURL = videoURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? videoURL
        guard let url = URL(string: "\(endpoint)?url=\(encodedURL)&format=json") else {
            throw VideoMetadataError.invalidURL
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw VideoMetadataError.apiError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VideoMetadataError.malformedResponse
        }

        // TikTok and Instagram put the caption in "title" field
        // YouTube puts the video title in "title" and description isn't returned via oEmbed
        let title = dict["title"] as? String
        let authorName = dict["author_name"] as? String

        // TikTok puts the full caption (often with recipe) in "title"
        // We treat it as caption since it's the closest we get without transcription
        let caption = dict["title"] as? String

        let thumbnailURL = dict["thumbnail_url"] as? String

        return VideoMetadata(
            title: title,
            authorName: authorName,
            caption: caption,
            thumbnailURL: thumbnailURL
        )
    }
}

enum VideoMetadataError: LocalizedError {
    case unsupportedSource
    case invalidURL
    case apiError(statusCode: Int)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .unsupportedSource:     return "This video source is not supported."
        case .invalidURL:            return "Could not construct oEmbed URL."
        case .apiError(let code):    return "oEmbed API returned HTTP \(code)."
        case .malformedResponse:     return "Could not parse oEmbed response."
        }
    }
}
