import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

@Suite struct ClaudeDelegationSampleTests {
    /// A real `turn_duration` record carrying a pending count.
    static let pending = #"{"parentUuid":"222fdc13-cfb9-4c0d-9cc4-4952202f8fce","isSidechain":false,"type":"system","subtype":"turn_duration","durationMs":133243,"messageCount":132,"pendingBackgroundAgentCount":1,"timestamp":"2026-08-22T23:43:17.655Z","uuid":"11111111-1111-1111-1111-111111111111","isMeta":false,"userType":"external","entrypoint":"cli","cwd":"/tmp/tbd-test/worktree","sessionId":"00000000-0000-0000-0000-000000000001","version":"2.1.239","gitBranch":"feature-branch"}"#

    /// The same record shape with the field OMITTED — how Claude Code spells zero.
    static let absent = #"{"parentUuid":"632a67a1-63dc-4c07-be99-1b8f1fb39f5f","isSidechain":false,"type":"system","subtype":"turn_duration","durationMs":146367,"messageCount":74,"timestamp":"2026-08-22T22:53:13.020Z","uuid":"11111111-1111-1111-1111-111111111111","isMeta":false,"userType":"external","entrypoint":"cli","cwd":"/tmp/tbd-test/worktree","sessionId":"00000000-0000-0000-0000-000000000001","version":"2.1.239","gitBranch":"feature-branch"}"#

    /// An ordinary assistant line, present so the scanner must skip non-matches.
    static let noise = #"{"type":"assistant","isSidechain":false,"uuid":"22222222-2222-2222-2222-222222222222","timestamp":"2026-08-22T23:43:10.000Z"}"#

    private func tail(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    @Test func readsThePendingCountFromTheNewestRecord() {
        #expect(ClaudeDelegationSample.pendingCount(
            inTail: tail([Self.noise, Self.pending])) == 1)
    }

    @Test func anOmittedFieldMakesNoClaim() {
        #expect(ClaudeDelegationSample.pendingCount(
            inTail: tail([Self.noise, Self.absent])) == nil)
    }

    /// The whole point of the level rail: the NEWEST record wins, so a later
    /// turn that reports no pending agents retracts an earlier claim.
    @Test func theNewestRecordWinsOverAnOlderOne() {
        #expect(ClaudeDelegationSample.pendingCount(
            inTail: tail([Self.pending, Self.absent])) == nil)
        #expect(ClaudeDelegationSample.pendingCount(
            inTail: tail([Self.absent, Self.pending])) == 1)
    }

    @Test func aTailWithNoTurnDurationMakesNoClaim() {
        #expect(ClaudeDelegationSample.pendingCount(
            inTail: tail([Self.noise, Self.noise])) == nil)
    }

    /// A 64 KiB window starts mid-record. The leading fragment needs no special
    /// handling: a byte range beginning mid-object is not valid JSON, so it
    /// fails to parse and is skipped like any other unreadable line. A half
    /// record is not evidence either way.
    @Test func aTruncatedLeadingRecordIsDiscarded() {
        let truncated = String(Self.pending.dropFirst(40))
        #expect(ClaudeDelegationSample.pendingCount(
            inTail: tail([truncated, Self.absent])) == nil)
        // And the fragment must not be mistaken for a claim on its own.
        #expect(ClaudeDelegationSample.pendingCount(
            inTail: tail([truncated])) == nil)
    }

    @Test func emptyAndGarbageTailsMakeNoClaim() {
        #expect(ClaudeDelegationSample.pendingCount(inTail: Data()) == nil)
        #expect(ClaudeDelegationSample.pendingCount(
            inTail: Data("not json at all\n".utf8)) == nil)
    }

    /// A background subagent runs its own turns in a sidechain, and those
    /// records must never speak for the main loop's count.
    @Test func aSidechainRecordMakesNoClaim() {
        let sidechain = Self.pending.replacingOccurrences(
            of: #""isSidechain":false"#,
            with: #""isSidechain":true"#)
        #expect(sidechain != Self.pending)
        #expect(ClaudeDelegationSample.pendingCount(inTail: tail([sidechain])) == nil)
        // And a sidechain record must not shadow the main loop's newest one.
        #expect(ClaudeDelegationSample.pendingCount(
            inTail: tail([Self.pending, sidechain])) == 1)
    }

    @Test func aZeroCountMakesNoClaim() {
        let zero = Self.pending.replacingOccurrences(
            of: #""pendingBackgroundAgentCount":1"#,
            with: #""pendingBackgroundAgentCount":0"#)
        #expect(ClaudeDelegationSample.pendingCount(inTail: tail([zero])) == nil)
    }

    @Test func anOversizedRecordIsSkippedRatherThanParsed() {
        let huge = #"{"subtype":"turn_duration","pad":"@","pendingBackgroundAgentCount":9}"#
            .replacingOccurrences(of: "@", with: String(repeating: "x", count: 1 << 20))
        #expect(ClaudeDelegationSample.pendingCount(inTail: tail([huge])) == nil)
    }
}

