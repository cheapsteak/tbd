import Foundation
import TBDShared

/// Archiving a multi-row sidebar selection: the row menu's Archive Selection
/// and the archive shortcut. Pure, like `RowActionMenu`, so every decision is
/// unit-testable without an `AppState` or a daemon:
///
/// - `actsOnSelection` – whether a row's menu acts on the selection at all.
/// - `canArchiveItself` and `archivableIDs` – which selected rows can be
///   archived: each on its own facts, then bottom-up through their children.
/// - `targets` – which rows run, in the run order
///   `AppState.selectionArchiveRunOrder` takes from the sidebar's own walk.
/// - `route` – one row takes the single-row archive, prompts included;
///   several take the bulk run; none is refused.
/// - `BulkSchedule` and `maxConcurrentArchives` – which of the bulk run's
///   rows start, which are skipped, and how many calls run at once.
/// - `failureReason`, `nestedNotArchivedReason` and `summary` – the bulk
///   run's one alert.
///
/// `AppState+SelectionArchive.swift` wires these to live state.
enum SelectionArchive {
    // MARK: - Selection mode

    /// Whether the menu for row `rowID` acts on the selection rather than on
    /// the row: the row is selected, and two or more selected IDs resolve to
    /// a row (`resolves`, which the app answers with `findWorktree(id:)`). A
    /// stale ID, one whose row has gone, does not count, so a row selected
    /// with stale IDs alone gets its own menu, as does the only selected row.
    /// A right-click outside the selection gets the row's own menu too, and
    /// leaves the selection alone.
    ///
    /// Cheap, since it runs for every right-click: a row outside the
    /// selection, or a selection of fewer than two IDs, is answered without
    /// resolving any ID, and resolving stops at the second row found.
    static func actsOnSelection(
        rowID: UUID, selectedIDs: Set<UUID>, resolves: (UUID) -> Bool
    ) -> Bool {
        guard selectedIDs.count >= 2, selectedIDs.contains(rowID) else { return false }
        var resolved = 0
        for id in selectedIDs where resolves(id) {
            resolved += 1
            if resolved == 2 { return true }
        }
        return false
    }

    // MARK: - Eligibility

    /// One selected row's facts, as `canArchiveItself` and `archivableIDs`
    /// read them. Built by `RowActionMenuActions.archiveCandidate()` from the
    /// derivations the row's own menu uses, so the two read the same state.
    struct Candidate: Equatable {
        let id: UUID
        var status: WorktreeStatus
        var location: WorktreeLocation
        var providerCapabilities: Set<String>
        var isGone: Bool
        var providerRetired: Bool
        /// The row's active and creating children (`AppState.children(of:)`),
        /// the set the row menu's `hasActiveChildren` counts.
        var activeChildIDs: Set<UUID>

        init(id: UUID,
             status: WorktreeStatus = .active,
             location: WorktreeLocation = .local,
             providerCapabilities: Set<String> = [],
             isGone: Bool = false,
             providerRetired: Bool = false,
             activeChildIDs: Set<UUID> = []) {
            self.id = id
            self.status = status
            self.location = location
            self.providerCapabilities = providerCapabilities
            self.isGone = isGone
            self.providerRetired = providerRetired
            self.activeChildIDs = activeChildIDs
        }
    }

    /// Whether a selected row could be archived on its own facts, before its
    /// children are counted:
    ///
    /// - its status is not `.main`, `.creating` or `.archived`;
    /// - it is not a remote lane whose provider cannot archive it, by the rule
    ///   the row's own Archive uses (`RowActionMenu.missingArchiveCapability`).
    ///
    /// A scratch row qualifies on the same terms.
    static func canArchiveItself(_ candidate: Candidate) -> Bool {
        if candidate.status == .main || candidate.status == .creating || candidate.status == .archived {
            return false
        }
        return !RowActionMenu.missingArchiveCapability(
            location: candidate.location, isGone: candidate.isGone,
            providerRetired: candidate.providerRetired,
            providerCapabilities: candidate.providerCapabilities)
    }

