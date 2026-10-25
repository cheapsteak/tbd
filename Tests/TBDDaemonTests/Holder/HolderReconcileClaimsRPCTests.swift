import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// `holder.reconcileClaims` through the router: the layer around the
/// registry's sweep rule, which owns three things a registry test cannot see.
///
/// - **When the app's pid is resolved at all.** Resolving it spawns `ps` twice
///   and blocks, and the sweep arrives every 2 s, so the handler asks the
///   registry's cheap gate first, and resolves only when there is something
///   to take back and the flag says to take it back. With the flag off a
///   candidate is never taken back, so it would pass the gate on every tick
///   until the app quits; the report matches by pid instead. The resolver
///   here counts its calls.
/// - **What an unresolvable pid does**: nothing, and without an error.
/// - **Which way the flag sends the sweep**, read from the database on every
///   call.
///
/// **No holder answers for any session here.** The registry is
/// `HolderClaimOwnershipTests`': a take-back attempted on it fails at the
/// hand-over and drops its claim, so a claim still recorded afterwards is what
/// "kept" looks like. The take-back itself, with a real reader on a real pty,
/// is `HolderClaimReconcileLiveTests`'.
///
/// Tier 1: no holder, no pty, no `ps` — the resolver is scripted.
@Suite struct HolderReconcileClaimsRPCTests {

    /// The app every sweep here speaks for, and the owner of every claim.
    private static let app = HolderClaimOwnershipTests.oldApp

