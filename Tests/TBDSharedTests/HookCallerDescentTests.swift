import Foundation
import Testing

@testable import TBDShared

/// Whether a hook's caller descends from the tab it names, over literal
/// process tables. Nothing here reads the real kernel. Every can't-tell case
/// puts its caller where the same table would otherwise prove it foreign, so
/// the rule under test is the only thing standing between it and a refusal.
@Suite("Hook caller descent")
struct HookCallerDescentTests {
    private static let born = Date(timeIntervalSince1970: 1_800_000_000)

    /// A holder (20) and its job (21), beside a stranger (41) under a host
    /// (40) that launchd parents: a complete chain that never meets the job.
    private static let tab: [pid_t: pid_t] = [20: 1, 21: 20, 40: 1, 41: 40]

    private static func table(_ parents: [pid_t: pid_t]) -> ProcessTableSnapshot {
        ProcessTableSnapshot(entries: parents.mapValues {
            ProcessTableSnapshot.Entry(parent: $0, startedAt: born)
        })
    }

    private static func holderRow(
        transport: TerminalTransport = .holder, worktreeID: UUID = UUID(),
        holderPID: Int32, childPID: Int32, parked: Bool = false, kind: TerminalKind = .shell
    ) -> TBDShared.Terminal {
        TBDShared.Terminal(
            worktreeID: worktreeID, tmuxWindowID: "", tmuxPaneID: "", createdAt: born,
            kind: kind, hibernatedAt: parked ? born : nil,
            transport: transport, holderPID: holderPID, childPID: childPID)
    }

    /// The one-tab verdict. `rows` defaults to the named row alone.
    private static func verdict(
        peer: pid_t?, row: TBDShared.Terminal, rows: [TBDShared.Terminal]? = nil,
        processes: ProcessTableSnapshot?
    ) -> HookCallerVerdict {
        HookCallerDescent.verdict(
            peerPID: peer, terminal: row, allTerminals: rows ?? [row], processes: processes)
    }

    private static func verdict(
        peer: pid_t?, worktree: UUID, rows: [TBDShared.Terminal],
        processes: ProcessTableSnapshot?
    ) -> HookCallerVerdict {
        HookCallerDescent.verdict(
            peerPID: peer, worktreeID: worktree, allTerminals: rows, processes: processes)
    }

    // MARK: - One tab

