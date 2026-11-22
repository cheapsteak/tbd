import DaemonTestSupport
import Foundation
import TBDShared
import Testing
import TestSupport

@testable import TBDDaemonLib

/// `repo.setRemoteFilter`, driven through `handleAppMessage`. Tier 1: the
/// service over an in-memory database, through fake session actions that
/// record the call, or through the router itself to show the phone writes
/// the column the laptop sidebar reads.
/// Spec: docs/specs/2026-11-22-phone-remote-session-filter-design.md.
@Suite("Phone repo.setRemoteFilter")
struct PhoneRemoteFilterTests {
    private static func seedRepo(_ db: TBDDatabase, hidden: Bool = false) async throws -> Repo {
        let repo = try await db.repos.create(
            path: "/acme/api-\(UUID().uuidString)", displayName: "acme-api", defaultBranch: "main")
        if hidden {
            try await db.repos.setHidden(id: repo.id, hidden: true)
        }
        return repo
    }

    /// The reply's `result`, as a JSON object.
    private static func result(_ bytes: Data) throws -> [String: Any] {
        let envelope = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        return try #require(envelope["result"] as? [String: Any])
    }

    // MARK: - Through the fake

    /// The request reaches the core with the repo and the value, replies `{}`,
    /// and its record names the repo.
    @Test func settingTheFilterReachesTheCore() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h.db)
        let outbox = await h.connect()

        let (reply, bytes) = try await h.request(
            .repoSetRemoteFilter, params: PhoneRepoSetRemoteFilterParams(repoID: repo.id, hidden: true), on: outbox)

        #expect(reply.error == nil)
        #expect(try Self.result(bytes).isEmpty)
        #expect(h.actions.registryRemoteHiddenSets == [RepoSetRegistryRemoteHiddenParams(repoID: repo.id, hidden: true)])
        #expect(h.recorder.records == [PhoneActionRecord(
            deviceName: "Acme Phone", action: "repo.setRemoteFilter", target: "repo:\(repo.id.uuidString)")])
    }

    /// Off is sent as off, not dropped.
    @Test func turningTheFilterOffSendsFalse() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h.db)
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .repoSetRemoteFilter, params: PhoneRepoSetRemoteFilterParams(repoID: repo.id, hidden: false), on: outbox)

        #expect(reply.error == nil)
        #expect(h.actions.registryRemoteHiddenSets == [RepoSetRegistryRemoteHiddenParams(repoID: repo.id, hidden: false)])
    }

    /// A repo the phone cannot see, because it is gone or hidden, is
    /// `not_found`, and nothing reaches the core.
    @Test func aHiddenOrMissingRepoIsNotFound() async throws {
        let h = try await PhoneServiceHarness.make()
        let hidden = try await Self.seedRepo(h.db, hidden: true)
        let outbox = await h.connect()

        for repoID in [hidden.id, UUID()] {
            let (reply, _) = try await h.request(
                .repoSetRemoteFilter, params: PhoneRepoSetRemoteFilterParams(repoID: repoID, hidden: true),
                on: outbox)
            #expect(reply.error == PhoneAppError(code: .notFound, message: PhoneAppService.noSuchRepoReason))
        }
        #expect(h.actions.registryRemoteHiddenSets.isEmpty)
    }

    /// A refusal from the core is `refused` with the core's reason.
    @Test func aRefusalFromTheCoreIsRefused() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h.db)
        h.actions.respond(to: .setRegistryRemoteHidden, with: RPCResponse(error: "The acme repo is busy."))
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .repoSetRemoteFilter, params: PhoneRepoSetRemoteFilterParams(repoID: repo.id, hidden: true), on: outbox)

        #expect(reply.error == PhoneAppError(code: .refused, message: "The acme repo is busy."))
    }

    /// A resend of the same request after a lost reply gets the first reply
    /// and does not reach the core again, so it cannot undo a later tap.
    @Test func aResendActsOnce() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h.db)
        let outbox = await h.connect()
        let id = UUID().uuidString
        let params = PhoneRepoSetRemoteFilterParams(repoID: repo.id, hidden: true)

        let (first, _) = try await h.request(.repoSetRemoteFilter, id: id, params: params, on: outbox)
        let (again, _) = try await h.request(.repoSetRemoteFilter, id: id, params: params, on: outbox)

        #expect(first.error == nil)
        #expect(again == first)
        #expect(h.actions.registryRemoteHiddenSets.count == 1)
    }

    // MARK: - Through the router

    /// A service over the real router, with phone control on and one paired
    /// phone, and every delta the router broadcasts.
    private struct RouterFixture {
        let db: TBDDatabase
        let service: PhoneAppService
        let peer: PhonePeer
        let deltas: DeltaLog
    }

    private final class DeltaLog: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [StateDelta] = []

        func append(_ delta: StateDelta) { lock.withLock { kept.append(delta) } }

        var filterChanges: [RepoRegistryRemoteHiddenDelta] {
            lock.withLock {
                kept.compactMap {
                    if case .repoRegistryRemoteHiddenChanged(let delta) = $0 { return delta }
                    return nil
                }
            }
        }
    }

    private func makeRouterFixture() async throws -> RouterFixture {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPhoneControlEnabled(true)
        let peer = PhonePeer(deviceID: UUID(), deviceName: "Acme Phone")
        try await db.phoneDevices.insert(PhoneDevice(
            id: peer.deviceID, name: peer.deviceName, publicKey: Data(repeating: 7, count: 32),
            roomID: UUID().uuidString, pairedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let subs = StateSubscriptionManager()
        let deltas = DeltaLog()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), hooks: HookResolver(), subscriptions: subs, leftoverTmuxProbe: .absent),
            subscriptions: subs,
            actuationLog: makeTestActuationLog(tag: "phone-remote-filter"))
        let service = PhoneAppService(
            db: db, actions: router, subscriptions: subs, pendingPrompts: router.pendingQuestions,
            locateTranscript: PhoneServiceHarness.locateTranscript,
            profileCheck: router.explicitProfileCheck,
            recorder: CapturingRecorder(), clock: EventDrivenTestClock())
        return RouterFixture(db: db, service: service, peer: peer, deltas: deltas)
    }

    /// A tap on the phone writes the repo's column, on then off, and each
    /// write broadcasts the delta that wakes the sessions publisher.
    @Test func thePhoneWritesTheColumnTheSidebarReads() async throws {
        let f = try await makeRouterFixture()
        let repo = try await Self.seedRepo(f.db)
        let outbox = CapturingOutbox()
        await f.service.phoneConnected(f.peer, outbox: outbox)

        for hidden in [true, false] {
            let index = outbox.bodies.count
            await f.service.handleAppMessage(
                try PhoneTestRequests.body(
                    .repoSetRemoteFilter, id: UUID().uuidString,
                    params: PhoneRepoSetRemoteFilterParams(repoID: repo.id, hidden: hidden)),
                from: f.peer)
            let bytes = try await outbox.body(at: index)
            let reply = try JSONDecoder().decode(PhoneTestReply.self, from: bytes)
            #expect(reply.error == nil)
            #expect(try await f.db.repos.get(id: repo.id)?.registryRemoteHidden == hidden)
        }
        #expect(f.deltas.filterChanges == [
            RepoRegistryRemoteHiddenDelta(repoID: repo.id, hidden: true),
            RepoRegistryRemoteHiddenDelta(repoID: repo.id, hidden: false),
        ])
    }
}