    /// The candidates that can be archived with the selection, decided bottom
    /// up: a row qualifies when it can be archived on its own facts
    /// (`canArchiveItself`) and every active child it has qualifies too, so
    /// the run can archive the child first. The daemon refuses to archive a
    /// row while an active child remains, so a row is held back by any child
    /// that will not go: one outside the selection (it is no candidate), one
    /// still creating, a remote lane whose provider cannot archive it, or one
    /// held back by a child of its own.
    ///
    /// A parent chain that loops has no row in it that can go first, so none
    /// of its rows qualifies. The daemon stays the authority over the rows
    /// that do: one it refuses at run time holds back its ancestors in the
    /// bulk run (`AppState.archiveInBulk`).
    static func archivableIDs(_ candidates: [Candidate]) -> Set<UUID> {
        var archivable = Set<UUID>()
        var waiting = candidates.filter { canArchiveItself($0) }
        // Each pass admits the rows whose children have all been admitted,
        // so a chain is admitted from its deepest row up. A pass that admits
        // nothing leaves only rows held back, and ends the walk.
        while true {
            let ready = waiting.filter { $0.activeChildIDs.isSubset(of: archivable) }
            guard !ready.isEmpty else { break }
            archivable.formUnion(ready.map(\.id))
            waiting.removeAll { archivable.contains($0.id) }
        }
        return archivable
    }

    // MARK: - Run order

    /// The selection's archivable rows (`archivableIDs`), in `runOrder`
    /// (`AppState.selectionArchiveRunOrder`: sidebar order, children before
    /// their parents). Rows that are not archivable are skipped and count for
    /// nothing. `runOrder` lists every row a candidate can be built from, so
    /// a candidate it does not list cannot arise; if one did, it would not be
    /// a target.
    static func targets(_ candidates: [Candidate], runOrder: [UUID]) -> [UUID] {
        let archivable = archivableIDs(candidates)
        return runOrder.filter { archivable.contains($0) }
    }

    // MARK: - Routing

    /// What archiving the selection does: the archive shortcut's whole
    /// decision (`AppState.archiveShortcutRoute()`), and what the row menu's
    /// Archive Selection runs (`AppState.archiveSelection()`).
    enum Route: Equatable, Sendable {
        /// Nothing happens, and nothing sounds: the shortcut with no row
        /// selected, or with one selected row the single-row rule refuses
        /// (`AppState.archiveShortcutTarget`).
        case nothing
        /// A selection with nothing archivable in it: nothing is archived,
        /// and `AppState.refusalBeep` sounds, the macOS cue for a command
        /// that cannot run.
        case refuse
        /// One archivable row: the single-row `archiveWorktree(id:)`, with its
        /// prompts, exactly as the row's own Archive.
        case single(UUID)
        /// Several: the bulk run archives them with no prompt and no per-row
        /// alert, up to `maxConcurrentArchives` at once and each parent after
        /// its selected children, then one alert sums up any failures.
        case bulk([UUID])
    }

    /// The route for a selection's targets (`targets`): none is refused, one
    /// takes the single-row archive, and several take the bulk run.
    static func route(_ targetIDs: [UUID]) -> Route {
        guard let only = targetIDs.first else { return .refuse }
        return targetIDs.count == 1 ? .single(only) : .bulk(targetIDs)
    }

    // MARK: - The bulk run's schedule

    /// The most `worktree.archive` calls the bulk run has in flight at once.
    /// While a call waits for its reply it blocks a thread of the shared
    /// thread pool, which has one thread per core, so a larger number starves
    /// the rest of the app. Each call also opens its own connection to the
    /// daemon's socket, and on darwin a connect to a listener whose accept
    /// queue is full is refused at once, which the app would read as a lost
    /// daemon.
    static let maxConcurrentArchives = 4

