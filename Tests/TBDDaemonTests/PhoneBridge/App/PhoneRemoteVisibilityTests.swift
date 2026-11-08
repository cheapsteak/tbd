import Foundation
import TBDShared
import Testing
import TestSupport

@testable import TBDDaemonLib

/// A remote session the sessions list leaves out is out of a phone's reach on
/// every path that acts on it: `message.send`, `session.setModel`,
/// `prompt.answer` and `transcript.open` refuse it `not_found`, as the local
/// paths refuse a tab in a hidden repo, and nothing reaches the provider.
/// The check and the list share one rule (`PhoneSnapshotBuilder.listsRemoteSession`),
/// so each test also reads the list the phone would be sent. Tier 1: the
/// service over an in-memory database, with fake session actions.
@Suite("Phone remote session visibility", .fastPassBounded)
struct PhoneRemoteVisibilityTests {
    private static let session = PhoneSessionRef.remote(provider: "acme-cloud", sessionID: "rs-1")
    private static let notFound = PhoneAppError(code: .notFound, message: PhoneAppService.noSuchSessionReason)
    private static let allow = PromptAnswer.permission(decision: .allow, message: nil)

    /// A harness whose provider declares every capability a phone uses and
    /// whose one remote session, `rs-1`, is resolved to `repoID`.
    private static func harness(resolvedTo repoID: (PhoneServiceHarness) async throws -> UUID?) async throws
        -> PhoneServiceHarness {
        let h = try await PhoneServiceHarness.make()
        try h.actions.registerProvider("acme-cloud", capabilities: [
            RemoteCapability.sendSubmit, RemoteCapability.answer, RemoteCapability.transcriptRead,
        ])
        let resolvedRepoID = try await repoID(h)
        try h.actions.listRemoteSession("acme-cloud", "rs-1", resolvedRepoID: resolvedRepoID)
        h.actions.respond(to: .remoteSendMessage, with: try RPCResponse(result: RemoteSendMessageResult(outcome: .sent)))
        h.actions.respond(
            to: .answerRemotePrompt, with: try RPCResponse(result: PromptAnswerResult(outcome: .delivered)))
        // A sync TBD itself refuses, so an open that gets past the check
        // shows it in `remoteSyncs` and ends there.
        h.actions.respond(to: .remoteTranscriptSync, with: RPCResponse(error: RemoteGateRefusal.backendsDisabled))
        return h
    }

    /// A new repo, hidden when `hidden`.
    private static func seedRepo(_ h: PhoneServiceHarness, hidden: Bool) async throws -> UUID {
        let repo = try await h.db.repos.create(
            path: "/acme/widgets-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        if hidden {
            try await h.db.repos.setHidden(id: repo.id, hidden: true)
        }
        return repo.id
    }

    /// Whether the sessions list the phone would be sent shows `rs-1`.
    private static func listed(_ h: PhoneServiceHarness) async throws -> Bool {
        let snapshot = try await h.service.gatherSnapshot()
        return snapshot.rows.contains { row in row.sessions.contains { $0.ref == Self.session } }
    }

    /// Sends one request of every acting path for `rs-1` and returns the
    /// errors of their replies, in the order sent.
    private static func actOnEveryPath(_ h: PhoneServiceHarness) async throws -> [PhoneAppError?] {
        let outbox = await h.connect()
        let (send, _) = try await h.request(
            .messageSend, params: MessageSendParams(session: Self.session, text: "hi"), on: outbox)
        let (model, _) = try await h.request(
            .sessionSetModel, params: SessionSetModelParams(session: Self.session, model: "opus"), on: outbox)
        let (answer, _) = try await h.request(
            .promptAnswer,
            params: PhonePromptAnswerParams(session: Self.session, promptID: "rp-1", answer: Self.allow),
            on: outbox)
        let (open, _) = try await h.request(
            .transcriptOpen, params: TranscriptOpenParams(session: Self.session, showDetails: false, resume: false),
            on: outbox)
        return [send.error, model.error, answer.error, open.error]
    }

