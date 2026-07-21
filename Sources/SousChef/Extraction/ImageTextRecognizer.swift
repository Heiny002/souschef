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
