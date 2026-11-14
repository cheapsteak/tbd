import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import DaemonTestSupport
import TBDKernel
import TestSupport

/// The router's conformance to `PhoneSessionActions`, the phone bridge's one
/// door into the RPC layer. Every call goes through the protocol, as the
/// bridge makes it, so each test proves the conformance reaches the core it
/// names with the phone's identity and nothing else.
///
/// Tier 2: in-memory GRDB, a dry-run tmux and a real actuation log under the
/// run's fenced scratch dir.
@Suite("RPCRouter PhoneSessionActions")
struct RPCRouterPhoneSessionActionsTests {

    private struct Fixture {
        let db: TBDDatabase
        let router: RPCRouter
        let logPath: String

        var actions: any PhoneSessionActions { router }

        func actuationRows() -> [ActuationRow] {
            ActuationRecordReader(activePath: logPath).readRows()
        }
    }

    /// The router fixture of `RPCRouterRemoteAnswerTests`, with no remote
    /// manager. The router records no app identity, so the socket check that
    /// guards `prompt.answer` refuses every caller that reaches it. It has a
    /// holder registry double, so the spawn gate grants it and a create
    /// reaches the handler's repo lookup; the double starts no holder.
    private func makeFixture() throws -> Fixture {
        let directory = URL(
            fileURLWithPath: fencedScratchRoot(prefix: "tbd-phone-actions"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logPath = directory.appendingPathComponent("actuations.jsonl").path
        let db = try TBDDatabase(inMemory: true)
        let subs = StateSubscriptionManager()
        let registry = makeHolderRegistryDouble(launch: FakeHolderLaunch())
        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
            subscriptions: subs)
        lifecycle.holderRegistry = registry
        let router = RPCRouter(
            db: db,
            lifecycle: lifecycle,
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: subs,
            actuationLog: ActuationLog(path: logPath))
        router.holderRegistry = registry
        return Fixture(db: db, router: router, logPath: logPath)
    }

    private func makeWorktree(_ f: Fixture, name: String) async throws -> Worktree {
        let repo = try await f.db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        return try await f.db.worktrees.create(
            repoID: repo.id, name: name, branch: "main",
            path: "/tmp/acme-wt-\(UUID().uuidString)", tmuxServer: "tbd-acme")
    }

    // MARK: - Handler-backed methods carry the phone actor

    @Test func phoneWakeRecordsThePhoneActor() async throws {
        let f = try makeFixture()
        let worktree = try await makeWorktree(f, name: "acme-wt")
        let terminal = try await f.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude)
        let d = UUID()

        _ = try await f.actions.phoneWake(TerminalWakeParams(terminalID: terminal.id), deviceID: d)

        let request = try #require(f.actuationRows().first { $0.method == RPCMethod.terminalWake })
        #expect(request.actor.kind == ActuationActor.Kind.phone)
        #expect(request.actor.device == d.uuidString, "the record names the phone's pairing")
        #expect(request.target?.terminal == terminal.id.uuidString)
    }

    // MARK: - A phone's message outside the send rail

    /// Messages the send rail refuses, each with the refusal it gets, its
    /// text and its code: a NUL, the bracketed-paste end marker, and a
    /// message of zero-width characters only.
    private static let refusedMessages: [(text: String, refusal: CodedRefusal, code: RPCErrorCode)] = [
        ("\u{0}", PhoneMessageText.controlCharacterRefusal, .messageControlCharacter),
        ("\u{1b}[201~", PhoneMessageText.controlCharacterRefusal, .messageControlCharacter),
        ("\u{200B}\u{2060}", PhoneMessageText.emptyRefusal, .messageEmpty),
    ]

    @Test func aPhoneMessageIsVettedByTheSendRailsRules() {
        #expect(PhoneMessageText.vetted("first\r\nsecond\tthird") == .deliver("first\nsecond\tthird"))
        #expect(PhoneMessageText.vetted("lone\rreturn") == .refused(PhoneMessageText.controlCharacterRefusal))
        #expect(PhoneMessageText.vetted("bell\u{7}") == .refused(PhoneMessageText.controlCharacterRefusal))
        #expect(PhoneMessageText.vetted("\r\n") == .refused(PhoneMessageText.emptyRefusal))
        #expect(PhoneMessageText.vetted("") == .refused(PhoneMessageText.emptyRefusal))
    }

    /// A first message that may be absent, as a wake or a create carries it:
    /// nil or empty is no message and passes as it came, and any other text
    /// meets the whole rule.
    @Test func aFirstMessageIsVettedOnlyWhenThereIsOne() {
        #expect(PhoneMessageText.vettedFirstMessage(nil) == .deliver(nil))
        #expect(PhoneMessageText.vettedFirstMessage("") == .deliver(""))
        #expect(PhoneMessageText.vettedFirstMessage("first\r\nsecond") == .deliver("first\nsecond"))
        #expect(PhoneMessageText.vettedFirstMessage(" \n") == .refused(PhoneMessageText.emptyRefusal))
        #expect(PhoneMessageText.vettedFirstMessage("\u{0}") == .refused(PhoneMessageText.controlCharacterRefusal))
    }

