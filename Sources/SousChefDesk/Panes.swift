import SwiftUI

// MARK: - Left: input + progress + trace

struct InputPane: View {
    @ObservedObject var model: DeskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SousChef Desk").font(.title2).bold()
            Text("Runs the app's real extraction pipeline.")
                .font(.caption).foregroundStyle(.secondary)

            TextField("Recipe or post URL…", text: $model.urlString)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.extract() }

            HStack {
                Button(model.isExtracting ? "Extracting…" : "Extract") { model.extract() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isExtracting)
                if model.isExtracting { ProgressView().controlSize(.small) }
            }

            // Environment readiness — the two optional rungs and whether they're armed.
            VStack(alignment: .leading, spacing: 4) {
                Label(model.cookiesPresent ? "Instagram cookies.txt found" : "No cookies.txt (Instagram authed rungs off)",
                      systemImage: model.cookiesPresent ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(model.cookiesPresent ? .green : .orange)
                Label(model.anthropicKeyPresent ? "ANTHROPIC_API_KEY set (LLM rungs on)" : "No ANTHROPIC_API_KEY (deterministic only)",
                      systemImage: model.anthropicKeyPresent ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(model.anthropicKeyPresent ? .green : .orange)
            }
            .font(.caption)

            if let error = model.errorText {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Divider()
            Text("Progress").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.progressLines.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.caption.monospaced()).id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.progressLines.count) {
                    proxy.scrollTo(model.progressLines.count - 1, anchor: .bottom)
                }
            }

            if let debug = model.result?.debugInfo {
                Divider()
                Text("Debug trace").font(.headline)
                ScrollView {
                    Text(debug)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding()
    }
}

// MARK: - Center: review mirror

struct ReviewPane: View {
    @ObservedObject var model: DeskModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Review").font(.title3).bold()
                if let r = model.result {
                    reviewBody(r)
                } else {
                    Text("Extract a recipe to review it here.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    @ViewBuilder
    private func reviewBody(_ r: ExtractionResult) -> some View {
        if r.isSubstitute {
            banner("Similar recipe — not the creator's own post.", color: .blue)
        }
        if r.wasTruncated {
            banner("Caption may be cut off — some steps could be missing.", color: .orange)
        }
        if r.isCollection {
            banner("Collection: \(1 + r.alternatives.count) recipes found. Showing the first; "
                   + "also: \(r.alternatives.compactMap(\.title).joined(separator: " · "))",
                   color: .purple)
        }

        Text(r.title ?? "(no title)").font(.title2).bold()
        Text("\(r.extractionMethod) · \(Int(r.confidence * 100))% confidence")
            .font(.caption).foregroundStyle(.secondary)

        HStack(spacing: 14) {
            if let yield = r.recipeYield { Label(yield, systemImage: "person.2") }
            if let prep = r.prepTime { Label("prep \(prep / 60)m", systemImage: "clock") }
            if let cook = r.cookTime { Label("cook \(cook / 60)m", systemImage: "flame") }
        }
        .font(.caption)

        if !r.equipment.isEmpty {
            Text("Equipment: " + r.equipment.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
        }

        Divider()
        Text("Ingredients (\(r.ingredients.count))").font(.headline)
        let groups = ingredientGroups(r)
        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
            if let name = group.0 {
                Text(name).font(.subheadline).bold().padding(.top, 4)
            }
            ForEach(Array(group.1.enumerated()), id: \.offset) { _, ing in
                Text("•  " + ing.text).textSelection(.enabled)
            }
        }

        Divider()
        Text("Steps (\(r.steps.count))").font(.headline)
        ForEach(Array(r.steps.enumerated()), id: \.offset) { idx, step in
            if sectionChanged(r, at: idx), let s = step.section {
                Text(s).font(.subheadline).bold().padding(.top, 4)
            }
            HStack(alignment: .top, spacing: 6) {
                Text("\(step.order).").bold().frame(width: 26, alignment: .trailing)
                Text(step.text).textSelection(.enabled)
            }
        }
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Ingredients grouped by section, sections in first-appearance order.
    private func ingredientGroups(_ r: ExtractionResult) -> [(String?, [RawIngredient])] {
        var order: [String?] = []
        var byKey: [String?: [RawIngredient]] = [:]
        for ing in r.ingredients {
            let key = (ing.section?.isEmpty == false) ? ing.section : nil
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(ing)
        }
        return order.map { ($0, byKey[$0] ?? []) }
    }

    private func sectionChanged(_ r: ExtractionResult, at idx: Int) -> Bool {
        guard let s = r.steps[idx].section, !s.isEmpty else { return false }
        return idx == 0 || r.steps[idx - 1].section != s
    }
}

// MARK: - Right: cook-mode mirror

struct CookPane: View {
    @ObservedObject var model: DeskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cook Mode").font(.title3).bold()

            if model.steps.isEmpty {
                Text("Steps appear here after extraction.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                // Part pills — jump between components, mirroring the app's tabs.
                if model.parts.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(model.parts, id: \.self) { part in
                                Button(part) { model.jump(toPart: part) }
                                    .buttonStyle(.bordered)
                                    .tint(currentPart == part ? .accentColor : .secondary)
                            }
                        }
                    }
                }

                let step = model.steps[model.stepIndex]
                if let section = step.section, !section.isEmpty {
                    Text(section).font(.headline).foregroundStyle(.secondary)
                }

                ScrollView {
                    Text(step.text)
                        .font(.title3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                Spacer()
                HStack {
                    Button("Previous") { model.stepIndex = max(0, model.stepIndex - 1) }
                        .disabled(model.stepIndex == 0)
                    Spacer()
                    Text("Step \(model.stepIndex + 1) of \(model.steps.count)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Next") { model.stepIndex = min(model.steps.count - 1, model.stepIndex + 1) }
                        .disabled(model.stepIndex >= model.steps.count - 1)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                }
            }
        }
        .padding()
    }

    private var currentPart: String? {
        model.steps.indices.contains(model.stepIndex) ? model.steps[model.stepIndex].section : nil
    }
}
