import SwiftUI

/// SC-033: Full URL import flow.
/// User pastes/enters URL → pipeline runs → ReviewView shows result.
struct ImportView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var clipboardHasURL = false
    @State private var phase: ImportPhase = .idle
    @State private var extractionResult: ExtractionResult?
    @State private var errorMessage: String?
    @State private var showReview = false
    @State private var statusText = ""  // SC-075: dynamic progress from bio link resolution
    @State private var showSimilarSheet = false
    @State private var directLinkText = ""  // user-pasted direct recipe URL on failure

    enum ImportPhase: Equatable {
        case idle
        case fetching
        case extracting
        case done
        case error
        case extractionFailed  // extraction ran but found nothing; alternatives may exist
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.scBackground.ignoresSafeArea()
                VStack(spacing: Spacing.lg) {
                    // .symbolRenderingMode(.monochrome) prevents CoreUI from building
                    // animated multi-layer keyframe paths for symbols like wand.and.sparkles
                    // and sparkle.magnifyingglass, which crash RBSymbolAnimator during
                    // sheet presentation layout (ClipStrokeKeyframes mergingRawIndexedKeyframes).
                    Spacer()
                    if phase == .extractionFailed {
                        extractionFailedSection
                    } else {
                        headerSection
                        urlInputSection
                        statusSection
                    }
                    Spacer()
                    if phase == .extractionFailed {
                        failureActionButtons
                    } else {
                        importButton
                    }
                }
                .padding(Spacing.md)
                .symbolRenderingMode(.monochrome)
            }
            .navigationTitle("Import Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.scBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .extractionFailed ? "Done" : "Cancel") { dismiss() }
                        .foregroundStyle(Color.scTextSecondary)
                }
                if phase == .extractionFailed {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Try Again") {
                            phase = .idle
                            extractionResult = nil
                            directLinkText = ""
                        }
                        .foregroundStyle(Color.scAccent)
                    }
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
            .sheet(isPresented: $showSimilarSheet) {
                if let result = extractionResult, !result.alternatives.isEmpty {
                    SimilarRecipePreviewSheet(
                        alternatives: result.alternatives,
                        onAccept: { chosen in
                            showSimilarSheet = false
                            extractionResult = chosen
                            phase = .done
                            showReview = true
                        },
                        onPasteLink: {
                            showSimilarSheet = false
                        },
                        onDismiss: {
                            showSimilarSheet = false
                        }
                    )
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                }
            }
            .onAppear { detectClipboardURL() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                detectClipboardURL()
            }
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
                if urlText.isEmpty && phase == .idle && clipboardHasURL {
                    Button {
                        readClipboard()
                    } label: {
                        Text("Paste")
                            .font(.scCaption)
                            .foregroundStyle(Color.scAccent)
                    }
                } else if !urlText.isEmpty && phase == .idle {
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

    // MARK: - Extraction Failure UI

    private var extractionFailedSection: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(Color.scAccent.opacity(0.7))

            VStack(spacing: Spacing.xs) {
                Text("Recipe Not Found")
                    .font(.scHeadline)
                    .foregroundStyle(Color.scTextPrimary)

                if let result = extractionResult, let authorHint = result.authorHint {
                    Text("We searched the caption from \(authorHint) but couldn't find a recipe.")
                        .font(.scBody)
                        .foregroundStyle(Color.scTextSecondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("We searched the caption but couldn't find a recipe at this link.")
                        .font(.scBody)
                        .foregroundStyle(Color.scTextSecondary)
                        .multilineTextAlignment(.center)
                }

                if let result = extractionResult, let preview = result.captionPreview, !preview.isEmpty {
                    Text("\u{201C}\(preview.trimmingCharacters(in: .whitespacesAndNewlines))\u{2026}\u{201D}")
                        .font(.scCaption)
                        .foregroundStyle(Color.scTextSecondary.opacity(0.7))
                        .italic()
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.top, Spacing.xs)
                }
            }

            // Direct link paste field
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Paste the direct recipe link:")
                    .font(.scCaption)
                    .foregroundStyle(Color.scTextSecondary)
                HStack {
                    Image(systemName: "link")
                        .foregroundStyle(Color.scTextSecondary)
                        .frame(width: 20)
                    TextField("https://", text: $directLinkText)
                        .font(.scBody)
                        .foregroundStyle(Color.scTextPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    if !directLinkText.isEmpty {
                        Button {
                            directLinkText = ""
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
                        .stroke(Color.scBorder, lineWidth: 1)
                )
            }
        }
    }

    private var failureActionButtons: some View {
        VStack(spacing: Spacing.sm) {
            // Primary: try the pasted direct link
            Button {
                urlText = directLinkText.trimmingCharacters(in: .whitespaces)
                phase = .idle
                extractionResult = nil
                directLinkText = ""
                Task { await runImport() }
            } label: {
                Label("Try This Link", systemImage: "arrow.down.circle.fill")
                    .font(.scLabel)
                    .frame(maxWidth: .infinity)
                    .padding(Spacing.md)
                    .background(
                        directLinkText.trimmingCharacters(in: .whitespaces).hasPrefix("http")
                            ? Color.scAccent : Color.scAccent.opacity(0.35)
                    )
                    .foregroundStyle(Color.scBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!directLinkText.trimmingCharacters(in: .whitespaces).hasPrefix("http"))

            // Secondary: see similar recipes (only shown when alternatives exist)
            if let result = extractionResult, !result.alternatives.isEmpty {
                Button {
                    showSimilarSheet = true
                } label: {
                    Label(
                        result.alternatives.count == 1 ? "See a Similar Recipe" : "See \(result.alternatives.count) Similar Recipes",
                        systemImage: "sparkle.magnifyingglass"
                    )
                    .font(.scLabel)
                    .frame(maxWidth: .infinity)
                    .padding(Spacing.md)
                    .background(Color.scSurface)
                    .foregroundStyle(Color.scTextPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12).stroke(Color.scBorder, lineWidth: 1)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch phase {
        case .fetching:
            progressRow(label: "Fetching page…", icon: "arrow.down.circle")
        case .extracting:
            progressRow(label: statusText.isEmpty ? "Extracting recipe…" : statusText, icon: "wand.and.sparkles")
        case .done:
            HStack(spacing: Spacing.sm) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Recipe found!").font(.scBody).foregroundStyle(Color.scTextPrimary)
            }
        case .idle, .error, .extractionFailed:
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

    /// detectPatterns checks clipboard content type WITHOUT reading it — no privacy prompt.
    /// Extracted into a nonisolated static so the pasteboard callback closure is never
    /// inferred as @MainActor — Swift 6 strict concurrency would otherwise check actor
    /// isolation when UIPasteboard calls the handler on its own serial queue, crashing.
    private func detectClipboardURL() {
        Task {
            clipboardHasURL = await Self.clipboardHasProbableURL()
        }
    }

    private nonisolated static func clipboardHasProbableURL() async -> Bool {
        await withCheckedContinuation { continuation in
            UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { result in
                continuation.resume(
                    returning: (try? result.get())?.contains(.probableWebURL) == true
                )
            }
        }
    }

    /// Called only on explicit user tap — iOS always allows user-initiated clipboard reads.
    private func readClipboard() {
        if let url = UIPasteboard.general.url {
            urlText = url.absoluteString
        } else if let clip = UIPasteboard.general.string, clip.hasPrefix("http") {
            urlText = clip
        }
        clipboardHasURL = false
    }

    private var canImport: Bool {
        !urlText.trimmingCharacters(in: .whitespaces).isEmpty &&
        phase != .fetching && phase != .extracting && phase != .extractionFailed
    }

    private var importButtonBackground: Color {
        canImport ? Color.scAccent : Color.scAccent.opacity(0.4)
    }

    private var urlFieldBorderColor: Color {
        switch phase {
        case .error:             return Color.red.opacity(0.5)
        case .done:              return Color.green.opacity(0.4)
        case .extractionFailed:  return Color.scAccent.opacity(0.4)
        default:                 return Color.scBorder
        }
    }

    private func friendlyError(_ error: Error) -> String {
        let msg = error.localizedDescription.lowercased()
        if msg.contains("offline") || msg.contains("network") || msg.contains("internet") ||
           msg.contains("not connected") || msg.contains("connection") {
            return "No internet connection. Check your network and try again."
        }
        if msg.contains("timed out") || msg.contains("timeout") {
            return "The request timed out. The site may be slow — try again."
        }
        if msg.contains("not found") || msg.contains("404") {
            return "Page not found. Check the URL and try again."
        }
        return "Something went wrong. Try a different URL or paste the recipe manually."
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
        statusText = ""
        phase = .fetching

        let pipeline = ExtractionPipeline()
        do {
            let result = try await pipeline.extract(from: url) { status in
                Task { @MainActor in
                    self.statusText = status
                    if self.phase == .fetching { self.phase = .extracting }
                }
            }
            await MainActor.run {
                if result.isViable {
                    extractionResult = result
                    phase = .done
                    showReview = true
                } else {
                    // Store result (may have .alternatives and .captionPreview) and show failure UI
                    extractionResult = result
                    phase = .extractionFailed
                }
            }
        } catch {
            await MainActor.run {
                phase = .error
                errorMessage = friendlyError(error)
            }
        }
    }
}

// MARK: - Preview

#Preview("Import View") {
    ImportView()
        .preferredColorScheme(.dark)
}
