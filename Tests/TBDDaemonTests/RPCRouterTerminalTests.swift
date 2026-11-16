import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import DaemonTestSupport
import TestSupport

// Terminal-scoped RPC methods: terminal.create (shell + claude), terminal.list,
// terminal.send, terminal.output.
extension RPCRouterTests {

    // MARK: - Terminal Tests

    @Test("terminal.create and terminal.list work together")
    func terminalCreateAndList() async throws {
        // On the holder transport, through the fixture's spawn double: listing
        // does not depend on the transport, and no process is started.
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        // terminal.create refuses to spawn into a missing directory, so the
        // worktree path must actually exist on disk.
        let wtPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-wt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: wtPath, withIntermediateDirectories: true)
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: wtPath,
            tmuxServer: "tbd-test"
        )

        // Create a terminal
        let createReq = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, cmd: "vim")
        )
        let createResp = await router.handle(createReq)
        #expect(createResp.success)

        let terminal = try createResp.decodeResult(Terminal.self)
        #expect(terminal.worktreeID == wt.id)
        #expect(terminal.transport == .holder)
        let launch = try #require(holder.launch(for: terminal.id))
        #expect(launch.commandLine?.contains("vim") == true)

        // List terminals
        let listReq = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id)
        )
        let listResp = await router.handle(listReq)
        #expect(listResp.success)

        let terminals = try listResp.decodeResult([Terminal].self)
        #expect(terminals.count == 1)
        #expect(terminals.map(\.id) == holder.launches.map(\.terminalID))
    }

    /// A live tmux row and the worktree that names its server: what an install
    /// whose tmux sessions outlived the update still has.
    private func makeTmuxRow() async throws -> Terminal {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: "/tmp/test-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-test"
        )
        return try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@mock-0",
            tmuxPaneID: "%mock-0",
            claudeSessionID: "sess-1",
            kind: .claude
        )
    }

    /// TBD no longer types into tmux. A send to a row whose session may still
    /// be running there is refused with `terminalOnTmux`, telling the person
    /// how to end the session and then move it, and nothing is probed.
    @Test("terminal.send to a live tmux row is refused as still running in tmux")
    func terminalSendToALiveTmuxRowIsRefused() async throws {
        let terminal = try await makeTmuxRow()

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(terminalID: terminal.id, text: "echo hello", submit: true)
        ))

        #expect(!response.success)
        #expect(response.errorCode == RPCErrorCode.terminalOnTmux.rawValue)
        #expect(response.error == LeftoverTmuxSession.stillRunningRefusal(
            terminalID: terminal.id, server: "tbd-test"))
        #expect(try await db.terminals.get(id: terminal.id)?.isParked == false)
    }

    /// A parked tmux row has nothing running to end, so its refusal points
    /// straight at the move, and at the retry that follows it.
    @Test("terminal.send --keys to a parked tmux row is refused with the move first")
    func terminalSendToAParkedTmuxRowIsRefused() async throws {
        let terminal = try await makeTmuxRow()
        try await db.terminals.setHibernated(id: terminal.id, sessionID: "sess-1")

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(terminalID: terminal.id, keys: "Escape")
        ))

        #expect(!response.success)
        #expect(response.errorCode == RPCErrorCode.terminalOnTmux.rawValue)
        #expect(response.error == TerminalTransportMigrator.migrateFirstRefusal(
            terminalID: terminal.id, retry: "wake it and send the keys again"))
    }

    // MARK: - Claude Terminal Creation

    @Test("terminal.create with type claude sets label and sessionID")
    func terminalCreateClaude() async throws {
        // On the holder transport, through the fixture's spawn double: the
        // label and the session id do not depend on the transport, and no
        // process is started.
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        // terminal.create refuses to spawn into a missing directory, so the
        // worktree path must actually exist on disk.
        let wtPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-wt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: wtPath, withIntermediateDirectories: true)
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: wtPath,
            tmuxServer: "tbd-test"
        )

        let createReq = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)
        )
        let createResp = await router.handle(createReq)
        #expect(createResp.success)

        let terminal = try createResp.decodeResult(Terminal.self)
        #expect(terminal.label == "Claude Code")
        #expect(terminal.claudeSessionID != nil)
        #expect(terminal.transport == .holder)
        #expect(holder.launches.map(\.terminalID) == [terminal.id])
    }

    // MARK: - Caller-supplied labels

    /// A `terminal.create` command doubles as the tab's title, so it is the one
    /// place caller text reaches a row's label. `TerminalLabel` names identities
    /// the daemon assigns and both sides of the socket read as such, so a
    /// command that spells one must not become one.
    private func makeLabelGuardWorktree() async throws -> Worktree {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        // terminal.create refuses to spawn into a missing directory, so the
        // worktree path must actually exist on disk.
        let wtPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-wt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: wtPath, withIntermediateDirectories: true)
        return try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: wtPath,
            tmuxServer: "tbd-test"
        )
    }

    private func createTerminal(worktreeID: UUID, cmd: String) async throws -> Terminal {
        let request = try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: worktreeID, cmd: cmd)
        )
        let response = await router.handle(request)
        #expect(response.success)
        return try response.decodeResult(Terminal.self)
    }

    @Test("terminal.create with a command naming the preSession hook does not read as a spawn still coming")
    func terminalCreateCmdCannotClaimPreSession() async throws {
        let wt = try await makeLabelGuardWorktree()
        let terminal = try await createTerminal(worktreeID: wt.id, cmd: TerminalLabel.preSession)
        #expect(terminal.label != TerminalLabel.preSession)
        #expect(terminal.label == nil)

        // Read the rows back the way every consumer does: this worktree's only
        // terminal is a shell somebody spawned, not a hook tab with an agent
        // still behind it, and a message parked on it would never be delivered.
        let listResponse = await router.handle(try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id)
        ))
        let rows = try listResponse.decodeResult([Terminal].self)
        #expect(rows.count == 1)
        #expect(PrimaryTerminal.spawnIsStillComing(terminals: rows) == false)
    }

    @Test("terminal.create with a command naming a login or agent identity does not claim it")
    func terminalCreateCmdCannotClaimOtherIdentities() async throws {
        let wt = try await makeLabelGuardWorktree()

        let login = try await createTerminal(worktreeID: wt.id, cmd: TerminalLabel.login)
        #expect(login.label == nil)

        let codex = try await createTerminal(worktreeID: wt.id, cmd: TerminalLabel.codex)
        #expect(codex.label == nil)
        #expect(codex.isCodexTerminal == false)

        let setup = try await createTerminal(worktreeID: wt.id, cmd: TerminalLabel.setup)
        #expect(setup.label == nil)
    }

    @Test("terminal.create keeps an ordinary command as the tab's label")
    func terminalCreateOrdinaryCmdKeepsItsLabel() async throws {
        let wt = try await makeLabelGuardWorktree()
        let terminal = try await createTerminal(worktreeID: wt.id, cmd: "vim")
        #expect(terminal.label == "vim")
        // Exact match, so a command that merely resembles an identity keeps it.
        let lowercased = try await createTerminal(worktreeID: wt.id, cmd: "codex")
        #expect(lowercased.label == "codex")
    }

    // MARK: - Terminal Output

    @Test("terminal.output returns error when terminal not found")
    func terminalOutputReturnsError_whenTerminalNotFound() async throws {
        let params = TerminalOutputParams(terminalID: UUID())
        let request = try RPCRequest(method: RPCMethod.terminalOutput, params: params)
        let response = await router.handle(request)
        #expect(!response.success)
        #expect(response.error?.contains("Terminal not found") == true)
    }

    /// TBD no longer reads tmux panes, so a tmux row's output is refused in
    /// the same words as a send to it.
    @Test("terminal.output of a live tmux row is refused as still running in tmux")
    func terminalOutputOfALiveTmuxRowIsRefused() async throws {
        let terminal = try await makeTmuxRow()

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalOutput,
            params: TerminalOutputParams(terminalID: terminal.id)))

        #expect(!response.success)
        #expect(response.errorCode == RPCErrorCode.terminalOnTmux.rawValue)
        #expect(response.error == LeftoverTmuxSession.stillRunningRefusal(
            terminalID: terminal.id, server: "tbd-test"))
    }
}