    /// A new worktree's first message rides its first agent's spawn command,
    /// so it meets the send rail's refusals before the create handler runs,
    /// and a refused one creates nothing. The repo does not exist, so a
    /// create that reached the handler would throw `WorktreeLifecycleError`
    /// rather than answer.
    @Test func phoneCreateWorktreeRefusesAMessageTheSendRailRefuses() async throws {
        let f = try makeFixture()

        for (text, refusal, code) in Self.refusedMessages {
            let response = try await f.actions.phoneCreateWorktree(
                WorktreeCreateParams(repoID: UUID(), prompt: text), deviceID: UUID())
            #expect(response.success == false)
            #expect(response.error == refusal.text, "refusal for \(text.debugDescription)")
            #expect(response.errorCode == code.rawValue, "code for \(text.debugDescription)")
        }
        let worktrees = try await f.db.worktrees.list()
        #expect(worktrees.isEmpty, "a refused message creates no worktree row")
        let createRows = f.actuationRows().filter { $0.method == RPCMethod.worktreeCreate }
        #expect(createRows.isEmpty, "a refused message never reaches the create handler")
    }

    /// The create handler gets the first message with the send rail's line
    /// endings, and still only the repo and the message.
    @Test func phoneWorktreeCreateHandsTheHandlerTheMessageWithBareLineFeeds() throws {
        let repoID = UUID()
        let vetted = RPCRouter.phoneWorktreeCreateVetted(
            WorktreeCreateParams(repoID: repoID, prompt: "first\r\nsecond", model: "opus"))

        guard case .deliver(let params) = vetted else {
            Issue.record("a message with CRLF line endings was refused: \(vetted)")
            return
        }
        #expect(params.repoID == repoID)
        #expect(params.prompt == "first\nsecond")
        #expect(try encodedKeys(params) == ["repoID", "prompt"])
    }