    /// The bulk run's scheduling decisions (`AppState.archiveInBulk`): which
    /// rows may start now, which are skipped without a call, and what became
    /// of each. Built from the targets in run order with their parent IDs,
    /// and pure, so the rules below are testable without `AppState` or a
    /// daemon.
    ///
    /// - **A row's turn** comes once every target whose parent it is, and
    ///   that comes before it in the run order, has an outcome. Every outcome
    ///   a row depends on is then settled before it acts, as if the rows ran
    ///   one by one in run order. A row waits only for earlier rows, so a loop
    ///   in the parent links cannot deadlock the run.
    /// - **A row whose turn has come** is skipped when one of those children
    ///   was not archived, naming the first such child in run order, since
    ///   the daemon would refuse it for that active child. Otherwise it
    ///   starts, in run order, while fewer than `maxConcurrent` calls are in
    ///   flight. A skip makes no call, so it takes no slot.
    /// - **Outcomes.** A skipped row is not archived, so the hold passes on to
    ///   its own parent. A row that has left the state by its turn is
    ///   `.vanished`: it is not counted, and it holds back no parent.
    ///
    /// The driver answers every turn: `begin` for a start, `record` for a
    /// skip or a vanished row, and `record` again when a started call ends.
    /// A turn left unanswered is offered again.
    struct BulkSchedule {
        /// One target: its ID and its parent's, if it has one.
        struct Target: Equatable, Sendable {
            let id: UUID
            let parentID: UUID?
        }

        /// What became of a row.
        enum Outcome: Equatable, Sendable {
            case archived
            /// Its call failed, or it was skipped. `name` is the row's display
            /// name, which the reason for skipping its parent gives.
            case notArchived(name: String)
            /// It had left the state by its turn.
            case vanished
        }

        /// What to do next with one row.
        enum Turn: Equatable, Sendable {
            /// Send its archive call.
            case start(UUID)
            /// Skip it without a call: its nested worktree `nestedName` was
            /// not archived.
            case skip(UUID, nestedName: String)

            var id: UUID {
                switch self {
                case .start(let id), .skip(let id, _): id
                }
            }
        }

        let maxConcurrent: Int
        /// The targets' IDs in run order. An ID listed twice is kept at its
        /// first place.
        let order: [UUID]
        /// Each target's children among the targets before it in run order,
        /// in run order. Its turn waits for these alone.
        private let earlierChildren: [UUID: [UUID]]
        /// The rows whose call has started and not yet ended.
        private(set) var inFlight: Set<UUID> = []
        private(set) var outcomes: [UUID: Outcome] = [:]

        init(_ targets: [Target], maxConcurrent: Int = SelectionArchive.maxConcurrentArchives) {
            self.maxConcurrent = maxConcurrent
            var seen = Set<UUID>()
            var order: [UUID] = []
            var earlierChildren: [UUID: [UUID]] = [:]
            for target in targets where seen.insert(target.id).inserted {
                order.append(target.id)
                // A parent not seen yet comes later in run order, so it
                // waits for this row. One seen already, or the row itself,
                // comes no later and does not wait for it.
                if let parentID = target.parentID, !seen.contains(parentID) {
                    earlierChildren[parentID, default: []].append(target.id)
                }
            }
            self.order = order
            self.earlierChildren = earlierChildren
        }

        /// Whether every row has an outcome.
        var isFinished: Bool { outcomes.count == order.count }

        /// The rows that have neither started nor got an outcome, in run
        /// order: what a run that stops starting rows leaves not attempted.
        var unstarted: [UUID] {
            order.filter { outcomes[$0] == nil && !inFlight.contains($0) }
        }

        /// Whether `id`'s turn can come: each of its children before it in
        /// run order has an outcome.
        func isReady(_ id: UUID) -> Bool {
            earlierChildren[id, default: []].allSatisfy { outcomes[$0] != nil }
        }

