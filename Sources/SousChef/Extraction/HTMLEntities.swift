import Foundation

/// One HTML-entity decoder for the whole extraction path. The app had four divergent copies;
/// this is the canonical one, and — critically for truncation detection — it decodes the
/// named ellipsis `&hellip;` and the numeric ellipsis forms (`&#8230;`, `&#x2026;`), which a
/// cut-off og:description ends with. Without decoding those, the "…" marker is invisible.
enum HTMLEntities {
    private static let named: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
        "&apos;": "'", "&nbsp;": " ", "&hellip;": "\u{2026}", "&mdash;": "\u{2014}",
        "&ndash;": "\u{2013}",
    ]

    /// Decode named entities plus decimal/hex numeric character references.
    static func decode(_ s: String) -> String {
        var out = s
        for (entity, char) in named {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        guard let re = try? NSRegularExpression(pattern: "&#([xX])?([0-9a-fA-F]+);") else { return out }
        for match in re.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let codeRange = Range(match.range(at: 2), in: out),
                  let fullRange = Range(match.range, in: out) else { continue }
            let isHex = match.range(at: 1).location != NSNotFound
            guard let code = UInt32(out[codeRange], radix: isHex ? 16 : 10),
                  let scalar = Unicode.Scalar(code) else { continue }
            out.replaceSubrange(fullRange, with: String(scalar))
        }
        return out
    }
}

/// Detects when a caption arrived cut off mid-recipe, so the import can say so instead of
/// silently saving half a recipe.
enum TruncationDetector {
    /// True when a caption's last content is an ellipsis after decoding entities and stripping
    /// the engagement preamble. og:description and WKWebView previews truncate exactly this
    /// way; a trailing "…" is the one reliable marker. (A markerless mid-word cut can't be
    /// detected here — that limitation is stated in the UI copy, not papered over.)
    ///
    /// The engagement prefix is stripped first because og:description wraps the caption in
    /// quotes, so a raw check would see the closing quote, not the ellipsis.
    static func isLikelyTruncated(_ caption: String) -> Bool {
        let decoded = HTMLEntities.decode(caption)
        let body = SocialTextFilter.stripEngagementPrefix(decoded)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D} \n\r\t"))
        guard !body.isEmpty else { return false }
        return body.hasSuffix("\u{2026}") || body.hasSuffix("...")
    }
}
