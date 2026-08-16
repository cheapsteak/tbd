import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// The statusline tee across `terminal.swapProfile` — "Switch account" on a
/// Watch Desk.
///
/// An `.inPlace` swap keeps the terminal row (`plannedTerminalID ==
/// oldTerminal.id`) and never touches `watch_desk_role`, so the row goes on
/// claiming to be a desk across the respawn. Resolving the overlay without that
/// role would leave it running with no tee — and, because a roleless resolve
/// deletes the session's capture, with no denominator either — while
/// `session.states` keeps reporting "the tee is installed but has not fired
/// yet" forever.
///
/// A `.fork` swap is the opposite case: it mints a fresh row branded no desk, so
/// its overlay must carry no tee or the two would disagree the other way.
///
/// Nested under `TBDHomeSerialized`: the per-session overlay and the capture
/// path resolve through the process-global `TBD_HOME`.
extension TBDHomeSerialized {
@Suite struct SwapProfileStatuslineTeeTests {

    private struct Scratch {
        let home: URL
        let prior: String?
        init() {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("tbd-swap-tee-\(UUID().uuidString)", isDirectory: true)
            prior = setTBDHome(home.path)
        }
        func cleanUp() {
            restoreTBDHome(prior)
            try? FileManager.default.removeItem(at: home)
        }
    }

    private struct Fixture {
        let db: TBDDatabase
        let router: RPCRouter
        let terminal: Terminal
    }

    private func isolatedConfigDirManager() -> ClaudeProfileConfigDirManager {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-swap-tee-claude-\(UUID().uuidString)", isDirectory: true)
        return ClaudeProfileConfigDirManager(
            baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
            hostBaseDirectory: home.appendingPathComponent("claude-host", isDirectory: true))
    }

    /// A live (unparked) Claude terminal, optionally branded a desk, in a
    /// worktree whose path exists on disk.
    ///
    /// - Parameter withConversation: when true the session's transcript carries
    ///   a user message, so `isSessionBlank` is false and the swap takes the
    ///   **resume** branch; when false it takes the **fresh** branch. Both
    ///   branches resolve their own overlay, so both are covered.
    private func makeFixture(
        _ scratch: Scratch, desk: Bool, withConversation: Bool
    ) async throws -> Fixture {
        let repoPath = scratch.home.appendingPathComponent("repo", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: repoPath, displayName: "repo", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main", path: repoPath,
            tmuxServer: "tbd-swap-tee")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", claudeSessionID: "sess-swap", kind: .claude,
            watchDeskRole: desk ? .readOnlyCoordinator : nil)
        if withConversation {
            let transcript = scratch.home.appendingPathComponent("sess-swap.jsonl").path
            let record = #"{"type":"user","message":{"content":"hello"}}"# + "\n"
            try Data(record.utf8).write(to: URL(fileURLWithPath: transcript))
            try await db.terminals.updateSession(
                id: terminal.id, sessionID: "sess-swap", transcriptPath: transcript)
        }
        let tmux = TmuxManager(dryRun: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date(),
            configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())
        let reloaded = try #require(try await db.terminals.get(id: terminal.id))
        return Fixture(db: db, router: router, terminal: reloaded)
    }

    private func swap(
        _ fixture: Fixture, mode: TerminalSwapMode
    ) async throws -> RPCResponse {
        let request = try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: fixture.terminal.id, newProfileID: nil, mode: mode))
        return await fixture.router.handle(request)
    }

    private func statusLineCommand(forSessionKey key: String) -> String? {
        let path = ClaudeHookOverlay.perSessionOverlayPath(sessionKey: key)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = parsed["statusLine"] as? [String: Any] else {
            return nil
        }
        return entry["command"] as? String
    }

    // MARK: -

    @Test(arguments: [true, false])
    func anInPlaceSwapOnADeskKeepsTheStatuslineTee(withConversation: Bool) async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let fixture = try await makeFixture(
            scratch, desk: true, withConversation: withConversation)

        let response = try await swap(fixture, mode: .inPlace)
        #expect(response.error == nil, "swap errored: \(response.error ?? "")")

        // The row still claims to be a desk…
        let after = try #require(try await fixture.db.terminals.get(id: fixture.terminal.id))
        #expect(after.watchDeskRole != nil)
        // …so the overlay it just respawned with had better install the tee.
        let command = try #require(
            statusLineCommand(forSessionKey: fixture.terminal.id.uuidString),
            "an in-place swap on a desk produced an overlay with no statusLine")
        #expect(command.contains(StatuslineTee.scriptPath))
        // The row is reused, so the capture path is too — and it must still be
        // the one the tee publishes to.
        #expect(command.contains(
            StatuslineTee.capturePath(sessionKey: fixture.terminal.id.uuidString)))
    }

    @Test func anInPlaceSwapOnAnOrdinaryTerminalInstallsNoStatusline() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let fixture = try await makeFixture(scratch, desk: false, withConversation: true)

        let response = try await swap(fixture, mode: .inPlace)
        #expect(response.error == nil, "swap errored: \(response.error ?? "")")

        // TBD's per-session `--settings` outranks the operator's `statusLine` in
        // every scope they can write, so a leak here takes over a slot they own.
        #expect(statusLineCommand(forSessionKey: fixture.terminal.id.uuidString) == nil)
    }

    /// The other direction of the same rule. A fork mints a fresh row branded
    /// no desk (`forkSwapNewTab` passes no role), so carrying the source row's
    /// role onto its overlay would install a tee on a session the desk
    /// machinery does not consider a desk.
    @Test func aForkSwapDoesNotCarryTheSourceRowsDeskRole() async throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let fixture = try await makeFixture(scratch, desk: true, withConversation: true)

        let response = try await swap(fixture, mode: .fork)
        #expect(response.error == nil, "swap errored: \(response.error ?? "")")

        let terminals = try await fixture.db.terminals.list(worktreeID: fixture.terminal.worktreeID)
        let forked = try #require(terminals.first { $0.id != fixture.terminal.id },
                                  "a fork swap created no new terminal")
        #expect(forked.watchDeskRole == nil)
        #expect(statusLineCommand(forSessionKey: forked.id.uuidString) == nil)
    }
}
}
