import Foundation

/// Reorders cooking steps so hands-off downtime (marinating, chilling, resting,
/// proofing) overlaps with an oven preheat that would otherwise sit idle before it.
///
/// Many recipes list "preheat the oven" *before* a passive wait like "marinate for
/// 10–15 minutes". Followed literally that wastes time: you heat the oven, then wait
/// again while the food marinates. Starting the preheat at the *beginning* of the
/// downtime window lets the oven come to temperature during the wait.
///
/// The transform is deliberately conservative — it moves a single preheat step to
/// the start of the first qualifying downtime window and does nothing otherwise.
/// Pure function, no side effects, so it is trivially unit-testable.
enum StepSequencer {

    /// Returns `steps` reordered so a pending oven preheat runs during hands-off
    /// downtime. Returns the input unchanged when there is nothing to gain.
    static func reorder(_ steps: [String]) -> [String] {
        guard steps.count >= 3 else { return steps }

        // First hands-off downtime step with a meaningful duration (the marinade/chill/rest).
        guard let waitIdx = steps.firstIndex(where: isPassiveDowntime) else { return steps }

        // The oven must actually be used *after* the downtime, otherwise there is nothing
        // to preheat for — this excludes a trailing "let rest before serving" step from
        // dragging the preheat down past the bake.
        guard steps[(waitIdx + 1)...].contains(where: isOvenUse) else { return steps }

        // A preheat that currently precedes the downtime — i.e. two idle periods in a row.
        guard let preheatIdx = steps.firstIndex(where: isPreheat), preheatIdx < waitIdx else {
            return steps
        }

        // If ANY step between the preheat and the wait uses the oven (par-bake, toast,
        // "bake the crust"), the preheat must stay where it is — moving it would put that
        // intermediate bake in a cold oven, exactly the hazard this module exists to
        // avoid (H11).
        if steps[(preheatIdx + 1)..<waitIdx].contains(where: isOvenUse) {
            return steps
        }

        // Already immediately before the wait → oven and downtime already overlap.
        if preheatIdx == waitIdx - 1 { return steps }

        var result = steps
        let preheat = result.remove(at: preheatIdx)
        // Removing an earlier element shifts the wait step left by one; insert
        // immediately before it so the preheat kicks off as the downtime begins.
        result.insert(preheat, at: waitIdx - 1)
        return result
    }

    // MARK: - Classification

    /// Hands-off waiting where the cook does nothing but let time pass.
    /// Must carry a real duration (≥ 5 min) so a preheat can usefully overlap it, and be
    /// short enough (≤ 1 h) that running the oven through it makes sense — an overnight
    /// marinade must NOT pull the preheat to its start and leave the oven on for hours
    /// (audit medium).
    static func isPassiveDowntime(_ step: String) -> Bool {
        let t = step.lowercased()
        guard passiveKeywords.contains(where: { t.contains($0) }) else { return false }
        guard let timer = TimerDetector.detect(in: step),
              timer.seconds >= 300, timer.seconds <= 3600 else { return false }
        return true
    }

    /// Starting the oven (or broiler) with no active work to do meanwhile.
    static func isPreheat(_ step: String) -> Bool {
        let t = step.lowercased()
        let mentionsPreheat = t.contains("preheat") || t.contains("pre-heat")
        let mentionsHeatOven = t.contains("heat") && t.contains("oven")
        guard mentionsPreheat || mentionsHeatOven else { return false }

        // Must actually concern the oven/broiler, or name a temperature (which implies it).
        let mentionsAppliance = t.contains("oven") || t.contains("broiler")
        let mentionsTemp = t.range(
            of: #"\d{2,3}\s*(?:°|degrees|deg\b|℉|℃)|\bgas mark\b"#,
            options: .regularExpression
        ) != nil
        return mentionsAppliance || mentionsTemp
    }

    /// A step that actually cooks in the oven — what the preheat is for.
    static func isOvenUse(_ step: String) -> Bool {
        let t = step.lowercased()
        return t.contains("bake") || t.contains("roast") || t.contains("broil")
            || t.contains("toast") || t.contains("in the oven") || t.contains("into the oven")
    }

    // Substrings, not whole words, so they catch inflections:
    // "marinat" → marinate / marinating / marinade; "refrigerat" → refrigerate/-ing.
    // Rest/rise are phrase-qualified to avoid matching "add the rest of…" etc.
    private static let passiveKeywords: [String] = [
        "marinat",
        "chill", "refrigerat", "in the fridge",
        "soak", "brine", "proof",
        "let it rest", "let rest", "rest for", "resting",
        "let sit", "let stand", "set aside",
        "let rise", "to rise", "rising", "let the dough",
    ]
}
