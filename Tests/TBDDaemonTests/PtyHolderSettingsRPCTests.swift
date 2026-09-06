import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// The RPC surface behind the Settings toggle for the pty-holder transport:
/// the `config.setPtyHolderEnabled` verb and the `daemon.capabilities`
/// read-back the toggle renders from.
///
/// The toggle reads the daemon's value rather than a local guess, so the two
/// halves it renders — the persisted flag and whether this daemon could
/// actually start a holder — both have to arrive over the wire and both have
/// to be able to say either thing.
@Suite("Pty holder settings RPC")
struct PtyHolderSettingsRPCTests {

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

    private func setPtyHolder(_ router: RPCRouter, enabled: Bool) async throws {
        let request = try RPCRequest(
            method: RPCMethod.configSetPtyHolderEnabled,
            params: ConfigSetPtyHolderEnabledParams(enabled: enabled))
        let response = await router.handle(request)
        #expect(response.success, "error: \(response.error ?? "nil")")
    }

    private func capabilities(_ router: RPCRouter) async throws -> DaemonCapabilitiesResult {
        let response = await router.handle(RPCRequest(method: RPCMethod.daemonCapabilities))
        return try response.decodeResult(DaemonCapabilitiesResult.self)
    }

    // MARK: - config.setPtyHolderEnabled

