import Foundation

/// Orders the components of a multi-part recipe so the longest-cooking part starts first.
///
/// A recipe like the steak wraps has four parts — flatbread (18–20 min), steak (10 min),
/// yogurt spread, onion salad. Cooked in caption order the flatbread starts last and
/// everything else goes cold waiting for it. Leading with the longest component means the
/// slow thing is underway while the quick things get made.
///
/// The reorder is deliberately conservative: it only fires when the difference is big enough
/// to matter. If the longest and the next-longest are within `tieThreshold`, the author's
/// original order is kept — a two-minute edge isn't worth overriding the human's sequencing.
enum ComponentSequencer {

    /// Cook-time differences at or below this are treated as a tie (seconds).
    static let tieThreshold = 4 * 60

    /// A recipe component: its heading, the steps under it, and the TOTAL hands-off time it
    /// needs — every duration in its steps summed, so dough that rests 30 min and then bakes
    /// 20 outranks a steak that sears for 10.
    struct Component: Equatable {
        let name: String?
        var steps: [String]
        var cookSeconds: Int
    }

    /// Group ordered (step, section) pairs into components, preserving first-appearance order.
    /// Steps with no section collapse into one leading unnamed component.
    static func components(from steps: [(text: String, section: String?)]) -> [Component] {
        var ordered: [Component] = []
        for step in steps {
            let key = step.section?.trimmingCharacters(in: .whitespaces)
            let name = (key?.isEmpty ?? true) ? nil : key
            if let idx = ordered.firstIndex(where: { $0.name == name }) {
                ordered[idx].steps.append(step.text)
                // Sum, not max: a component's real cost is prep + rest + cook combined.
                ordered[idx].cookSeconds += cookTime(of: step.text)
            } else {
                ordered.append(Component(name: name, steps: [step.text], cookSeconds: cookTime(of: step.text)))
            }
        }
        return ordered
    }

    /// Reorder so the longest-cooking component leads — unless the margin over the
    /// runner-up is within the tie threshold, in which case the original order stands.
    ///
    /// Only the slowest component is promoted; the rest keep their authored order. Moving
    /// every component by duration would scramble a sequence the author may have written
    /// for dependency reasons ("make the sauce, then toss the pasta in it").
    static func reorder(_ components: [Component]) -> [Component] {
        // Reordering is only meaningful across named parts. Unnamed steps are shared prep
        // ("preheat the oven"), so they stay pinned where they are rather than blocking the
        // reorder — previously any unnamed step disabled sequencing entirely.
        let namedIndices = components.indices.filter { components[$0].name != nil }
        guard namedIndices.count >= 2 else { return components }

        let times = namedIndices.map { components[$0].cookSeconds }.sorted(by: >)
        guard let longest = times.first, longest > 0 else { return components }
        let runnerUp = times.count > 1 ? times[1] : 0
        guard longest - runnerUp > tieThreshold else { return components }

        // The slowest named component moves to the position of the FIRST named component,
        // so it leads the parts without jumping ahead of shared prep that precedes them all.
        guard let slowestIdx = namedIndices.first(where: { components[$0].cookSeconds == longest }),
              let firstNamedIdx = namedIndices.first,
              slowestIdx != firstNamedIdx else { return components }

        var result = components
        let slowest = result.remove(at: slowestIdx)
        result.insert(slowest, at: firstNamedIdx)
        return result
    }

    /// Convenience: group, reorder, and flatten back to (step, section) pairs.
    static func sequence(_ steps: [(text: String, section: String?)]) -> [(text: String, section: String?)] {
        reorder(components(from: steps)).flatMap { component in
            component.steps.map { (text: $0, section: component.name) }
        }
    }

    // MARK: - Cook time

    /// The longest duration mentioned in a step, in seconds. Ranges ("18-20 minutes") take the
    /// upper bound — the component isn't finished until the slowest case is done.
    static func cookTime(of instruction: String) -> Int {
        var longest = 0
        let pattern = #"(\d+)\s*(?:[-–—]|\s+to\s+)?\s*(\d+)?\s*(hour|hr|minute|min|second|sec)s?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return 0 }
        let range = NSRange(instruction.startIndex..., in: instruction)
        for match in regex.matches(in: instruction, range: range) {
            guard let unitRange = Range(match.range(at: 3), in: instruction) else { continue }
            let unit = instruction[unitRange].lowercased()
            let multiplier: Int
            if unit.hasPrefix("h") { multiplier = 3600 }
            else if unit.hasPrefix("m") { multiplier = 60 }
            else { multiplier = 1 }

            // Upper bound of a range when present, else the single value.
            var value = 0
            if let hiRange = Range(match.range(at: 2), in: instruction), let hi = Int(instruction[hiRange]) {
                value = hi
            } else if let loRange = Range(match.range(at: 1), in: instruction), let lo = Int(instruction[loRange]) {
                value = lo
            }
            longest = max(longest, value * multiplier)
        }
        return longest
    }
}
