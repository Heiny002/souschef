import Foundation

enum WebPageFetcherError: LocalizedError {
    case invalidURL
    case blockedURL
    case tooManyRedirects
    case responseTooLarge
    case timeout
    case httpError(statusCode: Int)
    case noData

    var errorDescription: String? {
        switch self {
        case .invalidURL:        return "The URL is not valid."
        case .blockedURL:        return "The URL is not allowed."
        case .tooManyRedirects:  return "Too many redirects."
        case .responseTooLarge:  return "The response was too large."
        case .timeout:           return "The request timed out."
        case .httpError(let c):  return "HTTP error \(c)."
        case .noData:            return "No data received."
        }
    }
}

actor WebPageFetcher {
    private let timeout: TimeInterval
    private let maxRedirects: Int
    private let maxBytes: Int
    private let session: URLSession
    // Retained so it isn't deallocated while the session holds it weakly-by-convention.
    private let redirectGuard: RedirectGuard

    init(timeout: TimeInterval = 15, maxRedirects: Int = 5, maxBytes: Int = 10 * 1024 * 1024) {
        self.timeout = timeout
        self.maxRedirects = maxRedirects
        self.maxBytes = maxBytes

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpMaximumConnectionsPerHost = 4
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        ]
        // Redirects are followed through a delegate that counts hops and re-runs the SSRF
        // check on each new URL — otherwise URLSession auto-follows ~20 redirects and an
        // allowed URL could 302 to http://localhost or an internal host unchecked.
        let guardDelegate = RedirectGuard(maxRedirects: maxRedirects)
        self.redirectGuard = guardDelegate
        self.session = URLSession(configuration: config, delegate: guardDelegate, delegateQueue: nil)
    }

    deinit {
        // Break the session ⇄ delegate retain and cancel any in-flight task.
        session.invalidateAndCancel()
    }

    /// Fetch HTML from the given URL. Rejects non-https, loopback/LAN/reserved hosts, and
    /// responses larger than `maxBytes`; re-validates every redirect hop.
    func fetch(urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw WebPageFetcherError.invalidURL
        }
        guard Self.isAllowed(url) else {
            throw WebPageFetcherError.blockedURL
        }

        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        // Stream the body so an oversized response is aborted rather than fully buffered.
        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw WebPageFetcherError.noData
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            bytes.task.cancel()
            throw WebPageFetcherError.httpError(statusCode: httpResponse.statusCode)
        }
        if httpResponse.expectedContentLength > Int64(maxBytes) {
            bytes.task.cancel()
            throw WebPageFetcherError.responseTooLarge
        }

        var data = Data()
        if httpResponse.expectedContentLength > 0 {
            data.reserveCapacity(min(maxBytes, Int(httpResponse.expectedContentLength)))
        }
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes {
                bytes.task.cancel()
                throw WebPageFetcherError.responseTooLarge
            }
        }

        let encoding = detectEncoding(from: httpResponse, data: data)
        guard let html = String(data: data, encoding: encoding) ?? String(data: data, encoding: .isoLatin1) else {
            throw WebPageFetcherError.noData
        }
        return html
    }

    // MARK: - SSRF scheme/host validation

    /// True only for an https URL on a standard port whose host is a public name/address.
    /// Rejects other schemes and loopback / link-local / RFC1918 / CGNAT / ULA / multicast
    /// hosts and `.local`/`.internal`/`localhost` names, so scraped URLs can't drive requests
    /// at the local transcript server or other LAN/internal hosts.
    nonisolated static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        if let port = url.port, port != 443 { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return !isBlockedHost(host)
    }

    nonisolated static func isBlockedHost(_ host: String) -> Bool {
        if host == "localhost"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host.hasSuffix(".internal") { return true }

        // Strip IPv6 brackets ("[::1]" → "::1").
        let bare = (host.hasPrefix("[") && host.hasSuffix("]")) ? String(host.dropFirst().dropLast()) : host

        if let v4 = IPv4(bare) { return v4.isPrivateOrReserved }
        if bare.contains(":") { return isBlockedIPv6(bare) }
        return false
    }

    nonisolated private static func isBlockedIPv6(_ s: String) -> Bool {
        let l = s.lowercased()
        if l == "::1" || l == "::" { return true }                                     // loopback / unspecified
        if l.hasPrefix("fe8") || l.hasPrefix("fe9") || l.hasPrefix("fea") || l.hasPrefix("feb") {
            return true                                                                 // link-local fe80::/10
        }
        if l.hasPrefix("fc") || l.hasPrefix("fd") { return true }                      // unique-local fc00::/7
        // IPv4-mapped (::ffff:127.0.0.1) — validate the embedded v4.
        if let r = l.range(of: "::ffff:"), let v4 = IPv4(String(l[r.upperBound...])) {
            return v4.isPrivateOrReserved
        }
        return false
    }

    private struct IPv4 {
        let a, b, c, d: Int

        init?(_ s: String) {
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var octets: [Int] = []
            for p in parts {
                guard let n = Int(p), (0...255).contains(n) else { return nil }
                octets.append(n)
            }
            (a, b, c, d) = (octets[0], octets[1], octets[2], octets[3])
        }

        var isPrivateOrReserved: Bool {
            switch (a, b) {
            case (0, _):          return true   // 0.0.0.0/8 "this host"
            case (10, _):         return true   // 10.0.0.0/8
            case (127, _):        return true   // loopback
            case (169, 254):      return true   // link-local
            case (172, 16...31):  return true   // 172.16.0.0/12
            case (192, 168):      return true   // 192.168.0.0/16
            case (100, 64...127): return true   // CGNAT 100.64.0.0/10
            default:              return a >= 224   // multicast / reserved 224.0.0.0+
            }
        }
    }

    // MARK: - Encoding

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

/// Counts redirect hops per task and re-validates each new URL against the SSRF policy.
/// `completionHandler(nil)` stops following, so the 3xx surfaces as a non-2xx error.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let maxRedirects: Int
    private let lock = NSLock()
    private var counts: [Int: Int] = [:]

    init(maxRedirects: Int) { self.maxRedirects = maxRedirects }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        let hops = (counts[task.taskIdentifier] ?? 0) + 1
        counts[task.taskIdentifier] = hops
        lock.unlock()

        guard hops <= maxRedirects, let url = request.url, WebPageFetcher.isAllowed(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        counts[task.taskIdentifier] = nil
        lock.unlock()
    }
}