    @Test func theJobItselfIsInsideAtDepthZero() {
        let row = Self.holderRow(holderPID: 20, childPID: 21)
        #expect(Self.verdict(peer: 21, row: row, processes: Self.table(Self.tab))
            == .inside(terminalID: row.id, depth: 0))
    }

    /// job → claude → sh → tbd, the shape a real hook arrives in.
    @Test func aHookBelowTheJobIsInside() {
        let row = Self.holderRow(holderPID: 20, childPID: 21)
        var parents = Self.tab
        parents[22] = 21
        parents[23] = 22
        parents[24] = 23
        #expect(Self.verdict(peer: 24, row: row, processes: Self.table(parents))
            == .inside(terminalID: row.id, depth: 3))
    }

    /// The named row is in `allTerminals` too, as it is in the daemon: a row
    /// never contests its own job.
    @Test func aCompleteChainThatMissesTheJobIsProvenForeign() {
        let row = Self.holderRow(holderPID: 20, childPID: 21)
        #expect(Self.verdict(peer: 41, row: row, processes: Self.table(Self.tab))
            == .provenForeign)
    }

    /// The shape the guard exists for: a process below another tab's job
    /// still naming this tab. That other job anchors, but only the named
    /// row's job answers the question.
    @Test func aCallerInAnotherTabIsProvenForeign() {
        let named = Self.holderRow(holderPID: 20, childPID: 21)
        let other = Self.holderRow(holderPID: 30, childPID: 31)
        let processes = Self.table([20: 1, 21: 20, 30: 1, 31: 30, 32: 31])
        let rows = [named, other]
        #expect(Self.verdict(peer: 32, row: other, rows: rows, processes: processes)
            == .inside(terminalID: other.id, depth: 1), "the caller is in the other tab")
        #expect(Self.verdict(peer: 32, row: named, rows: rows, processes: processes)
            == .provenForeign)
    }

    // MARK: - Can't tell

    @Test func noPeerPIDCannotTell() {
        let row = Self.holderRow(holderPID: 20, childPID: 21)
        #expect(Self.verdict(peer: nil, row: row, processes: Self.table(Self.tab))
            == .cannotTell(.noPeerPID))
    }

    @Test func anUnreadableTableCannotTell() {
        let row = Self.holderRow(holderPID: 20, childPID: 21)
        #expect(Self.verdict(peer: 41, row: row, processes: nil)
            == .cannotTell(.tableUnreadable))
    }

    /// This tmux row carries pids that would anchor on a holder row, so its
    /// transport alone keeps it from proving anything.
    @Test func aTmuxRowCannotTell() {
        let row = Self.holderRow(transport: .tmux, holderPID: 20, childPID: 21)
        #expect(Self.verdict(peer: 41, row: row, processes: Self.table(Self.tab))
            == .cannotTell(.rowCannotAnchor))
    }

    /// A parked row may be mid-wake, its new job already sending SessionStart
    /// before the row records it. Its stale pids would anchor here, so being
    /// parked alone keeps it from proving anything.
    @Test func aParkedRowCannotTell() {
        let row = Self.holderRow(holderPID: 20, childPID: 21, parked: true)
        #expect(Self.verdict(peer: 41, row: row, processes: Self.table(Self.tab))
            == .cannotTell(.rowCannotAnchor))
    }

    @Test func aJobOutsideTheStartWindowCannotTell() {
        let row = Self.holderRow(holderPID: 20, childPID: 21)
        var entries = Self.table(Self.tab).entries
        entries[21] = ProcessTableSnapshot.Entry(
            parent: 20,
            startedAt: Self.born.addingTimeInterval(HolderChildIdentity.startWindow + 1))
        #expect(Self.verdict(
            peer: 41, row: row, processes: ProcessTableSnapshot(entries: entries))
            == .cannotTell(.rowCannotAnchor))
    }

    /// The recorded job's pid is alive under launchd rather than the holder:
    /// a reused pid, or a job that outlived its holder.
    @Test func aJobThatIsNotTheHoldersChildCannotTell() {
        let row = Self.holderRow(holderPID: 20, childPID: 21)
        #expect(Self.verdict(
            peer: 41, row: row, processes: Self.table([20: 1, 21: 1, 40: 1, 41: 40]))
            == .cannotTell(.rowCannotAnchor))
    }

    @Test func aDeadHolderCannotTell() {
        let row = Self.holderRow(holderPID: 20, childPID: 21)
        #expect(Self.verdict(
            peer: 41, row: row, processes: Self.table([21: 20, 40: 1, 41: 40]))
            == .cannotTell(.rowCannotAnchor))
    }

    /// Two rows naming one job anchor nothing, so not even a caller below that
    /// job is inside.
    @Test func twoRowsNamingOneJobCannotTell() {
        let first = Self.holderRow(holderPID: 20, childPID: 21)
        let second = Self.holderRow(holderPID: 20, childPID: 21)
        var parents = Self.tab
        parents[22] = 21
        let processes = Self.table(parents)
        let rows = [first, second]
        #expect(Self.verdict(peer: 41, row: first, rows: rows, processes: processes)
            == .cannotTell(.contestedJob))
        #expect(Self.verdict(peer: 22, row: first, rows: rows, processes: processes)
            == .cannotTell(.contestedJob))
    }

    /// The caller's grandparent (39) has left the table, so the walk cannot
    /// say what lies above it.
    @Test func aChainCutShortCannotTell() {
        let row = Self.holderRow(holderPID: 20, childPID: 21)
        #expect(Self.verdict(
            peer: 41, row: row, processes: Self.table([20: 1, 21: 20, 40: 39, 41: 40]))
            == .cannotTell(.ancestryIncomplete))
    }

    @Test func aPeerTheTableDoesNotHoldCannotTell() {
        let row = Self.holderRow(holderPID: 20, childPID: 21)
        #expect(Self.verdict(peer: 99, row: row, processes: Self.table(Self.tab))
            == .cannotTell(.ancestryIncomplete))
    }

    /// A table read across a fork can briefly disagree with itself. A walk
    /// that meets a repeat ended without reaching launchd.
    @Test func aChainThatLoopsCannotTell() {
        let row = Self.holderRow(holderPID: 20, childPID: 21)
        #expect(Self.verdict(
            peer: 41, row: row, processes: Self.table([20: 1, 21: 20, 40: 41, 41: 40]))
            == .cannotTell(.ancestryIncomplete))
    }

    // MARK: - Codex tabs

    /// The anchoring row and complete foreign chain that prove foreign for a
    /// shell, on a Codex tab. Codex's shared server runs the tab's own hooks
    /// outside its tree, so the table cannot tell that session from a
    /// stranger. Fails against the code before the fix, which answered
    /// `.provenForeign`.
    @Test func aCodexTabCannotProveACallerForeign() {
        let row = Self.holderRow(holderPID: 20, childPID: 21, kind: .codex)
        #expect(Self.verdict(peer: 41, row: row, processes: Self.table(Self.tab))
            == .cannotTell(.codexTab))
    }

    /// Inside still comes first: a hook below a Codex tab's job is inside.
    /// Passes before the fix too; it fails against a Codex check placed
    /// ahead of the walk.
    @Test func aHookBelowACodexTabsJobIsInside() {
        let row = Self.holderRow(holderPID: 20, childPID: 21, kind: .codex)
        var parents = Self.tab
        parents[22] = 21
        #expect(Self.verdict(peer: 22, row: row, processes: Self.table(parents))
            == .inside(terminalID: row.id, depth: 1))
    }

    /// Both rows anchor and the chain misses both jobs, which proves foreign
    /// with the Claude row alone. Fails against the code before the fix,
    /// which answered `.provenForeign` with the Codex row beside it too.
    @Test func aWorktreeWithACodexTabCannotProveACallerForeign() {
        let worktree = UUID()
        let claude = Self.holderRow(worktreeID: worktree, holderPID: 20, childPID: 21, kind: .claude)
        let codex = Self.holderRow(worktreeID: worktree, holderPID: 30, childPID: 31, kind: .codex)
        let processes = Self.table([20: 1, 21: 20, 30: 1, 31: 30, 40: 1, 41: 40])
        #expect(Self.verdict(
            peer: 41, worktree: worktree, rows: [claude], processes: processes)
            == .provenForeign, "the control: the Claude row alone proves")
        #expect(Self.verdict(
            peer: 41, worktree: worktree, rows: [claude, codex], processes: processes)
            == .cannotTell(.codexTab))
    }

    // MARK: - A worktree

    /// Any row's job will do, and the nearest on the walk is the one reported.
    /// The tmux row beside them cannot anchor, and still does not keep a
    /// caller below a job that can from being inside.
    @Test func aCallerBelowAnyRowsJobIsInside() {
        let worktree = UUID()
        let first = Self.holderRow(worktreeID: worktree, holderPID: 20, childPID: 21)
        let second = Self.holderRow(worktreeID: worktree, holderPID: 30, childPID: 31)
        let tmux = Self.holderRow(
            transport: .tmux, worktreeID: worktree, holderPID: 50, childPID: 51)
        let processes = Self.table(
            [20: 1, 21: 20, 30: 1, 31: 30, 32: 31, 33: 32, 50: 1, 51: 50])
        #expect(Self.verdict(
            peer: 33, worktree: worktree, rows: [first, second, tmux], processes: processes)
            == .inside(terminalID: second.id, depth: 2))
    }

    @Test func everyUnparkedRowMustAnchorForProof() {
        let worktree = UUID()
        let holder = Self.holderRow(worktreeID: worktree, holderPID: 20, childPID: 21)
        let tmux = Self.holderRow(
            transport: .tmux, worktreeID: worktree, holderPID: 50, childPID: 51)
        let second = Self.holderRow(worktreeID: worktree, holderPID: 30, childPID: 31)
        let processes = Self.table(
            [20: 1, 21: 20, 30: 1, 31: 30, 40: 1, 41: 40, 50: 1, 51: 50])
        #expect(Self.verdict(
            peer: 41, worktree: worktree, rows: [holder, tmux], processes: processes)
            == .cannotTell(.rowCannotAnchor))
        #expect(Self.verdict(
            peer: 41, worktree: worktree, rows: [holder, second], processes: processes)
            == .provenForeign)
    }

    /// The other row naming this worktree row's job lives in another worktree;
    /// the job is contested all the same.
    @Test func aWorktreeRowWhoseJobAnotherRowNamesCannotTell() {
        let worktree = UUID()
        let mine = Self.holderRow(worktreeID: worktree, holderPID: 20, childPID: 21)
        let elsewhere = Self.holderRow(holderPID: 20, childPID: 21)
        #expect(Self.verdict(
            peer: 41, worktree: worktree, rows: [mine, elsewhere],
            processes: Self.table(Self.tab))
            == .cannotTell(.contestedJob))
    }

    /// This parked row's stale pids would anchor were it not parked.
    @Test func onlyParkedRowsCannotTell() {
        let worktree = UUID()
        let parked = Self.holderRow(
            worktreeID: worktree, holderPID: 20, childPID: 21, parked: true)
        #expect(Self.verdict(
            peer: 41, worktree: worktree, rows: [parked], processes: Self.table(Self.tab))
            == .cannotTell(.noUnparkedRow))
        #expect(Self.verdict(
            peer: 41, worktree: worktree, rows: [], processes: Self.table(Self.tab))
            == .cannotTell(.noUnparkedRow))
    }

    @Test func anotherWorktreesJobDoesNotCount() {
        let named = UUID()
        let other = UUID()
        let mine = Self.holderRow(worktreeID: named, holderPID: 20, childPID: 21)
        let theirs = Self.holderRow(worktreeID: other, holderPID: 30, childPID: 31)
        let processes = Self.table([20: 1, 21: 20, 30: 1, 31: 30, 32: 31])
        let rows = [mine, theirs]
        #expect(Self.verdict(peer: 32, worktree: other, rows: rows, processes: processes)
            == .inside(terminalID: theirs.id, depth: 1), "the caller is below the other worktree's job")
        #expect(Self.verdict(peer: 32, worktree: named, rows: rows, processes: processes)
            == .provenForeign)
    }

    @Test func aWorktreeQuestionWithoutAPeerOrATableCannotTell() {
        let worktree = UUID()
        let row = Self.holderRow(worktreeID: worktree, holderPID: 20, childPID: 21)
        #expect(Self.verdict(
            peer: nil, worktree: worktree, rows: [row], processes: Self.table(Self.tab))
            == .cannotTell(.noPeerPID))
        #expect(Self.verdict(peer: 41, worktree: worktree, rows: [row], processes: nil)
            == .cannotTell(.tableUnreadable))
    }
}
