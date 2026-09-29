import Foundation

/// JSON import and export of AI actions (AI-14). The file is an envelope so the
/// format can evolve; a bare array of actions is also accepted on import.
enum AIActionTransfer {
    static let format = "clippy-ai-actions"
    static let version = 1

    struct Envelope: Codable {
        let format: String
        let version: Int
        let actions: [AIAction]
    }

    struct ImportResult: Equatable {
        var actions: [AIAction]
        /// Human-readable reasons entries were skipped.
        var skipped: [String]
    }

    enum TransferError: LocalizedError {
        case unreadable
        case wrongFormat(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: return "The file is not a valid Clippy actions export."
            case .wrongFormat(let found): return "Unsupported actions file (\(found))."
            }
        }
    }

    static func export(_ actions: [AIAction]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Envelope(format: format, version: version, actions: actions))
    }

    /// Decode and sanitize. Imported actions always get a fresh id and are never
    /// built-in, so an import cannot overwrite or impersonate a built-in action.
    static func importActions(from data: Data) throws -> ImportResult {
        let decoder = JSONDecoder()
        let decoded: [AIAction]
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            guard envelope.format == format else { throw TransferError.wrongFormat(envelope.format) }
            guard envelope.version <= version else { throw TransferError.wrongFormat("version \(envelope.version)") }
            decoded = envelope.actions
        } else if let bare = try? decoder.decode([AIAction].self, from: data) {
            decoded = bare
        } else {
            throw TransferError.unreadable
        }
        var result = ImportResult(actions: [], skipped: [])
        for var action in decoded {
            let name = action.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                result.skipped.append("An action with no name")
                continue
            }
            if AIActionTemplateValidator.hasErrors(AIActionTemplateValidator.validate(action.promptTemplate)) {
                result.skipped.append("\"\(name)\": empty prompt template")
                continue
            }
            action.id = UUID()
            action.name = name
            action.isBuiltIn = false
            action.temperature = min(max(action.temperature, 0), 1)
            action.maxTokens = min(max(action.maxTokens, 16), 4096)
            result.actions.append(action)
        }
        return result
    }
}