        /// The display name of the first of `id`'s children before it in run
        /// order that was not archived, or nil when none was.
        private func nestedNotArchived(_ id: UUID) -> String? {
            for child in earlierChildren[id, default: []] {
                if case .notArchived(let name)? = outcomes[child] { return name }
            }
            return nil
        }

        /// The next turn: the first row of `unstarted` that is ready
        /// (`isReady`) and can act now. A row a child held back
        /// (`nestedNotArchived`) can always act, as a skip; any other row only
        /// while a slot is free, as a start. Nil when no row can act until a
        /// call in flight ends, or when none is left.
        func nextTurn() -> Turn? {
            let slotFree = inFlight.count < maxConcurrent
            for id in unstarted where isReady(id) {
                if let nestedName = nestedNotArchived(id) {
                    return .skip(id, nestedName: nestedName)
                }
                if slotFree { return .start(id) }
            }
            return nil
        }

        /// `id`'s call has started.
        mutating func begin(_ id: UUID) {
            inFlight.insert(id)
        }

        /// What became of `id`: its call ended, or it was skipped or found
        /// gone at its turn.
        mutating func record(_ id: UUID, _ outcome: Outcome) {
            inFlight.remove(id)
            outcomes[id] = outcome
        }
    }

    // MARK: - The summary alert

    /// A row the bulk run could not archive: its display name and why.
    struct Failure: Equatable {
        let name: String
        let reason: String
    }

    /// The most characters one failure's reason keeps; a longer one is cut
    /// to end in "…" at this length.
    static let reasonCharacterLimit = 200

    /// The most failures the summary lists by name before one line counts
    /// the rest.
    static let summaryFailureLineLimit = 10

    /// Why one archive failed, on one short line: the first non-empty line of
    /// the daemon's refusal for an RPC error, without the transport's "RPC
    /// error:" prefix, otherwise of the error's description.
    ///
    /// The first line is the one that says what is wrong. The uncommitted
    /// changes refusal, for one, opens with "<name> has N uncommitted
    /// change(s) that archiving would delete:" and then lists the files; the
    /// list is left out, and the colon that introduced it becomes a full
    /// stop. A line longer than `reasonCharacterLimit` is cut to end in "…".
    static func failureReason(_ error: any Error) -> String {
        let text: String
        if case .rpcError(let refusal, _)? = error as? DaemonClientError {
            text = refusal
        } else {
            text = String(describing: error)
        }
        var line = text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        if line.hasSuffix(":") {
            line = String(line.dropLast()) + "."
        }
        guard line.count > reasonCharacterLimit else { return line }
        return line.prefix(reasonCharacterLimit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Why the bulk run skipped a row without asking the daemon: a nested
    /// worktree of it, named `nestedName`, was not archived, so the daemon
    /// would refuse the row for its active child.
    static func nestedNotArchivedReason(_ nestedName: String) -> String {
        "Not archived, because its nested worktree \"\(nestedName)\" was not archived."
    }

    /// The bulk run's one alert, shown only when something failed: how many
    /// rows were archived out of the `total` the run covered, then one line
    /// per failed or skipped worktree with its reason, up to
    /// `summaryFailureLineLimit` of them and then one line counting the rest.
    /// `notAttempted` counts the rows the run never started because it lost
    /// the connection to the daemon, the one thing that stops it early; they
    /// share one closing line rather than one each.
    static func summary(archived: Int, total: Int, failures: [Failure], notAttempted: Int = 0) -> String {
        let noun = total == 1 ? "worktree" : "worktrees"
        var lines = failures.prefix(summaryFailureLineLimit).map { "\($0.name): \($0.reason)" }
        if failures.count > summaryFailureLineLimit {
            lines.append("…and \(failures.count - summaryFailureLineLimit) more.")
        }
        if notAttempted > 0 {
            lines.append("\(notAttempted) more not attempted: lost the connection to the daemon.")
        }
        return (["Archived \(archived) of \(total) \(noun).", ""] + lines).joined(separator: "\n")
    }
}
