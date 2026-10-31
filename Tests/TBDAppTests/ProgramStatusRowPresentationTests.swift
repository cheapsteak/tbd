import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1: pure functions and in-memory AppState mutation; no daemon, no sleeps.

/// The sidebar row's reading of Program Status Protocol (OSC 7501) snapshots:
/// which snapshots speak for a terminal, the badge tooltip text, and the
/// app-side snapshot mirror.
/// Design: `docs/specs/2026-10-10-program-status-protocol-design.md`, "UI".
@Suite("ProgramStatusRowPresentation")
struct ProgramStatusRowPresentationTests {

    // MARK: - Fixtures

    private static let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private static func terminal(
        id: UUID = UUID(),
        label: String? = nil,
        incarnation: UUID?,
        kind: TerminalKind? = .claude,
        parked: Bool = false
    ) -> TBDShared.Terminal {
        TBDShared.Terminal(
            id: id,
            worktreeID: UUID(),
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: label,
            sessionIncarnationID: incarnation,
            kind: kind,
            hibernatedAt: parked ? observedAt : nil,
            transport: .holder
        )
    }

    private static func entry(
        _ state: ProgramStatusState,
        kind: ProgramStatusBlockKind? = nil,
        title: String? = nil,
        msg: String? = nil,
        progress: Int? = nil
    ) -> ProgramStatusEntry {
        ProgramStatusEntry(
            state: state, kind: kind, title: title, msg: msg, progress: progress,
            observedAt: observedAt)
    }

    private static func snapshot(
        terminalID: UUID = UUID(),
        incarnation: UUID?,
        main: ProgramStatusEntry?,
        tasks: [ProgramStatusTaskEntry] = [],
        revision: UInt64 = 1
    ) -> ProgramStatusSnapshot {
        ProgramStatusSnapshot(
            terminalID: terminalID, incarnationID: incarnation, main: main,
            tasks: tasks, revision: revision)
    }

    // MARK: - resolution(...)

    @Test func resolvesWhenUnparkedAndSameIncarnation() throws {
        let incarnation = UUID()
        let t = Self.terminal(incarnation: incarnation)
        let s = Self.snapshot(terminalID: t.id, incarnation: incarnation, main: Self.entry(.done))
        let r = try #require(ProgramStatusRowPresentation.resolution(terminal: t, snapshot: s))
        #expect(r.value == .done)
    }

    @Test func nilWhenNoSnapshot() {
        let t = Self.terminal(incarnation: UUID())
        #expect(ProgramStatusRowPresentation.resolution(terminal: t, snapshot: nil) == nil)
    }

    @Test func nilWhenParked() {
        let incarnation = UUID()
        let t = Self.terminal(incarnation: incarnation, parked: true)
        let s = Self.snapshot(terminalID: t.id, incarnation: incarnation, main: Self.entry(.working))
        #expect(ProgramStatusRowPresentation.resolution(terminal: t, snapshot: s) == nil)
    }

    @Test func nilWhenIncarnationsDiffer() {
        let t = Self.terminal(incarnation: UUID())
        let s = Self.snapshot(terminalID: t.id, incarnation: UUID(), main: Self.entry(.working))
        #expect(ProgramStatusRowPresentation.resolution(terminal: t, snapshot: s) == nil)
    }

    @Test func nilWhenNoMainEntry() {
        let incarnation = UUID()
        let t = Self.terminal(incarnation: incarnation)
        let task = ProgramStatusTaskEntry(id: "t1", entry: Self.entry(.working))
        let s = Self.snapshot(terminalID: t.id, incarnation: incarnation, main: nil, tasks: [task])
        #expect(ProgramStatusRowPresentation.resolution(terminal: t, snapshot: s) == nil)
    }

