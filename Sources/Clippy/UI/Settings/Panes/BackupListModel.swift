import Foundation

/// Display row for one backup snapshot.
struct BackupRow: Equatable, Identifiable {
    let id: String
    let title: String
    let sizeText: String
    let createdAt: Date
}

/// Pure formatting and ordering for the backup list.
enum BackupListModel {
    /// Rows newest first; ties broken by id so ordering is deterministic.
    static func rows(from snapshots: [BackupSnapshot], formatter: (Date) -> String = defaultDate) -> [BackupRow] {
        snapshots
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id > $1.id }
            .map { BackupRow(id: $0.id, title: formatter($0.createdAt), sizeText: PaneFormat.bytes($0.databaseBytes), createdAt: $0.createdAt) }
    }

    /// Medium date + short time.
    static func defaultDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Restore flow: idle -> confirming(id) -> restoring(id) -> done/failed. Restore is never reachable without confirming.
struct RestoreConfirmationState: Equatable {
    /// Flow phase.
    enum Phase: Equatable {
        case idle
        case confirming(String)
        case restoring(String)
        case done(String)
        case failed(String)
    }

    /// Current phase.
    private(set) var phase: Phase = .idle

    /// Creates an idle state.
    init() {}

    /// User asked to restore a snapshot; only valid from idle/done/failed.
    mutating func request(_ id: String) {
        guard !isBusy else { return }
        phase = .confirming(id)
    }

    /// User cancelled the confirmation.
    mutating func cancel() {
        if case .confirming = phase { phase = .idle }
    }

    /// User confirmed. Returns the id to restore, or nil when nothing was awaiting confirmation.
    mutating func confirm() -> String? {
        guard case .confirming(let id) = phase else { return nil }
        phase = .restoring(id)
        return id
    }

    /// Restore finished.
    mutating func finish(error: String?) {
        guard case .restoring(let id) = phase else { return }
        phase = error.map { .failed($0) } ?? .done(id)
    }

    /// Returns to idle after the result was shown.
    mutating func acknowledge() {
        switch phase {
        case .done, .failed: phase = .idle
        default: break
        }
    }

    /// True while a confirmation is showing or a restore runs.
    var isBusy: Bool {
        switch phase {
        case .confirming, .restoring: return true
        default: return false
        }
    }

    /// Snapshot id awaiting confirmation, if any.
    var pendingID: String? {
        if case .confirming(let id) = phase { return id }
        return nil
    }
}
