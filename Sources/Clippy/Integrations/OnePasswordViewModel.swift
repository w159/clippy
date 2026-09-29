import Foundation

/// What the 1Password pane is showing. Exactly one at a time, so the view can
/// never sit on an unexplained spinner (OPW-01).
enum OnePasswordViewState: Equatable {
    /// The `op` CLI is not installed.
    case notInstalled
    /// `op` is installed but has no authorized session; offer an `op signin` action.
    case needsSignIn(String)
    /// A list request is in flight (bounded by the load timeout).
    case loading
    /// The vault was read successfully and holds no items.
    case empty
    /// The request failed or timed out; the message is user-presentable.
    case error(String)
    /// Items are available.
    case ready
}

/// State machine behind `OnePasswordView`. Owns the list load and the per-item
/// detail load, cancels superseded tasks, and applies a result only while it is
/// still the current one (OPW-02). The `op` binary is reached through the
/// service's injectable runner, so tests script every transition.
@MainActor
final class OnePasswordViewModel: ObservableObject {
    @Published private(set) var state: OnePasswordViewState = .loading
    @Published private(set) var items: [OPItem] = []
    @Published private(set) var expandedItemID: String?
    @Published private(set) var detail: OPItemDetail?
    @Published private(set) var detailLoading = false
    @Published private(set) var detailError: String?
    /// True while an `op signin` request is running.
    @Published private(set) var signingIn = false

    /// Builds the service for the current vault setting, so a vault change takes
    /// effect on the next load without recreating the model.
    private let makeService: () -> OnePasswordService
    /// Re-probes whether `op` is installed. Injected so tests need no real CLI.
    private let probeInstalled: () -> Bool
    /// Upper bound for one list/detail request, on top of the subprocess timeout,
    /// so a runner that never returns still resolves to `.error`.
    private let deadline: TimeInterval

    private var loadTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    // Bumped whenever a load/detail is replaced; results carrying an older value are dropped.
    private var loadGeneration = 0
    private var detailGeneration = 0

    init(makeService: @escaping () -> OnePasswordService,
         probeInstalled: @escaping () -> Bool = { OnePasswordService.refreshInstalled() },
         deadline: TimeInterval = OnePasswordService.readTimeout + 5) {
        self.makeService = makeService
        self.probeInstalled = probeInstalled
        self.deadline = deadline
    }

    deinit {
        loadTask?.cancel()
        detailTask?.cancel()
    }

    // MARK: - List

    /// (Re)load the vault. Cancels any load and detail request in flight, re-probes
    /// the CLI, and collapses the expanded item.
    func reload() {
        loadTask?.cancel()
        cancelDetail()
        expandedItemID = nil
        loadGeneration += 1
        let generation = loadGeneration
        state = .loading

        guard probeInstalled() else {
            items = []
            state = .notInstalled
            return
        }

        let service = makeService()
        let limit = deadline
        loadTask = Task { [weak self] in
            let outcome: Result<[OPItem], Error>
            do {
                outcome = .success(try await Self.withDeadline(limit) { try await service.listItems() })
            } catch {
                outcome = .failure(error)
            }
            guard let self, !Task.isCancelled, generation == self.loadGeneration else { return }
            self.apply(outcome)
        }
    }

    private func apply(_ outcome: Result<[OPItem], Error>) {
        switch outcome {
        case .success(let fetched):
            items = fetched
            state = fetched.isEmpty ? .empty : .ready
        case .failure(let error):
            items = []
            state = Self.state(for: error)
        }
    }

    /// Map a service error to the pane state it should produce.
    static func state(for error: Error) -> OnePasswordViewState {
        switch error as? OnePasswordError {
        case .notInstalled:
            return .notInstalled
        case .notSignedIn(let detail):
            return .needsSignIn(detail)
        case .timedOut, .command, .none:
            return .error(error.localizedDescription)
        }
    }

    /// Run `op signin`, then reload on success. A failure surfaces as `.error`
    /// (or stays `.needsSignIn` when 1Password still reports no session).
    func signIn() {
        guard !signingIn else { return }
        signingIn = true
        let service = makeService()
        let limit = OnePasswordService.signInTimeout + 5
        Task { [weak self] in
            var failure: Error?
            do {
                try await Self.withDeadline(limit) { try await service.signIn() }
            } catch {
                failure = error
            }
            guard let self else { return }
            self.signingIn = false
            if let failure {
                self.state = Self.state(for: failure)
            } else {
                self.reload()
            }
        }
    }

    // MARK: - Detail

    /// Expand `item` (loading its fields) or collapse it when already expanded.
    func toggleExpand(_ item: OPItem) {
        if expandedItemID == item.id {
            collapse()
        } else {
            expand(item)
        }
    }

    /// Collapse and discard the detail so revealed values do not linger.
    func collapse() {
        cancelDetail()
        expandedItemID = nil
    }

    /// Re-request the expanded item's fields after a failure.
    func retryDetail() {
        guard let id = expandedItemID, let item = items.first(where: { $0.id == id }) else { return }
        expand(item)
    }

    private func expand(_ item: OPItem) {
        cancelDetail()
        expandedItemID = item.id
        detailGeneration += 1
        let generation = detailGeneration
        detailLoading = true

        let service = makeService()
        let limit = deadline
        detailTask = Task { [weak self] in
            let outcome: Result<OPItemDetail, Error>
            do {
                outcome = .success(try await Self.withDeadline(limit) {
                    try await service.fetchItemDetail(itemID: item.id)
                })
            } catch {
                outcome = .failure(error)
            }
            // A stale task never touches state, including `detailLoading`: the
            // replacement request owns it.
            guard let self, !Task.isCancelled, generation == self.detailGeneration else { return }
            self.detailLoading = false
            switch outcome {
            case .success(let fetched): self.detail = fetched
            case .failure(let error): self.detailError = error.localizedDescription
            }
        }
    }

    private func cancelDetail() {
        detailTask?.cancel()
        detailTask = nil
        detailGeneration += 1
        detail = nil
        detailError = nil
        detailLoading = false
    }

    // MARK: - Deadline

    /// Resolves exactly once, whichever side of the race gets there first.
    private final class Once {
        private let lock = NSLock()
        private var fired = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    /// Race `operation` against a timer. Throws `OnePasswordError.timedOut` when the
    /// timer wins, even if `operation` never returns and ignores cancellation (a
    /// task group would wait for it forever, which is the infinite spinner this
    /// type exists to prevent). The loser is cancelled.
    static func withDeadline<T: Sendable>(_ seconds: TimeInterval,
                                          _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = Once()
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                guard once.claim() else { return }
                continuation.resume(throwing: OnePasswordError.timedOut)
            }
            let work = Task {
                do {
                    let value = try await operation()
                    if once.claim() { timer.cancel(); continuation.resume(returning: value) }
                } catch {
                    if once.claim() { timer.cancel(); continuation.resume(throwing: error) }
                }
            }
            // The timer cannot cancel `work` from inside its own closure without
            // capturing it before it exists; chain the cancel here instead.
            Task {
                _ = await timer.result
                work.cancel()
            }
        }
    }
}
