import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// **Where a route stops being a row's.**
///
/// Two halves, and each is load-bearing on its own. The DATABASE half is
/// `resetAgentProcessLifecycle`: the column names the stream file one PROCESS
/// was launched against, so every process replacement must drop it or the app
/// tails a file the retired route's proxy has unlinked, and every
/// `TerminalReplacementSnapshot` taken afterwards compares against a path no
/// live process is writing. The SUPERVISOR half is
/// `ModelProxyRouteAttachment.retire`, the one door every teardown goes
/// through.
@Suite("Model proxy route retirement")
struct ModelProxyRouteRetirementTests {

    private func makeTerminal(_ db: TBDDatabase) async throws -> Terminal {
        let worktree = try await db.worktrees.createScratch(
            name: "wt", displayName: "wt",
            path: "/tmp/tbd-nonexistent-\(UUID().uuidString)", tmuxServer: "tbd-test")
        return try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", kind: .claude, claudeSessionID: "session-one")
    }

    // MARK: - The row

    /// The create path stamps the route IN the insert, not by a follow-up
    /// `UPDATE`, so a row never exists without it for a suspension in which a
    /// concurrent caller could snapshot it.
    @Test("create stamps the stream path on the row it inserts")
    func createStampsTheStreamPath() async throws {
        let db = try TBDDatabase(inMemory: true)
        let worktree = try await db.worktrees.createScratch(
            name: "wt", displayName: "wt",
            path: "/tmp/tbd-nonexistent-\(UUID().uuidString)", tmuxServer: "tbd-test")
        let path = "/tmp/tbd-streams/created.jsonl"

        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            label: "claude", kind: .claude, transport: .holder,
            transcriptStreamPath: path)

        #expect(terminal.transcriptStreamPath == path)
        let row = try #require(try await db.terminals.get(id: terminal.id))
        #expect(row.transcriptStreamPath == path)
    }

    /// The transcript path and the stream path are both per-process facts, and
    /// the reset that drops one must drop the other. Before the fix this test
    /// exists for, the stream path survived a replacement it did not describe.
    @Test("an agent process replacement clears the stream path with the transcript path")
    func replacementClearsTheStreamPath() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(db)
        try await db.terminals.setTranscriptStreamPath(
            terminalID: terminal.id, path: "/tmp/tbd-streams/before.jsonl")

        let observed = try #require(try await db.terminals.get(id: terminal.id))
        #expect(observed.transcriptStreamPath != nil, "precondition: the row is routed")
        let snapshot = TerminalReplacementSnapshot(terminal: observed)
        let incarnation = try await db.terminals.prepareProfileAgentRespawn(
            id: terminal.id, expectedState: snapshot, sessionID: "session-two",
            transcriptPath: nil, profileID: nil, at: Date())
        #expect(incarnation != nil, "the snapshot must still authorize the replacement")

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.transcriptStreamPath == nil)
        #expect(after.transcriptPath == nil)
    }

    /// The same reset reached through the parked-agent respawn the wake path
    /// takes, which is where a stale path would be re-stamped a moment later
    /// and so is the one that must start from nil.
    @Test("a parked row's respawn preparation clears the stream path")
    func hibernatedRespawnClearsTheStreamPath() async throws {
        let db = try TBDDatabase(inMemory: true)
        let terminal = try await makeTerminal(db)
        try await db.terminals.setTranscriptStreamPath(
            terminalID: terminal.id, path: "/tmp/tbd-streams/parked.jsonl")
        try await db.terminals.setHibernated(
            id: terminal.id, sessionID: "session-one", reason: .manual)

        let observed = try #require(try await db.terminals.get(id: terminal.id))
        let incarnation = try await db.terminals.prepareHibernatedAgentRespawn(
            id: terminal.id,
            expectedState: TerminalReplacementSnapshot(terminal: observed),
            at: Date())
        #expect(incarnation != nil)

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.transcriptStreamPath == nil)
    }

    // MARK: - The supervisor

    @Test("retire asks the supervisor for the row's token and drops exactly it")
    func retireDropsTheRowsToken() async throws {
        let supervisor = FakeModelProxySupervisor()
        supervisor.tokenForTerminal = "abcdefabcdefabcdefabcdefabcdefab"
        let terminalID = UUID()

        await ModelProxyRouteAttachment.retire(terminalID: terminalID, supervisor: supervisor)

        #expect(supervisor.retired == ["abcdefabcdefabcdefabcdefabcdefab"])
    }

    /// **The reason the token form exists.** A wake mints a route and can then
    /// find a live holder to adopt instead — two routes name that terminal at
    /// once, and only one of them is unused. Retiring by terminal id would ask
    /// the directory, which answers with whichever it listed first; retiring by
    /// the attachment's own token can only ever drop the one that was minted
    /// and never spawned against.
    @Test("the attachment form drops its own token, not whatever the row lists")
    func retireByTokenDropsTheMintedRoute() async throws {
        let supervisor = FakeModelProxySupervisor()
        supervisor.token = "11111111111111111111111111111111"
        // What a directory listing would answer with: the LIVE session's route.
        supervisor.tokenForTerminal = "22222222222222222222222222222222"
        let terminalID = UUID()

        var config = Config()
        config.modelProxyEnabled = true
        let outcome = await ModelProxyRouteAttachment.attach(
            terminalID: terminalID, config: config, profileKind: .oauth,
            profileBaseURL: nil, envOverrideBaseURL: nil, overlaySetsBaseURL: false,
            sensitiveEnv: [:], baseEnvironment: ["TBD_HOME": "/tmp/tbd-retire-token"],
            supervisor: supervisor)

        await ModelProxyRouteAttachment.retire(
            outcome, terminalID: terminalID, supervisor: supervisor)

        #expect(supervisor.retired == ["11111111111111111111111111111111"])
    }

    @Test("the attachment form is a no-op for a spawn that was never routed")
    func retireByTokenIsANoOpWhenUnproxied() async throws {
        let supervisor = FakeModelProxySupervisor()
        supervisor.tokenForTerminal = "22222222222222222222222222222222"
        await ModelProxyRouteAttachment.retire(
            .unproxied([:]), terminalID: UUID(), supervisor: supervisor)
        #expect(supervisor.retired.isEmpty)
    }

    /// A terminal that was never routed, and a daemon with no supervisor, are
    /// both no-ops rather than failures: teardown paths call this
    /// unconditionally and must not care.
    @Test("retire is a no-op with no route and with no supervisor")
    func retireIsANoOpWithNothingToRetire() async throws {
        let supervisor = FakeModelProxySupervisor()
        supervisor.tokenForTerminal = nil
        await ModelProxyRouteAttachment.retire(terminalID: UUID(), supervisor: supervisor)
        #expect(supervisor.retired.isEmpty)

        await ModelProxyRouteAttachment.retire(terminalID: UUID(), supervisor: nil)
    }
}
