import Foundation
import TBDShared
import Testing
import TestSupport

@testable import TBDDaemonLib

/// `worktree.create`, `remote.providers` and `remote.create`, driven through
/// `handleAppMessage`. Tier 1: the service over an in-memory database with
/// seeded repos, worktrees and tabs, fake session actions that record what
/// would have reached the daemon, and a virtual clock for the wait for a new
/// worktree's session. Nothing touches the disk, tmux or the network.
@Suite("Phone worktree.create and remote create", .clockDriven)
struct PhoneCreateTests {
    private static let provider = "acme-cloud"

    /// A provider's form: the two fields TBD fills, a string and a bool.
    private static let form = [
        ProviderCreateParamField(name: "repo", type: "string", label: "Repository", required: true),
        ProviderCreateParamField(name: "prompt", type: "text", label: "Prompt"),
        ProviderCreateParamField(name: "branch", type: "string", label: "Branch"),
        ProviderCreateParamField(name: "draft", type: "bool", label: "Open as draft"),
    ]

    /// Waits until `condition` holds, or throws naming `what`.
    private func waitUntil(_ what: String, _ condition: () async -> Bool) async throws {
        let deadline = TestDeadlines.saturatedPass
        switch await pollUntilTrue(timeout: deadline, condition) {
        case .satisfied:
            return
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            throw BoundedWaitTimeout(what: what, observed: nil, deadline: deadline)
        }
    }

    // MARK: - Fixtures

    /// A repo with `remoteURL`, hidden when asked.
    private static func seedRepo(
        _ h: PhoneServiceHarness, remoteURL: String? = "https://github.com/acme/api.git", hidden: Bool = false
    ) async throws -> Repo {
        let repo = try await h.db.repos.create(
            path: "/acme/api-\(UUID().uuidString)", displayName: "acme-api", defaultBranch: "main",
            remoteURL: remoteURL)
        if hidden {
            try await h.db.repos.setHidden(id: repo.id, hidden: true)
        }
        return repo
    }

    /// A worktree of `repo`, which the fake `phoneCreateWorktree` answers
    /// with as the pending worktree.
    private static func seedCreatedWorktree(_ h: PhoneServiceHarness, in repo: Repo) async throws -> TBDShared.Worktree {
        let worktree = try await h.db.worktrees.create(
            repoID: repo.id, name: "acme-new", displayName: "Acme new", branch: "acme-new",
            path: "/acme/api-new-\(UUID().uuidString)", tmuxServer: "tbd-acme")
        h.actions.respond(to: .createWorktree, with: try RPCResponse(result: worktree))
        return worktree
    }

    private static func seedTab(
        _ h: PhoneServiceHarness, in worktree: TBDShared.Worktree, kind: TerminalKind
    ) async throws -> TBDShared.Terminal {
        try await h.db.terminals.create(worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: kind)
    }

    /// A registered provider with `fields` as its form. Its command, its
    /// arguments and its remediation command carry text that must never
    /// reach the phone.
    private static func status(
        _ name: String = PhoneCreateTests.provider, fields: [ProviderCreateParamField] = PhoneCreateTests.form,
        describes: Bool = true,
        health: ProviderHealth = .ok, errorMessage: String? = nil
    ) -> RemoteProviderStatus {
        RemoteProviderStatus(
            config: RemoteProviderConfig(
                name: name, exec: "/usr/local/bin/acme-provider",
                args: ["--endpoint", "https://acme-control.example/secret-path"]),
            describe: describes ? ProviderDescribe(name: name, capabilities: ["send-submit"], createParams: fields) : nil,
            health: health, errorMessage: errorMessage,
            remediationLabel: "Sign in", remediationCommand: "acme login --token sk-remediation-secret")
    }

    /// Every later `phoneRemoteProviders` answers `statuses`.
    private static func offer(_ h: PhoneServiceHarness, _ statuses: [RemoteProviderStatus]) throws {
        h.actions.respond(to: .remoteProviders, with: try RPCResponse(result: RemoteProvidersResult(providers: statuses)))
    }

    /// Every later `phoneRemoteCreate` answers a new session `sessionID`.
    private static func startsSession(_ h: PhoneServiceHarness, _ sessionID: String = "rs-9") throws {
        h.actions.respond(to: .remoteCreate, with: try RPCResponse(result: RemoteSessionPayload(id: sessionID, state: .running)))
    }

