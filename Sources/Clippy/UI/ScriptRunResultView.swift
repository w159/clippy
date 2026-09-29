import AppKit
import SwiftUI

/// The run-result component shared by the panel and Settings (SCR-08): a status
/// header with distinct Success / Failed / Cancelled / Timed out states, live
/// streamed output while running, a two-axis output view, and Copy / Save as
/// clip actions that work for failed runs too. `outputToClipboard` itself is
/// applied once, by `ScriptRunCenter`, so it is identical on both surfaces.
struct ScriptRunResultView: View {
    enum Layout {
        /// Fixed-height output for a card in a list.
        case compact
        /// Output fills the space it is given (the Settings drawer).
        case fill
    }

    @ObservedObject var run: ScriptRun
    var layout: Layout
    /// Inserts text as a new clip; returns whether it was saved.
    var saveClip: (String) -> Bool
    var onDismiss: (() -> Void)?

    @ObservedObject private var settings = AppSettings.shared
    @State private var shownStream: ScriptOutputStream?
    @State private var saveTask: Task<Void, Never>?
    private var tokens: ThemeTokens { settings.theme }

    private var stdout: String { run.result?.stdout ?? run.liveStdout }
    private var stderr: String { run.result?.stderr ?? run.liveStderr }

    /// stdout unless the user picked otherwise, or it is empty and stderr is not.
    private var activeStream: ScriptOutputStream {
        if let shownStream { return shownStream }
        return stdout.isEmpty && !stderr.isEmpty ? .stderr : .stdout
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow
            if let result = run.result, result.truncated {
                Label("Output truncated: hit the capture ceiling", systemImage: "scissors")
                    .font(PanelTypography.micro(settings))
                    .foregroundStyle(tokens.danger)
            }
            if !stdout.isEmpty || !stderr.isEmpty {
                streamPicker
                outputArea
            } else if !run.isRunning {
                Text("(no output)")
                    .font(PanelTypography.metadata(settings))
                    .foregroundStyle(tokens.textSecondary)
                    .italic()
                if layout == .fill { Spacer(minLength: 0) }
            } else if layout == .fill {
                Spacer(minLength: 0)
            }
            actions
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: layout == .fill ? .infinity : nil, alignment: .topLeading)
        .background(tokens.scrollBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: Status

    private var statusRow: some View {
        HStack(spacing: 6) {
            ScriptRunChip(model: ScriptRunChipModel.model(for: run.result,
                                                           timeoutSeconds: run.script.timeoutSeconds))
            Spacer()
            if run.isRunning {
                Button("Stop") { run.cancel() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Icon, label and color for one finished run. Timeout and cancel are not
    /// failures of the script, so each gets its own look instead of red "Failed".
    struct Look {
        var icon: String
        var label: String
        var color: Color
    }

    static func look(for result: ScriptResult, script: Script, tokens: ThemeTokens) -> Look {
        switch result.outcome {
        case .success:
            return Look(icon: "checkmark.circle.fill", label: "Succeeded", color: tokens.success)
        case .failed:
            let label = result.launchFailed ? "Could not start" : "Failed (exit \(result.exitCode))"
            return Look(icon: "xmark.circle.fill", label: label, color: tokens.danger)
        case .cancelled:
            return Look(icon: "stop.circle.fill", label: "Cancelled", color: tokens.textSecondary)
        case .timedOut:
            let suffix = script.timeoutSeconds > 0 ? " after \(script.timeoutSeconds) s" : ""
            return Look(icon: "clock.badge.exclamationmark.fill", label: "Timed out" + suffix, color: tokens.warning)
        }
    }

    // MARK: Output

    @ViewBuilder
    private var streamPicker: some View {
        if !stdout.isEmpty && !stderr.isEmpty {
            Picker("Stream", selection: Binding(get: { activeStream }, set: { shownStream = $0 })) {
                Text("stdout").tag(ScriptOutputStream.stdout)
                Text("stderr").tag(ScriptOutputStream.stderr)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        } else {
            Text(activeStream == .stdout ? "stdout" : "stderr")
                .font(PanelTypography.micro(settings).weight(.semibold))
                .foregroundStyle(activeStream == .stderr ? tokens.danger.opacity(0.8) : tokens.textSecondary)
        }
    }

    private var outputArea: some View {
        let text = activeStream == .stdout ? stdout : stderr
        return OutputTextView(
            text: String(text.prefix(ScriptResult.viewCap)),
            font: .monospacedSystemFont(ofSize: max(10, CGFloat(settings.fontSizeBase) - 2), weight: .regular),
            textColor: NSColor(activeStream == .stderr ? tokens.danger : tokens.textPrimary),
            background: NSColor(tokens.panel),
            followsTail: run.isRunning,
            accessibilityLabel: activeStream == .stdout ? "Script output" : "Script errors")
            .frame(minHeight: layout == .fill ? 60 : 120, maxHeight: layout == .fill ? .infinity : 220)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if !stdout.isEmpty {
                    Button("Copy output") { copy(stdout) }
                        .controlSize(.small).buttonStyle(.bordered)
                }
                if !stderr.isEmpty {
                    Button("Copy stderr") { copy(stderr) }
                        .controlSize(.small).buttonStyle(.bordered)
                }
                if run.result != nil, !stdout.isEmpty || !stderr.isEmpty { saveMenu }
                Spacer()
                if run.result != nil, let onDismiss {
                    Button("Dismiss", action: onDismiss)
                        .controlSize(.small).buttonStyle(.borderless)
                        .foregroundStyle(tokens.textSecondary)
                }
            }
            if let status = run.saveStatus {
                Text(status)
                    .font(PanelTypography.micro(settings))
                    .foregroundStyle(status.hasPrefix("Saved") ? tokens.success : tokens.danger)
            }
        }
    }

    /// Save as clip: stdout, stderr, or both, so a failed run's error text can
    /// be kept as well.
    private var saveMenu: some View {
        Menu("Save as clip") {
            if !stdout.isEmpty { Button("Output") { save(stdout) } }
            if !stderr.isEmpty { Button("Errors (stderr)") { save(stderr) } }
            if !stdout.isEmpty && !stderr.isEmpty {
                Button("Output and errors") { save(stdout + "\n--- stderr ---\n" + stderr) }
            }
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }

    private func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private func save(_ text: String) {
        let message = saveClip(text) ? "Saved as clip" : "Could not save clip"
        run.saveStatus = message
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, run.saveStatus == message { run.saveStatus = nil }
        }
    }
}

#Preview("Run result") {
    ScriptRunResultView(run: ScriptRun(script: Script(name: "Preview", body: "echo hi")),
                        layout: .compact, saveClip: { _ in true }, onDismiss: nil)
        .clippyDesignSystem()
        .frame(width: 420, height: 220)
}