    /// A session resolved to a hidden repo is not in the list, and every path
    /// refuses it `not_found` with nothing sent to the provider.
    @Test func aSessionOfAHiddenRepoIsNotFoundOnEveryPath() async throws {
        let h = try await Self.harness { try await Self.seedRepo($0, hidden: true) }

        let listed = try await Self.listed(h)
        #expect(!listed)
        let errors = try await Self.actOnEveryPath(h)

        #expect(errors == [Self.notFound, Self.notFound, Self.notFound, Self.notFound])
        #expect(h.actions.remoteSends.isEmpty)
        #expect(h.actions.remoteAnswers.isEmpty)
        #expect(h.actions.remoteSyncs.isEmpty)
        let acted = h.actions.calls.filter { $0.deviceID != nil }
        #expect(acted.isEmpty)
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)
    }

    /// The same session resolved to a repo that is shown is in the list, and
    /// every path reaches the provider.
    @Test func aSessionOfAShownRepoIsReachedOnEveryPath() async throws {
        let h = try await Self.harness { try await Self.seedRepo($0, hidden: false) }

        let listed = try await Self.listed(h)
        #expect(listed)
        let errors = try await Self.actOnEveryPath(h)

        #expect(errors == [
            nil, nil, nil, PhoneAppError(code: .refused, message: RemoteGateRefusal.backendsDisabled),
        ])
        let texts = h.actions.remoteSends.map { $0.text }
        #expect(texts == ["hi", "/model opus"])
        #expect(h.actions.remoteAnswers.count == 1)
        #expect(h.actions.remoteSyncs.count == 1)
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)
    }

    /// A session resolved to a repo TBD no longer has is listed under its
    /// provider, as the sidebar places it, so the phone reaches it too: the
    /// check follows the list, not the bare resolution.
    @Test func aSessionOfARemovedRepoFollowsTheList() async throws {
        let h = try await Self.harness { _ in UUID() }

        let listed = try await Self.listed(h)
        #expect(listed)
        let errors = try await Self.actOnEveryPath(h)

        let acting = Array(errors.prefix(3))
        #expect(acting == [nil, nil, nil])
        #expect(h.actions.remoteSends.count == 2)
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)
    }

    /// A dismissed session and one missing from the laptop's list are not in
    /// the list, and a send to either is `not_found`.
    @Test func aDismissedOrMissingSessionIsNotFound() async throws {
        let h = try await Self.harness { _ in nil }
        try h.actions.listRemoteSession("acme-cloud", "rs-1", dismissed: true)
        let outbox = await h.connect()

        let listed = try await Self.listed(h)
        #expect(!listed)
        let (dismissed, _) = try await h.request(
            .messageSend, params: MessageSendParams(session: Self.session, text: "hi"), on: outbox)
        try h.actions.listRemoteSession("acme-cloud", "rs-2")
        let (missing, _) = try await h.request(
            .messageSend, params: MessageSendParams(session: Self.session, text: "hi"), on: outbox)

        #expect(dismissed.error == Self.notFound)
        #expect(missing.error == Self.notFound)
        #expect(h.actions.remoteSends.isEmpty)
    }

    /// The list's rule on its own: a session resolved to a hidden repo is
    /// placed in no row, and the same session resolved to a shown repo is.
    @Test func theListsRuleLeavesOutASessionOfAHiddenRepo() async throws {
        let h = try await PhoneServiceHarness.make()
        let shownID = try await Self.seedRepo(h, hidden: false)
        let hiddenID = try await Self.seedRepo(h, hidden: true)
        let repos = try await h.db.repos.list()
        func input(_ repoID: UUID) -> PhoneSnapshotInput {
            let session = RemoteSessionInfo(
                provider: "acme-cloud", payload: RemoteSessionPayload(id: "rs-1", state: .running),
                gone: false, dismissed: false, lastSeen: Date(timeIntervalSince1970: 1_800_000_000),
                resolvedRepoID: repoID)
            let provider = RemoteProviderStatus(
                config: RemoteProviderConfig(name: "acme-cloud", exec: "/usr/local/bin/acme-provider"),
                describe: ProviderDescribe(name: "acme-cloud", capabilities: []), health: .ok,
                errorMessage: nil, remediationLabel: nil, remediationCommand: nil)
            return PhoneSnapshotInput(
                repos: repos, worktrees: [], scratch: [], terminals: [:], tabOrder: [:], tabLabels: [:],
                profiles: [], states: [:], openPrompts: [:], remoteSessions: [session], providers: [provider])
        }

        let hidden = PhoneSnapshotBuilder.listsRemoteSession(provider: "acme-cloud", sessionID: "rs-1", in: input(hiddenID))
        let shown = PhoneSnapshotBuilder.listsRemoteSession(provider: "acme-cloud", sessionID: "rs-1", in: input(shownID))
        #expect(!hidden)
        #expect(shown)
        let hiddenRefs = PhoneSnapshotBuilder.build(input(hiddenID)).rows.flatMap { $0.sessions.map { $0.ref } }
        #expect(!hiddenRefs.contains(Self.session))
    }
}
