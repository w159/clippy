import Foundation

/// Result of describing an image clip.
struct ImageDescription: Equatable {
    /// How the text was produced.
    enum Origin: Equatable {
        /// Multimodal on-device Foundation Models (macOS 27+).
        case generative
        /// Vision classification + OCR; no generative model involved.
        case classification
    }

    var origin: Origin
    var text: String
    var labels: [String]

    /// Label shown under the result so users know what produced it.
    var originNote: String {
        switch origin {
        case .generative: return "Described on-device by the system language model."
        case .classification: return "On-device classification (no generative model available)"
        }
    }
}

/// Pure mapping from Vision observations to readable labels and a summary.
enum VisionLabelMapper {
    /// Minimum confidence for a classification label.
    static let confidenceFloor: Float = 0.15
    static let maxLabels = 6
    static let maxOCRChars = 300

    /// Labels at or above the floor, best first, humanized and de-duplicated.
    static func labels(from observations: [(identifier: String, confidence: Float)]) -> [String] {
        var seen = Set<String>()
        return observations
            .filter { $0.confidence >= confidenceFloor }
            .sorted { $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.identifier < $1.identifier }
            .compactMap { observation -> String? in
                let name = humanize(observation.identifier)
                return name.isEmpty || !seen.insert(name).inserted ? nil : name
            }
            .prefix(maxLabels).map { $0 }
    }

    /// "wine_bottle" -> "wine bottle".
    static func humanize(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// One-paragraph summary from labels and recognized text (both optional).
    static func summary(labels: [String], ocrText: String?) -> String {
        var parts: [String] = []
        if !labels.isEmpty { parts.append("Looks like: " + labels.joined(separator: ", ") + ".") }
        let flat = (ocrText ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !flat.isEmpty {
            let clipped = flat.count > maxOCRChars ? String(flat.prefix(maxOCRChars)) + "\u{2026}" : flat
            parts.append("Text in image: \(clipped)")
        }
        return parts.isEmpty ? "No labels or text were recognized." : parts.joined(separator: "\n")
    }
}