    /// A router over an in-memory database and a registry with no holder
    /// behind it, whose app-identity resolver records every pid it is asked
    /// about and resolves only `app`'s.
    private static func makeRouter() throws -> (RPCRouter, HolderRegistry, ResolvedPIDs) {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog())
        let registry = HolderClaimOwnershipTests.registry()
        router.holderRegistry = registry
        let resolved = ResolvedPIDs()
        let app = Self.app
        router.appIdentityResolver = { pid in
            resolved.append(pid)
            return pid == app.pid ? app : nil
        }
        return (router, registry, resolved)
    }

    /// One `holder.reconcileClaims` from `app`'s pid, decoded.
    private static func reconcile(
        _ router: RPCRouter, held: [UUID], throughSeq: UInt64 = 5
    ) async throws -> HolderReconcileClaimsResult {
        let response = await router.handle(
            try RPCRequest(
                method: RPCMethod.holderReconcileClaims,
                params: HolderReconcileClaimsParams(
                    appPID: app.pid, held: held, throughSeq: throughSeq)))
        #expect(response.success, "holder.reconcileClaims answered an error: \(response.error ?? "")")
        return try response.decodeResult(HolderReconcileClaimsResult.self)
    }

    private static func setFlag(_ router: RPCRouter, _ enabled: Bool) async throws {
        let response = await router.handle(
            try RPCRequest(
                method: RPCMethod.configSetHolderClaimReconcileEnabled,
                params: ConfigSetHolderClaimReconcileParams(enabled: enabled)))
        #expect(response.success)
    }

    // MARK: - The cheap gate comes first

    /// The steady state: every live panel's session is in `held`, and the
    /// sweep must cost no `ps`. That includes an app whose only claim is on a
    /// session it lists, which a gate looking only at ownership would pass.
    @Test func aSweepWithNoCandidatesResolvesNothing() async throws {
        let (router, registry, resolved) = try Self.makeRouter()

        let empty = try await Self.reconcile(router, held: [])
        #expect(empty == HolderReconcileClaimsResult())

        let session = UUID()
        await registry.recordViewerClaimForTesting(
            terminalID: session, generation: 11, owner: Self.app, attachSeq: 5)
        let heldOnly = try await Self.reconcile(router, held: [session])

        #expect(heldOnly == HolderReconcileClaimsResult())
        #expect(resolved.values == [], """
            a sweep with nothing to take back resolved the app's pid, which spawns ps on every \
            2 s tick
            """)
        #expect(await registry.viewerAttachment(for: session) == 11)
    }

    // MARK: - An unresolvable pid

    /// A pid that does not resolve — the process is gone, or `ps` would not
    /// answer — has no identity to compare with any claim's owner, so it
    /// sweeps nothing, even with the flag on, and the app hears no error.
    @Test func anUnresolvablePidSweepsNothing() async throws {
        let (router, registry, resolved) = try Self.makeRouter()
        router.appIdentityResolver = { pid in
            resolved.append(pid)
            return nil
        }
        try await Self.setFlag(router, true)
        let session = UUID()
        await registry.recordViewerClaimForTesting(
            terminalID: session, generation: 11, owner: Self.app, attachSeq: 5)

        let result = try await Self.reconcile(router, held: [])

        #expect(result == HolderReconcileClaimsResult())
        #expect(resolved.values == [Self.app.pid], """
            the sweep never reached the resolve, so this test says nothing about an \
            unresolvable pid
            """)
        #expect(await registry.viewerAttachment(for: session) == 11, """
            a sweep from a pid that resolved to no identity took back a claim
            """)
        #expect(await registry.viewerAttachmentOwner(for: session) == Self.app)
    }

    // MARK: - The flag

    /// Unset, the flag takes its shipped default, off: the sweep names what it
    /// would take back and changes nothing.
    @Test func flagOffReportsWithoutActing() async throws {
        let (router, registry, _) = try Self.makeRouter()
        let session = UUID()
        await registry.recordViewerClaimForTesting(
            terminalID: session, generation: 11, owner: Self.app, attachSeq: 5)

        let result = try await Self.reconcile(router, held: [])

        #expect(result.wouldTakeBack == [session])
        #expect(result.takenBack == [])
        #expect(await registry.viewerAttachment(for: session) == 11, """
            a sweep with the flag unset took back a claim
            """)
        #expect(await registry.viewerAttachmentOwner(for: session) == Self.app)
    }

    /// With the flag off a candidate is never taken back, so after one lost
    /// handback it passes the cheap gate on every tick until the app quits.
    /// Resolving the pid on each of those ticks would spawn `ps` twice every
    /// 2 s, so the report never resolves it: every sweep names the candidate,
    /// and none asks the resolver anything. Both the unset flag and one
    /// written off are checked, since each takes the report's branch.
    @Test(arguments: [nil, false] as [Bool?])
    func flagOffNeverResolvesThePid(written: Bool?) async throws {
        let (router, registry, resolved) = try Self.makeRouter()
        if let written {
            try await Self.setFlag(router, written)
        }
        let session = UUID()
        await registry.recordViewerClaimForTesting(
            terminalID: session, generation: 11, owner: Self.app, attachSeq: 5)

        for tick in 1...3 {
            let result = try await Self.reconcile(router, held: [])
            #expect(result == HolderReconcileClaimsResult(wouldTakeBack: [session]), """
                sweep \(tick) with the flag off stopped naming a candidate that still stands
                """)
        }

        #expect(resolved.values == [], """
            a sweep with the flag off resolved the app's pid, which spawns ps twice on every 2 s \
            tick for as long as one stuck candidate stands
            """)
        #expect(await registry.viewerAttachment(for: session) == 11, """
            a sweep with the flag off took back a claim
            """)
        #expect(await registry.wouldTakeBackNotices == 1)
    }

    /// On, the sweep resolves the pid and acts. The take-back fails at the
    /// hand-over here, since no holder answers, so nothing is listed as taken
    /// back, but the claim is gone and nothing is reported as merely what it
    /// would have done. Gone, it no longer passes the gate, so the next sweep
    /// resolves nothing.
    @Test func flagOnActs() async throws {
        let (router, registry, resolved) = try Self.makeRouter()
        try await Self.setFlag(router, true)
        let session = UUID()
        await registry.recordViewerClaimForTesting(
            terminalID: session, generation: 11, owner: Self.app, attachSeq: 5)

        let result = try await Self.reconcile(router, held: [])

        #expect(result.wouldTakeBack == [], "a sweep with the flag on only reported")
        #expect(resolved.values == [Self.app.pid], """
            a sweep with the flag on did not resolve the app's pid, so it cannot have compared \
            the app's identity with the claim's owner
            """)
        #expect(await registry.viewerAttachment(for: session) == nil, """
            a sweep with the flag on left standing a claim its app says it no longer holds
            """)

        let next = try await Self.reconcile(router, held: [])

        #expect(next == HolderReconcileClaimsResult())
        #expect(resolved.values == [Self.app.pid], """
            a sweep after the take-back resolved the pid again, though nothing was left to take \
            back
            """)
    }

    /// A candidate the flag leaves standing is selected on every tick. The
    /// app is told about it every time, and the log line is written once.
    @Test func aStuckCandidateIsLoggedOnce() async throws {
        let (router, registry, _) = try Self.makeRouter()
        let session = UUID()
        await registry.recordViewerClaimForTesting(
            terminalID: session, generation: 11, owner: Self.app, attachSeq: 5)

        let first = try await Self.reconcile(router, held: [])
        let second = try await Self.reconcile(router, held: [])

        #expect(first.wouldTakeBack == [session])
        #expect(second.wouldTakeBack == [session], """
            the second sweep stopped reporting a candidate that still stands
            """)
        #expect(await registry.wouldTakeBackNotices == 1, """
            two sweeps over one stuck candidate logged it more than once, which is some 1,800 \
            lines an hour for one session
            """)
    }

    // MARK: - No holder transport

    @Test func aDaemonWithoutAHolderRegistryAnswersEmpty() async throws {
        let (router, _, resolved) = try Self.makeRouter()
        router.holderRegistry = nil

        let result = try await Self.reconcile(router, held: [])

        #expect(result == HolderReconcileClaimsResult())
        #expect(resolved.values == [])
    }

    /// Every pid the resolver was asked about, in order.
    private final class ResolvedPIDs: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Int32] = []
        func append(_ pid: Int32) { lock.withLock { stored.append(pid) } }
        var values: [Int32] { lock.withLock { stored } }
    }
}
