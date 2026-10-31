import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import DaemonTestSupport
import TestSupport

/// Tier 2: the session-title round trip through the router — the `--name` a
/// Claude spawn gets, and the title `terminal.sessionTitle` hands back to the
/// `UserPromptSubmit` hook. See docs/specs/2026-10-14-session-title-sync-design.md.
@Suite("session title sync over RPC")
struct SessionTitleSyncRPCTests {
    /// Thread-safe collector for tmux argv lists invoked during dryRun.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        var calls: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        func record(_ args: [String]) {
            lock.lock(); defer { lock.unlock() }
            _calls.append(args)
        }
    }

    let db: TBDDatabase
    let router: RPCRouter
    private let recorder: Recorder

    init() throws {
        let recorder = Recorder()
        let tmux = TmuxManager(dryRun: true, dryRunRecorder: { recorder.record($0) })
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        self.recorder = recorder
        self.router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date(),
            actuationLog: makeTestActuationLog()
        )
    }

    /// A worktree named `acme-feature` whose path exists on disk, since
    /// `terminal.create` refuses to spawn into a missing directory.
    private func makeWorktree() async throws -> (Worktree, String) {
        let repo = try await db.repos.create(
            path: "/tmp/title-sync-repo-\(UUID().uuidString)",
            displayName: "title-sync-repo",
            defaultBranch: "main")
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("title-sync-wt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "acme-feature", branch: "tbd/acme-feature",
            path: path, tmuxServer: "tbd-title-sync")
        return (wt, path)
    }

    /// The seeded row takes the lowest possible id, so it sorts first even
    /// when a later row's `createdAt` ties it at the store's millisecond
    /// resolution (the store orders by `createdAt`, then `id`).
    private func makeClaudeRow(worktreeID: UUID) async throws -> Terminal {
        try await db.terminals.create(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            worktreeID: worktreeID, tmuxWindowID: "@seed", tmuxPaneID: "%seed",
            label: TerminalLabel.claudeCode, claudeSessionID: UUID().uuidString, kind: .claude)
    }

    /// A second Claude row, created after the seeded one and sorting after it
    /// on id as well.
    private func makeSecondClaudeRow(worktreeID: UUID) async throws -> Terminal {
        try await db.terminals.create(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            worktreeID: worktreeID, tmuxWindowID: "@second", tmuxPaneID: "%second",
            label: TerminalLabel.claudeCode, claudeSessionID: UUID().uuidString, kind: .claude)
    }

    /// The `new-window` argv lines the dryRun tmux recorded.
    private func spawnArgv() -> [String] {
        recorder.calls
            .filter { $0.contains("new-window") }
            .map { $0.joined(separator: " ") }
    }

    /// Sends one `UserPromptSubmit` hook's `terminal.sessionTitle` and returns
    /// the response. The row's own incarnation rides along unless the caller
    /// names another, so the hook is accepted rather than refused as a stale
    /// process's.
    private func prompt(
        _ terminal: Terminal, incarnationID: UUID?? = nil
    ) async throws -> RPCResponse {
        let request = try RPCRequest(
            method: RPCMethod.terminalSessionTitle,
            params: TerminalSessionTitleParams(
                terminalID: terminal.id,
                sessionIncarnationID: incarnationID ?? terminal.sessionIncarnationID))
        return await router.handle(request)
    }

    private func title(_ response: RPCResponse) throws -> String? {
        try response.decodeResult(TerminalSessionTitleResult.self).sessionTitle
    }

    /// One prompt that asks for a title, reduced to the title it got back.
    private func promptTitle(_ terminal: Terminal) async throws -> String? {
        let response = try await prompt(terminal)
        #expect(response.success)
        return try title(response)
    }

    private func rename(_ worktreeID: UUID, to name: String) async throws {
        let request = try RPCRequest(
            method: RPCMethod.worktreeRename,
            params: WorktreeRenameParams(worktreeID: worktreeID, displayName: name))
        #expect((await router.handle(request)).success)
    }

    @Test("a second Claude terminal spawns with the suffixed --name, and its first prompt carries no title")
    func secondTerminalSpawnsSuffixed() async throws {
        let (wt, path) = try await makeWorktree()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await makeClaudeRow(worktreeID: wt.id)
        await router.activityLedger.setEnabled(true)

        let createResponse = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)))
        #expect(createResponse.success)
        let created = try createResponse.decodeResult(Terminal.self)

        #expect(spawnArgv().contains { $0.contains("--name 'acme-feature · 2'") })

        let response = try await prompt(created)
        #expect(response.success)
        #expect(try title(response) == nil)
        // The hook was accepted — it stamped the PR schedule's ledger — so the
        // nil above is the change rule's answer rather than an identity
        // refusal's.
        #expect(await router.activityLedger.snapshot().hooks[created.id] != nil)
    }

    @Test("a rename is handed to the session once, on its next prompt")
    func renameIsSentOnce() async throws {
        let (wt, path) = try await makeWorktree()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let terminal = try await makeClaudeRow(worktreeID: wt.id)
        await router.lifecycle.sessionTitles.record(
            terminalID: terminal.id, worktreeID: wt.id, title: "acme-feature")

        #expect(try await promptTitle(terminal) == nil)

        try await rename(wt.id, to: "Acme Checkout Flow")
        #expect(try await promptTitle(terminal) == "Acme Checkout Flow")
        #expect(try await promptTitle(terminal) == nil)
    }

    @Test("with no recorded title (a daemon restart), the first prompt carries the title")
    func noRecordedTitleSendsOnce() async throws {
        let (wt, path) = try await makeWorktree()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let terminal = try await makeClaudeRow(worktreeID: wt.id)

        #expect(try await promptTitle(terminal) == "acme-feature")
        #expect(try await promptTitle(terminal) == nil)
    }

    @Test("a hook from another incarnation gets no title and leaves the record for the live one")
    func aStaleIncarnationGetsNoTitle() async throws {
        let (wt, path) = try await makeWorktree()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let terminal = try await makeClaudeRow(worktreeID: wt.id)
        await router.lifecycle.sessionTitles.record(
            terminalID: terminal.id, worktreeID: wt.id, title: "acme-feature")
        try await rename(wt.id, to: "Acme Checkout Flow")
        await router.activityLedger.setEnabled(true)

        let stale = try await prompt(terminal, incarnationID: UUID())
        #expect(stale.success)
        #expect(try title(stale) == nil)
        #expect(await router.activityLedger.snapshot().hooks[terminal.id] == nil)
        // The refused hook did not move the record: the live session's next
        // prompt still gets the rename.
        #expect(await router.lifecycle.sessionTitles.lastApplied(terminalID: terminal.id) == "acme-feature")
        #expect(try await promptTitle(terminal) == "Acme Checkout Flow")
    }

    @Test("a Codex terminal that asks gets no title")
    func codexGetsNoTitle() async throws {
        let (wt, path) = try await makeWorktree()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let codex = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@codex", tmuxPaneID: "%codex",
            label: TerminalLabel.codex, kind: .codex)

        let response = try await prompt(codex)
        #expect(response.success)
        #expect(try title(response) == nil)
    }

    @Test("a successful spawn records the --name it gave the session")
    func successfulSpawnRecordsItsName() async throws {
        let (wt, path) = try await makeWorktree()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let createResponse = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)))
        #expect(createResponse.success)
        let created = try createResponse.decodeResult(Terminal.self)

        #expect(await router.lifecycle.sessionTitles.lastApplied(terminalID: created.id) == "acme-feature")
    }

    @Test("renaming a Claude tab retitles its session on the next prompt")
    func tabRenameRetitles() async throws {
        let (wt, path) = try await makeWorktree()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try await makeClaudeRow(worktreeID: wt.id)
        let second = try await makeSecondClaudeRow(worktreeID: wt.id)
        let titles = router.lifecycle.sessionTitles
        await titles.record(terminalID: first.id, worktreeID: wt.id, title: "acme-feature")
        await titles.record(terminalID: second.id, worktreeID: wt.id, title: "acme-feature · 2")
        #expect(try await promptTitle(second) == nil)

        let rename = await router.handle(try RPCRequest(
            method: RPCMethod.tabSetLabel,
            params: TabSetLabelParams(tabID: second.id, worktreeID: wt.id, label: "reviewer")))
        #expect(rename.success)

        #expect(try await promptTitle(second) == "acme-feature · reviewer")
        #expect(try await promptTitle(second) == nil)
        // The first tab's title did not move.
        #expect(try await promptTitle(first) == nil)
    }

    @Test("a new spawn skips the number a tab that has not re-prompted still carries")
    func spawnSkipsATakenNumber() async throws {
        let (wt, path) = try await makeWorktree()
        defer { try? FileManager.default.removeItem(atPath: path) }
        // The worktree's first tab has closed; the survivor still carries the
        // ` · 2` it was given while it was second.
        let survivor = try await makeClaudeRow(worktreeID: wt.id)
        await router.lifecycle.sessionTitles.record(
            terminalID: survivor.id, worktreeID: wt.id, title: "acme-feature · 2")

        let createResponse = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)))
        #expect(createResponse.success)
        let created = try createResponse.decodeResult(Terminal.self)

        #expect(spawnArgv().contains { $0.contains("--name 'acme-feature · 3'") })
        #expect(await router.lifecycle.sessionTitles.lastApplied(terminalID: created.id) == "acme-feature · 3")
    }

    @Test("recreating a Claude tab as a plain shell forgets its title, freeing the number")
    func recreateAsShellForgetsTitle() async throws {
        let (wt, path) = try await makeWorktree()
        defer { try? FileManager.default.removeItem(atPath: path) }
        // No claudeSessionID, so the recreate takes the plain-shell arm.
        let tab = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@old", tmuxPaneID: "%old",
            label: TerminalLabel.claudeCode, kind: .claude)
        let titles = router.lifecycle.sessionTitles
        await titles.record(terminalID: tab.id, worktreeID: wt.id, title: "acme-feature")

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: tab.id)))
        #expect(response.success, "error: \(response.error ?? "nil")")

        #expect(try await db.terminals.get(id: tab.id)?.kind == .shell)
        #expect(await titles.lastApplied(terminalID: tab.id) == nil)
    }

    @Test("a prompt leaves the reservation of a spawn whose row is not written yet")
    func promptKeepsInFlightReservations() async throws {
        let (wt, path) = try await makeWorktree()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let terminal = try await makeClaudeRow(worktreeID: wt.id)
        let inFlight = UUID()
        let titles = router.lifecycle.sessionTitles
        await titles.record(terminalID: terminal.id, worktreeID: wt.id, title: "acme-feature")
        let spawn = await ClaudeSessionTitle.forSpawn(
            db: db, store: titles, worktreeID: wt.id, displayName: wt.displayName,
            terminalID: inFlight)
        #expect(spawn.name == "acme-feature · 2")

        #expect(try await promptTitle(terminal) == nil)

        #expect(await titles.isReserved(terminalID: inFlight))
        #expect(await titles.lastApplied(terminalID: inFlight) == "acme-feature · 2")
    }

    @Test("a terminal.create made while another spawn holds a reservation takes the next number")
    func createSkipsAReservedTitle() async throws {
        let (wt, path) = try await makeWorktree()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await makeClaudeRow(worktreeID: wt.id)
        // A spawn in flight, its row not written yet, already holds ` · 2`.
        let inFlight = await ClaudeSessionTitle.forSpawn(
            db: db, store: router.lifecycle.sessionTitles, worktreeID: wt.id,
            displayName: wt.displayName, terminalID: UUID())
        #expect(inFlight.name == "acme-feature · 2")

        let createResponse = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: wt.id, type: .claude)))
        #expect(createResponse.success)
        let created = try createResponse.decodeResult(Terminal.self)

        #expect(spawnArgv().contains { $0.contains("--name 'acme-feature · 3'") })
        #expect(await router.lifecycle.sessionTitles.lastApplied(terminalID: created.id) == "acme-feature · 3")
        #expect(await router.lifecycle.sessionTitles.isReserved(terminalID: created.id) == false)
    }
}