    private static func result<R: Codable>(_ type: R.Type, from bytes: Data) throws -> R {
        try JSONDecoder().decode(PhoneReplyEnvelope<R>.self, from: bytes).result
    }

    /// The form values the one `remote.create` that reached the daemon sent.
    private static func sentForm(_ h: PhoneServiceHarness) throws -> [String: Any] {
        let creates = h.actions.remoteCreates
        try #require(creates.count == 1)
        let object = try JSONSerialization.jsonObject(with: Data(creates[0].paramsJSON.utf8))
        return try #require(object as? [String: Any])
    }

    private static func createParams(
        repoID: UUID, message: String = "fix it", strings: [String: String] = [:], bools: [String: Bool] = [:],
        provider: String = PhoneCreateTests.provider
    ) -> PhoneRemoteCreateParams {
        PhoneRemoteCreateParams(provider: provider, repoID: repoID, message: message, strings: strings, bools: bools)
    }

    // MARK: - worktree.create

    /// The wait finds the agent tab the create made after it began waiting,
    /// on the delta that announces it.
    @Test func createWorktreeRepliesWithTheFirstSession() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        let worktree = try await Self.seedCreatedWorktree(h, in: repo)
        let outbox = await h.connect()
        let body = try PhoneTestRequests.body(
            .worktreeCreate, id: "create", params: PhoneWorktreeCreateParams(repoID: repo.id, message: "Add a search box."))

        await h.service.handleAppMessage(body, from: h.peer)
        // The wait has subscribed and is sleeping.
        try await h.clock.requireSleeperArmed()
        let tab = try await Self.seedTab(h, in: worktree, kind: .claude)
        h.subscriptions.broadcast(delta: .terminalCreated(
            TerminalDelta(terminalID: tab.id, worktreeID: worktree.id, label: nil)))
        let bytes = try await outbox.body(at: 0)

