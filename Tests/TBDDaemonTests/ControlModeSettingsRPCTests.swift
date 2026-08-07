import Darwin
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// M5: persisted settings toggle for control mode. Covers the
/// `config.setControlMode` RPC, the extended `daemon.capabilities` response
/// (tmuxVersion + support flag), and the gate's per-decision evaluation of
/// the persisted flag (env || flag, env is the developer override).
@Suite("Control mode settings RPC")
struct ControlModeSettingsRPCTests {

    /// Build a fresh router over an in-memory DB with dry-run tmux (same
    /// harness style as AttachRPCTests).
    private func makeRouterAndDB() throws -> (RPCRouter, TBDDatabase) {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog()
        )
        return (router, db)
    }

    private func makeWorktree(in db: TBDDatabase, tmuxServer: String = "tbd-cm-settings-test") async throws -> UUID {
        let repo = try await db.repos.create(
            path: "/tmp/cm-settings-repo-\(UUID().uuidString)",
            displayName: "cm-settings", defaultBranch: "main"
        )
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "cm-settings-wt",
            branch: "main", path: "/tmp/cm-settings-wt-\(UUID().uuidString)",
            tmuxServer: tmuxServer
        )
        return worktree.id
    }

    private func makeSocketPair() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        try pair.withUnsafeMutableBufferPointer { buf in
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress) == 0 else {
                throw FDChannelError.sendFailed(errno)
            }
        }
        return (pair[0], pair[1])
    }

    /// Bridge whose persisted-flag provider reads the DB config row live —
    /// the production wiring shape, so a toggle affects the NEXT decision.
    private func bridge(
        db: TBDDatabase,
        vending: FDVendingServer = FDVendingServer(),
        environment: [String: String] = [:],
        tmuxVersion: TmuxVersion? = TmuxVersion(major: 3, minor: 6)
    ) -> TmuxControlModeBridge {
        TmuxControlModeBridge(
            supervisor: TmuxControlSupervisor(),
            tmuxVersion: tmuxVersion,
            environment: environment,
            fdVending: vending,
            persistedFlagProvider: { [config = db.config] in
                (try? await config.get().controlModeEnabled) ?? false
            })
    }

    private func setControlMode(_ router: RPCRouter, enabled: Bool) async throws {
        let request = try RPCRequest(
            method: RPCMethod.configSetControlMode,
            params: ConfigSetControlModeParams(enabled: enabled))
        let response = await router.handle(request)
        #expect(response.success)
    }

    private func attach(_ router: RPCRouter, worktreeID: UUID, paneID: String, windowID: String) async throws -> AttachRequestResult {
        let request = try RPCRequest(
            method: RPCMethod.attachRequest,
            params: AttachRequestParams(
                worktreeID: worktreeID, paneID: paneID, windowID: windowID, attachID: UUID()))
        let response = await router.handle(request)
        return try response.decodeResult(AttachRequestResult.self)
    }

    // MARK: - config.setControlMode

    @Test("config.setControlMode persists the flag")
    func setControlModePersists() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setControlMode(router, enabled: true)
        #expect(try await db.config.get().controlModeEnabled == true)
        try await setControlMode(router, enabled: false)
        #expect(try await db.config.get().controlModeEnabled == false)
    }

    // MARK: - daemon.capabilities

    @Test("capabilities carries the tmux version and support flag")
    func capabilitiesCarriesVersion() async throws {
        let (router, db) = try makeRouterAndDB()
        router.controlMode = bridge(db: db, tmuxVersion: TmuxVersion(major: 3, minor: 6, suffix: "a"))
        let response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        let result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.tmuxVersion == "3.6a")
        #expect(result.controlModeSupported == true)
    }

    @Test("capabilities reports unsupported (and gate closed) for tmux < 3.2 even with the flag on")
    func capabilitiesUnsupportedOldTmux() async throws {
        let (router, db) = try makeRouterAndDB()
        try await db.config.setControlModeEnabled(true)
        router.controlMode = bridge(db: db, tmuxVersion: TmuxVersion(major: 3, minor: 1))
        let response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        let result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.tmuxVersion == "3.1")
        #expect(result.controlModeSupported == false)
        #expect(result.controlModeEnabled == false)
    }

    @Test("capabilities with no bridge reports no version and unsupported")
    func capabilitiesNoBridge() async throws {
        let (router, _) = try makeRouterAndDB()
        let response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        let result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.tmuxVersion == nil)
        #expect(result.controlModeSupported == false)
        #expect(result.controlModeEnabled == false)
    }

    @Test("capabilities reflects a flag flip without a daemon restart")
    func capabilitiesReEvaluatesFlag() async throws {
        let (router, db) = try makeRouterAndDB()
        router.controlMode = bridge(db: db)

        var response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        var result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.controlModeEnabled == false)

        try await setControlMode(router, enabled: true)
        response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.controlModeEnabled == true)
    }

    /// Codable back-compat: capabilities JSON from a pre-M5 daemon (no new
    /// keys) must still decode in a newer app.
    @Test("capabilities JSON without the new keys decodes with safe defaults")
    func capabilitiesDecodeBackCompat() throws {
        let json = Data(#"{"controlModeEnabled":true}"#.utf8)
        let result = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: json)
        #expect(result.controlModeEnabled == true)
        #expect(result.tmuxVersion == nil)
        #expect(result.controlModeSupported == false)
    }

    // MARK: - Gate branches through attach.request

    @Test("flag on, env off: attach proceeds (fd vended)")
    func attachProceedsOnFlag() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(clientSide) }

        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db)
        try await db.config.setControlModeEnabled(true)
        router.controlMode = bridge(db: db, vending: vending)

        let result = try await attach(router, worktreeID: worktreeID, paneID: "%11", windowID: "@11")
        #expect(result.status == "pending")

        let (rxFD, header) = try SidecarTestSupport.receiveVend(from: clientSide)
        defer { Darwin.close(rxFD) }
        #expect(header.paneID == "%11")
    }

    @Test("flag off, env off: attach is unavailable; flipping the flag affects the NEXT attach")
    func toggleMidSessionAffectsNextAttach() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(clientSide) }

        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db)
        router.controlMode = bridge(db: db, vending: vending)

        let before = try await attach(router, worktreeID: worktreeID, paneID: "%12", windowID: "@12")
        #expect(before.status == "unavailable")

        try await setControlMode(router, enabled: true)

        let after = try await attach(router, worktreeID: worktreeID, paneID: "%12", windowID: "@12")
        #expect(after.status == "pending")
        let (rxFD, _) = try SidecarTestSupport.receiveVend(from: clientSide)
        Darwin.close(rxFD)
    }

    @Test("env on, flag off: attach proceeds (env is the developer override)")
    func envOverridePrecedence() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(clientSide) }

        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db)
        try await db.config.setControlModeEnabled(false)
        router.controlMode = bridge(
            db: db, vending: vending, environment: ["TBD_TMUX_CONTROL_MODE": "1"])

        let result = try await attach(router, worktreeID: worktreeID, paneID: "%13", windowID: "@13")
        #expect(result.status == "pending")
        let (rxFD, _) = try SidecarTestSupport.receiveVend(from: clientSide)
        Darwin.close(rxFD)
    }

    @Test("flag on but tmux < 3.2: attach stays unavailable")
    func flagOnOldTmuxUnavailable() async throws {
        let (router, db) = try makeRouterAndDB()
        let worktreeID = try await makeWorktree(in: db)
        try await db.config.setControlModeEnabled(true)
        router.controlMode = bridge(db: db, tmuxVersion: TmuxVersion(major: 3, minor: 1))

        let result = try await attach(router, worktreeID: worktreeID, paneID: "%14", windowID: "@14")
        #expect(result.status == "unavailable")
    }
}
