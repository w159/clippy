import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Whether Apple's on-device Foundation Models can run right now, with a reason when not.
enum FoundationModelsAvailability {
    /// Availability plus a short human explanation.
    struct Status: Equatable {
        var isAvailable: Bool
        var reason: String
    }

    /// Reads `SystemLanguageModel.default.availability` when the framework exists.
    static func current() -> Status {
        #if canImport(FoundationModels)
            switch SystemLanguageModel.default.availability {
            case .available:
                return Status(isAvailable: true, reason: "Apple Intelligence is ready on this Mac.")
            case .unavailable:
                return Status(isAvailable: false, reason: "Apple Intelligence is not available. Turn it on in System Settings, or wait for the model to finish downloading.")
            @unknown default:
                return Status(isAvailable: false, reason: "Apple Intelligence status is unknown.")
            }
        #else
            return Status(isAvailable: false, reason: "This build of macOS does not include Apple Intelligence.")
        #endif
    }
}
