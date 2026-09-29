import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension ScriptsView {
    // MARK: - Drawer

    var currentHistory: [ScriptRunRecord] {
        editing.map { store.history(for: $0.id) } ?? []
    }

    var drawer: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Drawer", selection: $drawerTab) {
                    Text("Output").tag(DrawerTab.output)
                    Text("History (\(currentHistory.count))").tag(DrawerTab.history)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            switch drawerTab {
            case .output:
                if let run = currentRun {
                    ScriptRunResultView(run: run, layout: .fill,
                                        saveClip: { (try? ClipDatabase.shared.insertTextClip($0)) != nil },
                                        onDismiss: { if let id = editing?.id { center.dismiss(id) } })
                        .padding(.horizontal, 10).padding(.bottom, 8)
                } else {
                    Text("Run the script to see its output here.")
                        .font(.callout).foregroundStyle(tokens.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .history:
                historyList
            }
        }
        .background(tokens.panel)
    }

    var historyList: some View {
        HSplitView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(currentHistory) { record in
                        Button { historyDetail = record } label: {
                            HStack(spacing: 6) {
                                Image(systemName: Self.icon(for: record.outcome))
                                    .foregroundStyle(Self.color(for: record.outcome, tokens: tokens))
                                Text(record.startedAt, format: .dateTime.month().day().hour().minute().second())
                                Spacer(minLength: 4)
                                Text("exit \(record.exitCode)").foregroundStyle(tokens.textSecondary)
                                Text("\(record.durationMs) ms").foregroundStyle(tokens.textSecondary).monospacedDigit()
                            }
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(rowBackground(selected: historyDetail?.id == record.id))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
            .frame(minWidth: 220)
            Group {
                if let record = historyDetail, let out = record.stdout ?? record.stderr {
                    let text = [record.stdout, record.stderr].compactMap { $0 }.filter { !$0.isEmpty }
                        .joined(separator: "\n--- stderr ---\n")
                    OutputTextView(text: text.isEmpty ? out : text,
                                   textColor: NSColor(tokens.textPrimary), background: NSColor(tokens.panel))
                } else {
                    Text(historyDetail == nil ? "Select a run." : "Output was not kept for this run.")
                        .font(.callout).foregroundStyle(tokens.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 160)
        }
    }

    static func icon(for outcome: ScriptResult.Outcome) -> String {
        ScriptRunChipModel.kind(for: outcome).symbol
    }

    static func color(for outcome: ScriptResult.Outcome, tokens: ThemeTokens) -> Color {
        switch outcome {
        case .success: return tokens.success
        case .failed: return tokens.danger
        case .cancelled: return tokens.textSecondary
        case .timedOut: return tokens.warning
        }
    }
}
