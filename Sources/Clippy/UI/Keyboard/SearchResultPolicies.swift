import Foundation

/// What the History pane lists. Browsing, it is the unfiled clips: filing a
/// clip moves it into its category like a file into a folder. Searching, it is
/// every match, filed or not, because a search typed into History is a search
/// of the whole history. Filed clips used to vanish from History results, so a
/// clip saved into any category could not be found from the main list at all.
enum HistoryPanePolicy {
    static func visible(_ clips: [Clip], query: String, isFiled: (Clip) -> Bool) -> [Clip] {
        isSearching(query) ? clips : clips.filter { !isFiled($0) }
    }

    /// The store treats a whitespace-only query as no query; so does the pane.
    static func isSearching(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Where the keyboard cursor lands when the visible list republishes.
///
/// After the query changes the cursor follows the best match (index 0) until
/// the user moves it. Before, the cursor stayed on whichever clip it was on if
/// that clip was anywhere in the new results, while the list scrolled to the
/// top: Return then pasted an off-screen clip instead of the top result.
/// Background pulses (a new capture, a pin) with an unchanged query keep the
/// cursor on the same clip.
enum ResultSelectionPolicy {
    ///
    /// `previousIndex` is where the cursor was. When the anchored clip is gone
    /// (deleted, filed away) the cursor lands on its neighbour, the same row
    /// clamped to the list, instead of jumping to row 0.
    static func index(in clips: [Clip], anchor: Int64?, followsTop: Bool, previousIndex: Int = 0) -> Int {
        guard !followsTop else { return 0 }
        if let anchor, let index = clips.firstIndex(where: { $0.id == anchor }) { return index }
        return max(0, min(previousIndex, clips.count - 1))
    }
}
