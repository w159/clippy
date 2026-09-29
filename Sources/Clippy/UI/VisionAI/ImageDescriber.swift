import Foundation
import ImageIO
import Vision

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Availability probes, injected so gating is testable.
struct DescribeAvailability: Equatable {
    var osSupportsImageInput: Bool
    var modelAvailable: Bool
    var modelSupportsVision: Bool

    /// Generative description needs all three; otherwise the Vision fallback runs.
    var canUseGenerative: Bool { osSupportsImageInput && modelAvailable && modelSupportsVision }

    /// Probes the running system. Image prompts are a macOS 27 API.
    static func current() -> DescribeAvailability {
        #if canImport(FoundationModels)
            if #available(macOS 27.0, *) {
                let model = SystemLanguageModel.default
                var available = false
                if case .available = model.availability { available = true }
                return DescribeAvailability(
                    osSupportsImageInput: true, modelAvailable: available,
                    modelSupportsVision: model.capabilities.contains(.vision))
            }
        #endif
        return DescribeAvailability(osSupportsImageInput: false, modelAvailable: false, modelSupportsVision: false)
    }
}

/// Describes an image file entirely on-device. Uses the multimodal Foundation
/// Models path when available, else Vision classification + OCR.
enum ImageDescriber {
    enum DescribeError: Error { case unreadableImage }

    /// `availability` defaults to a live probe.
    static func describe(imageURL: URL, availability: DescribeAvailability = .current()) async throws -> ImageDescription {
        #if canImport(FoundationModels)
            if #available(macOS 27.0, *), availability.canUseGenerative,
                let text = try? await generate(imageURL: imageURL)
            {
                return ImageDescription(origin: .generative, text: text, labels: [])
            }
        #endif
        return try await classify(imageURL: imageURL)
    }

    /// Vision fallback: classification labels plus recognized text.
    static func classify(imageURL: URL) async throws -> ImageDescription {
        try await Task.detached(priority: .userInitiated) {
            let classify = VNClassifyImageRequest()
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(url: imageURL)
            do { try handler.perform([classify, text]) } catch { throw DescribeError.unreadableImage }
            let observations = (classify.results ?? []).map { ($0.identifier, $0.confidence) }
            let labels = VisionLabelMapper.labels(from: observations)
            let ocr = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            return ImageDescription(
                origin: .classification, text: VisionLabelMapper.summary(labels: labels, ocrText: ocr), labels: labels)
        }.value
    }

    #if canImport(FoundationModels)
        @available(macOS 27.0, *)
        private static func generate(imageURL: URL) async throws -> String {
            let session = LanguageModelSession(instructions: "You describe images for a clipboard manager. Be brief and factual.")
            let response = try await session.respond {
                "Describe this image in two sentences, then list any text it contains."
                Attachment(imageURL: imageURL)
            }
            return response.content
        }
    #endif
}
