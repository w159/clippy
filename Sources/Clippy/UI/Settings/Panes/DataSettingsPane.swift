import SwiftUI

/// Data settings: storage, backups, maintenance, import/export, OCR index, smart collections.
struct DataSettingsPane: View {
    @State private var notice: PaneNotice?

    /// Creates the pane.
    init() {}

    var body: some View {
        PaneScroll(title: "Data", notice: $notice) {
            DataStorageSection()
            DataBackupSection(notice: $notice)
            DataMaintenanceSection(notice: $notice)
            DataArchiveSection(notice: $notice)
            DataOCRIndexSection(notice: $notice)
            DataSmartCollectionsSection(notice: $notice)
        }
    }
}

#Preview("Data settings") {
    DataSettingsPane().frame(width: 640, height: 800)
}
