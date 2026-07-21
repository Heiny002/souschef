import SwiftUI
import UIKit

/// "Scan a recipe" import: capture or pick a photo → on-device OCR (`ImageTextRecognizer`)
/// → the same `PastedTextExtractor` that powers paste-import → `ReviewView` to edit and
/// save. Entirely offline; no network or API key.
struct RecipeScannerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .idle
    @State private var showPicker = false
    @State private var pickerSource: CameraImagePicker.Source = .camera
    @State private var result: ExtractionResult?
    @State private var showReview = false
    @State private var errorMessage: String?

    enum Phase: Equatable { case idle, recognizing, failed }

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.scBackground.ignoresSafeArea()
                VStack(spacing: Spacing.lg) {
                    Spacer()
                    header
                    if phase == .recognizing {
                        recognizingRow
                    } else {
                        if let errorMessage, phase == .failed {
                            Text(errorMessage)
                                .font(.scBody)
                                .foregroundStyle(Color.scTextSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, Spacing.md)
                        }
                        captureButtons
                    }
                    Spacer()
                }
                .padding(Spacing.md)
            }
            .navigationTitle("Scan Recipe")
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
                if let result {
                    ReviewView(
                        result: result,
                        onSave: { _ in dismiss() },
                        onRetry: { reset() }
                    )
                }
            }
            .fullScreenCover(isPresented: $showPicker) {
                CameraImagePicker(source: pickerSource) { image in
                    showPicker = false
                    if let image {
                        Task { await handle(image) }
                    }
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(Color.scAccent)
            Text("Scan a recipe")
                .font(.scHeadline)
                .foregroundStyle(Color.scTextPrimary)
            Text("Point at a cookbook page, card, or screenshot. We'll read the text and let you review it.")
                .font(.scCaption)
                .foregroundStyle(Color.scTextSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var recognizingRow: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView().tint(Color.scAccent)
            Text("Reading the recipe…")
                .font(.scBody)
                .foregroundStyle(Color.scTextSecondary)
        }
    }

    private var captureButtons: some View {
        VStack(spacing: Spacing.sm) {
            if cameraAvailable {
                Button {
                    pickerSource = .camera
                    showPicker = true
                } label: {
                    Label("Take Photo", systemImage: "camera.fill")
                        .font(.scLabel)
                        .frame(maxWidth: .infinity)
                        .padding(Spacing.md)
                        .background(Color.scAccent)
                        .foregroundStyle(Color.scBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            Button {
                pickerSource = .library
                showPicker = true
            } label: {
                Label("Choose from Library", systemImage: "photo.on.rectangle")
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

    // MARK: - Logic

    private func handle(_ image: UIImage) async {
        phase = .recognizing
        errorMessage = nil

        let text = await ImageTextRecognizer.recognizeText(in: image)
        var extracted = PastedTextExtractor().extract(text: text)
        extracted.extractionMethod = "photo-ocr"   // badge it as a scan, not a paste

        guard !extracted.ingredients.isEmpty || !extracted.steps.isEmpty else {
            phase = .failed
            errorMessage = text.isEmpty
                ? "We couldn't read any text in that photo. Try a clearer, straight-on shot with good lighting."
                : "We read the photo but couldn't pick out a recipe. Try a clearer shot, or add it manually."
            return
        }
        result = extracted
        phase = .idle
        showReview = true
    }

    private func reset() {
        result = nil
        phase = .idle
        errorMessage = nil
    }
}

#Preview("Scanner") {
    RecipeScannerView()
        .preferredColorScheme(.dark)
}
