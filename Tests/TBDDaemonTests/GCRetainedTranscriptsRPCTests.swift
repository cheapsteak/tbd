import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// The RPC surface for `gc_retained_transcripts_enabled` — the soak gate on the
/// `OrphanGC` leg that unlinks retained transcripts nobody references and drops
/// receipts whose expiry has passed.
///
/// The verb exists so the soak can be entered and left through a supported
/// path. Without it the only way to lift the gate is a hand-written `UPDATE`
/// against `~/tbd/state.db`, which this project's own rules put out of bounds —
/// the same reasoning that gave every sibling soak gate an RPC of its own.
@Suite("GC retained transcripts RPC")
struct GCRetainedTranscriptsRPCTests {

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

    private func setFlag(_ router: RPCRouter, enabled: Bool) async throws {
        let request = try RPCRequest(
            method: RPCMethod.configSetGCRetainedTranscriptsEnabled,
            params: ConfigSetGCRetainedTranscriptsParams(enabled: enabled))
        let response = await router.handle(request)
        #expect(response.success, "\(String(describing: response.error))")
    }

    // MARK: - The method reaches a handler at all

    /// The wire name, pinned. A rename would leave every shipped CLI calling a
    /// method the router answers with `unknown method`, and the failure would
    /// only show up at runtime.
    @Test("the method name is config.setGCRetainedTranscriptsEnabled")
    func methodName() {
        #expect(
            RPCMethod.configSetGCRetainedTranscriptsEnabled
                == "config.setGCRetainedTranscriptsEnabled")
    }

    /// The gate is off before anybody calls the verb — so a passing "on" test
    /// below cannot be passing because the flag was already on.
    @Test("the gate is off before the verb is called")
    func offBeforeAnyCall() async throws {
        let (_, db) = try makeRouterAndDB()
        #expect(try await db.config.get().gcRetainedTranscriptsEnabled == false)
    }

    // MARK: - Round trip

    @Test("the verb lifts the gate")
    func setEnabledPersists() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setFlag(router, enabled: true)
        #expect(try await db.config.get().gcRetainedTranscriptsEnabled == true)
    }

    /// An explicit opt-out is stored as a real `0`, not left as the NULL that
    /// merely resolves to today's default — that is what keeps it honored
    /// through graduation, when the shipped default flips.
    @Test("the verb records an explicit opt-out, not a NULL")
    func setDisabledPersistsAsAnExplicitFalse() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setFlag(router, enabled: false)
        #expect(try await db.config.get().gcRetainedTranscriptsEnabled == false)
        let stored = try await db.writerForTests.read { conn in
            try ConfigRecord.fetchOne(conn, key: ConfigStore.singletonID)?
                .gc_retained_transcripts_enabled
        }
        #expect(stored == false)
    }

    @Test("the verb round-trips on and back off")
    func roundTrip() async throws {
        let (router, db) = try makeRouterAndDB()
        try await setFlag(router, enabled: true)
        #expect(try await db.config.get().gcRetainedTranscriptsEnabled == true)
        try await setFlag(router, enabled: false)
        #expect(try await db.config.get().gcRetainedTranscriptsEnabled == false)
    }

    // MARK: - It gates one leg and no other

    /// Lifting this gate must not lift any sibling. The one that matters most
    /// is `remoteDeleteEnabled`: this verb reclaims TBD's own local residue,
    /// that one destroys a session on a provider, and no operator opting into
    /// a local sweep is asking for the irreversible verb.
    @Test("lifting this gate lifts no sibling flag")
    func doesNotDisturbSiblingFlags() async throws {
        let (router, db) = try makeRouterAndDB()
        let before = try await db.config.get()
        try await setFlag(router, enabled: true)
        let config = try await db.config.get()
        #expect(config.gcRetainedTranscriptsEnabled == true)
        #expect(config.remoteDeleteEnabled == false)
        #expect(config.gcProfileDirsEnabled == false)
        #expect(config.gcOrphanProcessesEnabled == false)
        #expect(config.gcHolderRendezvousEnabled == false)
        #expect(config.gcRowlessHoldersEnabled == false)
        #expect(config.reapHolderChildrenEnabled == false)
        // The master switch is untouched in the other direction: this verb
        // neither turns GC on nor off.
        #expect(config.gcEnabled == before.gcEnabled)
    }

    /// …and the reverse. `tbd remote allow-delete on` must leave this sweep
    /// disabled, so the two opt-ins stay genuinely separate gestures.
    @Test("the remote-delete verb does not lift this gate")
    func theRemoteDeleteVerbDoesNotLiftThisGate() async throws {
        let (router, db) = try makeRouterAndDB()
        let request = try RPCRequest(
            method: RPCMethod.configSetRemoteDeleteEnabled,
            params: ConfigSetRemoteDeleteEnabledParams(enabled: true))
        let response = await router.handle(request)
        #expect(response.success)
        let config = try await db.config.get()
        #expect(config.remoteDeleteEnabled == true)
        #expect(config.gcRetainedTranscriptsEnabled == false)
    }

    // MARK: - Wire type

    @Test("the params type round-trips")
    func paramsRoundTrip() throws {
        for enabled in [true, false] {
            let decoded = try JSONDecoder().decode(
                ConfigSetGCRetainedTranscriptsParams.self,
                from: try JSONEncoder().encode(
                    ConfigSetGCRetainedTranscriptsParams(enabled: enabled)))
            #expect(decoded.enabled == enabled)
        }
    }
}
