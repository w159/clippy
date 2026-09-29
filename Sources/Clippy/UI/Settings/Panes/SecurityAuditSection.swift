import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Audit log summary: entry count, tamper verification, export and reveal.
struct SecurityAuditSection: View {
    @Binding var notice: PaneNotice?
    @State private var entryCount: Int?
    @State private var verification: AuditLog.VerificationReport?
    @State private var verifying = false

    /// Creates the section.
    init(notice: Binding<PaneNotice?>) { self._notice = notice }

    var body: some View {
        PaneSection("Audit log", footer: "A hash-chained record of deletes, exports and rule runs. It never stores clip content.") {
            SettingsRow(title: "Entries", detail: Text(entryCount.map { "\($0) recorded" } ?? "Counting\u{2026}")) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AuditLog.shared.directory]) }
            }
            Divider()
            SettingsRow(title: "Verify integrity", detail: verificationText) {
                Button(verifying ? "Verifying\u{2026}" : "Verify") { verify() }.disabled(verifying)
            }
            Divider()
            SettingsRow(title: "Export") {
                HStack {
                    Button("JSON\u{2026}") { export(.json) }
                    Button("CSV\u{2026}") { export(.csv) }
                }
            }
        }
        .task { entryCount = await Task.detached { AuditLog.shared.allEntries().count }.value }
    }

    private var verificationText: Text {
        guard let report = verification else { return Text("Checks every entry's hash chain for tampering.") }
        if report.isValid { return Text("No tampering found in \(report.entriesChecked) entries across \(report.filesChecked) files.") }
        return Text("Tampering detected: \(report.failures.count) problem\(report.failures.count == 1 ? "" : "s") in \(Set(report.failures.map(\.file)).count) file(s).")
            .foregroundColor(.red)
    }

    private func verify() {
        verifying = true
        Task {
            let report = await Task.detached { AuditLog.shared.verify() }.value
            verification = report
            verifying = false
            notice = report.isValid ? .success("Audit log verified.") : .failure("Audit log failed verification.")
        }
    }

    private func export(_ format: AuditLog.ExportFormat) {
        let panel = NSSavePanel()
        let isJSON = format == .json
        panel.allowedContentTypes = [isJSON ? .json : .commaSeparatedText]
        panel.nameFieldStringValue = isJSON ? "clippy-audit.json" : "clippy-audit.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try AuditLog.shared.export(to: url, format: format)
            notice = .success("Exported \(count) entries.")
        } catch {
            notice = .failure("Export failed.")
        }
    }
}