        let result = try Self.result(PhoneWorktreeCreateResult.self, from: bytes)
        #expect(result == PhoneWorktreeCreateResult(worktreeID: worktree.id, session: .local(terminalID: tab.id)))
        #expect(h.subscriptions.subscriberCount == 0)
        #expect(h.recorder.records == [PhoneActionRecord(
            deviceName: "Acme Phone", action: "worktree.create", target: "repo:\(repo.id.uuidString)")])
    }

    /// A tab made before the wait subscribed is found by the first look,
    /// with no delta and no time passing. A shell tab is not a session.
    @Test func createWorktreeFindsASessionMadeBeforeTheWait() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        let worktree = try await Self.seedCreatedWorktree(h, in: repo)
        _ = try await Self.seedTab(h, in: worktree, kind: .shell)
        let tab = try await Self.seedTab(h, in: worktree, kind: .claude)
        let outbox = await h.connect()

        let (reply, bytes) = try await h.request(
            .worktreeCreate, params: PhoneWorktreeCreateParams(repoID: repo.id, message: "Add a search box."), on: outbox)

        #expect(reply.error == nil)
        let result = try Self.result(PhoneWorktreeCreateResult.self, from: bytes)
        #expect(result.session == .local(terminalID: tab.id))
        #expect(h.subscriptions.subscriberCount == 0)
    }

    @Test func createWorktreeRepliesWithoutASessionAfterTheWait() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        let worktree = try await Self.seedCreatedWorktree(h, in: repo)
        let outbox = await h.connect()
        let body = try PhoneTestRequests.body(
            .worktreeCreate, id: "create", params: PhoneWorktreeCreateParams(repoID: repo.id, message: "Add a search box."))

        await h.service.handleAppMessage(body, from: h.peer)
        try await h.clock.requireAdvanceWhenArmed(by: .seconds(30))
        let bytes = try await outbox.body(at: 0)

        let result = try Self.result(PhoneWorktreeCreateResult.self, from: bytes)
        #expect(result.worktreeID == worktree.id)
        #expect(result.session == nil)
        #expect(h.subscriptions.subscriberCount == 0)
    }

    /// The create carries the repo and the message, and nothing else the
    /// params could hold, under the verified pairing's device.
    @Test func createWorktreePassesOnlyRepoAndPrompt() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        let worktree = try await Self.seedCreatedWorktree(h, in: repo)
        _ = try await Self.seedTab(h, in: worktree, kind: .claude)
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .worktreeCreate, params: PhoneWorktreeCreateParams(repoID: repo.id, message: "Add a search box."), on: outbox)

        #expect(reply.error == nil)
        #expect(h.actions.calls.contains(FakeSessionActions.Call(method: .createWorktree, deviceID: h.peer.deviceID)))
        let creates = h.actions.worktreeCreates
        try #require(creates.count == 1)
        #expect(creates[0].repoID == repo.id)
        #expect(creates[0].prompt == "Add a search box.")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(creates[0]))
        let keys = try #require(encoded as? [String: Any]).keys.sorted()
        #expect(keys == ["prompt", "repoID"])
    }

    /// A message of only whitespace and invisible characters creates the
    /// worktree with no first message.
    @Test func createWorktreeWithABlankMessageHasNoFirstMessage() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        let worktree = try await Self.seedCreatedWorktree(h, in: repo)
        _ = try await Self.seedTab(h, in: worktree, kind: .claude)
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .worktreeCreate, params: PhoneWorktreeCreateParams(repoID: repo.id, message: " \n\u{200B}\t"), on: outbox)

        #expect(reply.error == nil)
        let creates = h.actions.worktreeCreates
        try #require(creates.count == 1)
        #expect(creates[0].prompt == nil)
    }

    /// A repo the phone cannot see, because it is gone or hidden, is
    /// `not_found`, and nothing is created.
    @Test func createWorktreeInAHiddenOrMissingRepoIsNotFound() async throws {
        let h = try await PhoneServiceHarness.make()
        let hidden = try await Self.seedRepo(h, hidden: true)
        let outbox = await h.connect()

        for repoID in [hidden.id, UUID()] {
            let (reply, _) = try await h.request(
                .worktreeCreate, params: PhoneWorktreeCreateParams(repoID: repoID, message: "Add a search box."),
                on: outbox)
            #expect(reply.error == PhoneAppError(code: .notFound, message: PhoneAppService.noSuchRepoReason))
        }
        #expect(h.actions.worktreeCreates.isEmpty)
    }

    @Test func createWorktreeWithAMessageTooLongIsABadRequest() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        let outbox = await h.connect()
        let message = String(repeating: "a", count: PhoneAppConstants.messageMaxBytes + 1)

        let (reply, _) = try await h.request(
            .worktreeCreate, params: PhoneWorktreeCreateParams(repoID: repo.id, message: message), on: outbox)

        #expect(reply.error == PhoneAppError(code: .badRequest, message: PhoneAppService.messageTooLongReason))
        #expect(h.actions.worktreeCreates.isEmpty)
    }

    /// A refused create is `refused` with the daemon's words, such as the
    /// phone message rule's, and waits for nothing.
    @Test func aRefusedCreateReturnsTheDaemonsReason() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        h.actions.respond(to: .createWorktree, with: RPCResponse(error: PhoneMessageText.controlCharacterRefusal))
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .worktreeCreate, params: PhoneWorktreeCreateParams(repoID: repo.id, message: "fix\u{1b}[201~it"), on: outbox)

        #expect(reply.error == PhoneAppError(code: .refused, message: PhoneMessageText.controlCharacterRefusal))
        #expect(h.subscriptions.subscriberCount == 0)
    }

    @Test func aCreateResultThatDoesNotDecodeIsInternal() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        h.actions.respond(to: .createWorktree, with: .ok())
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .worktreeCreate, params: PhoneWorktreeCreateParams(repoID: repo.id, message: "Add a search box."), on: outbox)

        #expect(reply.error?.code == .internalError)
        #expect(h.subscriptions.subscriberCount == 0)
    }

    /// A revoke during the wait cancels it, and the wait's subscriber goes.
    @Test func revokingDuringTheWaitLeavesNoSubscriber() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        _ = try await Self.seedCreatedWorktree(h, in: repo)
        _ = await h.connect()
        let before = h.subscriptions.subscriberCount
        let body = try PhoneTestRequests.body(
            .worktreeCreate, id: "create", params: PhoneWorktreeCreateParams(repoID: repo.id, message: "Add a search box."))

        await h.service.handleAppMessage(body, from: h.peer)
        try await h.clock.requireSleeperArmed()
        #expect(h.subscriptions.subscriberCount == before + 1)
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)

        try await waitUntil("the wait's subscriber to go") {
            h.subscriptions.subscriberCount == before
        }
        try await waitUntil("the cancelled request to end") {
            await h.service.requestsRunning(for: h.peer.deviceID) == 0
        }
    }

    /// A resent create creates once and gets the first reply's bytes.
    @Test func aResentCreateCreatesOnce() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        let worktree = try await Self.seedCreatedWorktree(h, in: repo)
        _ = try await Self.seedTab(h, in: worktree, kind: .claude)
        let outbox = await h.connect()
        let body = try PhoneTestRequests.body(
            .worktreeCreate, id: "create", params: PhoneWorktreeCreateParams(repoID: repo.id, message: "Add a search box."))

        let (first, replied) = try await h.send(body, on: outbox)
        let (_, again) = try await h.send(body, on: outbox)

        #expect(first.error == nil)
        #expect(again == replied)
        #expect(h.actions.worktreeCreates.count == 1)
    }

    // MARK: - remote.providers

    /// The phone gets a provider's form without `repo` and `prompt`, which
    /// TBD fills, and with nothing of the provider's command, arguments or
    /// remediation command.
    @Test func providersHideRepoAndPromptFields() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        try Self.offer(h, [Self.status()])
        let outbox = await h.connect()

        let (reply, bytes) = try await h.request(
            .remoteProviders, params: PhoneRemoteProvidersParams(repoID: repo.id), on: outbox)

        #expect(reply.error == nil)
        let providers = try Self.result(PhoneRemoteProvidersResult.self, from: bytes).providers
        try #require(providers.count == 1)
        #expect(providers[0].name == Self.provider)
        #expect(providers[0].available)
        #expect(providers[0].reason == nil)
        #expect(providers[0].acceptsPrompt)
        let names = providers[0].fields.map(\.name)
        #expect(names == ["branch", "draft"])
        let text = String(decoding: bytes, as: UTF8.self)
        for secret in ["acme-provider", "acme-control.example", "sk-remediation-secret", "Sign in", "send-submit"] {
            #expect(!text.contains(secret), "the reply carries \(secret)")
        }
        #expect(h.recorder.records.isEmpty)
    }

    /// Each field carries the value TBD would fill in: the repo's stored
    /// value over the laptop's, then the field's own default, and a bool
    /// field's `true`.
    @Test func providersPrefillFromTheRepoAndTheLaptop() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        try await h.db.repos.setRemoteCreateDefaults(id: repo.id, defaults: ["branch": "b"])
        try await h.db.config.setRemoteCreateDefaults(["branch": "main", "size": "large", "draft": "true"])
        let fields = Self.form + [
            ProviderCreateParamField(name: "size", type: "enum", label: "Machine size", required: true, values: ["small", "large"]),
            ProviderCreateParamField(name: "timeout", type: "int", defaultValue: "30"),
        ]
        try Self.offer(h, [Self.status(fields: fields)])
        let outbox = await h.connect()

        let (_, bytes) = try await h.request(
            .remoteProviders, params: PhoneRemoteProvidersParams(repoID: repo.id), on: outbox)

        let providers = try Self.result(PhoneRemoteProvidersResult.self, from: bytes).providers
        try #require(providers.count == 1)
        #expect(providers[0].fields == [
            PhoneFormField(name: "branch", type: "string", label: "Branch", required: false, values: nil, prefill: "b"),
            PhoneFormField(name: "draft", type: "bool", label: "Open as draft", required: false, values: nil, prefill: "true"),
            PhoneFormField(
                name: "size", type: "enum", label: "Machine size", required: true, values: ["small", "large"],
                prefill: "large"),
            PhoneFormField(name: "timeout", type: "int", label: nil, required: false, values: nil, prefill: "30"),
        ])
    }

    /// A provider that is not ready says why, in a fixed line for its health
    /// and never in its health message, and carries no fields: it needs a
    /// sign-in, it is stale or failing, it has no form yet, or it cannot read
    /// the repo.
    @Test func aProviderThatIsNotReadySaysWhy() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h, remoteURL: nil)
        try Self.offer(h, [
            Self.status("acme-auth", health: .needsAuth, errorMessage: "Not signed in"),
            Self.status("acme-failing", health: .error, errorMessage: "exit 2"),
            Self.status("acme-quiet", health: .stale),
            Self.status("acme-new", describes: false),
            Self.status("acme-repo"),
        ])
        let outbox = await h.connect()

        let (_, bytes) = try await h.request(
            .remoteProviders, params: PhoneRemoteProvidersParams(repoID: repo.id), on: outbox)

        let providers = try Self.result(PhoneRemoteProvidersResult.self, from: bytes).providers
        try #require(providers.count == 5)
        let reasons = providers.map { [$0.name, $0.reason ?? "<none>"] }
        #expect(reasons == [
            ["acme-auth", PhoneAppService.providerNeedsSignInReason],
            ["acme-failing", PhoneAppService.providerNotReadyReason],
            ["acme-quiet", PhoneAppService.providerNotReadyReason],
            ["acme-new", PhoneAppService.noCreateFormReason],
            ["acme-repo", PhoneAppService.repoHasNoRemoteReason],
        ])
        let available = providers.map(\.available)
        #expect(available == [false, false, false, false, false])
        let fieldCounts = providers.map(\.fields.count)
        #expect(fieldCounts == [0, 0, 0, 0, 0])
    }

    /// A provider's health message can be its raw stderr, which can quote a
    /// token. Neither `remote.providers` nor `remote.create` sends it, in any
    /// health that is not `ok`.
    @Test(arguments: [ProviderHealth.needsAuth, .stale, .error])
    func aProvidersHealthMessageNeverReachesThePhone(_ health: ProviderHealth) async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        let stderr = "curl: 401 https://acme-control.example/v1/sessions?access_token=sk-test-secret"
        try Self.offer(h, [Self.status(health: health, errorMessage: stderr)])
        try Self.startsSession(h)
        let outbox = await h.connect()

        let (_, listed) = try await h.request(
            .remoteProviders, params: PhoneRemoteProvidersParams(repoID: repo.id), on: outbox)
        let (created, refused) = try await h.request(
            .remoteCreate, params: Self.createParams(repoID: repo.id), on: outbox)

        #expect(created.error?.code == .unsupported)
        #expect(h.actions.remoteCreates.isEmpty)
        for bytes in [listed, refused] {
            let text = String(decoding: bytes, as: UTF8.self)
            for secret in ["sk-test-secret", "access_token", "acme-control.example", "curl"] {
                #expect(!text.contains(secret), "a \(health.rawValue) reply carries \(secret)")
            }
        }
    }

    @Test func providersForAHiddenRepoAreNotFound() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h, hidden: true)
        try Self.offer(h, [Self.status()])
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .remoteProviders, params: PhoneRemoteProvidersParams(repoID: repo.id), on: outbox)

        #expect(reply.error == PhoneAppError(code: .notFound, message: PhoneAppService.noSuchRepoReason))
    }

    // MARK: - remote.create

    /// TBD fills `repo` from the tapped repo's remote and `prompt` from the
    /// message, and lays the phone's values over the rest.
    @Test func remoteCreateFillsRepoAndPrompt() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h, remoteURL: "git@github.com:acme/api.git")
        let fields = Array(Self.form.prefix(3))
        try Self.offer(h, [Self.status(fields: fields)])
        try Self.startsSession(h, "rs-9")
        let outbox = await h.connect()

        let (reply, bytes) = try await h.request(
            .remoteCreate, params: Self.createParams(repoID: repo.id, strings: ["branch": "b"]), on: outbox)

        #expect(reply.error == nil)
        let session = try Self.result(SessionRefResult.self, from: bytes).session
        #expect(session == .remote(provider: Self.provider, sessionID: "rs-9"))
        let creates = h.actions.remoteCreates
        try #require(creates.count == 1)
        #expect(creates[0].provider == Self.provider)
        let sent = try JSONDecoder().decode([String: String].self, from: Data(creates[0].paramsJSON.utf8))
        #expect(sent == ["repo": "acme/api", "prompt": "fix it", "branch": "b"])
        #expect(h.actions.calls.contains(FakeSessionActions.Call(method: .remoteCreate, deviceID: h.peer.deviceID)))
        #expect(h.recorder.records == [PhoneActionRecord(
            deviceName: "Acme Phone", action: "remote.create", target: "provider:\(Self.provider)")])
    }

    @Test func remoteCreateRefusesAMissingRequiredField() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        let fields = Self.form + [
            ProviderCreateParamField(name: "size", type: "enum", required: true, values: ["small", "large"]),
        ]
        try Self.offer(h, [Self.status(fields: fields)])
        try Self.startsSession(h)
        let outbox = await h.connect()

        let (reply, _) = try await h.request(.remoteCreate, params: Self.createParams(repoID: repo.id), on: outbox)

        #expect(reply.error == PhoneAppError(code: .badRequest, message: "size is required"))
        #expect(h.actions.remoteCreates.isEmpty)
    }

    /// A value for a field the form does not have, for `repo` or `prompt`,
    /// which TBD fills, or of the wrong kind for its field, is `bad_request`.
    @Test func remoteCreateRefusesAValueTheFormDoesNotAskFor() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        try Self.offer(h, [Self.status()])
        try Self.startsSession(h)
        let outbox = await h.connect()
        let cases: [([String: String], [String: Bool])] = [
            (["token": "sk-x"], [:]),
            (["repo": "acme/other"], [:]),
            (["prompt": "something else"], [:]),
            (["draft": "true"], [:]),
            ([:], ["branch": true]),
            ([:], ["repo": true]),
        ]

        for (strings, bools) in cases {
            let (reply, _) = try await h.request(
                .remoteCreate, params: Self.createParams(repoID: repo.id, strings: strings, bools: bools), on: outbox)
            #expect(reply.error == PhoneAppError(code: .badRequest, message: PhoneAppService.notAFormFieldReason))
        }
        #expect(h.actions.remoteCreates.isEmpty)
    }

    /// A message holding a control character is refused with the words the
    /// send path uses, and reaches no provider.
    @Test func remoteCreateRefusesAControlCharacterInTheMessage() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        try Self.offer(h, [Self.status()])
        try Self.startsSession(h)
        let outbox = await h.connect()

        for message in ["fix\u{1b}[201~it", "fix\u{0}it", "fix\rit"] {
            let (reply, _) = try await h.request(
                .remoteCreate, params: Self.createParams(repoID: repo.id, message: message), on: outbox)
            #expect(reply.error == PhoneAppError(code: .refused, message: PhoneMessageText.controlCharacterRefusal))
        }
        #expect(h.actions.remoteCreates.isEmpty)
    }

    /// A blank message sends no prompt, even where a stored value would
    /// prefill one.
    @Test func remoteCreateWithABlankMessageSendsNoPrompt() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        try await h.db.config.setRemoteCreateDefaults(["prompt": "a stored prompt"])
        try Self.offer(h, [Self.status()])
        try Self.startsSession(h)
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .remoteCreate, params: Self.createParams(repoID: repo.id, message: " \n\u{200B}"), on: outbox)

        #expect(reply.error == nil)
        let sent = try Self.sentForm(h)
        #expect(!sent.keys.contains("prompt"))
        let repoValue = sent["repo"] as? String
        let draft = sent["draft"] as? Bool
        #expect(repoValue == "acme/api")
        #expect(draft == false)
    }

    @Test func remoteCreateMakesEveryLineEndABareLineFeed() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        try Self.offer(h, [Self.status()])
        try Self.startsSession(h)
        let outbox = await h.connect()

        let (reply, _) = try await h.request(
            .remoteCreate, params: Self.createParams(repoID: repo.id, message: "fix\r\nit", bools: ["draft": true]),
            on: outbox)

        #expect(reply.error == nil)
        let sent = try Self.sentForm(h)
        let prompt = sent["prompt"] as? String
        let draft = sent["draft"] as? Bool
        #expect(prompt == "fix\nit")
        #expect(draft == true)
    }

    @Test func remoteCreateRefusesAMessageTheProviderCannotTake() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        let fields = Self.form.filter { $0.name != "prompt" }
        try Self.offer(h, [Self.status(fields: fields)])
        try Self.startsSession(h)
        let outbox = await h.connect()

        let (reply, _) = try await h.request(.remoteCreate, params: Self.createParams(repoID: repo.id), on: outbox)

        #expect(reply.error == PhoneAppError(code: .badRequest, message: PhoneAppService.providerTakesNoMessageReason))
        #expect(h.actions.remoteCreates.isEmpty)
    }

    /// A provider that is not registered, and a repo that is gone or hidden,
    /// are `not_found`.
    @Test func remoteCreateUnderAMissingProviderOrRepoIsNotFound() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        let hidden = try await Self.seedRepo(h, hidden: true)
        try Self.offer(h, [Self.status()])
        try Self.startsSession(h)
        let outbox = await h.connect()

        let (noProvider, _) = try await h.request(
            .remoteCreate, params: Self.createParams(repoID: repo.id, provider: "acme-other"), on: outbox)
        let (hiddenRepo, _) = try await h.request(
            .remoteCreate, params: Self.createParams(repoID: hidden.id), on: outbox)
        let (noRepo, _) = try await h.request(
            .remoteCreate, params: Self.createParams(repoID: UUID()), on: outbox)

        #expect(noProvider.error == PhoneAppError(code: .notFound, message: PhoneAppService.noSuchProviderReason))
        #expect(hiddenRepo.error == PhoneAppError(code: .notFound, message: PhoneAppService.noSuchRepoReason))
        #expect(noRepo.error == PhoneAppError(code: .notFound, message: PhoneAppService.noSuchRepoReason))
        #expect(h.actions.remoteCreates.isEmpty)
    }

    /// A provider that is not ready, or whose `repo` field the repo cannot
    /// answer, is `unsupported` with the reason `remote.providers` gives.
    @Test func remoteCreateOnAProviderThatIsNotReadyIsUnsupported() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        let noRemote = try await Self.seedRepo(h, remoteURL: nil)
        try Self.offer(h, [
            Self.status(health: .needsAuth, errorMessage: "Not signed in"),
            Self.status("acme-repo"),
        ])
        try Self.startsSession(h)
        let outbox = await h.connect()

        let (signedOut, _) = try await h.request(.remoteCreate, params: Self.createParams(repoID: repo.id), on: outbox)
        let (repoless, _) = try await h.request(
            .remoteCreate, params: Self.createParams(repoID: noRemote.id, provider: "acme-repo"), on: outbox)

        #expect(signedOut.error == PhoneAppError(code: .unsupported, message: PhoneAppService.providerNeedsSignInReason))
        #expect(repoless.error == PhoneAppError(code: .unsupported, message: PhoneAppService.repoHasNoRemoteReason))
        #expect(h.actions.remoteCreates.isEmpty)
    }

    /// More values than a form may carry, and a value too long, are
    /// `bad_request` before anything is read.
    @Test func remoteCreateRefusesAnOversizedForm() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        try Self.offer(h, [Self.status()])
        try Self.startsSession(h)
        let outbox = await h.connect()
        let many = Dictionary(uniqueKeysWithValues: (0...PhoneAppService.formValuesMax).map { ("field-\($0)", "x") })
        let long = String(repeating: "b", count: PhoneAppService.formValueMaxBytes + 1)

        let (tooMany, _) = try await h.request(
            .remoteCreate, params: Self.createParams(repoID: repo.id, strings: many), on: outbox)
        let (tooLong, _) = try await h.request(
            .remoteCreate, params: Self.createParams(repoID: repo.id, strings: ["branch": long]), on: outbox)

        #expect(tooMany.error == PhoneAppError(code: .badRequest, message: PhoneAppService.tooManyFormValuesReason))
        #expect(tooLong.error == PhoneAppError(code: .badRequest, message: PhoneAppService.formValueTooLongReason))
        #expect(h.actions.remoteCreates.isEmpty)
        #expect(!h.actions.calls.contains(FakeSessionActions.Call(method: .remoteProviders, deviceID: nil)))
    }

    @Test func aRefusedRemoteCreateReturnsTheDaemonsReason() async throws {
        let h = try await PhoneServiceHarness.make()
        let repo = try await Self.seedRepo(h)
        try Self.offer(h, [Self.status()])
        h.actions.respond(to: .remoteCreate, with: RPCResponse(error: "acme-cloud: quota reached"))
        let outbox = await h.connect()

        let (reply, _) = try await h.request(.remoteCreate, params: Self.createParams(repoID: repo.id), on: outbox)

        #expect(reply.error == PhoneAppError(code: .refused, message: "acme-cloud: quota reached"))
    }
}
