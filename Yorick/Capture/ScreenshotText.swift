import AppKit
import Vision

/// Reading the words out of a crop, entirely on this Mac.
///
/// This is the one signal accessibility genuinely cannot supply. The AX tree
/// describes what an app CHOOSES to expose, and the surfaces that expose
/// nothing are exactly the ones people gesture at most: Figma's canvas is
/// WebGL with no text elements at all, Google Docs paints its own glyphs,
/// charts and dashboards are pictures, error dialogs in games and installers
/// are pictures, and anything screen-shared or embedded in a video is a
/// picture. `ContextCollector` returns empty for all of them; Vision does not.
///
/// It also carries a stronger claim than any AX fact. A pointed element is
/// wherever the mouse happened to be; a framed region is a deliberate act —
/// the user drew a box around the thing they meant. That makes OCR'd text
/// from a crop the highest-intent subject candidate available, which is why
/// `TitleComposer` ranks it above the pointed element.
///
/// Local, offline, no model, no network. Vision ships with macOS.
enum ScreenshotText {
    /// Recognized lines, most title-like first.
    ///
    /// Ordering is by GLYPH HEIGHT, not reading order: in almost any
    /// interface the biggest text in a region is its heading, and the heading
    /// is what names the thing. Reading order would return whatever happened
    /// to sit at the top of the box.
    static func lines(in image: CGImage, limit: Int = 6) async -> [String] {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let ranked = observations
                    .compactMap { observation -> (text: String, height: CGFloat)? in
                        guard let candidate = observation.topCandidates(1).first else { return nil }
                        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Single characters and stray punctuation are chrome,
                        // not names.
                        guard text.count >= 2 else { return nil }
                        return (text, observation.boundingBox.height)
                    }
                    .sorted { $0.height > $1.height }
                    .map(\.text)
                continuation.resume(returning: Array(ranked.prefix(limit)))
            }
            // .accurate over .fast: this runs once, after the user has already
            // stopped talking, so there is no latency budget to protect and a
            // misread heading is worse than a slow one.
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }

    /// Convenience over stored JPEG data.
    static func lines(in data: Data, limit: Int = 6) async -> [String] {
        guard let image = NSBitmapImageRep(data: data)?.cgImage else { return [] }
        return await lines(in: image, limit: limit)
    }

    /// The one line most likely to NAME what was framed.
    ///
    /// Length-capped for the same reason `TitleComposer.isNameLike` exists: a
    /// paragraph read out of a crop is evidence, but it is not what you call
    /// something.
    static func subjectLine(in data: Data) async -> String? {
        await lines(in: data, limit: 4).first { TitleComposer.isNameLike($0) }
    }
}
