import Foundation

/// Why `HookCallerDescent` could not settle where a hook's caller sits. Each
/// one accepts the event; the reason is there to be logged.
public enum HookCallerUncertainty: String, Sendable, Equatable {
    /// The connection carried no peer pid.
    case noPeerPID
    /// The process table could not be read.
    case tableUnreadable
    /// A row the answer rests on cannot anchor a walk: a tmux row, a parked
    /// row, a dead holder, a job that is no longer its holder's child, or a job
    /// that started outside the window.
    case rowCannotAnchor
    /// A row the answer rests on names a live job that another row names too.
    case contestedJob
    /// The worktree has no row that is not parked, so it has no job to descend
    /// from.
    case noUnparkedRow
    /// The caller's ancestry stops short of launchd: the caller or an ancestor
    /// is missing from the table, the walk met a repeat, or it reached
    /// `ProcessTableSnapshot.maximumDepth`.
    case ancestryIncomplete
    /// A row the answer rests on is a Codex tab, and the caller is not inside
    /// it. Codex's TUI hosts its sessions in a shared background server
    /// unless started with `--no-daemon`, and that server runs hooks with the
    /// environment of whichever tab started it (herdrdev/herdr#4649). So a
    /// hook for the tab's own session can come from outside the tab's tree,
    /// and the process table cannot tell it from a stranger's.
    case codexTab
}

/// What the process tree says about a hook's caller and the tab it names.
public enum HookCallerVerdict: Sendable, Equatable {
    /// The caller is a named row's live job or descends from it. `depth`
    /// counts the hops from the job down to the caller: 0 when the caller is
    /// the job itself.
    case inside(terminalID: UUID, depth: Int)
    /// The caller's whole ancestry reaches launchd without passing through any
    /// job the question names, and every row it rests on could anchor a walk
    /// and is not a Codex tab. The only answer that refuses.
    case provenForeign
    /// Anything short of proof either way.
    case cannotTell(HookCallerUncertainty)
}

/// Whether the process that sent a hook's RPC descends from the tab the hook
/// names.
///
/// A hook learns its tab from `TBD_TERMINAL_ID` or `TBD_WORKTREE_ID` in its
/// own environment, and an environment is inherited: a process that has left
/// the tab's tree — a session hosted by a background daemon, an agent
/// `nohup`'d from an earlier job — still carries the tab's markers and still
/// names the tab. The caller's pid, by contrast, comes from the kernel
/// (`LOCAL_PEERPID`) and cannot be forged, so the process tree above it is
/// what this verdict reads.
///
/// **A different question from `HolderDescentIndex`'s.** The index answers
/// "which tab is this process in?", so it never consults an environment
/// variable: a forged one would hand one tab's identity to another process.
/// This verdict starts from the environment's claim — the row or worktree the
/// hook named — and only tests it, against the process tree and nothing else.
/// The claim chooses which job to look for; it never stands in for finding it.
/// The rules for when a row may anchor a walk are the index's own
/// (`HolderDescentIndex.liveJob`), and so is the rule that a job two rows name
/// anchors nothing.
///
/// **Only proof refuses.** A hook event is an input, and refusing a real one —
/// a SessionStart from a tab whose row has not yet recorded its woken job —
/// leaves the tab on the wrong session, which costs more than accepting a
/// stray. So the answer is `.provenForeign` only when the caller's ancestry
/// reached launchd without meeting a job, and every row the question rests on
/// could anchor. Everything short of that is `.cannotTell`, with its reason.
///
/// **Inside wins.** A caller whose ancestry contains an anchoring job is inside
/// however incomplete the rest of the picture is: the job was seen, and seeing
/// it is all that accepting needs.
///
/// **A Codex tab never proves foreign.** Codex's TUI hosts its sessions in a
/// shared background server unless started with `--no-daemon`, and that
/// server runs hooks with the environment of whichever tab started it
/// (herdrdev/herdr#4649). A hook for the tab's own session can then come from
/// outside the tab's tree, so where the table would prove a caller foreign to
/// a Codex tab, the answer is `.codexTab` instead. A caller inside one is
/// still inside.
///
/// A view, like the index: it reads the rows and the table it was given and
/// writes nothing.
public enum HookCallerDescent {
    /// Whether `peerPID` is `terminal`'s live job or descends from it. A
    /// caller outside a Codex row is never `.provenForeign`.
    ///
    /// `allTerminals` is every row the daemon holds, and is read only to find
    /// another row naming `terminal`'s job. `terminal` may be among them or
    /// not; a row is never contested by itself.
    public static func verdict(
        peerPID: pid_t?, terminal: Terminal, allTerminals: [Terminal],
        processes: ProcessTableSnapshot?,
        startWindow: TimeInterval = HolderChildIdentity.startWindow
    ) -> HookCallerVerdict {
        guard let peerPID else { return .cannotTell(.noPeerPID) }
        guard let processes else { return .cannotTell(.tableUnreadable) }
        let claims = HookCallerJobClaims(
            rows: allTerminals, processes: processes, startWindow: startWindow)
        let ancestry = processes.ancestry(of: peerPID)
        switch claims.anchor(of: terminal) {
        case .cannotAnchor:
            return .cannotTell(.rowCannotAnchor)
        case .contested:
            return .cannotTell(.contestedJob)
        case .job(let job):
            if let depth = ancestry.firstIndex(of: job) {
                return .inside(terminalID: terminal.id, depth: depth)
            }
            // Its own session's hooks may run in Codex's shared server,
            // outside this tree.
            if terminal.isCodexTerminal { return .cannotTell(.codexTab) }
            return foreignWhenComplete(ancestry, in: processes)
        }
    }