    @Test func mapsErrorNeedsAuthAndWorkingTaskCount() throws {
        let incarnation = UUID()
        let t = Self.terminal(incarnation: incarnation)

        let failed = Self.snapshot(terminalID: t.id, incarnation: incarnation, main: Self.entry(.error))
        #expect(ProgramStatusRowPresentation.resolution(terminal: t, snapshot: failed)?.value == .error)

        let auth = Self.snapshot(
            terminalID: t.id, incarnation: incarnation, main: Self.entry(.blocked, kind: .auth))
        #expect(ProgramStatusRowPresentation.resolution(terminal: t, snapshot: auth)?.value == .needsAuth)

        let busy = Self.snapshot(
            terminalID: t.id, incarnation: incarnation, main: Self.entry(.working),
            tasks: [
                ProgramStatusTaskEntry(id: "a", entry: Self.entry(.working)),
                ProgramStatusTaskEntry(id: "b", entry: Self.entry(.working)),
                ProgramStatusTaskEntry(id: "c", entry: Self.entry(.done)),
            ])
        let r = try #require(ProgramStatusRowPresentation.resolution(terminal: t, snapshot: busy))
        #expect(r.value == .working)
        #expect(r.workingTaskCount == 2)
    }

    // MARK: - tooltip(...)

    @Test func tooltipIsNilForAnEmptyList() {
        #expect(ProgramStatusRowPresentation.tooltip(terminals: []) == nil)
    }

    @Test func tooltipSkipsNonAuthoritativeSnapshots() {
        let s = Self.snapshot(
            incarnation: nil, main: nil,
            tasks: [ProgramStatusTaskEntry(id: "a", entry: Self.entry(.working))])
        #expect(ProgramStatusRowPresentation.tooltip(terminals: [(label: "Claude", snapshot: s)]) == nil)
    }

