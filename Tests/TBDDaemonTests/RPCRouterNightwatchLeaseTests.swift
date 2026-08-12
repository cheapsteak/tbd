import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

// Nested under TBDHomeSerialized: the lease handlers write capability files
// through `WatchDeskLeaseCredentialFile`, which resolves its directory from the
// process-global TBD_HOME. See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {
@Suite("nightwatch.lease RPC handlers")
struct RPCRouterNightwatchLeaseTests {
    /// Restores the displaced value rather than unsetting. `scripts/test.sh`
    /// exports `TBD_HOME` for the whole run, so `unsetenv` does not return to
    /// "whatever the harness wanted" — it returns to the developer's real
    /// `~/tbd`, process-wide, for every suite running concurrently, until
    /// something happens to set it again. See `Tests/TestSupport/TBDHomeEnvSupport.swift`.
    private func isolateTBDHome() -> (URL, () -> Void) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-lease-rpc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true)
        let priorTBDHome = setTBDHome(home.path)
        return (home, {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: home)
        })
    }

    private struct Fixture {
        let db: TBDDatabase
        let router: RPCRouter
        let desk: Worktree
        let claude: Terminal
        let codex: Terminal
    }

    private func fixture() async throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())
        let desk = try await db.worktrees.createScratch(
            name: "watch-desk", displayName: "Watch Desk",
            path: "/tmp/watch-desk-\(UUID())", tmuxServer: "test")
        let claude = try await db.terminals.create(
            worktreeID: desk.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, kind: .claude)
        let codex = try await db.terminals.create(
            worktreeID: desk.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: TerminalLabel.codex, kind: .codex)
        return Fixture(db: db, router: router, desk: desk, claude: claude, codex: codex)
    }

    private func acquire(
        _ f: Fixture, terminal: Terminal
    ) async throws -> NightwatchLeaseAcquisitionResult {
        let response = await f.router.handle(try RPCRequest(
            method: RPCMethod.nightwatchLeaseAcquire,
            params: NightwatchLeaseAcquireParams(
                worktreeID: f.desk.id, terminalID: terminal.id)))
        return try response.decodeResult(NightwatchLeaseAcquisitionResult.self)
    }

    private func credentials(
        _ path: String
    ) throws -> NightwatchLeaseCredentialsParams {
        let credential = try WatchDeskLeaseCredentialFile.read(path: path)
        return NightwatchLeaseCredentialsParams(
            worktreeID: credential.worktreeID, terminalID: credential.terminalID,
            token: credential.token, generation: credential.generation)
    }

    // MARK: - acquire

    @Test("acquire issues a 0600 capability outside the desk and reports judge")
    func acquireIssuesCapability() async throws {
        let (home, cleanup) = isolateTBDHome(); defer { cleanup() }
        let f = try await fixture()

        let result = try await acquire(f, terminal: f.claude)

        #expect(result.lease.terminalID == f.claude.id)
        #expect(result.lease.generation == 1)
        #expect(result.lease.valid)
        #expect(result.lease.role == .judge)

        // The capability lives under TBD_HOME, never inside the shared desk.
        #expect(result.credentialFile.hasPrefix(home.path))
        #expect(!result.credentialFile.hasPrefix(f.desk.localPath))
        let mode = try FileManager.default
            .attributesOfItem(atPath: result.credentialFile)[.posixPermissions]
        #expect((mode as? NSNumber)?.intValue == 0o600)

        // The token rides the file, never the RPC result.
        let encoded = try #require(
            String(data: try JSONEncoder().encode(result.lease), encoding: .utf8))
        let token = try WatchDeskLeaseCredentialFile.read(
            path: result.credentialFile).token
        #expect(!encoded.contains(token.uuidString))
        #expect(!encoded.lowercased().contains("token"))
    }

    @Test("acquire refuses a desk that already has an unexpired holder")
    func acquireRefusesUnexpiredHolder() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let f = try await fixture()
        _ = try await acquire(f, terminal: f.claude)

        let second = await f.router.handle(try RPCRequest(
            method: RPCMethod.nightwatchLeaseAcquire,
            params: NightwatchLeaseAcquireParams(
                worktreeID: f.desk.id, terminalID: f.codex.id)))

        #expect(!second.success)
        let held = try #require(
            try await f.db.watchDeskLeases.status(worktreeID: f.desk.id))
        #expect(held.terminalID == f.claude.id)
        #expect(held.generation == 1)
    }

    /// The handler's stated guarantee: never leave an authoritative row whose
    /// owner received no capability.
    @Test("acquire revokes the row it just wrote when the capability cannot be written")
    func acquireRevokesWhenCapabilityWriteFails() async throws {
        let (home, cleanup) = isolateTBDHome(); defer { cleanup() }
        let f = try await fixture()

        // Occupy `runtime` with a regular file so creating the leases directory
        // underneath it fails deterministically.
        let runtime = home.appendingPathComponent("runtime")
        try? FileManager.default.removeItem(at: runtime)
        try Data().write(to: runtime)

        let response = await f.router.handle(try RPCRequest(
            method: RPCMethod.nightwatchLeaseAcquire,
            params: NightwatchLeaseAcquireParams(
                worktreeID: f.desk.id, terminalID: f.claude.id)))

        #expect(!response.success)
        // A row may exist, but it must not be authoritative.
        let lease = try await f.db.watchDeskLeases.status(worktreeID: f.desk.id)
        #expect(lease?.isValid(at: Date()) != true)
    }

    // MARK: - validate / renew / status

    @Test("validate and renew demand the exact unexpired triple")
    func validateAndRenewDemandExactTriple() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let f = try await fixture()
        let acquired = try await acquire(f, terminal: f.claude)
        let good = try credentials(acquired.credentialFile)

        let validated = await f.router.handle(try RPCRequest(
            method: RPCMethod.nightwatchLeaseValidate, params: good))
        #expect(validated.success)
        let validatedSnapshot = try validated.decodeResult(WatchDeskLeaseSnapshot.self)
        #expect(validatedSnapshot.role == .judge)

        let renewed = await f.router.handle(try RPCRequest(
            method: RPCMethod.nightwatchLeaseRenew, params: good))
        #expect(renewed.success)
        let snapshot = try renewed.decodeResult(WatchDeskLeaseSnapshot.self)
        // Renewal extends authority; it never mints a new generation.
        #expect(snapshot.generation == acquired.lease.generation)
        #expect(snapshot.expiresAt >= acquired.lease.expiresAt)

        let staleGeneration = NightwatchLeaseCredentialsParams(
            worktreeID: good.worktreeID, terminalID: good.terminalID,
            token: good.token, generation: good.generation + 1)
        let staleRenew = await f.router.handle(try RPCRequest(
            method: RPCMethod.nightwatchLeaseRenew, params: staleGeneration))
        #expect(!staleRenew.success)

        let foreignToken = NightwatchLeaseCredentialsParams(
            worktreeID: good.worktreeID, terminalID: good.terminalID,
            token: UUID(), generation: good.generation)
        let foreignValidate = await f.router.handle(try RPCRequest(
            method: RPCMethod.nightwatchLeaseValidate, params: foreignToken))
        #expect(!foreignValidate.success)
    }

    @Test("status reports the holder without disclosing the capability")
    func statusReportsHolderOnly() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let f = try await fixture()
        let acquired = try await acquire(f, terminal: f.claude)

        let response = await f.router.handle(try RPCRequest(
            method: RPCMethod.nightwatchLeaseStatus,
            params: NightwatchLeaseStatusParams(worktreeID: f.desk.id)))
        let status = try response.decodeResult(NightwatchLeaseStatusResult.self)

        #expect(status.held)
        #expect(status.lease?.terminalID == f.claude.id)
        let token = try WatchDeskLeaseCredentialFile.read(
            path: acquired.credentialFile).token
        let encoded = try #require(
            String(data: try JSONEncoder().encode(status), encoding: .utf8))
        #expect(!encoded.contains(token.uuidString))
    }

    // MARK: - transfer

    @Test("transfer moves authority, swaps capabilities, and fences the predecessor")
    func transferMovesAuthority() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let f = try await fixture()
        let acquired = try await acquire(f, terminal: f.claude)
        let source = try credentials(acquired.credentialFile)

        let response = await f.router.handle(try RPCRequest(
            method: RPCMethod.nightwatchLeaseTransfer,
            params: NightwatchLeaseTransferParams(
                worktreeID: source.worktreeID, fromTerminalID: source.terminalID,
                toTerminalID: f.codex.id, token: source.token,
                generation: source.generation)))
        let transferred = try response.decodeResult(NightwatchLeaseAcquisitionResult.self)

        #expect(transferred.lease.terminalID == f.codex.id)
        #expect(transferred.lease.generation == acquired.lease.generation + 1)
        #expect(transferred.lease.role == .judge)

        // The successor holds exactly one capability, and it is the returned one.
        // Canonicalize both sides: the directory listing resolves /var to
        // /private/var while the handler returns the path it composed.
        let successorPaths = WatchDeskLeaseCredentialFile.paths(terminalID: f.codex.id)
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let returnedPath = URL(fileURLWithPath: transferred.credentialFile)
            .resolvingSymlinksInPath().path
        #expect(successorPaths == [returnedPath])
        // The predecessor's capability is gone, and its old triple is fenced.
        #expect(WatchDeskLeaseCredentialFile.paths(terminalID: f.claude.id).isEmpty)
        let fencedRenew = await f.router.handle(try RPCRequest(
            method: RPCMethod.nightwatchLeaseRenew, params: source))
        #expect(!fencedRenew.success)

        // The successor's fresh capability is a different secret.
        let successorToken = try WatchDeskLeaseCredentialFile.read(
            path: transferred.credentialFile).token
        #expect(successorToken != source.token)
    }

    /// The prepared-then-committed ordering must not strand an inert capability
    /// when the store rejects the transfer.
    @Test("a rejected transfer leaves the successor no capability and the predecessor authoritative")
    func rejectedTransferLeavesNoInertCapability() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let f = try await fixture()
        let acquired = try await acquire(f, terminal: f.claude)
        let source = try credentials(acquired.credentialFile)

        // A terminal on a different desk: the handler authenticates and writes
        // the successor capability before the store rejects it as off-desk.
        let otherDesk = try await f.db.worktrees.createScratch(
            name: "other-desk", displayName: "Other Desk",
            path: "/tmp/other-desk-\(UUID())", tmuxServer: "test")
        let outsider = try await f.db.terminals.create(
            worktreeID: otherDesk.id, tmuxWindowID: "@9", tmuxPaneID: "%9",
            label: TerminalLabel.claudeCode, kind: .claude)

        let response = await f.router.handle(try RPCRequest(
            method: RPCMethod.nightwatchLeaseTransfer,
            params: NightwatchLeaseTransferParams(
                worktreeID: source.worktreeID, fromTerminalID: source.terminalID,
                toTerminalID: outsider.id, token: source.token,
                generation: source.generation)))

        #expect(!response.success)
        #expect(WatchDeskLeaseCredentialFile.paths(terminalID: outsider.id).isEmpty)

        // The predecessor keeps working at its original generation.
        let still = try #require(
            try await f.db.watchDeskLeases.status(worktreeID: f.desk.id))
        #expect(still.terminalID == f.claude.id)
        #expect(still.generation == acquired.lease.generation)
        let predecessorRenew = await f.router.handle(try RPCRequest(
            method: RPCMethod.nightwatchLeaseRenew, params: source))
        #expect(predecessorRenew.success)
    }

    @Test("transfer with stale credentials never writes a successor capability")
    func staleTransferWritesNothing() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let f = try await fixture()
        let acquired = try await acquire(f, terminal: f.claude)

        let response = await f.router.handle(try RPCRequest(
            method: RPCMethod.nightwatchLeaseTransfer,
            params: NightwatchLeaseTransferParams(
                worktreeID: f.desk.id, fromTerminalID: f.claude.id,
                toTerminalID: f.codex.id, token: UUID(),
                generation: acquired.lease.generation)))

        #expect(!response.success)
        #expect(WatchDeskLeaseCredentialFile.paths(terminalID: f.codex.id).isEmpty)
    }

    // MARK: - release

    @Test("release tombstones the lease, drops the capability, and clears roles")
    func releaseClearsEverything() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let f = try await fixture()
        let acquired = try await acquire(f, terminal: f.claude)
        let held = try credentials(acquired.credentialFile)

        let released = await f.router.handle(try RPCRequest(
            method: RPCMethod.nightwatchLeaseRelease, params: held))
        #expect(released.success)

        #expect(WatchDeskLeaseCredentialFile.paths(terminalID: f.claude.id).isEmpty)

        let response = await f.router.handle(try RPCRequest(
            method: RPCMethod.nightwatchLeaseStatus,
            params: NightwatchLeaseStatusParams(worktreeID: f.desk.id)))
        let status = try response.decodeResult(NightwatchLeaseStatusResult.self)
        #expect(!status.held)
        // The row survives so the generation is never reused, but it reports no
        // mutable authority.
        #expect(status.lease?.valid == false)
        #expect(status.lease?.role == .readOnlyCoordinator)

        for terminal in [f.claude, f.codex] {
            let row = try #require(try await f.db.terminals.get(id: terminal.id))
            #expect(row.watchDeskRole == nil)
        }

        // A successor acquires above the released generation.
        let next = try await acquire(f, terminal: f.codex)
        #expect(next.lease.generation == acquired.lease.generation + 1)
    }
}
}
