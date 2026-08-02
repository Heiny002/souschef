import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Reads BURNED-IN captions out of a recipe video's frames.
///
/// A huge share of recipe reels narrate the method and caption the narration on screen
/// ("captioned audio"), leaving the written caption as a hook. No text route reaches that
/// recipe: it exists only as pixels. This samples frames across the video, runs the same
/// Vision OCR the carousel slides use, and merges the per-frame texts into one document.
///
/// Everything is on-device and API-free: AVFoundation decodes the frames, Vision reads
/// them. The cheap text-triage pass rejects caption-free frames before paying for full
/// recognition, and captions persist on screen for seconds, so a sparse sample (~1 frame
/// every 1.5–2.5 s) sees every caption at least once.
enum VideoFrameTextExtractor {

    /// Sampling stops growing past this many frames — a longer video just gets a sparser
    /// stride. Bounds both decode time and OCR passes.
    static let maxFrames = 48
    /// Videos past this length are sampled only up to here. A recipe reel is 30–90 s; a
    /// 20-minute upload is not going to caption its recipe in minute 14.
    static let maxSeconds: Double = 120

    /// OCR text merged across the video's frames, deduplicated line-by-line in first-seen
    /// order. Empty when the URL is disallowed, the download fails, or no frame has text.
    static func extractText(videoURL: URL,
                            progress: (@Sendable (String) -> Void)? = nil) async -> String {
        // The URL comes out of parsed Instagram JSON — attacker-influenceable — so it
        // passes the same SSRF guard as every other fetched URL.
        guard WebPageFetcher.isAllowed(videoURL) else { return "" }
        progress?("Downloading the video…")
        guard let localURL = await download(videoURL) else { return "" }
        defer { try? FileManager.default.removeItem(at: localURL) }

        let asset = AVURLAsset(url: localURL)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0.5
        else { return "" }
        let seconds = min(duration.seconds, maxSeconds)
        let interval = max(1.5, seconds / Double(maxFrames))
        // Start half a second in: frame 0 is often a title card or still-black fade.
        let times = stride(from: 0.5, to: seconds, by: interval).map {
            CMTime(seconds: $0, preferredTimescale: 600)
        }
        guard !times.isEmpty else { return "" }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // 1080 px is plenty for caption-sized text and keeps decode + OCR fast.
        generator.maximumSize = CGSize(width: 1080, height: 1080)
        // Captions persist for seconds — loose tolerance lets the decoder land on nearby
        // keyframes instead of seeking exactly, which is dramatically faster.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var frameTexts: [String] = []
        var index = 0
        for await result in generator.images(for: times) {
            index += 1
            if index % 8 == 0 { progress?("Reading on-screen captions… (\(index)/\(times.count))") }
            guard let cg = try? result.image, let data = jpegData(cg) else { continue }
            // Triage before recognition, same staging as the carousel path.
            guard await ImageTextRecognizer.hasText(inImageData: data) else { continue }
            let text = await ImageTextRecognizer.recognizeText(inImageData: data)
            if !text.isEmpty { frameTexts.append(text) }
        }
        return mergeFrameTexts(frameTexts)
    }

    /// Merge per-frame OCR texts into one document: lines in first-seen order, duplicates
    /// dropped. Captions persist across many sampled frames (and watermarks/handles across
    /// ALL of them), so near-verbatim repeats are the norm — the dedupe key strips case,
    /// punctuation, and space runs so OCR jitter ("Add the flour" / "Add the flour.")
    /// doesn't leak duplicates through. Pure + testable.
    static func mergeFrameTexts(_ texts: [String]) -> String {
        var seen = Set<String>()
        var lines: [String] = []
        for text in texts {
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                let key = line.lowercased()
                    .filter { $0.isLetter || $0.isNumber || $0 == " " }
                    .split(separator: " ").joined(separator: " ")
                guard !line.isEmpty, key.count > 2, !seen.contains(key) else { continue }
                seen.insert(key)
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Plumbing

    private static func download(_ url: URL) async -> URL? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        guard let (tmp, response) = try? await session.download(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else { return nil }
        // AVFoundation sniffs the container from the path extension; the download lands
        // extensionless, so give it one.
        let mp4 = tmp.deletingPathExtension().appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: mp4)
        guard (try? FileManager.default.moveItem(at: tmp, to: mp4)) != nil else { return nil }
        return mp4
    }

    /// Encode a decoded frame back to JPEG so it can ride the existing Data-based OCR
    /// entry points (which also keeps CGImage out of the recognizer's concurrency domain).
    private static func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image,
            [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
