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

/// One cook-mode step as the phone would show it: micro-split, sequenced, quantity-annotated,
/// with any detected timer attached.
struct DeskStep {
    let text: String
    let section: String?
    let timer: DetectedTimer?
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
    @Published var cookSteps: [DeskStep] = []

    var cookiesPresent: Bool {
        let path = ProcessInfo.processInfo.environment["SOUSCHEF_COOKIES"] ?? "cookies.txt"
        return FileManager.default.fileExists(atPath: path)
    }

    /// Same resolution the pipeline itself uses (Info.plist → env → Secrets.xcconfig), so
    /// this label can never disagree with what the extraction actually does.
    var anthropicKeyPresent: Bool {
        ExtractionPipeline.anthropicAPIKey != nil
    }

    /// "branch @ shortsha", read from the checkout at launch — so it's always obvious which
    /// build is running (the recurring failure mode is an aborted pull leaving old code).
    /// "+ local changes" is the tell for exactly that: a dirty tree that will block a pull.
    let buildStamp: String = DeskModel.gitStamp()

    private static func gitStamp() -> String {
        func git(_ args: [String]) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git"] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return nil }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty ?? true) ? nil : text
        }
        guard let sha = git(["rev-parse", "--short", "HEAD"]) else { return "version unknown" }
        let branch = git(["rev-parse", "--abbrev-ref", "HEAD"]) ?? "?"
        // Empty porcelain output maps to nil above, so non-nil means the tree is dirty.
        let dirty = git(["status", "--porcelain"]) != nil ? " + local changes" : ""
        return "\(branch) @ \(sha)\(dirty)"
    }

    func extract() {
        let url = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !isExtracting else { return }
        isExtracting = true
        progressLines = ["Starting…"]
        result = nil
        errorText = nil
        stepIndex = 0
        cookSteps = []

        Task {
            do {
                let r = try await ExtractionPipeline().extract(from: url) { [weak self] line in
                    Task { @MainActor in self?.progressLines.append(line) }
                }
                self.result = r
                self.cookSteps = Self.buildCookSteps(from: r)
                self.progressLines.append("Done — \(r.ingredients.count) ingredients, \(r.steps.count) steps.")
            } catch {
                self.errorText = error.localizedDescription
            }
            self.isExtracting = false
        }
    }

    /// Steps of the current result; the cook pane navigates these.
    var steps: [DeskStep] { cookSteps }

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

    // MARK: - Cook-step construction (mirrors CookModeView.buildMicroSteps exactly)

    /// The phone's Cook Mode chain, run on an extraction result: micro-step split (bulleted
    /// lists stay whole), per-component sequencing, first-mention quantity annotation via
    /// the app's IngredientAnnotator, then timer detection — so the right pane shows the
    /// steps precisely as the phone would cook them.
    private static func buildCookSteps(from result: ExtractionResult) -> [DeskStep] {
        let sorted = result.steps.sorted { $0.order < $1.order }

        var pieces: [(text: String, section: String?)] = []
        for step in sorted {
            let parts = step.text.contains("\n• ")
                ? [step.text]
                : MicroStepSplitter.split(step.text)
            pieces.append(contentsOf: parts.map { (text: $0, section: step.section) })
        }

        var sequenced: [(text: String, section: String?)] = []
        for group in groupedByRun(pieces) {
            let reordered = StepSequencer.reorder(group.map(\.text))
            sequenced.append(contentsOf: reordered.map { (text: $0, section: group.first?.section ?? nil) })
        }

        // Same raw-text → parsed → Ingredient mapping the app's save flow performs. The
        // model objects live only in memory here — never inserted into a SwiftData store.
        let parser = IngredientParser()
        let parsed = result.ingredients.map { parser.parse(raw: $0.text, section: $0.section) }
        let ingredients = parsed.enumerated().map { idx, p in
            let ing = Ingredient(item: p.item, rawText: p.rawText, order: idx)
            ing.quantity = p.quantity
            ing.unit = p.unit
            ing.preparation = p.preparation
            ing.section = p.section
            return ing
        }
        let annotated = IngredientAnnotator.annotate(sequenced.map(\.text), with: ingredients)

        return annotated.enumerated().map { idx, text in
            DeskStep(text: text,
                     section: idx < sequenced.count ? sequenced[idx].section : nil,
                     timer: TimerDetector.detect(in: text))
        }
    }

    /// Split a step list into consecutive runs that share the same component, so sequencing
    /// never moves a step across a component boundary. (Mirror of CookModeView.groupedByRun.)
    private static func groupedByRun(_ pieces: [(text: String, section: String?)]) -> [[(text: String, section: String?)]] {
        var runs: [[(text: String, section: String?)]] = []
        for piece in pieces {
            if var last = runs.last, last.first?.section == piece.section {
                last.append(piece)
                runs[runs.count - 1] = last
            } else {
                runs.append([piece])
            }
        }
        return runs
    }
}
