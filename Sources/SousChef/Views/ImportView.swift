import SwiftUI

/// SC-033: Full URL import flow.
/// User pastes/enters URL → pipeline runs → ReviewView shows result.
struct ImportView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var phase: ImportPhase = .idle
    @State private var extractionResult: ExtractionResult?
    @State private var errorMessage: String?
    @State private var showReview = false

    enum ImportPhase: Equatable {
        case idle
        case fetching
        case extracting
        case done
        case error
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.scBackground.ignoresSafeArea()
                VStack(spacing: Spacing.lg) {
                    Spacer()
                    headerSection
                    urlInputSection
                    statusSection
                    Spacer()
                    importButton
                }
                .padding(Spacing.md)
            }
            .navigationTitle("Import Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.scBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.scTextSecondary)
                }
            }
            .navigationDestination(isPresented: $showReview) {
                if let result = extractionResult {
                    ReviewView(
                        result: result,
                        onSave: { _ in dismiss() },
                        onRetry: { phase = .idle; extractionResult = nil }
                    )
                }
            }
            .onAppear { pasteFromClipboard() }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: sourceIcon)
                .font(.system(size: 48))
                .foregroundStyle(Color.scAccent)
            Text("Paste a recipe URL")
                .font(.scHeadline)
                .foregroundStyle(Color.scTextPrimary)
            Text("AllRecipes, Food Network, TikTok, YouTube, and more")
                .font(.scCaption)
                .foregroundStyle(Color.scTextSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var urlInputSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Image(systemName: "link")
                    .foregroundStyle(Color.scTextSecondary)
                    .frame(width: 20)
                TextField("https://", text: $urlText)
                    .font(.scBody)
                    .foregroundStyle(Color.scTextPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .disabled(phase == .fetching || phase == .extracting)
                if !urlText.isEmpty && phase == .idle {
                    Button {
                        urlText = ""
                        errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.scTextSecondary)
                    }
                }
            }
            .padding(Spacing.md)
            .background(Color.scSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(urlFieldBorderColor, lineWidth: 1)
            )

            if let error = errorMessage {
                Text(error)
                    .font(.scCaption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, Spacing.xs)
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch phase {
        case .fetching:
            progressRow(label: "Fetching page…", icon: "arrow.down.circle")
        case .extracting:
            progressRow(label: "Extracting recipe…", icon: "wand.and.sparkles")
        case .done:
            HStack(spacing: Spacing.sm) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Recipe found!").font(.scBody).foregroundStyle(Color.scTextPrimary)
            }
        case .idle, .error:
            EmptyView()
        }
    }

    private func progressRow(label: String, icon: String) -> some View {
        HStack(spacing: Spacing.sm) {
            ProgressView().tint(Color.scAccent)
            Image(systemName: icon).foregroundStyle(Color.scAccent)
            Text(label).font(.scBody).foregroundStyle(Color.scTextSecondary)
        }
    }

    private var importButton: some View {
        Button {
            Task { await runImport() }
        } label: {
            Group {
                if phase == .fetching || phase == .extracting {
                    ProgressView().tint(Color.scBackground)
                } else {
                    Label("Extract Recipe", systemImage: "arrow.down.circle.fill")
                }
            }
            .font(.scLabel)
            .frame(maxWidth: .infinity)
            .padding(Spacing.md)
            .background(importButtonBackground)
            .foregroundStyle(Color.scBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!canImport)
    }

    // MARK: - Logic

    private func pasteFromClipboard() {
        guard urlText.isEmpty,
              let clip = UIPasteboard.general.string,
              clip.hasPrefix("http") else { return }
        urlText = clip
    }

    private var canImport: Bool {
        !urlText.trimmingCharacters(in: .whitespaces).isEmpty &&
        phase != .fetching && phase != .extracting
    }

    private var importButtonBackground: Color {
        canImport ? Color.scAccent : Color.scAccent.opacity(0.4)
    }

    private var urlFieldBorderColor: Color {
        switch phase {
        case .error: return Color.red.opacity(0.5)
        case .done:  return Color.green.opacity(0.4)
        default:     return Color.scBorder
        }
    }

    private var sourceIcon: String {
        let cleaned = urlText.lowercased()
        if cleaned.contains("tiktok")     { return "video.fill" }
        if cleaned.contains("youtube") || cleaned.contains("youtu.be") { return "play.rectangle.fill" }
        if cleaned.contains("instagram")  { return "camera.fill" }
        return "safari.fill"
    }

    private func runImport() async {
        let url = urlText.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }

        errorMessage = nil
        phase = .fetching

        let pipeline = ExtractionPipeline()
        do {
            let result = try await pipeline.extract(from: url)
            await MainActor.run {
                if result.isViable {
                    extractionResult = result
                    phase = .done
                    showReview = true
                } else {
                    phase = .error
                    errorMessage = "Couldn't find a recipe at that URL. Try a different link."
                }
            }
        } catch {
            await MainActor.run {
                phase = .error
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Preview

#Preview("Import View") {
    ImportView()
        .preferredColorScheme(.dark)
}
