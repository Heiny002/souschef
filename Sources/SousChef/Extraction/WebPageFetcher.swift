import Foundation

enum WebPageFetcherError: LocalizedError {
    case invalidURL
    case tooManyRedirects
    case timeout
    case httpError(statusCode: Int)
    case noData

    var errorDescription: String? {
        switch self {
        case .invalidURL:        return "The URL is not valid."
        case .tooManyRedirects:  return "Too many redirects."
        case .timeout:           return "The request timed out."
        case .httpError(let c):  return "HTTP error \(c)."
        case .noData:            return "No data received."
        }
    }
}

actor WebPageFetcher {
    private let timeout: TimeInterval
    private let maxRedirects: Int
    private let session: URLSession

    init(timeout: TimeInterval = 15, maxRedirects: Int = 5) {
        self.timeout = timeout
        self.maxRedirects = maxRedirects

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpMaximumConnectionsPerHost = 4
        // Handle redirects manually via delegate
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        ]
        self.session = URLSession(configuration: config)
    }

    /// Fetch HTML from the given URL, following up to `maxRedirects` redirects.
    func fetch(urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw WebPageFetcherError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebPageFetcherError.noData
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebPageFetcherError.httpError(statusCode: httpResponse.statusCode)
        }

        // Detect encoding from Content-Type header or default to UTF-8
        let encoding = detectEncoding(from: httpResponse, data: data)
        guard let html = String(data: data, encoding: encoding) ?? String(data: data, encoding: .isoLatin1) else {
            throw WebPageFetcherError.noData
        }

        return html
    }

    // MARK: - Private

    private func detectEncoding(from response: HTTPURLResponse, data: Data) -> String.Encoding {
        if let contentType = response.value(forHTTPHeaderField: "Content-Type"),
           contentType.lowercased().contains("charset=") {
            let parts = contentType.components(separatedBy: "charset=")
            if let charsetPart = parts.last?.trimmingCharacters(in: .whitespaces).lowercased() {
                if charsetPart.hasPrefix("utf-8") { return .utf8 }
                if charsetPart.hasPrefix("iso-8859-1") { return .isoLatin1 }
                if charsetPart.hasPrefix("windows-1252") { return .windowsCP1252 }
            }
        }
        // Check BOM in data
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF { return .utf8 }
        return .utf8
    }
}
