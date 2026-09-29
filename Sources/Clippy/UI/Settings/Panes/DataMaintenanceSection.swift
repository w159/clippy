import SwiftUI

/// Integrity check, VACUUM with size delta, and orphaned media report and sweep.
struct DataMaintenanceSection: View {
    @Binding var notice: PaneNotice?
    @State private var integrityText: String?
    @State private var vacuumText: String?
    @State private var orphanText: String?
    @State private var orphanCount = 0
    @State private var busy = false
    @State private var confirmSweep = false

    /// Creates the section.
    init(notice: Binding<PaneNotice?>) { self._notice = notice }

    var body: some View {
        PaneSection("Maintenance", footer: "Compacting rewrites the database file and can take a moment on large histories.") {
            SettingsRow(title: "Integrity check", detail: Text(integrityText ?? "Verifies the database structure.")) {
                Button("Check") { run { try Self.integrity() } set: { integrityText = $0 } }.disabled(busy)
            }
            Divider()
            SettingsRow(title: "Compact database", detail: Text(vacuumText ?? "Reclaims unused space (VACUUM).")) {
                Button("Compact") { run { try Self.vacuum() } set: { vacuumText = $0 } }.disabled(busy)
            }
            Divider()
            SettingsRow(title: "Orphaned media", detail: Text(orphanText ?? "Finds media files no clip uses.")) {
                HStack {
                    Button("Scan") { scan() }.disabled(busy)
                    Button("Remove\u{2026}") { confirmSweep = true }.disabled(busy || orphanCount == 0)
                }
            }
        }
        .confirmationDialog("Delete orphaned media files?", isPresented: $confirmSweep, titleVisibility: .visible) {
            Button("Delete Files", role: .destructive) { sweep() }
        } message: {
            Text("\(orphanCount) file\(orphanCount == 1 ? "" : "s") no clip references will be permanently deleted.")
        }
    }

    private nonisolated static func integrity() throws -> String {
        let report = try ClipDatabase.shared.integrityCheck()
        return report.isHealthy ? "Database is healthy." : "\(report.problems.count) problem\(report.problems.count == 1 ? "" : "s") found."
    }

    private nonisolated static func vacuum() throws -> String {
        let report = try ClipDatabase.shared.vacuum()
        return "\(PaneFormat.bytes(report.bytesBefore)) \u{2192} \(PaneFormat.bytes(report.bytesAfter)), reclaimed \(PaneFormat.bytes(report.reclaimed))."
    }

    private func run(_ work: @escaping @Sendable () throws -> String, set: @escaping (String) -> Void) {
        busy = true
        Task {
            let text = await Task.detached { () -> String in
                do { return try work() } catch { return "Failed: \(error.localizedDescription)" }
            }.value
            set(text)
            busy = false
        }
    }

    private func describe(_ report: OrphanMediaReport) -> String {
        "\(report.orphanedFiles.count) orphaned (\(PaneFormat.bytes(report.orphanedBytes))), \(report.missingFiles.count) missing on disk."
    }

    private func scan() {
        busy = true
        Task {
            let report = await Task.detached { try? ClipDatabase.shared.orphanMediaReport() }.value
            busy = false
            guard let report else { orphanText = "Scan failed."; return }
            orphanCount = report.orphanedFiles.count
            orphanText = describe(report)
        }
    }

    private func sweep() {
        busy = true
        Task {
            let report = await Task.detached { try? ClipDatabase.shared.orphanMediaReport(remove: true) }.value
            busy = false
            orphanCount = 0
            orphanText = report.map { "Removed \($0.removedCount) file\($0.removedCount == 1 ? "" : "s")." } ?? "Sweep failed."
            notice = report == nil ? .failure("Media sweep failed.") : .success(orphanText ?? "Done.")
        }
    }
}