    /// A create with no first message, nil or empty, carries no phone message,
    /// so no message rule applies and it reaches the handler, which throws for
    /// the missing repo.
    @Test func phoneCreateWorktreeWithNoFirstMessageStillReachesTheHandler() async throws {
        let f = try makeFixture()

        for prompt in [nil, ""] as [String?] {
            await #expect(throws: WorktreeLifecycleError.self) {
                _ = try await f.actions.phoneCreateWorktree(
                    WorktreeCreateParams(repoID: UUID(), prompt: prompt), deviceID: UUID())
            }
        }
    }

    /// A wake's message is the respawned session's first prompt, carried in a
    /// process's argument list, so it meets the send rail's refusals before
    /// the wake handler runs, and a refused one records no wake.
    @Test func phoneWakeRefusesAMessageTheSendRailRefuses() async throws {
        let f = try makeFixture()
        let worktree = try await makeWorktree(f, name: "acme-wt")
        let terminal = try await f.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude)

        for (text, refusal, code) in Self.refusedMessages {
            let response = try await f.actions.phoneWake(
                TerminalWakeParams(terminalID: terminal.id, prompt: text), deviceID: UUID())
            #expect(response.success == false)
            #expect(response.error == refusal.text, "refusal for \(text.debugDescription)")
            #expect(response.errorCode == code.rawValue, "code for \(text.debugDescription)")
        }
        let wakeRows = f.actuationRows().filter { $0.method == RPCMethod.terminalWake }
        #expect(wakeRows.isEmpty, "a refused message never reaches the wake handler")
    }

    /// The handler gets the message with the send rail's line endings.
    @Test func phoneWakeHandsTheHandlerTheMessageWithBareLineFeeds() async throws {
        let f = try makeFixture()
        let worktree = try await makeWorktree(f, name: "acme-wt")
        let terminal = try await f.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude)

        _ = try await f.actions.phoneWake(
            TerminalWakeParams(terminalID: terminal.id, prompt: "first\r\nsecond"), deviceID: UUID())

        let request = try #require(f.actuationRows().first { $0.method == RPCMethod.terminalWake })
        #expect(request.prompt == "first\nsecond")
    }

    /// A wake with an empty prompt carries no message, so no message rule
    /// applies and the handler runs.
    @Test func phoneWakeWithAnEmptyPromptStillReachesTheHandler() async throws {
        let f = try makeFixture()
        let worktree = try await makeWorktree(f, name: "acme-wt")
        let terminal = try await f.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude)

        let response = try await f.actions.phoneWake(
            TerminalWakeParams(terminalID: terminal.id, prompt: ""), deviceID: UUID())

        #expect(response.error != PhoneMessageText.emptyRefusal.text)
        let wakeRows = f.actuationRows().filter { $0.method == RPCMethod.terminalWake }
        #expect(wakeRows.count == 1)
    }

    /// Every worktree is asked about, and a plain shell is never reported on.
    @Test func phoneSessionStatesListsAgentTerminalsOnly() async throws {
        let f = try makeFixture()
        let first = try await makeWorktree(f, name: "acme-one")
        let second = try await makeWorktree(f, name: "acme-two")
        let shell = try await f.db.terminals.create(
            worktreeID: first.id, tmuxWindowID: "@0", tmuxPaneID: "%0", kind: .shell)
        let claude = try await f.db.terminals.create(
            worktreeID: first.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude)
        let codex = try await f.db.terminals.create(
            worktreeID: second.id, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .codex)

        let response = try await f.actions.phoneSessionStates()

        #expect(response.success, "error: \(response.error ?? "none")")
        let reports = try response.decodeResult(SessionStatesResult.self).reports
        let reported = Set(reports.map(\.terminalID))
        #expect(reported == [claude.id, codex.id])
        #expect(!reported.contains(shell.id), "a shell terminal is never reported on")
    }

    /// A row with no recorded kind is a shell when it carries no Claude
    /// session id, as the send rail reads it, so the phone never hears of it.
    /// A kindless row with a session id is Claude's and is reported. The app's
    /// `session.states` still reports both.
    @Test func phoneSessionStatesHidesAKindlessRowWithNoSession() async throws {
        let f = try makeFixture()
        let worktree = try await makeWorktree(f, name: "acme-kindless")
        let kindlessShell = try await f.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@3", tmuxPaneID: "%3")
        let kindlessClaude = try await f.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@4", tmuxPaneID: "%4",
            claudeSessionID: "sess-kindless")

        let response = try await f.actions.phoneSessionStates()

        #expect(response.success, "error: \(response.error ?? "none")")
        let reported = Set(try response.decodeResult(SessionStatesResult.self).reports.map(\.terminalID))
        #expect(reported == [kindlessClaude.id])
        #expect(!reported.contains(kindlessShell.id), "a kindless row with no session is a shell")

        let appResponse = try await f.router.handleSessionStates(
            JSONEncoder().encode(SessionStatesParams()))
        let appReported = Set(
            try appResponse.decodeResult(SessionStatesResult.self).reports.map(\.terminalID))
        #expect(appReported == [kindlessShell.id, kindlessClaude.id], "the app's handler is unchanged")
    }

    // MARK: - The answer core runs under the phone's pairing

    /// The socket check refuses every caller on this router, so an answer that
    /// reaches the terminal lookup took the paired-phone authority. The prompt's
    /// terminal does not exist, so the answer is `already_resolved`, and the
    /// record names the phone.
    @Test func phoneAnswerPromptSkipsTheSocketCheckAndRecordsThePhone() async throws {
        let f = try makeFixture()
        try await f.db.config.setTranscriptPromptAnswerEnabled(true)
        let d = UUID()
        let params = PromptAnswerParams(
            terminalID: UUID(), promptID: "p-1", answer: .permission(decision: .allow, message: nil))

        let response = try await f.actions.phoneAnswerPrompt(params, deviceID: d)

        #expect(response.error != RPCRouter.promptAnswerNotFromAppRefusal)
        #expect(response.success, "error: \(response.error ?? "none")")
        #expect(try response.decodeResult(PromptAnswerResult.self).outcome == .alreadyResolved)
        let request = try #require(f.actuationRows().first { $0.method == RPCMethod.promptAnswer })
        #expect(request.actor == ActuationActor.phone(deviceID: d))
    }

    // MARK: - The send rail

    /// The conformance reaches the paired-phone rail, which forces the gate on,
    /// so params that turn it off still cannot type into an open prompt.
    @Test func phoneSendIntoAnOpenPromptIsRefusedEvenWhenItsParamsTurnTheGateOff() async throws {
        let harness = try await SendHarness.make()
        _ = try await harness.db.terminals.setActivityState(
            id: harness.terminal.id,
            activityState: .waitingForUser,
            source: .programStatus,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            awaitingInputReason: AwaitingInputReason(
                message: "Allow Bash(rm -rf)?", hookEventName: "Notification",
                notificationType: "permission_prompt"))
        let actions: any PhoneSessionActions = harness.router
        let d = UUID()

        let response = try await actions.phoneSend(
            TerminalSendParams(
                terminalID: harness.terminal.id, submit: true,
                parts: [.text("hi")], envelope: .suppressed, gateOnAwaitingInput: false),
            deviceID: d)

        #expect(!response.success)
        #expect(try #require(response.error).contains("Allow Bash(rm -rf)?"))
        #expect(harness.tmux.pastedBodies.isEmpty, "nothing may be typed")

        let logPath = await harness.router.actuationLog.path
        let request = try #require(
            ActuationRecordReader(activePath: logPath).readRows()
                .first { $0.method == RPCMethod.terminalSend })
        #expect(request.actor == ActuationActor.phone(deviceID: d), "the record names the phone's pairing")
    }

    // MARK: - The conformance keeps only the fields a phone may set

    /// The keys `params` encodes. A nil optional encodes no key, so these are
    /// exactly the fields that are set.
    private func encodedKeys(_ params: some Encodable) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(params))
        return Set(try #require(object as? [String: Any]).keys)
    }

    /// A phone's create keeps the repo and the first message, and nothing
    /// else, whatever the bridge passed. Every field is set, so the rebuild has
    /// something to drop from each.
    @Test func phoneWorktreeCreateParamsKeepOnlyTheRepoAndTheFirstMessage() throws {
        let full = WorktreeCreateParams(
            repoID: UUID(), folder: "acme-folder", branch: "acme-branch", displayName: "Acme",
            prompt: "first message", cols: 80, rows: 24, parentWorktreeID: UUID(),
            siblingOfWorktreeID: UUID(), callerWorktreeID: UUID(), suppressAutoParent: true,
            useExistingBranch: true, profileID: UUID(), model: "opus",
            primaryAgentPreference: .codex, claudeSettingsOverlay: "{}", prNumber: 7,
            checkoutPRHead: true, autoArchiveOnMerge: true, codexModel: "acme-model",
            pluginDirs: ["/nonexistent"])
        let narrowed = RPCRouter.phoneWorktreeCreateParams(full)

        #expect(try encodedKeys(narrowed) == ["repoID", "prompt"])
        #expect(narrowed.repoID == full.repoID)
        #expect(narrowed.prompt == "first message")
    }

    /// The socket's create refuses a missing plugin folder before it looks for
    /// the repo. The phone's create never carries the folder, so it gets past
    /// that check and stops at the missing repo instead.
    @Test func phoneCreateWorktreeIsNotRefusedForAPluginFolderItCannotSet() async throws {
        let f = try makeFixture()
        let params = WorktreeCreateParams(repoID: UUID(), prompt: "hi", pluginDirs: ["/nonexistent"])

        let socket = try await f.router.handleWorktreeCreate(JSONEncoder().encode(params))
        #expect(socket.error?.contains("plugin folder does not exist") == true)

        await #expect(throws: WorktreeLifecycleError.self) {
            _ = try await f.actions.phoneCreateWorktree(params, deviceID: UUID())
        }
    }

    /// A phone's wake keeps the terminal and the message, so it can never
    /// resume a session on the default account or pick its window size.
    @Test func phoneWakeParamsKeepOnlyTheTerminalAndTheMessage() throws {
        let full = TerminalWakeParams(
            terminalID: UUID(), cols: 80, rows: 24, fallbackToDefaultProfile: true, prompt: "hi")
        let narrowed = RPCRouter.phoneWakeParams(full)

        #expect(try encodedKeys(narrowed) == ["terminalID", "prompt"])
        #expect(narrowed.terminalID == full.terminalID)
        #expect(narrowed.prompt == "hi")
    }

    /// A phone's remote create keeps the provider and its form values.
    @Test func phoneRemoteCreateParamsKeepOnlyTheProviderAndItsFormValues() throws {
        let full = RemoteCreateParams(
            provider: "agentbox", paramsJSON: #"{"repo": "acme/api"}"#,
            parentWorktreeID: UUID(), seedRetainedKey: "acme-key")
        let narrowed = RPCRouter.phoneRemoteCreateParams(full)

        #expect(try encodedKeys(narrowed) == ["provider", "paramsJSON"])
        #expect(narrowed.provider == "agentbox")
        #expect(narrowed.paramsJSON == #"{"repo": "acme/api"}"#)
    }

    /// A phone's profile swap keeps the terminal, the new profile and the
    /// mode, so it never picks the window size.
    @Test func phoneSwapProfileParamsKeepOnlyTheTerminalTheProfileAndTheMode() throws {
        let full = TerminalSwapProfileParams(
            terminalID: UUID(), newProfileID: UUID(), cols: 80, rows: 24, mode: .fork)
        let narrowed = RPCRouter.phoneSwapProfileParams(full)

        #expect(try encodedKeys(narrowed) == ["terminalID", "newProfileID", "mode"])
        #expect(narrowed.terminalID == full.terminalID)
        #expect(narrowed.newProfileID == full.newProfileID)
        #expect(narrowed.mode == .fork)
    }

    /// A phone's remote message keeps the provider, the session and the text.
    @Test func phoneRemoteSendMessageParamsKeepTheProviderTheSessionAndTheText() throws {
        let full = RemoteSendMessageParams(provider: "agentbox", sessionID: "s-1", text: "hi")
        let narrowed = RPCRouter.phoneRemoteSendMessageParams(full)

        #expect(try encodedKeys(narrowed) == ["provider", "sessionID", "text"])
        #expect(narrowed.provider == "agentbox")
        #expect(narrowed.sessionID == "s-1")
        #expect(narrowed.text == "hi")
    }

    /// A phone's answer keeps the terminal, the prompt and the answer.
    @Test func phonePromptAnswerParamsKeepTheTerminalThePromptAndTheAnswer() throws {
        let full = PromptAnswerParams(
            terminalID: UUID(), promptID: "p-1", answer: .permission(decision: .allow, message: "ok"))
        let narrowed = RPCRouter.phonePromptAnswerParams(full)

        #expect(try encodedKeys(narrowed) == ["terminalID", "promptID", "answer"])
        #expect(narrowed.terminalID == full.terminalID)
        #expect(narrowed.promptID == "p-1")
        #expect(narrowed.answer == .permission(decision: .allow, message: "ok"))
    }

    /// A phone's remote answer keeps the provider, the session, the prompt and
    /// the answer.
    @Test func phoneRemoteAnswerParamsKeepTheProviderTheSessionThePromptAndTheAnswer() throws {
        let full = RemoteAnswerParams(
            provider: "agentbox", sessionID: "s-1", promptID: "p-1",
            answer: .question(answers: ["Which?": "A"]))
        let narrowed = RPCRouter.phoneRemoteAnswerParams(full)

        #expect(try encodedKeys(narrowed) == ["provider", "sessionID", "promptID", "answer"])
        #expect(narrowed.provider == "agentbox")
        #expect(narrowed.sessionID == "s-1")
        #expect(narrowed.promptID == "p-1")
        #expect(narrowed.answer == .question(answers: ["Which?": "A"]))
    }

    /// A phone's remote transcript reads keep the provider and the session.
    @Test func phoneRemoteTranscriptParamsKeepOnlyTheProviderAndTheSession() throws {
        let sync = RPCRouter.phoneRemoteTranscriptSyncParams(
            RemoteTranscriptSyncParams(provider: "agentbox", sessionID: "s-1"))
        #expect(try encodedKeys(sync) == ["provider", "sessionID"])
        #expect(sync.provider == "agentbox")
        #expect(sync.sessionID == "s-1")

        let earlier = RPCRouter.phoneRemoteTranscriptLoadEarlierParams(
            RemoteTranscriptLoadEarlierParams(provider: "agentbox", sessionID: "s-2"))
        #expect(try encodedKeys(earlier) == ["provider", "sessionID"])
        #expect(earlier.provider == "agentbox")
        #expect(earlier.sessionID == "s-2")
    }

    // MARK: - Remote sessions

    private struct RemoteFixture {
        let router: RPCRouter
        let manager: RemoteProviderManager
        let invoker: FakeProviderInvoker
        let logPath: String
        let registryURL: URL

        var actions: any PhoneSessionActions { router }

        func actuationRows() -> [ActuationRow] {
            ActuationRecordReader(activePath: logPath).readRows()
        }
    }

    /// The router fixture of `RPCRouterRemoteSeedTests`, with remote backends
    /// on and one provider, `agentbox`, that has already described itself.
    /// The router records no app identity, so the socket check refuses every
    /// caller that reaches it.
    private func makeRemoteFixture(_ script: [ProviderResult]) async throws -> RemoteFixture {
        let directory = URL(
            fileURLWithPath: fencedScratchRoot(prefix: "tbd-phone-actions-remote"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registryURL = directory.appendingPathComponent("agent-providers.json")
        try #"[{"name": "agentbox", "exec": "/nonexistent"}]"#
            .write(to: registryURL, atomically: true, encoding: .utf8)
        let logPath = directory.appendingPathComponent("actuations.jsonl").path
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setRemoteBackendsEnabled(true)
        let subs = StateSubscriptionManager()
        let invoker = FakeProviderInvoker(script: script)
        let manager = RemoteProviderManager(
            db: db, subscriptions: subs, runner: invoker, registryURL: registryURL,
            actuationLog: makeTestActuationLog())
        await manager.loadRegistryAndDescribe()
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
                subscriptions: subs),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: subs,
            remoteManager: manager,
            actuationLog: ActuationLog(path: logPath))
        return RemoteFixture(
            router: router, manager: manager, invoker: invoker, logPath: logPath, registryURL: registryURL)
    }

    private static func describeDeclaring(_ capabilities: [String]) -> ProviderResult {
        let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ", ")
        return providerOK(#"{"contract_versions": [1], "name": "agentbox", "capabilities": [\#(caps)]}"#)
    }

    /// A provider added to the registry file while the daemon runs is
    /// invisible to `phoneCachedRemoteProviders`, which reads the registry as
    /// last read, and registered by `phoneRemoteProviders`, which re-reads
    /// it as `remote.providers` does. The new provider's enrollment describe
    /// fails, so it starts no poll loop.
    @Test func onlyPhoneRemoteProvidersReReadsTheRegistry() async throws {
        let f = try await makeRemoteFixture([
            Self.describeDeclaring([]),
            ProviderResult(exitCode: 1, stdout: Data(), stderr: "acme describe failed"),
        ])
        try #"[{"name": "agentbox", "exec": "/nonexistent"}, {"name": "acmebox", "exec": "/nonexistent"}]"#
            .write(to: f.registryURL, atomically: true, encoding: .utf8)

        let cached = try await f.actions.phoneCachedRemoteProviders()
        let cachedNames = try cached.decodeResult(RemoteProvidersResult.self).providers.map(\.config.name)
        #expect(cachedNames == ["agentbox"])

        let refreshed = try await f.actions.phoneRemoteProviders()
        let refreshedNames = try refreshed.decodeResult(RemoteProvidersResult.self).providers.map(\.config.name)
        #expect(refreshedNames == ["acmebox", "agentbox"])
    }

    /// The socket's create refuses a seed for a provider that never declared
    /// `seed`. The phone's create never carries the seed, so the same params
    /// create a session, and the provider's stdin holds no `seed` field.
    @Test func phoneRemoteCreateIsNotRefusedForASeedItCannotSet() async throws {
        let f = try await makeRemoteFixture([
            Self.describeDeclaring([]),
            providerOK(#"{"id": "new-1", "state": "starting"}"#),
            providerOK(#"{"complete": true, "sessions": []}"#),
        ])
        let params = RemoteCreateParams(
            provider: "agentbox", paramsJSON: "{}", seedRetainedKey: "acme-key")
        let d = UUID()

        let socket = try await f.router.handleRemoteCreate(JSONEncoder().encode(params))
        #expect(socket.error?.contains("has not declared capability 'seed'") == true)

        let response = try await f.actions.phoneRemoteCreate(params, deviceID: d)

        #expect(response.success, "error: \(response.error ?? "none")")
        #expect(f.invoker.callsSnapshot() == [["describe"], ["create"], ["list"]])
        let stdin = try #require(f.invoker.stdinsSnapshot().compactMap { $0 }.first)
        let body = try #require(try JSONSerialization.jsonObject(with: stdin) as? [String: Any])
        #expect(body.keys.sorted() == ["idempotency_key", "params"])
        let request = try #require(f.actuationRows().first { $0.method == RPCMethod.remoteCreate })
        #expect(request.actor == ActuationActor.phone(deviceID: d))
    }

    /// Remote create form values holding `prompt` as their one value.
    private static func promptForm(_ prompt: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [PhoneMessageText.remoteCreatePromptField: prompt])
        return try #require(String(data: data, encoding: .utf8))
    }

    /// The provider pastes a new session's first message into it, so a first
    /// message the send rail refuses reaches no provider, creates nothing and
    /// records no create.
    @Test func phoneRemoteCreateRefusesAMessageTheSendRailRefuses() async throws {
        let f = try await makeRemoteFixture([Self.describeDeclaring([])])

        for (text, refusal, code) in Self.refusedMessages {
            let response = try await f.actions.phoneRemoteCreate(
                RemoteCreateParams(provider: "agentbox", paramsJSON: try Self.promptForm(text)),
                deviceID: UUID())
            #expect(response.success == false)
            #expect(response.error == refusal.text, "refusal for \(text.debugDescription)")
            #expect(response.errorCode == code.rawValue, "code for \(text.debugDescription)")
        }
        #expect(f.invoker.callsSnapshot() == [["describe"]], "a refused message never reaches the provider")
        let createRows = f.actuationRows().filter { $0.method == RPCMethod.remoteCreate }
        #expect(createRows.isEmpty)
    }

    /// The create handler gets the first message with the send rail's line
    /// endings, the other form values as they came, and still only the
    /// provider and the form values.
    @Test func phoneRemoteCreateVettedHandsTheHandlerTheMessageWithBareLineFeeds() throws {
        let full = RemoteCreateParams(
            provider: "agentbox", paramsJSON: #"{"prompt": "first\r\nsecond", "repo": "acme/api"}"#,
            parentWorktreeID: UUID(), seedRetainedKey: "acme-key")

        let vetted = RPCRouter.phoneRemoteCreateVetted(full)

        guard case .deliver(let params) = vetted else {
            Issue.record("a message with CRLF line endings was refused: \(vetted)")
            return
        }
        #expect(try encodedKeys(params) == ["provider", "paramsJSON"])
        #expect(params.provider == "agentbox")
        let form = try #require(
            try JSONSerialization.jsonObject(with: Data(params.paramsJSON.utf8)) as? [String: String])
        #expect(form == ["prompt": "first\nsecond", "repo": "acme/api"])
    }

    /// Form values with no first message carry no phone message, so they pass
    /// as they came, byte for byte.
    @Test func phoneRemoteCreateVettedKeepsFormValuesWithNoFirstMessage() {
        for paramsJSON in ["{}", #"{"prompt": ""}"#, #"{"repo": "acme/api"}"#, "not json"] {
            let vetted = RPCRouter.phoneRemoteCreateVetted(
                RemoteCreateParams(provider: "agentbox", paramsJSON: paramsJSON))
            guard case .deliver(let params) = vetted else {
                Issue.record("form values \(paramsJSON) were refused: \(vetted)")
                continue
            }
            #expect(params.paramsJSON == paramsJSON)
        }
    }

    /// A `prompt` that is there and is not a string is refused, whatever it
    /// holds: the provider would paste its own text for the value, which the
    /// phone message rule never saw, such as an array or an object holding
    /// the bracketed-paste end marker.
    @Test func phoneRemoteCreateVettedRefusesAPromptThatIsNotAString() throws {
        let marker = "\u{1b}[201~"
        let forms: [[String: Any]] = [
            [PhoneMessageText.remoteCreatePromptField: [marker, "acme"]],
            [PhoneMessageText.remoteCreatePromptField: ["text": marker]],
            [PhoneMessageText.remoteCreatePromptField: 3],
            [PhoneMessageText.remoteCreatePromptField: NSNull()],
        ]
        for form in forms {
            let data = try JSONSerialization.data(withJSONObject: form)
            let paramsJSON = try #require(String(data: data, encoding: .utf8))
            let vetted = RPCRouter.phoneRemoteCreateVetted(
                RemoteCreateParams(provider: "agentbox", paramsJSON: paramsJSON))
            guard case .refused(let reason) = vetted else {
                Issue.record("form values \(paramsJSON) were not refused: \(vetted)")
                continue
            }
            #expect(reason == RemoteCreateRefusal.promptNotString, "form \(paramsJSON)")
        }
    }

    /// Through the door, an array or an object `prompt` holding the
    /// bracketed-paste end marker reaches no provider, creates nothing and
    /// records no create.
    @Test func phoneRemoteCreateRefusesAPromptThatIsNotAString() async throws {
        let f = try await makeRemoteFixture([Self.describeDeclaring([])])
        let marker = "\u{1b}[201~"
        let forms: [[String: Any]] = [
            [PhoneMessageText.remoteCreatePromptField: [marker]],
            [PhoneMessageText.remoteCreatePromptField: ["text": marker]],
        ]

        for form in forms {
            let data = try JSONSerialization.data(withJSONObject: form)
            let paramsJSON = try #require(String(data: data, encoding: .utf8))
            let response = try await f.actions.phoneRemoteCreate(
                RemoteCreateParams(provider: "agentbox", paramsJSON: paramsJSON), deviceID: UUID())
            #expect(response.success == false)
            #expect(response.error == RemoteCreateRefusal.promptNotString.text, "form \(paramsJSON)")
            #expect(response.errorCode == RPCErrorCode.remotePromptNotText.rawValue, "form \(paramsJSON)")
        }
        #expect(f.invoker.callsSnapshot() == [["describe"]], "a refused prompt never reaches the provider")
        let createRows = f.actuationRows().filter { $0.method == RPCMethod.remoteCreate }
        #expect(createRows.isEmpty)
    }

    /// Every one of TBD's coded refusals answers with its words and its code,
    /// and keeps both across the wire. `RemoteCreateRefusal.formNotWritable`
    /// is checked only here: the form it would refuse came out of
    /// `JSONSerialization`, which always writes it out again, so no request
    /// reaches it.
    @Test func everyCodedRefusalAnswersWithItsTextAndItsCode() throws {
        let refusals: [(refusal: CodedRefusal, code: RPCErrorCode)] = [
            (RemoteGateRefusal.backendsDisabled, .remoteBackendsOff),
            (RemoteGateRefusal.claudeCloudDisabled, .claudeCloudOff),
            (PhoneMessageText.emptyRefusal, .messageEmpty),
            (PhoneMessageText.controlCharacterRefusal, .messageControlCharacter),
            (RemoteCreateRefusal.promptNotString, .remotePromptNotText),
            (RemoteCreateRefusal.formNotWritable, .remoteFormNotWritable),
            (RemoteSendMessageRefusal.exited, .remoteSessionExited),
            (RemoteSendMessageRefusal.waitingInput, .remoteSessionWaitingInput),
            (RemoteSendMessageRefusal.waitingInputAnswerOnCard, .remoteSessionWaitingInput),
            (RemoteTranscriptRefusal.dismissed, .remoteSessionDismissed),
            (RemoteTranscriptRefusal.loadEarlierOff, .loadEarlierOff),
            (RemoteTranscriptRefusal.nothingEarlier, .nothingEarlier),
            (RemoteTranscriptRefusal.removed, .remoteSessionRemoved),
            (PromptAnswerRefusal.disabled, .promptAnswerOff),
            (PromptAnswerRefusal.settingUnread, .promptAnswerSettingUnread),
            (PromptAnswerRefusal.notMirrored, .promptNotMirrored),
        ]

        for (refusal, code) in refusals {
            let sent = try JSONEncoder().encode(refusal.response)
            let received = try JSONDecoder().decode(RPCResponse.self, from: sent)
            #expect(received.success == false, "\(refusal.text)")
            #expect(received.error == refusal.text, "\(refusal.text)")
            #expect(received.errorCode == code.rawValue, "\(refusal.text)")
        }
    }

    /// Only the first message is held to the phone message rule. Every other
    /// form value may be one the laptop filled in, a stored create default
    /// among them, so a lone CR, a CRLF or a blank in one passes as it came:
    /// byte for byte when the first message needs no change, and as it was
    /// when the form is written out again around a changed first message.
    @Test func phoneRemoteCreateVettedLeavesEveryOtherFormValueAsItCame() throws {
        let unchanged = #"{"title": "first\rsecond", "prompt": "hi"}"#
        let kept = RPCRouter.phoneRemoteCreateVetted(RemoteCreateParams(provider: "agentbox", paramsJSON: unchanged))
        guard case .deliver(let keptParams) = kept else {
            Issue.record("a laptop default with a lone CR was refused: \(kept)")
            return
        }
        #expect(keptParams.paramsJSON == unchanged)

        let vetted = RPCRouter.phoneRemoteCreateVetted(RemoteCreateParams(
            provider: "agentbox",
            paramsJSON: #"{"title": "   ", "branch": "one\r\ntwo", "note": "a\rb", "prompt": "first\r\nsecond"}"#))
        guard case .deliver(let params) = vetted else {
            Issue.record("a laptop default was refused: \(vetted)")
            return
        }
        let form = try #require(
            try JSONSerialization.jsonObject(with: Data(params.paramsJSON.utf8)) as? [String: String])
        #expect(form == ["title": "   ", "branch": "one\r\ntwo", "note": "a\rb", "prompt": "first\nsecond"])
    }

    /// Through the door, a laptop default holding a lone CR in a field other
    /// than the first message reaches the provider as it came, with the
    /// first message's CRLF made a bare LF.
    @Test func phoneRemoteCreatePassesALaptopDefaultWithALoneCarriageReturn() async throws {
        let f = try await makeRemoteFixture([
            Self.describeDeclaring([]),
            providerOK(#"{"id": "new-1", "state": "starting"}"#),
            providerOK(#"{"complete": true, "sessions": []}"#),
        ])
        let data = try JSONSerialization.data(withJSONObject: [
            "title": "acme\rdefault", PhoneMessageText.remoteCreatePromptField: "first\r\nsecond",
        ])
        let paramsJSON = try #require(String(data: data, encoding: .utf8))

        let response = try await f.actions.phoneRemoteCreate(
            RemoteCreateParams(provider: "agentbox", paramsJSON: paramsJSON), deviceID: UUID())

        #expect(response.success, "error: \(response.error ?? "none")")
        let stdin = try #require(f.invoker.stdinsSnapshot().compactMap { $0 }.first)
        let body = try #require(try JSONSerialization.jsonObject(with: stdin) as? [String: Any])
        let form = try #require(body["params"] as? [String: Any])
        #expect(form["title"] as? String == "acme\rdefault")
        #expect(form["prompt"] as? String == "first\nsecond")
    }

    /// The provider's create gets the first message with bare line feeds, and
    /// the record names the phone.
    @Test func phoneRemoteCreateDeliversTheMessageWithBareLineFeeds() async throws {
        let f = try await makeRemoteFixture([
            Self.describeDeclaring([]),
            providerOK(#"{"id": "new-1", "state": "starting"}"#),
            providerOK(#"{"complete": true, "sessions": []}"#),
        ])
        let d = UUID()

        let response = try await f.actions.phoneRemoteCreate(
            RemoteCreateParams(provider: "agentbox", paramsJSON: try Self.promptForm("first\r\nsecond")),
            deviceID: d)

        #expect(response.success, "error: \(response.error ?? "none")")
        let stdin = try #require(f.invoker.stdinsSnapshot().compactMap { $0 }.first)
        let body = try #require(try JSONSerialization.jsonObject(with: stdin) as? [String: Any])
        let form = try #require(body["params"] as? [String: Any])
        #expect(form["prompt"] as? String == "first\nsecond")
        let request = try #require(f.actuationRows().first { $0.method == RPCMethod.remoteCreate })
        #expect(request.actor == ActuationActor.phone(deviceID: d))
    }

    /// The `remote.answer` core under the phone's pairing, through the door:
    /// no socket peer, delivered, and the record names the phone.
    @Test func phoneAnswerRemotePromptIsDeliveredAndRecordsThePhone() async throws {
        let f = try await makeRemoteFixture([
            Self.describeDeclaring([RemoteCapability.answer]),
            providerOK(#"""
                {"sessions": [{"id": "s-1", "state": "running", "agent_state": "waiting_input", \#
                "pending_prompt": {"id": "p-1", "kind": "permission", "tool_name": "Bash", \#
                "tool_input": {"command": "touch x"}}}]}
                """#),
            providerOK("{}"),
        ])
        try await f.router.db.config.setTranscriptPromptAnswerEnabled(true)
        await f.manager.pollOnce(provider: RemoteProviderConfig(name: "agentbox", exec: "/nonexistent"))
        let d = UUID()

        let response = try await f.actions.phoneAnswerRemotePrompt(
            RemoteAnswerParams(
                provider: "agentbox", sessionID: "s-1", promptID: "p-1",
                answer: .permission(decision: .allow, message: nil)),
            deviceID: d)

        #expect(response.success, "error: \(response.error ?? "none")")
        #expect(try response.decodeResult(PromptAnswerResult.self).outcome == .delivered)
        #expect(f.invoker.callsSnapshot().filter { $0.first == "answer" } == [["answer", "s-1", "p-1"]])
        let request = try #require(f.actuationRows().first { $0.method == RPCMethod.remoteAnswer })
        #expect(request.actor == ActuationActor.phone(deviceID: d), "the record names the phone's pairing")
    }

    /// The provider pastes a remote message into its session, so a message the
    /// send rail refuses reaches no provider and records no send.
    @Test func phoneRemoteSendMessageRefusesAMessageTheSendRailRefuses() async throws {
        let f = try await makeRemoteFixture([
            Self.describeDeclaring(["send", RemoteCapability.sendSubmit]),
        ])

        for (text, refusal, code) in Self.refusedMessages {
            let response = try await f.actions.phoneRemoteSendMessage(
                RemoteSendMessageParams(provider: "agentbox", sessionID: "s-1", text: text),
                deviceID: UUID())
            #expect(response.success == false)
            #expect(response.error == refusal.text, "refusal for \(text.debugDescription)")
            #expect(response.errorCode == code.rawValue, "code for \(text.debugDescription)")
        }
        #expect(f.invoker.callsSnapshot() == [["describe"]], "a refused message never reaches the provider")
        let sendRows = f.actuationRows().filter { $0.method == RPCMethod.remoteSendMessage }
        #expect(sendRows.isEmpty)
    }

    /// The provider gets the message with the send rail's line endings, and
    /// the record names the phone.
    @Test func phoneRemoteSendMessageDeliversTheMessageWithBareLineFeeds() async throws {
        let f = try await makeRemoteFixture([
            Self.describeDeclaring(["send", RemoteCapability.sendSubmit]),
            providerOK("{}"),
        ])
        let d = UUID()

        let response = try await f.actions.phoneRemoteSendMessage(
            RemoteSendMessageParams(provider: "agentbox", sessionID: "s-1", text: "first\r\nsecond"),
            deviceID: d)

        #expect(response.success, "error: \(response.error ?? "none")")
        #expect(f.invoker.callsSnapshot().last == ["send", "s-1", "--submit"])
        #expect(f.invoker.stdinsSnapshot().last ?? nil == Data("first\nsecond".utf8))
        let request = try #require(f.actuationRows().first { $0.method == RPCMethod.remoteSendMessage })
        #expect(request.actor == ActuationActor.phone(deviceID: d))
    }
}