    @Test("config.setPtyHolderEnabled persists the opt-in")
    func setEnabledPersists() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setPtyHolder(router, enabled: true)
        #expect(try await db.config.get().ptyHolderEnabled == true)
    }

    /// The off branch, and it is not the same assertion as "never touched": a
    /// deliberate opt-out has to be a real `0`, so it survives the day the
    /// shipped default graduates to true.
    @Test("config.setPtyHolderEnabled persists an explicit opt-out as a real 0")
    func setDisabledPersists() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setPtyHolder(router, enabled: false)
        #expect(try await db.config.get().ptyHolderEnabled == false)
        let stored = try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)?.pty_holder_enabled
        }
        #expect(stored == false, "an explicit off must be a stored 0, not a NULL")
    }

    /// The third state: nobody has chosen. A row that has never been written
    /// reads NULL, so the shipped default is what the toggle shows — and the
    /// opt-out above is distinguishable from it.
    @Test("an untouched install stores NULL, not a 0")
    func untouchedStoresNull() async throws {
        let (_, db) = try makeRouterAndDB()
        let stored = try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)?.pty_holder_enabled
        }
        #expect(stored == nil)
    }

    // MARK: - daemon.capabilities

    @Test("capabilities reports the pty-holder flag OFF by default")
    func capabilitiesDefaultsOff() async throws {
        let (router, _) = try makeRouterAndDB()
        #expect(try await capabilities(router).ptyHolderEnabled == Config.ptyHolderDefault)
        #expect(Config.ptyHolderDefault == false, "the shipped default is still OFF during the soak")
    }

    /// The round trip the toggle actually performs: set, read back, set back,
    /// read back. Both directions, because a payload that hard-coded either
    /// value would pass a one-directional test.
    @Test("capabilities re-evaluates the pty-holder flag without a restart")
    func capabilitiesReEvaluatesFlag() async throws {
        let (router, _) = try makeRouterAndDB()

        try await setPtyHolder(router, enabled: true)
        #expect(try await capabilities(router).ptyHolderEnabled == true)

        try await setPtyHolder(router, enabled: false)
        #expect(try await capabilities(router).ptyHolderEnabled == false)
    }

    // MARK: - The supported half

    /// No registry at all — mock mode, and the state every unit-test router is
    /// in. `canSpawn` cannot be true, so Settings greys the toggle out.
    @Test("capabilities reports the transport unsupported with no registry")
    func capabilitiesUnsupportedWithoutRegistry() async throws {
        let (router, _) = try makeRouterAndDB()
        #expect(try await capabilities(router).ptyHolderSupported == false)
    }

    /// A registry that exists but has no spawner — a daemon whose `TBDHolder`
    /// binary an upgrade moved away. The registry is still built, because
    /// adoption reaches a running holder through its socket; it just cannot
    /// start a new one, so the create gate falls back to tmux and the toggle
    /// must not claim otherwise.
    @Test("capabilities reports unsupported for a registry that cannot spawn")
    func capabilitiesUnsupportedWithoutSpawner() async throws {
        let (router, _) = try makeRouterAndDB()
        router.holderRegistry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": "/tmp/tbd-ph-\(UUID().uuidString.prefix(8))"],
            listTerminals: { [] },
            spawner: nil)
        #expect(try await capabilities(router).ptyHolderSupported == false)
    }

    /// The opposite branch, so the field is not merely a constant false: a
    /// registry holding a spawner reports supported. `canSpawn` is decided in
    /// `init` from the spawner's presence alone, so nothing is launched here.
    @Test("capabilities reports supported for a registry that can spawn")
    func capabilitiesSupportedWithSpawner() async throws {
        let (router, _) = try makeRouterAndDB()
        router.holderRegistry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": "/tmp/tbd-ph-\(UUID().uuidString.prefix(8))"],
            listTerminals: { [] },
            spawner: HolderSpawner(
                executableURL: URL(fileURLWithPath: "/nonexistent/TBDHolder")))
        #expect(try await capabilities(router).ptyHolderSupported == true)
    }

    /// The two halves are independent: turning the flag on cannot conjure a
    /// helper, and the toggle has to be able to show "on, but this daemon
    /// cannot act on it".
    @Test("the flag and the supported half move independently")
    func flagAndSupportAreIndependent() async throws {
        let (router, _) = try makeRouterAndDB()
        try await setPtyHolder(router, enabled: true)
        let result = try await capabilities(router)
        #expect(result.ptyHolderEnabled == true)
        #expect(result.ptyHolderSupported == false)
    }

    // MARK: - Codable back-compat

    /// An older daemon sends neither field. `enabled` falls through to the
    /// shipped default rather than pretending the transport is live, and
    /// `supported` is honestly false — which greys the toggle out instead of
    /// offering a switch that daemon would ignore.
    @Test("capabilities JSON without the pty-holder fields decodes conservatively")
    func capabilitiesDecodeBackCompat() throws {
        let json = Data(#"{"controlModeEnabled":true,"controlModeSupported":false}"#.utf8)
        let result = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: json)
        #expect(result.ptyHolderEnabled == Config.ptyHolderDefault)
        #expect(result.ptyHolderSupported == false)
    }

    /// …and a daemon that does send them is believed, in both directions, so
    /// the decoder is not just returning its fallbacks.
    @Test("capabilities JSON carrying the pty-holder fields round-trips")
    func capabilitiesDecodeCarriesValues() throws {
        let on = Data(#"{"ptyHolderEnabled":true,"ptyHolderSupported":true}"#.utf8)
        let onResult = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: on)
        #expect(onResult.ptyHolderEnabled == true)
        #expect(onResult.ptyHolderSupported == true)

        let off = Data(#"{"ptyHolderEnabled":false,"ptyHolderSupported":false}"#.utf8)
        let offResult = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: off)
        #expect(offResult.ptyHolderEnabled == false)
        #expect(offResult.ptyHolderSupported == false)
    }

    @Test("ConfigSetPtyHolderEnabledParams round-trips both values")
    func paramsRoundTrip() throws {
        for value in [true, false] {
            let decoded = try JSONDecoder().decode(
                ConfigSetPtyHolderEnabledParams.self,
                from: try JSONEncoder().encode(ConfigSetPtyHolderEnabledParams(enabled: value)))
            #expect(decoded.enabled == value)
        }
    }

    // MARK: - config.setHolderHibernationEnabled

    private func setHolderHibernation(_ router: RPCRouter, enabled: Bool) async throws {
        let request = try RPCRequest(
            method: RPCMethod.configSetHolderHibernationEnabled,
            params: ConfigSetHolderHibernationEnabledParams(enabled: enabled))
        let response = await router.handle(request)
        #expect(response.success, "error: \(response.error ?? "nil")")
    }

    /// The RPC persists on and off through the router — the round trip the
    /// Settings toggle actually performs.
    @Test("config.setHolderHibernationEnabled persists on and off through the router")
    func setHolderHibernationPersistsBothDirections() async throws {
        let (router, db) = try makeRouterAndDB()

        try await setHolderHibernation(router, enabled: true)
        #expect(try await db.config.get().holderHibernationEnabled == true)

        try await setHolderHibernation(router, enabled: false)
        #expect(try await db.config.get().holderHibernationEnabled == false)
        let stored = try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)?.holder_hibernation_enabled
        }
        #expect(stored == false, "an explicit off must be a stored 0, not a NULL")
    }

    /// An untouched install stores NULL, not a 0 — the third state, same shape
    /// as the pty-holder transport gate above.
    @Test("an untouched install stores NULL for holder hibernation")
    func untouchedStoresNullForHolderHibernation() async throws {
        let (_, db) = try makeRouterAndDB()
        let stored = try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)?.holder_hibernation_enabled
        }
        #expect(stored == nil)
    }

    @Test("capabilities reports holder hibernation OFF by default")
    func capabilitiesHolderHibernationDefaultsOff() async throws {
        let (router, _) = try makeRouterAndDB()
        #expect(
            try await capabilities(router).holderHibernationEnabled
                == Config.holderHibernationEnabledDefault)
        #expect(
            Config.holderHibernationEnabledDefault == false,
            "the shipped default is still OFF during the soak")
    }

    /// Capabilities re-evaluates the flag on every call, exactly like the
    /// pty-holder transport gate — no daemon restart needed.
    @Test("capabilities re-evaluates holder hibernation without a restart")
    func capabilitiesReEvaluatesHolderHibernation() async throws {
        let (router, _) = try makeRouterAndDB()

        try await setHolderHibernation(router, enabled: true)
        #expect(try await capabilities(router).holderHibernationEnabled == true)

        try await setHolderHibernation(router, enabled: false)
        #expect(try await capabilities(router).holderHibernationEnabled == false)
    }

    /// An older daemon sends no such field; the decoder falls through to
    /// `false` rather than assuming the gate is live.
    @Test("capabilities JSON without holder hibernation decodes to false")
    func capabilitiesHolderHibernationDecodeBackCompat() throws {
        let json = Data(#"{"controlModeEnabled":true,"controlModeSupported":false}"#.utf8)
        let result = try JSONDecoder().decode(DaemonCapabilitiesResult.self, from: json)
        #expect(result.holderHibernationEnabled == false)
    }

    @Test("ConfigSetHolderHibernationEnabledParams round-trips both values")
    func holderHibernationParamsRoundTrip() throws {
        for value in [true, false] {
            let decoded = try JSONDecoder().decode(
                ConfigSetHolderHibernationEnabledParams.self,
                from: try JSONEncoder().encode(
                    ConfigSetHolderHibernationEnabledParams(enabled: value)))
            #expect(decoded.enabled == value)
        }
    }
}