    @Test func tooltipMainLineWithTitleAndProgress() {
        let s = Self.snapshot(
            incarnation: nil, main: Self.entry(.working, title: "Refactoring", progress: 40))
        #expect(ProgramStatusRowPresentation.tooltip(terminals: [(label: "Claude", snapshot: s)])
            == "Claude: working — Refactoring (40%)")
    }

    @Test func tooltipMainLineAloneWhenNoTitleProgressOrMsg() {
        let s = Self.snapshot(incarnation: nil, main: Self.entry(.done))
        #expect(ProgramStatusRowPresentation.tooltip(terminals: [(label: "Claude", snapshot: s)])
            == "Claude: done")
    }

    @Test func tooltipMsgAndTaskLines() {
        let s = Self.snapshot(
            incarnation: nil,
            main: Self.entry(.error, msg: "Build failed"),
            tasks: [
                ProgramStatusTaskEntry(id: "t1", entry: Self.entry(.working, title: "Run tests", msg: "12 of 40")),
                ProgramStatusTaskEntry(id: "t2", entry: Self.entry(.done)),
            ])
        let expected = """
            Claude: error
            Build failed
              • Run tests: working — 12 of 40
              • t2: done
            """
        #expect(ProgramStatusRowPresentation.tooltip(terminals: [(label: "Claude", snapshot: s)]) == expected)
    }

    @Test func tooltipSeparatesTerminalsWithABlankLine() {
        let a = Self.snapshot(incarnation: nil, main: Self.entry(.done))
        let b = Self.snapshot(incarnation: nil, main: Self.entry(.blocked, kind: .auth))
        let text = ProgramStatusRowPresentation.tooltip(terminals: [
            (label: "Claude", snapshot: a),
            (label: "Reviewer", snapshot: b),
        ])
        #expect(text == "Claude: done\n\nReviewer: needs sign-in")
    }

    @Test func tooltipLabelFallsBackToClaude() {
        #expect(ProgramStatusRowPresentation.tooltipLabel(for: Self.terminal(incarnation: nil)) == "Claude")
        #expect(ProgramStatusRowPresentation.tooltipLabel(
            for: Self.terminal(label: "Reviewer", incarnation: nil)) == "Reviewer")
    }

    @Test func unlabeledCodexFallsBackToCodex() {
        #expect(ProgramStatusRowPresentation.tooltipLabel(
            for: Self.terminal(incarnation: nil, kind: .codex)) == "Codex")
        // A legacy no-kind row is Claude unless its label says Codex, and a
        // label of its own wins either way.
        #expect(ProgramStatusRowPresentation.tooltipLabel(
            for: Self.terminal(incarnation: nil, kind: nil)) == "Claude")
        #expect(ProgramStatusRowPresentation.tooltipLabel(
            for: Self.terminal(label: "Reviewer", incarnation: nil, kind: .codex)) == "Reviewer")
    }

    /// A Codex snapshot has a main entry and nothing else — no task entries,
    /// no title, msg or progress — so its tooltip is the one head line.
    @Test func codexTooltipIsOneLine() {
        let t = Self.terminal(incarnation: nil, kind: .codex)
        let s = Self.snapshot(terminalID: t.id, incarnation: nil, main: Self.entry(.done))
        let text = ProgramStatusRowPresentation.tooltip(terminals: [
            (label: ProgramStatusRowPresentation.tooltipLabel(for: t), snapshot: s),
        ])
        #expect(text == "Codex: done")
    }

    // MARK: - Badge help

    @Test func badgeHelpUsesTheOSCTooltipWhenItDescribesTheSelectedBadge() {
        let help = ProgramStatusRowPresentation.badgeHelp(
            selected: .working, oscTooltip: "Claude: working",
            resolvedValues: [.working], genericHelp: "Agent is working")
        #expect(help == "Claude: working")
    }

    /// An unread error notification wins the badge while OSC says working:
    /// the badge keeps its own help rather than a tooltip about working.
    @Test func badgeHelpKeepsTheGenericHelpWhenAnotherSignalSelectedTheBadge() {
        let help = ProgramStatusRowPresentation.badgeHelp(
            selected: .error, oscTooltip: "Claude: working",
            resolvedValues: [.working], genericHelp: "Error")
        #expect(help == "Error")
    }

    @Test func badgeHelpKeepsTheGenericHelpWithoutAnOSCTooltip() {
        let help = ProgramStatusRowPresentation.badgeHelp(
            selected: .working, oscTooltip: nil,
            resolvedValues: [], genericHelp: "Agent is working")
        #expect(help == "Agent is working")
    }

    @Test func badgeHelpMatchesAnyOSCTerminalNotOnlyTheFirst() {
        let help = ProgramStatusRowPresentation.badgeHelp(
            selected: .turnFailed, oscTooltip: "both",
            resolvedValues: [.idle, .error], genericHelp: "The last turn failed")
        #expect(help == "both")
    }

    /// A done session shows exactly like an idle one: no suffix. The bold
    /// name already marks a finished turn the user has not read, and done
    /// stays set until the next turn, so a badge would sit on nearly every
    /// waiting row.
    @Test func doneSelectsNoSuffixLikeIdle() {
        #expect(ProgramStatusRowPresentation.suffixIndicator(for: .done) == nil)
    }

    @Test func suffixIndicatorMapsEachOSCState() {
        #expect(ProgramStatusRowPresentation.suffixIndicator(for: .working) == .working)
        #expect(ProgramStatusRowPresentation.suffixIndicator(for: .awaitingInput(reason: nil)) == .attention)
        #expect(ProgramStatusRowPresentation.suffixIndicator(for: .needsAuth) == .needsAuth)
        #expect(ProgramStatusRowPresentation.suffixIndicator(for: .error) == .turnFailed)
        #expect(ProgramStatusRowPresentation.suffixIndicator(for: .idle) == nil)
        #expect(ProgramStatusRowPresentation.suffixIndicator(for: .unknown(why: "x")) == nil)
    }
}

