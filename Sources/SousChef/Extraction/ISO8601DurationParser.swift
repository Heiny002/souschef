import Foundation

/// Parses ISO 8601 duration strings into seconds.
/// Handles: PT45M, PT1H30M, P1DT2H, P0Y0M0DT0H45M0S — and decimal components
/// like PT1.5H / PT2.5M, which schema.org plugins emit for "1½ hours" (previously
/// dropped entirely, so a 90-minute time read as absent).
enum ISO8601DurationParser {
    static func seconds(from duration: String) -> Int? {
        let s = duration.uppercased().trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("P") else { return nil }

        var total = 0.0
        var current = ""
        var inTime = false

        for char in s.dropFirst() {
            switch char {
            case "T":
                inTime = true
            case "Y":
                // Years — ignore for recipe durations
                current = ""
            case "M":
                if let v = Double(current) {
                    total += inTime ? v * 60 : v * 30 * 24 * 3600
                }
                current = ""
            case "W":
                if let v = Double(current) { total += v * 7 * 24 * 3600 }
                current = ""
            case "D":
                if let v = Double(current) { total += v * 24 * 3600 }
                current = ""
            case "H":
                if let v = Double(current) { total += v * 3600 }
                current = ""
            case "S":
                if let v = Double(current) { total += v }
                current = ""
            default:
                if char.isNumber || char == "." {
                    current.append(char)
                }
            }
        }

        // Untrusted input: reject non-finite / absurd values before the Int cast (which
        // traps above Int.max) — same hardening as TimerDetector.
        guard total.isFinite, total > 0, total <= 7 * 24 * 3600 else { return nil }
        return Int(total)
    }
}

// MARK: - Labeled prose durations

/// Parses human-written durations that follow a label in page/transcript text —
/// "Prep time: 20 minutes", "Total time: 1 hr 30 min", "cook for 1.5 hours".
///
/// Shared by HeuristicExtractor and TranscriptExtractor, whose previous copies each
/// matched only the FIRST number+unit — so "1 hr 30 min" read as 60 minutes (audit
/// medium: compound durations truncated).
enum DurationTextParser {
    // Group 1: hours value · group 2: trailing minutes after hours · group 3: minutes-only
    private static let pattern =
        #"(?:\s*:?\s*)(?:for\s+)?(?:(\d+(?:\.\d+)?)\s*h(?:(?:ou)?rs?)?\b\.?(?:\s*(?:and\s+)?(\d+(?:\.\d+)?)\s*min(?:ute)?s?\b)?|(\d+(?:\.\d+)?)\s*min(?:ute)?s?\b)"#

    /// Seconds for the first "<label> …duration…" occurrence in `text`, or nil.
    static func seconds(in text: String, after label: String) -> Int? {
        let full = NSRegularExpression.escapedPattern(for: label) + Self.pattern
        guard let regex = try? NSRegularExpression(pattern: full, options: .caseInsensitive),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        func value(_ i: Int) -> Double? {
            guard let r = Range(m.range(at: i), in: text) else { return nil }
            return Double(text[r])
        }

        let secs: Double
        if let hours = value(1) {
            secs = hours * 3600 + (value(2) ?? 0) * 60
        } else if let minutes = value(3) {
            secs = minutes * 60
        } else {
            return nil
        }
        guard secs.isFinite, secs > 0, secs <= 7 * 24 * 3600 else { return nil }
        return Int(secs)
    }
}
