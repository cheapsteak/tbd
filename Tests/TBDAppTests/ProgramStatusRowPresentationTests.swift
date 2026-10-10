import Foundation
import Testing
@testable import TBDApp
import TBDShared

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
        parked: Bool = false
    ) -> TBDShared.Terminal {
        TBDShared.Terminal(
            id: id,
            worktreeID: UUID(),
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: label,
            sessionIncarnationID: incarnation,
            kind: .claude,
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

    @Test func resolvesWhenEnabledUnparkedAndSameIncarnation() throws {
        let incarnation = UUID()
        let t = Self.terminal(incarnation: incarnation)
        let s = Self.snapshot(terminalID: t.id, incarnation: incarnation, main: Self.entry(.done))
        let r = try #require(ProgramStatusRowPresentation.resolution(terminal: t, snapshot: s, enabled: true))
        #expect(r.value == .done)
    }

    @Test func nilWhenFlagOff() {
        let incarnation = UUID()
        let t = Self.terminal(incarnation: incarnation)
        let s = Self.snapshot(terminalID: t.id, incarnation: incarnation, main: Self.entry(.done))
        #expect(ProgramStatusRowPresentation.resolution(terminal: t, snapshot: s, enabled: false) == nil)
    }

    @Test func nilWhenNoSnapshot() {
        let t = Self.terminal(incarnation: UUID())
        #expect(ProgramStatusRowPresentation.resolution(terminal: t, snapshot: nil, enabled: true) == nil)
    }

    @Test func nilWhenParked() {
        let incarnation = UUID()
        let t = Self.terminal(incarnation: incarnation, parked: true)
        let s = Self.snapshot(terminalID: t.id, incarnation: incarnation, main: Self.entry(.working))
        #expect(ProgramStatusRowPresentation.resolution(terminal: t, snapshot: s, enabled: true) == nil)
    }

    @Test func nilWhenIncarnationsDiffer() {
        let t = Self.terminal(incarnation: UUID())
        let s = Self.snapshot(terminalID: t.id, incarnation: UUID(), main: Self.entry(.working))
        #expect(ProgramStatusRowPresentation.resolution(terminal: t, snapshot: s, enabled: true) == nil)
    }

    @Test func nilWhenNoMainEntry() {
        let incarnation = UUID()
        let t = Self.terminal(incarnation: incarnation)
        let task = ProgramStatusTaskEntry(id: "t1", entry: Self.entry(.working))
        let s = Self.snapshot(terminalID: t.id, incarnation: incarnation, main: nil, tasks: [task])
        #expect(ProgramStatusRowPresentation.resolution(terminal: t, snapshot: s, enabled: true) == nil)
    }

    @Test func mapsErrorNeedsAuthAndWorkingTaskCount() throws {
        let incarnation = UUID()
        let t = Self.terminal(incarnation: incarnation)

        let failed = Self.snapshot(terminalID: t.id, incarnation: incarnation, main: Self.entry(.error))
        #expect(ProgramStatusRowPresentation.resolution(terminal: t, snapshot: failed, enabled: true)?.value == .error)

        let auth = Self.snapshot(
            terminalID: t.id, incarnation: incarnation, main: Self.entry(.blocked, kind: .auth))
        #expect(ProgramStatusRowPresentation.resolution(terminal: t, snapshot: auth, enabled: true)?.value == .needsAuth)

        let busy = Self.snapshot(
            terminalID: t.id, incarnation: incarnation, main: Self.entry(.working),
            tasks: [
                ProgramStatusTaskEntry(id: "a", entry: Self.entry(.working)),
                ProgramStatusTaskEntry(id: "b", entry: Self.entry(.working)),
                ProgramStatusTaskEntry(id: "c", entry: Self.entry(.done)),
            ])
        let r = try #require(ProgramStatusRowPresentation.resolution(terminal: t, snapshot: busy, enabled: true))
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
}

/// The app's mirror of the daemon's program-status snapshots.
@MainActor
@Suite("AppState program-status mirror")
struct ProgramStatusMirrorTests {
    private func makeAppState() -> (AppState, () -> Void) {
        let suiteName = "TBDAppTests.ProgramStatusMirror.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let state = AppState(userDefaults: defaults)
        return (state, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func capabilities(programStatus: Bool) -> DaemonCapabilitiesResult {
        var caps = DaemonCapabilitiesResult(controlModeEnabled: false, panelSurfaceEnabled: false)
        caps.programStatusEnabled = programStatus
        return caps
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

    @Test func turningTheFlagOffDropsSnapshots() async {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        state.daemonCapabilities = capabilities(programStatus: true)
        let id = UUID()
        state.applyProgramStatusSnapshot(snapshot(id, revision: 1, state: .done))
        let off = capabilities(programStatus: false)
        state.daemonCapabilitiesFetcher = { @MainActor in off }
        await state.refreshDaemonCapabilities()
        #expect(state.programStatusSnapshots.isEmpty)
    }

    @Test func aRefreshThatLeavesTheFlagOnKeepsSnapshots() async {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        state.daemonCapabilities = capabilities(programStatus: true)
        let id = UUID()
        state.applyProgramStatusSnapshot(snapshot(id, revision: 1, state: .done))
        let on = capabilities(programStatus: true)
        state.daemonCapabilitiesFetcher = { @MainActor in on }
        await state.refreshDaemonCapabilities()
        #expect(state.programStatusSnapshots[id]?.main?.state == .done)
    }
}