    /// Whether `peerPID` descends from the live job of any row in
    /// `worktreeID`, for a call that names a worktree rather than a tab.
    ///
    /// Inside when the caller descends from any of the worktree's jobs; the
    /// nearest one on the walk up is the one reported. Proven foreign only when
    /// the worktree has at least one row that is not parked, every such row can
    /// anchor a walk, none of them is a Codex tab, and the caller's complete
    /// ancestry meets none of their jobs. Parked rows name no process and are
    /// left out; a worktree with no other row is `.noUnparkedRow`, for the
    /// same reason a parked row cannot anchor.
    public static func verdict(
        peerPID: pid_t?, worktreeID: UUID, allTerminals: [Terminal],
        processes: ProcessTableSnapshot?,
        startWindow: TimeInterval = HolderChildIdentity.startWindow
    ) -> HookCallerVerdict {
        guard let peerPID else { return .cannotTell(.noPeerPID) }
        guard let processes else { return .cannotTell(.tableUnreadable) }
        let claims = HookCallerJobClaims(
            rows: allTerminals, processes: processes, startWindow: startWindow)
        let unparked = allTerminals.filter { $0.worktreeID == worktreeID && !$0.isParked }
        let anchors = unparked.map { (terminalID: $0.id, anchor: claims.anchor(of: $0)) }
        var rowByJob: [pid_t: UUID] = [:]
        for row in anchors {
            if case .job(let job) = row.anchor { rowByJob[job] = row.terminalID }
        }
        let ancestry = processes.ancestry(of: peerPID)
        for (depth, pid) in ancestry.enumerated() {
            if let terminalID = rowByJob[pid] {
                return .inside(terminalID: terminalID, depth: depth)
            }
        }
        guard !anchors.isEmpty else { return .cannotTell(.noUnparkedRow) }
        if anchors.contains(where: { $0.anchor == .cannotAnchor }) {
            return .cannotTell(.rowCannotAnchor)
        }
        if anchors.contains(where: { $0.anchor == .contested }) {
            return .cannotTell(.contestedJob)
        }
        // A Codex tab's own hooks may run in Codex's shared server, outside
        // every tab's tree, so the caller could be that tab's session.
        if unparked.contains(where: \.isCodexTerminal) {
            return .cannotTell(.codexTab)
        }
        return foreignWhenComplete(ancestry, in: processes)
    }

    /// Proven foreign when `ancestry` reached launchd, else can't tell.
    ///
    /// `ancestry(of:)` stops at a pid the table does not hold, at a repeat and
    /// at `ProcessTableSnapshot.maximumDepth`, and each of those leaves its
    /// last element with a parent above launchd; a pid the table does not hold
    /// at all leaves it empty. Only a walk that ended because it reached
    /// launchd has seen every ancestor, so only that walk can say the job is
    /// not among them.
    private static func foreignWhenComplete(
        _ ancestry: [pid_t], in processes: ProcessTableSnapshot
    ) -> HookCallerVerdict {
        guard let last = ancestry.last, let parent = processes.parent(of: last), parent <= 1
        else { return .cannotTell(.ancestryIncomplete) }
        return .provenForeign
    }
}

/// What one row contributes to a hook caller's walk.
private enum HookCallerRowAnchor: Equatable {
    /// The row's live job, which no other row names.
    case job(pid_t)
    /// `HolderDescentIndex.liveJob` refuses the row.
    case cannotAnchor
    /// The row's live job is one another row names too. Two rows naming one
    /// job cannot both be right, and nothing here can say which is, so the job
    /// anchors nothing — the rule `HolderDescentIndex` applies.
    case contested
}

/// Which rows name each live job, read once per verdict.
private struct HookCallerJobClaims {
    let processes: ProcessTableSnapshot
    let startWindow: TimeInterval
    /// Row IDs rather than a count, so the same row listed twice, or a row
    /// asked about that is also in the list, never contests itself.
    let rowsByJob: [pid_t: Set<UUID>]

    init(rows: [Terminal], processes: ProcessTableSnapshot, startWindow: TimeInterval) {
        var rowsByJob: [pid_t: Set<UUID>] = [:]
        for row in rows {
            guard let job = HolderDescentIndex.liveJob(
                of: row, in: processes, startWindow: startWindow)
            else { continue }
            rowsByJob[job, default: []].insert(row.id)
        }
        self.processes = processes
        self.startWindow = startWindow
        self.rowsByJob = rowsByJob
    }

    func anchor(of row: Terminal) -> HookCallerRowAnchor {
        guard let job = HolderDescentIndex.liveJob(
            of: row, in: processes, startWindow: startWindow)
        else { return .cannotAnchor }
        let others = (rowsByJob[job] ?? []).contains { $0 != row.id }
        return others ? .contested : .job(job)
    }
}
