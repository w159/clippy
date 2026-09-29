import SwiftUI

/// The five states a script run can show in the output drawer and panel cards.
enum ScriptRunChipKind: String, CaseIterable, Equatable {
    case running, success, failed, cancelled, timedOut

    /// SF Symbol for the state. Shape differs per state so colour is never the only cue.
    var symbol: String {
        switch self {
        case .running: return "circle.dotted"
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case .timedOut: return "clock.badge.exclamationmark.fill"
        }
    }

    /// Design-system severity that colours the chip.
    var severity: BannerSeverity {
        switch self {
        case .running, .cancelled: return .neutral
        case .success: return .success
        case .failed: return .danger
        case .timedOut: return .warning
        }
    }
}

/// Display model for a run-state chip. Pure so the mapping is unit-testable.
struct ScriptRunChipModel: Equatable {
    var kind: ScriptRunChipKind
    var title: String
    /// Duration text such as "0.3 s", nil while running.
    var duration: String?

    /// Maps a finished result (or nil while running) to a chip. `timeoutSeconds`
    /// is the script's configured limit and only decorates the timed-out title.
    static func model(for result: ScriptResult?, timeoutSeconds: Int = 0) -> ScriptRunChipModel {
        guard let result else { return ScriptRunChipModel(kind: .running, title: "Running", duration: nil) }
        let duration = formatDuration(milliseconds: result.durationMs)
        switch result.outcome {
        case .success:
            return ScriptRunChipModel(kind: .success, title: "Success", duration: duration)
        case .failed:
            let title = result.launchFailed ? "Could not start" : "Failed (exit \(result.exitCode))"
            return ScriptRunChipModel(kind: .failed, title: title, duration: duration)
        case .cancelled:
            return ScriptRunChipModel(kind: .cancelled, title: "Cancelled", duration: duration)
        case .timedOut:
            let title = timeoutSeconds > 0 ? "Timed out after \(timeoutSeconds) s" : "Timed out"
            return ScriptRunChipModel(kind: .timedOut, title: title, duration: duration)
        }
    }

    /// Maps a stored history outcome to a chip kind.
    static func kind(for outcome: ScriptResult.Outcome) -> ScriptRunChipKind {
        switch outcome {
        case .success: return .success
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        }
    }

    /// "412 ms" under a second, otherwise one decimal of seconds ("0.3 s" style above 1 s).
    static func formatDuration(milliseconds: Int) -> String {
        let clamped = max(0, milliseconds)
        if clamped < 1000 { return "\(clamped) ms" }
        return String(format: "%.1f s", Double(clamped) / 1000)
    }
}

/// Capsule chip for a run state: icon, title and optional duration.
struct ScriptRunChip: View {
    @Environment(\.clippyTokens) private var tokens
    let model: ScriptRunChipModel

    var body: some View {
        let color = model.kind.severity.foreground(in: tokens)
        HStack(spacing: tokens.metrics.space.one) {
            Image(systemName: model.kind.symbol).symbolRenderingMode(.hierarchical)
            Text(model.title).fontWeight(.medium)
            if let duration = model.duration {
                Text(duration).foregroundStyle(tokens.textSecondary).monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(color)
        .padding(.horizontal, tokens.metrics.space.two)
        .padding(.vertical, tokens.metrics.space.one)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Run state: \(model.title)" + (model.duration.map { ", \($0)" } ?? ""))
    }
}
