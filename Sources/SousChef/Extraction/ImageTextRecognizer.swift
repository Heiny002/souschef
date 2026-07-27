import Foundation
import Vision
import UIKit

/// On-device OCR for the "scan a recipe" import path. Uses the Vision framework, so it runs
/// entirely offline with no API cost — the recognized text is fed straight into
/// `PastedTextExtractor`, exactly like a paste.
enum ImageTextRecognizer {

    /// Recognize text in an image, returned as newline-separated lines in reading order
    /// (top-to-bottom, left-to-right). Returns "" if the image can't be read or holds no text.
    ///
    /// The image is encoded to `Data` before crossing onto a background queue so nothing
    /// non-Sendable (CGImage / the Vision request objects) escapes the concurrency domain —
    /// the request is built and consumed entirely inside the background closure. Recognition
    /// runs off the main thread so the UI keeps its "Reading…" spinner responsive.
    static func recognizeText(in image: UIImage) async -> String {
        guard let data = image.jpegData(compressionQuality: 0.9) ?? image.pngData() else { return "" }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                // Accurate + language correction: recipes are prose, and correction fixes the
                // common OCR slips before the parser sees them.
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(data: data, orientation: orientation, options: [:])
                do {
                    try handler.perform([request])
                    let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                    continuation.resume(returning: assemble(observations))
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    /// Cheap "does this image carry text at all?" pass, for triaging a carousel before paying
    /// for full recognition on every slide.
    ///
    /// `VNDetectTextRectanglesRequest` only locates text regions — it never reads characters —
    /// so it costs a fraction of `VNRecognizeTextRequest`. A typical recipe carousel is one
    /// hero food photo followed by a few text slides; this skips the photos.
    ///
    /// `minimumCoverage` is the share of the image that must be text-like. A little stray text
    /// (a watermark, a logo, a handle burned into the corner) shouldn't qualify a slide as a
    /// recipe page, but a genuine text slide covers a lot of the frame.
    static func hasText(in image: UIImage, minimumCoverage: CGFloat = 0.02) async -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.8) ?? image.pngData() else {
            return false
        }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectTextRectanglesRequest()
                request.reportCharacterBoxes = false

                let handler = VNImageRequestHandler(data: data, orientation: orientation, options: [:])
                do {
                    try handler.perform([request])
                    let boxes = (request.results as? [VNTextObservation]) ?? []
                    // Normalized boxes, so areas sum toward 1.0 for a full frame of text.
                    let coverage = boxes.reduce(CGFloat.zero) { sum, box in
                        sum + (box.boundingBox.width * box.boundingBox.height)
                    }
                    continuation.resume(returning: coverage >= minimumCoverage)
                } catch {
                    // Vision failed rather than found nothing — let the caller try real OCR
                    // instead of silently dropping a slide that might hold the recipe.
                    continuation.resume(returning: true)
                }
            }
        }
    }

    /// Order recognized-text observations into lines. Vision's origin is bottom-left, so a
    /// larger normalized Y is higher on the page; group by row (within a small Y tolerance)
    /// and read left-to-right within a row.
    private static func assemble(_ observations: [VNRecognizedTextObservation]) -> String {
        let lines = observations
            .compactMap { obs -> (y: CGFloat, x: CGFloat, text: String)? in
                guard let top = obs.topCandidates(1).first else { return nil }
                let box = obs.boundingBox
                return (box.origin.y, box.origin.x, top.string)
            }
            .sorted { a, b in
                if abs(a.y - b.y) > 0.02 { return a.y > b.y }
                return a.x < b.x
            }
        return lines.map(\.text).joined(separator: "\n")
    }
}

private extension CGImagePropertyOrientation {
    /// Map a `UIImage.Orientation` (what the camera/library hands us) to the Core Graphics
    /// orientation Vision expects, so rotated photos OCR correctly.
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up:            self = .up
        case .upMirrored:    self = .upMirrored
        case .down:          self = .down
        case .downMirrored:  self = .downMirrored
        case .left:          self = .left
        case .leftMirrored:  self = .leftMirrored
        case .right:         self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default:    self = .up
        }
    }
}
