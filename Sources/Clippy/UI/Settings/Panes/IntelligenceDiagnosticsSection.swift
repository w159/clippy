import SwiftUI

/// Context-reader timing diagnostics per app, with reset. Bundle ids and timings only.
struct IntelligenceDiagnosticsSection: View {
    @Environment(\.clippyTokens) private var tokens
    @State private var rows: [DiagnosticsRow] = []

    /// Creates the section.
    init() {}

    var body: some View {
        PaneSection("Context reader diagnostics", footer: "Apps that repeatedly time out are skipped for a while so the panel opens quickly.") {
            if rows.isEmpty {
                SettingsRow(title: "No timings yet", detail: Text("Timings appear after Clippy reads an app's context.")) { EmptyView() }
            } else {
                header
                ForEach(rows) { row in
                    Divider()
                    HStack {
                        Text(row.bundleID).font(.callout).foregroundStyle(tokens.textPrimary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        cell(row.averageText, width: 70)
                        cell(row.timeoutsText, width: 60)
                        cell(row.skippedText, width: 110, warn: row.isSkipped)
                    }
                    .frame(minHeight: 32)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(row.bundleID), average \(row.averageText), \(row.timeoutsText) timeouts, skipped \(row.skippedText)")
                }
            }
            Divider()
            SettingsRow(title: "Reset diagnostics") {
                Button("Reset") {
                    ContextReaderStats.shared.reset()
                    reload()
                }
                .disabled(rows.isEmpty)
            }
        }
        .onAppear(perform: reload)
    }

    private var header: some View {
        HStack {
            Text("App").frame(maxWidth: .infinity, alignment: .leading)
            cell("Average", width: 70)
            cell("Timeouts", width: 60)
            cell("Skipped", width: 110)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tokens.textSecondary)
        .frame(minHeight: 28)
        .accessibilityHidden(true)
    }

    private func cell(_ text: String, width: CGFloat, warn: Bool = false) -> some View {
        Text(text).font(.callout.monospacedDigit()).foregroundStyle(warn ? tokens.warning : tokens.textSecondary)
            .frame(width: width, alignment: .trailing)
    }

    private func reload() { rows = DiagnosticsRowFormatter.rows(from: ContextReaderStats.shared.snapshot()) }
}
