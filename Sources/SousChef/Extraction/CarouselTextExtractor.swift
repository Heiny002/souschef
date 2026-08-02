import Foundation

/// Reads a recipe out of an Instagram carousel's SLIDES.
///
/// A large share of recipe carousels put the ingredients and method in the images — text laid
/// over a photo — and leave the caption as a one-line hook. Caption extraction returns nothing
/// useful for those, so the only way to reach the recipe is to read the slides themselves.
///
/// The pass is deliberately staged, cheapest first:
///   1. Fetch the slide URLs (one authenticated media-info call).
///   2. Download each slide.
///   3. **Triage**: `VNDetectTextRectangles` asks "is there text here at all?" without reading
///      characters. A typical carousel is a hero food photo plus a few text slides, so this
///      skips the photos before paying for recognition on them.
///   4. Full OCR only on the slides that survived triage.
///
/// The combined text is handed to the same parser as a paste or a photo scan, so everything
/// downstream — sections, scaling, equipment — works identically.
enum CarouselTextExtractor {

    /// Slides beyond this are ignored. Instagram allows 20; a recipe that needs more than 12
    /// isn't a recipe, and each extra slide costs a download plus an OCR pass.
    static let maxSlides = 12

    /// OCR text from a carousel's slides, joined in slide order. Empty when the post isn't a
    /// carousel, has no text slides, or the user isn't connected to Instagram.
    ///
    /// `progress` reports slide-by-slide so the import screen can show real movement — this
    /// can take several seconds and silence reads as a hang.
    static func extractText(shortcode: String,
                            progress: (@Sendable (String) -> Void)? = nil) async -> String {
        combine(await extractSlideTexts(shortcode: shortcode, progress: progress))
    }

    /// Per-slide OCR texts for an Instagram carousel, in slide order.
    static func extractSlideTexts(shortcode: String,
                                  progress: (@Sendable (String) -> Void)? = nil) async -> [String] {
        let urls = await InstagramAuth.fetchCarouselImageURLs(shortcode: shortcode)
        return await extractSlideTexts(imageURLs: urls, progress: progress)
    }

    /// OCR text from a set of already-resolved slide image URLs, joined in order.
    static func extractText(imageURLs urls: [URL],
                            progress: (@Sendable (String) -> Void)? = nil) async -> String {
        combine(await extractSlideTexts(imageURLs: urls, progress: progress))
    }

    /// The platform-agnostic OCR core, one text per slide that HAS text (food-photo slides
    /// are dropped by the triage pass, so they act as natural separators). Instagram resolves
    /// URLs from a shortcode, TikTok photo mode hands them over from its embed data. Keeping
    /// slides separate is what lets the pipeline tell ONE recipe spread across slides from a
    /// COLLECTION of recipes, one per slide.
    static func extractSlideTexts(imageURLs urls: [URL],
                                  progress: (@Sendable (String) -> Void)? = nil) async -> [String] {
        guard !urls.isEmpty else { return [] }

        let slides = Array(urls.prefix(maxSlides))
        if urls.count > maxSlides {
            progress?("Reading the first \(maxSlides) of \(urls.count) slides…")
        }

        var pieces: [String] = []
        for (index, url) in slides.enumerated() {
            progress?("Reading slide \(index + 1) of \(slides.count)…")
            guard let imageData = await downloadImageData(url) else { continue }

            // Triage before recognition — the whole point of the staged pass.
            guard await ImageTextRecognizer.hasText(inImageData: imageData) else { continue }

            let text = await ImageTextRecognizer.recognizeText(inImageData: imageData)
            if let cleaned = SocialTextFilter.cleanEntry(text), !cleaned.isEmpty {
                pieces.append(cleaned)
            }
        }
        return pieces
    }

    /// Join slide texts into one document.
    ///
    /// Blank lines between slides matter: the parser detects sections by paragraph structure,
    /// and a carousel's slides are already the recipe's natural sections ("Ingredients" on one,
    /// "Method" on the next). Runs of blank lines are collapsed so a slide that ends in
    /// whitespace doesn't create a gap the parser reads as a section break.
    static func combine(_ pieces: [String]) -> String {
        pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    // MARK: - Download

    /// Raw image bytes — Vision consumes encoded data directly (no image-type
    /// round-trip), which keeps this file platform-neutral for the macOS harness.
    private static func downloadImageData(_ url: URL) async -> Data? {
        // These URLs come from parsed Instagram/TikTok JSON — attacker-influenceable — so
        // they pass the same SSRF guard as web fetches before any request is made.
        guard WebPageFetcher.isAllowed(url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // Instagram's CDN serves images without auth, but wants a browser-ish UA.
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: .ephemeral)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else { return nil }
        return data
    }
}
