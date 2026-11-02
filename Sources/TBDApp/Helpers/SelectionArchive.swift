import Foundation
import TBDShared

/// Archiving a multi-row sidebar selection: the row menu's Archive Selection
/// and the archive shortcut. Pure, like `RowActionMenu`, so every decision is
/// unit-testable without an `AppState` or a daemon:
///
/// - `actsOnSelection` – whether a row's menu acts on the selection at all.
/// - `isArchivable` – whether one selected row can be archived.
/// - `childrenFirst` and `targets` – which rows run, and in what order.
/// - `route` – one row takes the single-row archive, prompts included;
///   several take the bulk run.
/// - `failureReason` and `summary` – the bulk run's one alert.
///
/// `AppState+SelectionArchive.swift` wires these to live state.
enum SelectionArchive {
    // MARK: - Selection mode

    /// Whether the menu for row `rowID` acts on the selection rather than on
    /// the row: the row is selected and the selection holds two or more rows.
    /// A right-click outside the selection, or on the only selected row, gets
    /// the row's own menu and leaves the selection alone.
    static func actsOnSelection(rowID: UUID, selectedIDs: Set<UUID>) -> Bool {
        selectedIDs.count >= 2 && selectedIDs.contains(rowID)
    }

    // MARK: - Eligibility

    /// One selected row's facts, as `isArchivable` reads them. Built by
    /// `RowActionMenuActions.archiveCandidate()` from the derivations the
    /// row's own menu uses, so the two read the same state.
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

    /// Whether a selected row can be archived along with the rest:
    ///
    /// - its status is not `.main`, `.creating` or `.archived`;
    /// - it is not a remote lane whose provider cannot archive it, by the rule
    ///   the row's own Archive uses (`RowActionMenu.missingArchiveCapability`);
    /// - every active child it has is selected too, so the run archives the
    ///   child first.
    ///
    /// A scratch row is archivable on the same terms; the run sends it to
    /// `scratch.archive`. The daemon stays the authority: a child it refuses
    /// leaves its parent refused as well, and both refusals are reported.
    static func isArchivable(_ candidate: Candidate, selectedIDs: Set<UUID>) -> Bool {
        if candidate.status == .main || candidate.status == .creating || candidate.status == .archived {
            return false
        }
        if RowActionMenu.missingArchiveCapability(
            location: candidate.location, isGone: candidate.isGone,
            providerRetired: candidate.providerRetired,
            providerCapabilities: candidate.providerCapabilities) {
            return false
        }
        return candidate.activeChildIDs.isSubset(of: selectedIDs)
    }

    // MARK: - Run order

    /// `rows`' IDs reordered so that every row comes after its descendants
    /// and the order is otherwise kept: a post-order walk of the forest the
    /// rows' parent links make. A row whose parent is not in `rows` is a root.
    /// Duplicates keep their first place. A row whose parent chain loops
    /// reaches no root and is walked from where it is listed, so every row
    /// comes back exactly once.
    static func childrenFirst(_ rows: [Worktree]) -> [UUID] {
        var listed = Set<UUID>()
        var order: [UUID] = []
        var parentOf: [UUID: UUID] = [:]
        for row in rows {
            guard listed.insert(row.id).inserted else { continue }
            order.append(row.id)
            if let parent = row.parentWorktreeID, parent != row.id {
                parentOf[row.id] = parent
            }
        }
        var childrenOf: [UUID: [UUID]] = [:]
        var roots: [UUID] = []
        for id in order {
            if let parent = parentOf[id], listed.contains(parent) {
                childrenOf[parent, default: []].append(id)
            } else {
                roots.append(id)
            }
        }

        var result: [UUID] = []
        var visited = Set<UUID>()
        // Iterative, so a deep or looping chain cannot exhaust the stack.
        for start in roots + order {
            var stack: [(id: UUID, childrenDone: Bool)] = [(start, false)]
            while let entry = stack.popLast() {
                if entry.childrenDone {
                    result.append(entry.id)
                    continue
                }
                guard visited.insert(entry.id).inserted else { continue }
                stack.append((entry.id, true))
                for child in (childrenOf[entry.id] ?? []).reversed() where !visited.contains(child) {
                    stack.append((child, false))
                }
            }
        }
        return result
    }

    /// The selection's archivable rows, in `runOrder`
    /// (`AppState.selectionArchiveRunOrder`: sidebar order, children before
    /// their parents). Rows that are not archivable are skipped and count for
    /// nothing. An archivable row `runOrder` does not list goes last, by ID,
    /// so the run is still deterministic.
    static func targets(_ candidates: [Candidate], selectedIDs: Set<UUID>, runOrder: [UUID]) -> [UUID] {
        let archivable = Set(candidates.filter { isArchivable($0, selectedIDs: selectedIDs) }.map(\.id))
        let ordered = runOrder.filter { archivable.contains($0) }
        let unlisted = archivable.subtracting(ordered).sorted { $0.uuidString < $1.uuidString }
        return ordered + unlisted
    }

    // MARK: - Routing

    /// What archiving a selection's targets does.
    enum Route: Equatable, Sendable {
        /// No archivable row: nothing happens.
        case nothing
        /// One archivable row: the single-row `archiveWorktree(id:)`, with its
        /// prompts, exactly as the row's own Archive.
        case single(UUID)
        /// Several: each is archived in turn with no prompt and no per-row
        /// alert, then one alert sums up any failures.
        case bulk([UUID])
    }

    static func route(_ targetIDs: [UUID]) -> Route {
        guard let only = targetIDs.first else { return .nothing }
        return targetIDs.count == 1 ? .single(only) : .bulk(targetIDs)
    }

    // MARK: - The summary alert

    /// A row the bulk run could not archive: its display name and why.
    struct Failure: Equatable {
        let name: String
        let reason: String
    }

    /// Why one archive failed, on one line: the daemon's refusal sentence for
    /// an RPC error, without the transport's "RPC error:" prefix, otherwise
    /// the error's description. A refusal that spans lines, such as the list
    /// of uncommitted changes, is joined into one so the summary keeps one
    /// line per worktree.
    static func failureReason(_ error: any Error) -> String {
        let text: String
        if case .rpcError(let refusal, _)? = error as? DaemonClientError {
            text = refusal
        } else {
            text = String(describing: error)
        }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The bulk run's one alert, shown only when something failed: how many
    /// rows were archived out of how many were attempted, then one line per
    /// failed worktree with its reason.
    static func summary(archived: Int, attempted: Int, failures: [Failure]) -> String {
        let noun = attempted == 1 ? "worktree" : "worktrees"
        let lines = failures.map { "\($0.name): \($0.reason)" }
        return (["Archived \(archived) of \(attempted) \(noun).", ""] + lines).joined(separator: "\n")
    }
}
