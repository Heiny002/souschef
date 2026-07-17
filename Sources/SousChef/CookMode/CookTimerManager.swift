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

// MARK: - CookTimerState

/// Cook Mode countdown, anchored to the wall clock (C4).
///
/// Two guarantees the old decrement-a-counter version couldn't make:
/// 1. Locking the phone / backgrounding never loses time — remaining time is recomputed
///    from a stored `endDate` on every tick and on `reconcile()` (called when the scene
///    becomes active again), so the countdown is correct the instant the app returns.
/// 2. Expiry alerts through a locked screen — starting the timer schedules a time-sensitive
///    local notification for the expiry moment; pausing/stopping cancels it. In the
///    foreground iOS suppresses that notification, and the in-app sound + haptic fire
///    instead, so the user hears exactly one alert either way.
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
    /// Wall-clock moment the running timer expires. nil when not running.
    private var endDate: Date?
    /// Pending per-side rollover, cancellable so a timer configured in the 1.5s gap
    /// isn't clobbered by a stale closure (audit medium: delayed reset never cancelled).
    private var pendingSideAdvance: DispatchWorkItem?

    private static let notificationID = "cook-timer-expiry"
    /// Test hook: suppresses notification scheduling (and its permission prompt) in CI.
    nonisolated(unsafe) static var notificationsSuppressed = false

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

    func start(now: Date = Date()) {
        guard !isRunning, secondsRemaining > 0 else { return }
        isRunning = true
        endDate = now.addingTimeInterval(TimeInterval(secondsRemaining))
        scheduleExpiryNotification()
        ticker?.invalidate()
        // Half-second cadence so the displayed value tracks the wall clock closely
        // even when timer coalescing delays a tick.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
    }

    func pause(now: Date = Date()) {
        if isRunning, let endDate {
            secondsRemaining = max(0, Int(endDate.timeIntervalSince(now).rounded(.up)))
        }
        isRunning = false
        endDate = nil
        ticker?.invalidate()
        ticker = nil
        cancelExpiryNotification()
    }

    func reset() {
        pendingSideAdvance?.cancel()
        pendingSideAdvance = nil
        pause()
        secondsRemaining = totalSeconds
        sideNumber = 1
        didComplete = false
    }

    func stop() {
        pendingSideAdvance?.cancel()
        pendingSideAdvance = nil
        pause()
        secondsRemaining = 0
        totalSeconds = 0
        sideNumber = 1
        totalSides = 1
        didComplete = false
    }

    /// Recompute remaining time from the wall clock. Called on every ticker fire and by
    /// CookModeView when the scene becomes active, so time spent locked/suspended is
    /// always accounted for.
    func reconcile(now: Date = Date()) {
        guard isRunning, let endDate else { return }
        let remaining = Int(endDate.timeIntervalSince(now).rounded(.up))
        secondsRemaining = max(0, remaining)
        if remaining <= 0 { complete() }
    }

    // MARK: - Completion

    private func complete() {
        isRunning = false
        endDate = nil
        ticker?.invalidate()
        ticker = nil
        didComplete = true

        // Foreground alert: system sound ×3 + a haptic. The scheduled local notification
        // covers the locked/background case (iOS suppresses it while foregrounded).
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.8) {
                AudioServicesPlaySystemSound(1005)
            }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        // Per-side: roll to the next side after a beat, via a cancellable work item so
        // stop()/configure() in the gap can't be clobbered by this stale closure.
        if sideNumber < totalSides {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.sideNumber += 1
                self.secondsRemaining = self.totalSeconds
                self.didComplete = false
            }
            pendingSideAdvance = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    // MARK: - Expiry notification

    private func scheduleExpiryNotification() {
        guard !Self.notificationsSuppressed else { return }
        let timerLabel = label
        Task { [weak self] in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            // Re-read the deadline after the (possibly slow) permission prompt so the
            // notification still fires at the true expiry moment.
            guard let self, self.isRunning, let end = self.endDate else { return }
            let interval = end.timeIntervalSinceNow
            guard interval > 1 else { return }

            let content = UNMutableNotificationContent()
            content.title = "Timer finished"
            content.body = timerLabel.isEmpty ? "Your cook timer is done." : "Your \(timerLabel) timer is done."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            try? await center.add(UNNotificationRequest(
                identifier: Self.notificationID, content: content, trigger: trigger
            ))
        }
    }

    private func cancelExpiryNotification() {
        guard !Self.notificationsSuppressed else { return }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }
}
