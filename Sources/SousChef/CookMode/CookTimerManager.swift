import Foundation
import AudioToolbox

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

    private static let rangeRE = try! NSRegularExpression(
        pattern: #"(\d+(?:\.\d+)?)\s*(?:to|-)\s*(\d+(?:\.\d+)?)\s*(minutes?|mins?|hours?|hrs?|seconds?|secs?)"#,
        options: .caseInsensitive
    )

    private static func detectRange(in text: String) -> (label: String, seconds: Int)? {
        let ns = NSRange(text.startIndex..., in: text)
        guard let m = rangeRE.firstMatch(in: text, range: ns),
              let r1 = Range(m.range(at: 1), in: text),
              let r2 = Range(m.range(at: 2), in: text),
              let r3 = Range(m.range(at: 3), in: text),
              let lo = Double(text[r1]),
              let hi = Double(text[r2]) else { return nil }

        let unit = String(text[r3])
        let mid = (lo + hi) / 2.0
        let secs = toSeconds(mid, unit: unit)
        guard secs >= 10 else { return nil }
        let label = "\(Int(lo))–\(Int(hi)) \(normalizeUnit(unit, count: Int(hi)))"
        return (label, secs)
    }

    // MARK: - Single "5 minutes"

    private static let singleRE = try! NSRegularExpression(
        pattern: #"(\d+(?:\.\d+)?)\s*(minutes?|mins?|hours?|hrs?|seconds?|secs?)"#,
        options: .caseInsensitive
    )

    private static func detectSingle(in text: String) -> (label: String, seconds: Int)? {
        let ns = NSRange(text.startIndex..., in: text)
        guard let m = singleRE.firstMatch(in: text, range: ns),
              let r1 = Range(m.range(at: 1), in: text),
              let r2 = Range(m.range(at: 2), in: text),
              let value = Double(text[r1]) else { return nil }

        let unit = String(text[r2])
        let secs = toSeconds(value, unit: unit)
        guard secs >= 10 else { return nil }
        let label = "\(Int(value)) \(normalizeUnit(unit, count: Int(value)))"
        return (label, secs)
    }

    // MARK: - Helpers

    private static func toSeconds(_ v: Double, unit: String) -> Int {
        let u = unit.lowercased()
        if u.hasPrefix("hour") || u.hasPrefix("hr") { return Int(v * 3600) }
        if u.hasPrefix("min") { return Int(v * 60) }
        return Int(v)
    }

    private static func normalizeUnit(_ unit: String, count: Int) -> String {
        let u = unit.lowercased()
        if u.hasPrefix("hour") || u.hasPrefix("hr") { return count == 1 ? "hour" : "hours" }
        if u.hasPrefix("min") { return count == 1 ? "minute" : "minutes" }
        return count == 1 ? "second" : "seconds"
    }
}

// MARK: - CookTimerState

@MainActor
final class CookTimerState: ObservableObject {
    @Published var isRunning = false
    @Published var secondsRemaining = 0
    @Published var totalSeconds = 0
    @Published var label = ""
    @Published var sideNumber = 1       // 1 or 2 for per-side timers
    @Published var totalSides = 1
    @Published var didComplete = false

    private var ticker: Timer?

    var isConfigured: Bool { totalSeconds > 0 }

    var progressFraction: Double {
        guard totalSeconds > 0 else { return 0 }
        return 1.0 - Double(secondsRemaining) / Double(totalSeconds)
    }

    var formattedTime: String {
        let s = secondsRemaining
        let m = s / 60, sec = s % 60
        return String(format: "%d:%02d", m, sec)
    }

    func configure(from detected: DetectedTimer) {
        stop()
        totalSeconds = detected.seconds
        secondsRemaining = detected.seconds
        label = detected.label
        totalSides = detected.isPerSide ? 2 : 1
        sideNumber = 1
        didComplete = false
    }

    func start() {
        guard !isRunning, secondsRemaining > 0 else { return }
        isRunning = true
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func pause() {
        isRunning = false
        ticker?.invalidate()
        ticker = nil
    }

    func reset() {
        pause()
        secondsRemaining = totalSeconds
        sideNumber = 1
        didComplete = false
    }

    func stop() {
        pause()
        secondsRemaining = 0
        totalSeconds = 0
        sideNumber = 1
        totalSides = 1
        didComplete = false
    }

    private func tick() {
        guard isRunning else { return }
        if secondsRemaining > 0 {
            secondsRemaining -= 1
        }
        if secondsRemaining == 0 && isRunning {
            isRunning = false
            ticker?.invalidate()
            ticker = nil
            didComplete = true
            // Repeating alert: play 3 times with 0.8s gap
            for i in 0..<3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.8) {
                    AudioServicesPlaySystemSound(1005)
                }
            }
            // Per-side: advance to next side
            if sideNumber < totalSides {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self else { return }
                    self.sideNumber += 1
                    self.secondsRemaining = self.totalSeconds
                    self.didComplete = false
                }
            }
        }
    }
}
