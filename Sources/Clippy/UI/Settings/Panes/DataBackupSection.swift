import AppKit
import SwiftUI

/// Backups: create, copy to a folder, list, and restore with confirmation.
struct DataBackupSection: View {
    @Binding var notice: PaneNotice?
    @State private var snapshots: [BackupSnapshot] = []
    @State private var restore = RestoreConfirmationState()
    @State private var working = false

    /// Creates the section.
    init(notice: Binding<PaneNotice?>) { self._notice = notice }

    private var rows: [BackupRow] { BackupListModel.rows(from: snapshots) }

    var body: some View {
        PaneSection("Backup and restore", footer: "Restoring replaces the current history. Clippy first saves a backup of the current state so you can undo it.") {
            SettingsRow(title: "Create backup", detail: Text("Saved in Clippy's Backups folder.")) {
                HStack {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([ClipDatabase.shared.backupsDirectory])
                    } label: { Image(systemName: "folder") }
                        .help("Show the Backups folder in Finder")
                        .accessibilityLabel("Show Folder")
                    Button("Copy To\u{2026}") { chooseFolder() }.disabled(working)
                        .help("Create a backup and copy it to a folder you choose")
                    Button(working ? "Working\u{2026}" : "Back Up Now") { create(copyTo: nil) }
                        .buttonStyle(.borderedProminent).disabled(working)
                }
            }
            if rows.isEmpty {
                Divider()
                SettingsRow(title: "No backups yet") { EmptyView() }
            }
            ForEach(rows) { row in
                Divider()
                SettingsRow(title: LocalizedStringKey(row.title), detail: Text(row.sizeText)) {
                    HStack {
                        Button { delete(row.id) } label: { Image(systemName: "trash") }
                            .help("Delete this backup")
                            .accessibilityLabel("Delete")
                        Button("Restore\u{2026}") { restore.request(row.id) }.disabled(restore.isBusy)
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { restore.pendingID != nil }, set: { if !$0 { restore.cancel() } }),
                            titleVisibility: .visible) {
            Button("Restore", role: .destructive) { confirmRestore() }
            Button("Cancel", role: .cancel) { restore.cancel() }
        } message: {
            Text("The current history is replaced by the backup. A safety backup is taken first.")
        }
    }

    private func reload() { snapshots = ClipDatabase.shared.listBackups() }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        create(copyTo: url)
    }

    private func create(copyTo folder: URL?) {
        working = true
        Task {
            let result = await Task.detached { () -> Result<Void, Error> in
                Result {
                    let snapshot = try ClipDatabase.shared.createBackup()
                    if let folder {
                        try FileManager.default.copyItem(at: snapshot.url, to: folder.appendingPathComponent(snapshot.url.lastPathComponent))
                    }
                }
            }.value
            working = false
            reload()
            if case .failure = result { notice = .failure("Backup failed.") } else { notice = .success(folder == nil ? "Backup created." : "Backup created and copied.") }
        }
    }

    private func delete(_ id: String) {
        guard let snapshot = snapshots.first(where: { $0.id == id }) else { return }
        do { try ClipDatabase.shared.deleteBackup(snapshot); reload() } catch { notice = .failure("Could not delete the backup.") }
    }

    private func confirmRestore() {
        guard let snapshotID = restore.confirm(), let snapshot = snapshots.first(where: { $0.id == snapshotID }) else { restore.finish(error: "Backup not found."); return }
        Task {
            let error = await Task.detached { () -> String? in
                do { try ClipDatabase.shared.restoreBackup(snapshot); return nil } catch { return error.localizedDescription }
            }.value
            restore.finish(error: error)
            notice = error.map { .failure("Restore failed: \($0)") } ?? .success("Backup restored.")
            restore.acknowledge()
            reload()
        }
    }
}
