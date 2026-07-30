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

    /// Order recognized-text observations into reading order, column-aware.
    private static func assemble(_ observations: [VNRecognizedTextObservation]) -> String {
        let lines = observations.compactMap { obs -> (box: CGRect, text: String)? in
            guard let top = obs.topCandidates(1).first else { return nil }
            return (obs.boundingBox, top.string)
        }
        return assembleLines(lines)
    }

    /// Reading order for recognized lines. A two-column recipe card (ingredients left, method
    /// right — the dominant recipe-slide layout) interleaves badly under a plain row sort:
    /// Vision reads straight across the gutter, so the parser sees alternating fragments of
    /// both columns. Instead: merge the lines' horizontal extents; a persistent vertical
    /// gutter splits the page into columns, each read top-to-bottom, left column first.
    /// Lines spanning most of the page width (the title banner) sit above the columns.
    /// Falls back to the plain row sort whenever there is no CONFIDENT gutter — a false
    /// split reorders real text, so the detector must earn its keep.
    ///
    /// Boxes are Vision-normalized: origin bottom-left, so a larger Y is higher on the page.
    static func assembleLines(_ lines: [(box: CGRect, text: String)]) -> String {
        func rowOrder(_ ls: [(box: CGRect, text: String)]) -> [String] {
            ls.sorted { a, b in
                if abs(a.box.origin.y - b.box.origin.y) > 0.02 { return a.box.origin.y > b.box.origin.y }
                return a.box.origin.x < b.box.origin.x
            }.map(\.text)
        }
        let plain = rowOrder(lines).joined(separator: "\n")
        guard lines.count >= 6 else { return plain }

        // A line spanning most of the width bridges any gutter (the title) — set it aside so
        // it can't collapse the column detection, and emit it above the columns.
        let banners = lines.filter { $0.box.width >= 0.6 }
        let body = lines.filter { $0.box.width < 0.6 }
        guard body.count >= 6 else { return plain }

        // Merge horizontal extents into runs; a gap >= gutter between runs is a column split.
        let gutter: CGFloat = 0.03
        var runs: [(minX: CGFloat, maxX: CGFloat)] = []
        for line in body.sorted(by: { $0.box.minX < $1.box.minX }) {
            if let last = runs.last, line.box.minX <= last.maxX + gutter {
                runs[runs.count - 1].maxX = max(last.maxX, line.box.maxX)
            } else {
                runs.append((line.box.minX, line.box.maxX))
            }
        }
        guard runs.count >= 2 else { return plain }

        // Assign lines to runs; a run only counts as a column with >= 3 lines (stray marks —
        // page numbers, watermarks — must not manufacture a column). Lines from non-qualifying
        // runs are folded into the nearest real column so no text is lost.
        var columns: [[(box: CGRect, text: String)]] = Array(repeating: [], count: runs.count)
        for line in body {
            let idx = runs.indices.min {
                abs(line.box.midX - (runs[$0].minX + runs[$0].maxX) / 2)
                    < abs(line.box.midX - (runs[$1].minX + runs[$1].maxX) / 2)
            } ?? 0
            columns[idx].append(line)
        }
        let qualifying = columns.indices.filter { columns[$0].count >= 3 }
        guard qualifying.count >= 2 else { return plain }
        var grouped: [Int: [(box: CGRect, text: String)]] = [:]
        for (i, column) in columns.enumerated() {
            for line in column {
                let target = qualifying.contains(i) ? i : qualifying.min {
                    abs(line.box.midX - (runs[$0].minX + runs[$0].maxX) / 2)
                        < abs(line.box.midX - (runs[$1].minX + runs[$1].maxX) / 2)
                }!
                grouped[target, default: []].append(line)
            }
        }

        var pieces: [String] = []
        if !banners.isEmpty { pieces.append(rowOrder(banners).joined(separator: "\n")) }
        for i in qualifying.sorted() {
            pieces.append(rowOrder(grouped[i] ?? []).joined(separator: "\n"))
        }
        return pieces.joined(separator: "\n\n")
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