@Suite struct ClaudeDelegationPublicationTests {
    /// The rail publishes through the SAME response-derived field Codex uses,
    /// so no column and no migration are involved.
    @Test func aClaimMapsToWorkingAndNoClaimMapsToNil() {
        #expect(RPCRouter.delegationPresentation(pendingCount: 2) == .working)
        #expect(RPCRouter.delegationPresentation(pendingCount: 1) == .working)
        #expect(RPCRouter.delegationPresentation(pendingCount: nil) == nil)
    }
}

/// The publish step's parked skip, driven through `terminal.list`.
///
/// `RowStatusIndicator` ranks working above hibernated, and a parked session
/// runs nothing that could ever restate the level, so a claim standing at park
/// time would replace the calm moon with animated dots that nothing retracts.
@Suite struct ClaudeDelegationParkedPublicationTests {
    private func makeFixture() async throws -> (RPCRouter, TBDDatabase, Terminal, URL) {
        let db = try TBDDatabase(inMemory: true)
        let tmux = TmuxManager(dryRun: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date(),
            actuationLog: makeTestActuationLog())
        let repo = try await db.repos.create(
            path: "/tmp/cdp-repo-\(UUID().uuidString)",
            displayName: "cdp-repo",
            defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: "/tmp/cdp-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-cdp")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-cdp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let transcript = dir.appendingPathComponent("session.jsonl")
        try Data((ClaudeDelegationSampleTests.pending + "\n").utf8).write(to: transcript)
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "Claude",
            kind: .claude)
        try await db.terminals.updateSession(
            id: terminal.id, sessionID: "s1", transcriptPath: transcript.path)
        await router.claudeDelegationTracker.mark(terminalID: terminal.id)
        return (router, db, terminal, dir)
    }

    private func listPresentation(
        _ router: RPCRouter, _ terminal: Terminal
    ) async throws -> TerminalActivityState? {
        let request = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: terminal.worktreeID))
        let response = await router.handle(request)
        #expect(response.success)
        let terminals = try response.decodeResult([Terminal].self)
        #expect(terminals.count == 1)
        return terminals.first?.presentationActivityState
    }

    /// The un-parked control: without it the two parked cases below would pass
    /// against a rail that publishes nothing at all.
    @Test("a live Claude terminal publishes its delegation claim")
    func aLiveTerminalPublishesItsClaim() async throws {
        let (router, _, terminal, dir) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(try await listPresentation(router, terminal) == .working)
    }

    @Test("a hibernated Claude terminal publishes no delegation claim")
    func aHibernatedTerminalPublishesNoClaim() async throws {
        let (router, db, terminal, dir) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await db.terminals.setHibernated(id: terminal.id, sessionID: "s1")

        #expect(try await listPresentation(router, terminal) == nil)
    }

    @Test("a suspended Claude terminal publishes no delegation claim")
    func aSuspendedTerminalPublishesNoClaim() async throws {
        let (router, db, terminal, dir) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await db.terminals.setSuspended(id: terminal.id, sessionID: "s1")

        #expect(try await listPresentation(router, terminal) == nil)
    }
}
