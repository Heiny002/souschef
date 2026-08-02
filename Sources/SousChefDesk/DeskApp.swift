import SwiftUI
import AppKit

/// SousChefDesk: the app's real extraction pipeline in a three-pane macOS window —
/// input on the left, the extracted recipe (review mirror) in the center, and a
/// cook-mode-style step display on the right.
@main
struct DeskApp: App {
    @StateObject private var model = DeskModel()

    var body: some Scene {
        WindowGroup("SousChef Desk") {
            HStack(spacing: 0) {
                InputPane(model: model)
                    .frame(width: 340)
                Divider()
                ReviewPane(model: model)
                    .frame(minWidth: 400)
                Divider()
                CookPane(model: model)
                    .frame(minWidth: 380)
            }
            .frame(minWidth: 1180, minHeight: 720)
            .onAppear {
                // `swift run` launches without a bundle; claim a regular-app presence so the
                // window comes to the front instead of hiding behind the terminal.
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

/// State + the single action: run the REAL ExtractionPipeline on a URL.
@MainActor
final class DeskModel: ObservableObject {
    @Published var urlString = ""
    @Published var isExtracting = false
    @Published var progressLines: [String] = []
    @Published var result: ExtractionResult?
    @Published var errorText: String?
    @Published var stepIndex = 0

    var cookiesPresent: Bool {
        let path = ProcessInfo.processInfo.environment["SOUSCHEF_COOKIES"] ?? "cookies.txt"
        return FileManager.default.fileExists(atPath: path)
    }

    var anthropicKeyPresent: Bool {
        !(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "").isEmpty
    }

    func extract() {
        let url = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !isExtracting else { return }
        isExtracting = true
        progressLines = ["Starting…"]
        result = nil
        errorText = nil
        stepIndex = 0

        Task {
            do {
                let r = try await ExtractionPipeline().extract(from: url) { [weak self] line in
                    Task { @MainActor in self?.progressLines.append(line) }
                }
                self.result = r
                self.progressLines.append("Done — \(r.ingredients.count) ingredients, \(r.steps.count) steps.")
            } catch {
                self.errorText = error.localizedDescription
            }
            self.isExtracting = false
        }
    }

    /// Steps of the current result; the cook pane navigates these.
    var steps: [RawStep] { result?.steps ?? [] }

    /// Unique step sections in first-appearance order — the cook pane's part pills.
    var parts: [String] {
        var seen: [String] = []
        for step in steps {
            if let s = step.section, !s.isEmpty, !seen.contains(s) { seen.append(s) }
        }
        return seen
    }

    func jump(toPart part: String) {
        if let idx = steps.firstIndex(where: { $0.section == part }) { stepIndex = idx }
    }
}
