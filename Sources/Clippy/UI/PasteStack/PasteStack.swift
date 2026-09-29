import Foundation
import SwiftUI

/// Which end `PasteStack.next()` takes from.
enum PasteStackOrder: String, CaseIterable, Identifiable {
    /// First in, first out (a queue): items paste in the order they were added.
    case fifo
    /// Last in, first out: the most recently added item pastes first.
    case lifo

    var id: String { rawValue }

    /// Picker label.
    var label: String { self == .fifo ? "In order (first copied first)" : "Reverse (last copied first)" }
}

/// Why a clip was not added to the stack. Messages never carry clip content.
enum PasteStackRefusal: Error, Equatable {
    /// The clip is flagged or detected as sensitive.
    case sensitive
    /// The stack holds `PasteStack.capacity` items already.
    case full
    /// The clip has no stored identity to paste from.
    case unsupported

    /// Short user-facing reason.
    var message: String {
        switch self {
        case .sensitive: return "Sensitive clips can't be added to the paste stack."
        case .full: return "The paste stack is full."
        case .unsupported: return "This clip can't be added to the paste stack."
        }
    }
}

/// One queued clip.
struct PasteStackItem: Identifiable, Equatable {
    let id = UUID()
    let clip: Clip

    static func == (lhs: PasteStackItem, rhs: PasteStackItem) -> Bool { lhs.id == rhs.id }
}

/// Ordered in-memory collection of clips for sequential paste (FEAT-06). Never
/// persisted: quitting the app clears it. Sensitive clips are refused. Mutate
/// from the main thread (it publishes to SwiftUI).
@MainActor
final class PasteStack: ObservableObject {
    /// The app-wide stack.
    static let shared = PasteStack()
    /// Maximum queued items.
    static let capacity = 50

    /// Items in stack order: index 0 is the oldest.
    @Published private(set) var items: [PasteStackItem] = []
    /// While true, every newly captured clip is appended (in addition to history).
    @Published var isCollecting = false
    /// Which end `next()` pops. Persisted via `AppendPreferences.stackOrder`.
    @Published var order: PasteStackOrder {
        didSet { AppendPreferences.stackOrder = order }
    }

    private let isSensitive: (Clip) -> Bool

    /// `isSensitive` is injectable for tests; the default is `SensitiveContent.isSensitive(clip:)`.
    init(order: PasteStackOrder = AppendPreferences.stackOrder,
         isSensitive: @escaping (Clip) -> Bool = { SensitiveContent.isSensitive(clip: $0) }) {
        self.order = order
        self.isSensitive = isSensitive
    }

    /// Number of queued items.
    var count: Int { items.count }

    /// The item `next()` would return, without removing it.
    var upcoming: PasteStackItem? { order == .fifo ? items.first : items.last }

    /// Index of `upcoming` within `items`, for highlighting.
    var upcomingIndex: Int? { items.isEmpty ? nil : (order == .fifo ? 0 : items.count - 1) }

    /// Appends `clip`, or reports why it was refused.
    @discardableResult
    func add(_ clip: Clip) -> Result<Int, PasteStackRefusal> {
        guard clip.id != nil else { return .failure(.unsupported) }
        guard !isSensitive(clip) else { return .failure(.sensitive) }
        guard items.count < Self.capacity else { return .failure(.full) }
        items.append(PasteStackItem(clip: clip))
        return .success(items.count)
    }

    /// Removes and returns the next item per `order`; nil when empty.
    @discardableResult
    func next() -> PasteStackItem? {
        guard !items.isEmpty else { return nil }
        return order == .fifo ? items.removeFirst() : items.removeLast()
    }

    /// Removes the item with `id`; returns whether it was present.
    @discardableResult
    func remove(id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items.remove(at: index)
        return true
    }

    /// Removes the items at `offsets`.
    func remove(atOffsets offsets: IndexSet) {
        items.remove(atOffsets: offsets)
    }

    /// Reorders like `List.onMove`.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    /// Empties the stack.
    func clear() {
        items.removeAll()
    }
}
