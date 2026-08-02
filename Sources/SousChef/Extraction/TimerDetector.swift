import Foundation

// Lives in Extraction (not CookMode) because StepSequencer consumes it at parse time and
// the SousChefDesk macOS harness compiles this directory — CookTimerManager.swift, its old
// home, is UIKit/UserNotifications-bound and can never join a macOS build.

// MARK: - DetectedTimer

struct DetectedTimer {
    let label: String       // e.g. "3–5 minutes"
    let seconds: Int        // duration in seconds (midpoint for ranges)
    let isPerSide: Bool     // true → two sequential timers ("per side")
}

// MARK: - TimerDetector

/// Parses cooking-time mentions from instruction text.
enum TimerDetector {

    /// Extract a timer from a step instruction. Returns nil if no time found.
    static func detect(in instruction: String) -> DetectedTimer? {
        let text = instruction.lowercased()
        let perSide = text.contains("per side") || text.contains("each side")
            || text.contains("per breast") || text.contains("per piece")

        if let r = detectRange(in: text) {
            return DetectedTimer(label: r.label, seconds: r.seconds, isPerSide: perSide)
        }
        if let s = detectSingle(in: text) {
            return DetectedTimer(label: s.label, seconds: s.seconds, isPerSide: perSide)
        }
        return nil
    }

    // MARK: - Range "2-3 minutes" / "2 to 3 minutes"

    // Separator accepts "to" plus hyphen and the typographic dashes recipe plugins
    // often emit (en-dash "–", em-dash "—", minus "−") — otherwise "10–15 minutes"
    // silently fails to match and no timer is offered.
    private static let rangeRE = try? NSRegularExpression(
        pattern: #"(\d+(?:\.\d+)?)\s*(?:to|[-–—−])\s*(\d+(?:\.\d+)?)\s*(minutes?|mins?|hours?|hrs?|seconds?|secs?)"#,
        options: .caseInsensitive
    )

    private static func detectRange(in text: String) -> (label: String, seconds: Int)? {
        let ns = NSRange(text.startIndex..., in: text)
        guard let m = rangeRE?.firstMatch(in: text, range: ns),
              let r1 = Range(m.range(at: 1), in: text),
              let r2 = Range(m.range(at: 2), in: text),
              let r3 = Range(m.range(at: 3), in: text),
              let lo = Double(text[r1]),
              let hi = Double(text[r2]) else { return nil }

        let unit = String(text[r3])
        let mid = (lo + hi) / 2.0
        guard let secs = toSeconds(mid, unit: unit), secs >= 10 else { return nil }
        let label = "\(Int(lo))–\(Int(hi)) \(normalizeUnit(unit, count: Int(hi)))"
        return (label, secs)
    }

    // MARK: - Single "5 minutes"

    private static let singleRE = try? NSRegularExpression(
        pattern: #"(\d+(?:\.\d+)?)\s*(minutes?|mins?|hours?|hrs?|seconds?|secs?)"#,
        options: .caseInsensitive
    )

    private static func detectSingle(in text: String) -> (label: String, seconds: Int)? {
        let ns = NSRange(text.startIndex..., in: text)
        guard let m = singleRE?.firstMatch(in: text, range: ns),
              let r1 = Range(m.range(at: 1), in: text),
              let r2 = Range(m.range(at: 2), in: text),
              let value = Double(text[r1]) else { return nil }

        let unit = String(text[r2])
        guard let secs = toSeconds(value, unit: unit), secs >= 10 else { return nil }
        let label = "\(Int(value)) \(normalizeUnit(unit, count: Int(value)))"
        return (label, secs)
    }

    // MARK: - Helpers

    /// Longest a cook timer is allowed to be (24h). Scraped instruction text is untrusted,
    /// so an absurd digit run ("cook for 99999999999999999999 minutes") must be rejected.
    private static let maxSeconds: Double = 86_400

    private static func toSeconds(_ v: Double, unit: String) -> Int? {
        let u = unit.lowercased()
        let multiplier: Double
        if u.hasPrefix("hour") || u.hasPrefix("hr") { multiplier = 3600 }
        else if u.hasPrefix("min") { multiplier = 60 }
        else { multiplier = 1 }

        // Clamp in Double space BEFORE the `Int(...)` cast, which traps above Int.max.
        let seconds = v * multiplier
        guard seconds.isFinite, seconds >= 0, seconds <= maxSeconds else { return nil }
        return Int(seconds)
    }

    private static func normalizeUnit(_ unit: String, count: Int) -> String {
        let u = unit.lowercased()
        if u.hasPrefix("hour") || u.hasPrefix("hr") { return count == 1 ? "hour" : "hours" }
        if u.hasPrefix("min") { return count == 1 ? "minute" : "minutes" }
        return count == 1 ? "second" : "seconds"
    }
}

// MARK: - TimerSubjectExtractor

/// Pulls the food being cooked out of a step instruction ("Grill the chicken for 7 minutes
/// per side" → "chicken") so a finished per-side timer can say "Flip the chicken" instead
/// of a generic "time to flip".
enum TimerSubjectExtractor {
    private static let verbRE = try? NSRegularExpression(
        pattern: #"\b(?:grill|sear|cook|fry|saut[eé]|brown|roast|bake|toast|char|griddle|crisp|broil)\s+(?:the\s+|your\s+|each\s+)?([a-z][a-z'-]*(?:\s+[a-z][a-z'-]*)?)"#,
        options: .caseInsensitive
    )

    /// Words that end (or invalidate) the captured noun phrase — "chicken for 7" must
    /// become "chicken", and "cook it" must yield nothing at all.
    private static let stopWords: Set<String> = [
        "for", "until", "on", "in", "over", "about", "to", "with", "and", "then",
        "at", "per", "each", "side", "sides", "a", "an", "another",
        "minute", "minutes", "min", "mins", "hour", "hours", "second", "seconds",
        "them", "it", "everything", "well", "gently", "thoroughly",
    ]

    static func subject(in instruction: String) -> String? {
        let text = instruction.lowercased()
        let ns = NSRange(text.startIndex..., in: text)
        guard let m = verbRE?.firstMatch(in: text, range: ns),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        var kept: [String] = []
        for word in text[r].split(separator: " ").map(String.init) {
            if stopWords.contains(word) { break }
            kept.append(word)
        }
        guard !kept.isEmpty else { return nil }
        return kept.joined(separator: " ")
    }
}
