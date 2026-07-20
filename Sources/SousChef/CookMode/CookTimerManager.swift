import Foundation
import AudioToolbox
import UserNotifications
import UIKit

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

// MARK: - CookTimer

/// One countdown in the Cook Mode timer stack. A value type — all mutation goes through
/// CookTimerStack so a single ObservableObject publishes every change.
struct CookTimer: Identifiable, Equatable {
    let id: UUID
    let label: String
    let totalSeconds: Int
    /// Micro-step this timer came from — powers tap-to-show-step and completion guidance.
    let stepIndex: Int
    let stepInstruction: String

    var secondsRemaining: Int
    var sideNumber: Int         // 1 or 2 for per-side timers
    var totalSides: Int
    var isRunning: Bool
    var didComplete: Bool
    /// Wall-clock moment this timer expires. nil when not running.
    var endDate: Date?

    var isPerSide: Bool { totalSides > 1 }
    var hasSidesLeft: Bool { sideNumber < totalSides }

    var progressFraction: Double {
        guard totalSeconds > 0 else { return 0 }
        return 1.0 - Double(secondsRemaining) / Double(totalSeconds)
    }

    var formattedTime: String {
        let m = secondsRemaining / 60, s = secondsRemaining % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - CookTimerStack

/// Cook Mode countdowns, anchored to the wall clock (C4) and stackable — the step-4 simmer
/// keeps running while step 5 starts its own sear timer.
///
/// Guarantees carried over from the single-timer version:
/// 1. Locking the phone / backgrounding never loses time — remaining time is recomputed
///    from each timer's stored `endDate` on every tick and on `reconcile()` (called when
///    the scene becomes active again).
/// 2. Expiry alerts through a locked screen — every started timer schedules its own
///    time-sensitive local notification (unique per-timer identifier); pausing/removing
///    cancels just that one. In the foreground iOS suppresses the notification and the
///    in-app sound + haptic fire instead.
///
/// Per-side timers never auto-advance: side 1 completing surfaces "flip" guidance via
/// `justCompleted`, and side 2 starts only when the user acts (startNextSide).
@MainActor
final class CookTimerStack: ObservableObject {
    @Published private(set) var timers: [CookTimer] = []
    /// Snapshot of the most recently completed timer, driving the "what to do next"
    /// overlay. Cleared by the view (dismiss) or by acting on the completion.
    @Published var justCompleted: CookTimer?

    private var ticker: Timer?

    /// Test hook: suppresses notification scheduling (and its permission prompt) in CI.
    nonisolated(unsafe) static var notificationsSuppressed = false

    var runningTimers: [CookTimer] { timers.filter(\.isRunning) }
    var hasTimers: Bool { !timers.isEmpty }

    func timer(id: UUID) -> CookTimer? { timers.first { $0.id == id } }
    func timer(forStep index: Int) -> CookTimer? { timers.first { $0.stepIndex == index } }

    // MARK: - Lifecycle

    @discardableResult
    func add(_ detected: DetectedTimer, stepIndex: Int, stepInstruction: String,
             now: Date = Date()) -> UUID {
        let t = CookTimer(
            id: UUID(),
            label: detected.label,
            totalSeconds: detected.seconds,
            stepIndex: stepIndex,
            stepInstruction: stepInstruction,
            secondsRemaining: detected.seconds,
            sideNumber: 1,
            totalSides: detected.isPerSide ? 2 : 1,
            isRunning: false,
            didComplete: false,
            endDate: nil
        )
        timers.append(t)
        start(id: t.id, now: now)
        return t.id
    }

    func start(id: UUID, now: Date = Date()) {
        guard let i = index(of: id), !timers[i].isRunning, timers[i].secondsRemaining > 0
        else { return }
        timers[i].isRunning = true
        timers[i].didComplete = false
        timers[i].endDate = now.addingTimeInterval(TimeInterval(timers[i].secondsRemaining))
        scheduleExpiryNotification(for: timers[i])
        ensureTicker()
    }

    func pause(id: UUID, now: Date = Date()) {
        guard let i = index(of: id) else { return }
        if timers[i].isRunning, let end = timers[i].endDate {
            timers[i].secondsRemaining = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
        }
        timers[i].isRunning = false
        timers[i].endDate = nil
        cancelExpiryNotification(id: id)
        stopTickerIfIdle()
    }

    func reset(id: UUID) {
        guard let i = index(of: id) else { return }
        pause(id: id)
        timers[i].secondsRemaining = timers[i].totalSeconds
        timers[i].sideNumber = 1
        timers[i].didComplete = false
        if justCompleted?.id == id { justCompleted = nil }
    }

    func remove(id: UUID) {
        pause(id: id)
        timers.removeAll { $0.id == id }
        if justCompleted?.id == id { justCompleted = nil }
    }

    /// Roll a completed per-side timer to its next side and start it. Driven by the
    /// completion overlay's "Start side 2" button — flipping is a user action, never
    /// automatic (the old auto-rollover raced with stop/reconfigure; see audit medium).
    func startNextSide(id: UUID, now: Date = Date()) {
        guard let i = index(of: id), timers[i].hasSidesLeft else { return }
        timers[i].sideNumber += 1
        timers[i].secondsRemaining = timers[i].totalSeconds
        timers[i].didComplete = false
        if justCompleted?.id == id { justCompleted = nil }
        start(id: id, now: now)
    }

    func stopAll() {
        for t in timers { cancelExpiryNotification(id: t.id) }
        timers.removeAll()
        justCompleted = nil
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: - Reconcile

    /// Recompute every running timer's remaining time from the wall clock. Called on
    /// every ticker fire and by CookModeView when the scene becomes active, so time
    /// spent locked/suspended is always accounted for.
    func reconcile(now: Date = Date()) {
        for i in timers.indices {
            guard timers[i].isRunning, let end = timers[i].endDate else { continue }
            let remaining = Int(end.timeIntervalSince(now).rounded(.up))
            timers[i].secondsRemaining = max(0, remaining)
            if remaining <= 0 { complete(at: i) }
        }
        stopTickerIfIdle()
    }

    private func complete(at i: Int) {
        timers[i].isRunning = false
        timers[i].endDate = nil
        timers[i].secondsRemaining = 0
        timers[i].didComplete = true
        justCompleted = timers[i]

        // Foreground alert: system sound ×3 + a haptic. The scheduled local notification
        // covers the locked/background case (iOS suppresses it while foregrounded).
        for n in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(n) * 0.8) {
                AudioServicesPlaySystemSound(1005)
            }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - Ticker

    private func ensureTicker() {
        guard ticker == nil else { return }
        // Half-second cadence so the displayed value tracks the wall clock closely
        // even when timer coalescing delays a tick.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
    }

    private func stopTickerIfIdle() {
        guard runningTimers.isEmpty else { return }
        ticker?.invalidate()
        ticker = nil
    }

    private func index(of id: UUID) -> Int? {
        timers.firstIndex { $0.id == id }
    }

    // MARK: - Expiry notifications (one per timer)

    private static func notificationID(for id: UUID) -> String {
        "cook-timer-expiry-\(id.uuidString)"
    }

    private func scheduleExpiryNotification(for timer: CookTimer) {
        guard !Self.notificationsSuppressed else { return }
        let timerID = timer.id
        let timerLabel = timer.label
        Task { [weak self] in
            let center = UNUserNotificationCenter.current()
            // No-ops (without UI) when permission was already decided; prompts only the
            // first time. Avoids fetching UNNotificationSettings, which is non-Sendable
            // under Swift 6 strict concurrency.
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            // Re-read the deadline after the (possibly slow) permission prompt so the
            // notification still fires at the true expiry moment — and only if this
            // specific timer is still running.
            guard let self, let current = self.timer(id: timerID),
                  current.isRunning, let end = current.endDate else { return }
            let interval = end.timeIntervalSinceNow
            guard interval > 1 else { return }

            let content = UNMutableNotificationContent()
            content.title = "Timer finished"
            content.body = timerLabel.isEmpty
                ? "Your cook timer is done."
                : "Your \(timerLabel) timer is done."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            try? await center.add(UNNotificationRequest(
                identifier: Self.notificationID(for: timerID), content: content, trigger: trigger
            ))
        }
    }

    private func cancelExpiryNotification(id: UUID) {
        guard !Self.notificationsSuppressed else { return }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.notificationID(for: id)])
    }
}
