import Foundation

/// Reads API keys straight out of a local `Secrets.xcconfig` — the macOS harness's third
/// and final key source.
///
/// The app gets its keys via Secrets.xcconfig → build settings → Info.plist, but `swift run`
/// has no build-setting injection, so the harness reads the very same file directly. That
/// removes the `export ANTHROPIC_API_KEY=…` step entirely (an export only lives in the one
/// terminal session it was typed in, which made "no key" the default failure mode).
///
/// Path: `SOUSCHEF_SECRETS` env var, else `Secrets.xcconfig` in the working directory —
/// which is the repo root under `swift run`. The file is gitignored; nothing here logs or
/// exposes the values. On iOS this compiles to a stub that always returns nil.
enum XcconfigSecrets {

    /// The value for `key` in the xcconfig, or nil when the file or key is absent/empty.
    static func value(forKey key: String) -> String? {
        #if os(macOS)
        let path = ProcessInfo.processInfo.environment["SOUSCHEF_SECRETS"] ?? "Secrets.xcconfig"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//"), let eq = line.firstIndex(of: "=") else { continue }
            let name = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard name == key else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // xcconfig line comments: "KEY = value // note"
            if let comment = value.range(of: "//") {
                value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            return value.isEmpty ? nil : value
        }
        return nil
        #else
        _ = key
        return nil
        #endif
    }
}