/// The app's mirror of the daemon's program-status snapshots.
@MainActor
@Suite("AppState program-status mirror")
struct ProgramStatusMirrorTests {
    private func makeAppState() -> (AppState, () -> Void) {
        let suite = TestDefaultsSuite("TBDAppTests.ProgramStatusMirror")
        let defaults = suite.defaults
        let state = AppState(userDefaults: defaults)
        return (state, { suite.tearDown() })
    }

    private func snapshot(
        _ terminalID: UUID, revision: UInt64, state: ProgramStatusState? = .working
    ) -> ProgramStatusSnapshot {
        let main: ProgramStatusEntry? = state.map {
            ProgramStatusEntry(state: $0, observedAt: Date(timeIntervalSince1970: 1_800_000_000))
        }
        return ProgramStatusSnapshot(
            terminalID: terminalID, incarnationID: nil, main: main, tasks: [], revision: revision)
    }

    @Test func appliesANewerSnapshot() {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        let id = UUID()
        state.applyProgramStatusSnapshot(snapshot(id, revision: 1, state: .working))
        state.applyProgramStatusSnapshot(snapshot(id, revision: 2, state: .done))
        #expect(state.programStatusSnapshots[id]?.main?.state == .done)
        #expect(state.programStatusRevisions[id] == 2)
    }

    @Test func dropsAnOlderSnapshot() {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        let id = UUID()
        state.applyProgramStatusSnapshot(snapshot(id, revision: 5, state: .done))
        state.applyProgramStatusSnapshot(snapshot(id, revision: 4, state: .working))
        #expect(state.programStatusSnapshots[id]?.main?.state == .done)
        #expect(state.programStatusRevisions[id] == 5)
    }

    @Test func anEmptySnapshotRemovesTheEntryAndBlocksAnOlderOne() {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        let id = UUID()
        state.applyProgramStatusSnapshot(snapshot(id, revision: 1, state: .working))
        state.applyProgramStatusSnapshot(snapshot(id, revision: 2, state: nil))
        #expect(state.programStatusSnapshots[id] == nil)
        state.applyProgramStatusSnapshot(snapshot(id, revision: 1, state: .working))
        #expect(state.programStatusSnapshots[id] == nil)
    }

    @Test func theDeltaUpdatesTheMirror() {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        let id = UUID()
        state.handleDelta(.terminalProgramStatusChanged(snapshot(id, revision: 3, state: .error)))
        #expect(state.programStatusSnapshots[id]?.main?.state == .error)
    }

    @Test func hydrateSeedsFromTheList() async {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        let a = UUID()
        let b = UUID()
        let listed = [snapshot(a, revision: 1, state: .done), snapshot(b, revision: 7, state: .working)]
        state.programStatusListFetcher = { @MainActor in listed }
        await state.hydrateProgramStatus()
        #expect(state.programStatusSnapshots[a]?.main?.state == .done)
        #expect(state.programStatusSnapshots[b]?.main?.state == .working)
    }

    @Test func hydrateDoesNotOverwriteANewerDelta() async {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        let id = UUID()
        state.applyProgramStatusSnapshot(snapshot(id, revision: 9, state: .done))
        let stale = [snapshot(id, revision: 8, state: .working)]
        state.programStatusListFetcher = { @MainActor in stale }
        await state.hydrateProgramStatus()
        #expect(state.programStatusSnapshots[id]?.main?.state == .done)
    }

    /// A capabilities refresh carries nothing about program status, so it
    /// leaves the mirror alone.
    @Test func aCapabilitiesRefreshKeepsSnapshots() async {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        let id = UUID()
        state.applyProgramStatusSnapshot(snapshot(id, revision: 1, state: .done))
        let refreshed = DaemonCapabilitiesResult(controlModeEnabled: false)
        state.daemonCapabilitiesFetcher = { @MainActor in refreshed }
        await state.refreshDaemonCapabilities()
        #expect(state.programStatusSnapshots[id]?.main?.state == .done)
    }
}
