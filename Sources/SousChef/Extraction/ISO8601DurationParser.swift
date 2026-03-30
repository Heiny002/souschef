import Foundation

/// Parses ISO 8601 duration strings into seconds.
/// Handles: PT45M, PT1H30M, P1DT2H, P0Y0M0DT0H45M0S
enum ISO8601DurationParser {
    static func seconds(from duration: String) -> Int? {
        let s = duration.uppercased().trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("P") else { return nil }

        var total = 0
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
                if let v = Int(current) {
                    total += inTime ? v * 60 : v * 30 * 24 * 3600
                }
                current = ""
            case "W":
                if let v = Int(current) { total += v * 7 * 24 * 3600 }
                current = ""
            case "D":
                if let v = Int(current) { total += v * 24 * 3600 }
                current = ""
            case "H":
                if let v = Int(current) { total += v * 3600 }
                current = ""
            case "S":
                if let v = Int(current) { total += v }
                current = ""
            default:
                if char.isNumber || char == "." {
                    current.append(char)
                }
            }
        }

        return total > 0 ? total : nil
    }
}
