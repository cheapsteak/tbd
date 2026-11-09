import Foundation
import GRDB
import TBDShared
import TestSupport

@testable import TBDDaemonLib

// Fakes and helpers for the phone app service's tests. Tier 1: everything here
// is in-process state, and nothing touches the disk or the network.

// MARK: - FakeSessionActions

/// A `PhoneSessionActions` that records every call and answers each method
/// with a canned `RPCResponse`: `RPCResponse.ok()` unless a test sets one with
/// `respond(to:with:)`.
///
/// `calls` lists every call in order with the device it acted for. Each method
/// that takes params also keeps them, typed, in its own list (`sends`,
/// `answers`, …), so a test can compare exactly what reached the daemon.
final class FakeSessionActions: PhoneSessionActions, @unchecked Sendable {
    /// The protocol's methods, one case each.
    enum Method: String, CaseIterable, Sendable {
        case sessionStates
        case answerPrompt
        case answerRemotePrompt
        case send
        case wake
        case swapProfile
        case createWorktree
        case remoteProviders
        case cachedRemoteProviders
        case remoteSessions
        case remoteCreate
        case remoteSendMessage
        case remoteTranscriptSync
        case remoteTranscriptLoadEarlier
    }

    /// One call: the method, and the device it acted for (nil for a read).
    struct Call: Equatable, Sendable {
        let method: Method
        let deviceID: UUID?
    }

    private struct Log {
        var calls: [Call] = []
        var answers: [PromptAnswerParams] = []
        var remoteAnswers: [RemoteAnswerParams] = []
        var sends: [TerminalSendParams] = []
        var wakes: [TerminalWakeParams] = []
        var swaps: [TerminalSwapProfileParams] = []
        var worktreeCreates: [WorktreeCreateParams] = []
        var remoteCreates: [RemoteCreateParams] = []
        var remoteSends: [RemoteSendMessageParams] = []
        var remoteSyncs: [RemoteTranscriptSyncParams] = []
        var remoteLoadEarliers: [RemoteTranscriptLoadEarlierParams] = []
    }

    /// Answers one call at the moment it is made.
    typealias Handler = @Sendable () -> RPCResponse

    private let lock = NSLock()
    private var log = Log()
    private var responses: [Method: RPCResponse] = [:]
    private var handlers: [Method: Handler] = [:]
    private var gates: [Method: PhoneTestGate] = [:]
    private var holderSpawns = true

    init() {}

    /// What `phoneSpawnsOnHolder` answers: true, the shipped default, unless
    /// a test puts new sessions on tmux. Not recorded in `calls`, since it
    /// acts on nothing.
    var spawnsOnHolder: Bool {
        get { lock.withLock { holderSpawns } }
        set { lock.withLock { holderSpawns = newValue } }
    }

    var calls: [Call] { lock.withLock { log.calls } }
    var answers: [PromptAnswerParams] { lock.withLock { log.answers } }
    var remoteAnswers: [RemoteAnswerParams] { lock.withLock { log.remoteAnswers } }
    var sends: [TerminalSendParams] { lock.withLock { log.sends } }
    var wakes: [TerminalWakeParams] { lock.withLock { log.wakes } }
    var swaps: [TerminalSwapProfileParams] { lock.withLock { log.swaps } }
    var worktreeCreates: [WorktreeCreateParams] { lock.withLock { log.worktreeCreates } }
    var remoteCreates: [RemoteCreateParams] { lock.withLock { log.remoteCreates } }
    var remoteSends: [RemoteSendMessageParams] { lock.withLock { log.remoteSends } }
    var remoteSyncs: [RemoteTranscriptSyncParams] { lock.withLock { log.remoteSyncs } }
    var remoteLoadEarliers: [RemoteTranscriptLoadEarlierParams] { lock.withLock { log.remoteLoadEarliers } }

    /// Every later call of `method` answers `response`.
    func respond(to method: Method, with response: RPCResponse) {
        lock.withLock { responses[method] = response }
    }

    /// Every later call of `method` answers what `handler` returns when the
    /// call is made, in place of any `respond(to:with:)`. The handler runs
    /// outside the fake's lock, so it may do work of its own, such as
    /// writing the file a remote transcript sync would.
    func handle(_ method: Method, with handler: @escaping Handler) {
        lock.withLock { handlers[method] = handler }
    }

    /// Every later call of `method` is recorded at once, then holds its
    /// response until `gate` opens. Only the answer methods honour it.
    func hold(_ method: Method, on gate: PhoneTestGate) {
        lock.withLock { gates[method] = gate }
    }

    private func gate(for method: Method) -> PhoneTestGate? {
        lock.withLock { gates[method] }
    }

    /// Every later `phoneRemoteProviders` answers one registered provider,
    /// `name`, that declares `capabilities` in its `describe`.
    func registerProvider(_ name: String, capabilities: [String]) throws {
        let provider = RemoteProviderStatus(
            config: RemoteProviderConfig(name: name, exec: "/usr/local/bin/acme-provider"),
            describe: ProviderDescribe(name: name, capabilities: capabilities), health: .ok,
            errorMessage: nil, remediationLabel: nil, remediationCommand: nil)
        respond(to: .remoteProviders, with: try RPCResponse(result: RemoteProvidersResult(providers: [provider])))
    }

    /// Every later `phoneRemoteSessions` lists one running session,
    /// `sessionID` of `provider`, resolved to `repoID` when one is given, so
    /// an action on it passes the phone's visibility check once its provider
    /// is registered.
    func listRemoteSession(
        _ provider: String, _ sessionID: String, resolvedRepoID: UUID? = nil, dismissed: Bool = false
    ) throws {
        let info = RemoteSessionInfo(
            provider: provider, payload: RemoteSessionPayload(id: sessionID, state: .running),
            gone: false, dismissed: dismissed, lastSeen: Date(timeIntervalSince1970: 1_800_000_000),
            resolvedRepoID: resolvedRepoID)
        respond(to: .remoteSessions, with: try RPCResponse(result: RemoteSessionsResult(sessions: [info])))
    }

    /// Records a call of `method` and answers what `answering`, `method`
    /// unless given, is set to answer.
    private func record(
        _ method: Method, deviceID: UUID?, answering: Method? = nil, keep: (inout Log) -> Void = { _ in }
    ) -> RPCResponse {
        let source = answering ?? method
        let (handler, response) = lock.withLock { () -> (Handler?, RPCResponse) in
            log.calls.append(Call(method: method, deviceID: deviceID))
            keep(&log)
            return (handlers[source], responses[source] ?? .ok())
        }
        return handler?() ?? response
    }

    func phoneSessionStates() async throws -> RPCResponse {
        record(.sessionStates, deviceID: nil)
    }

    func phoneAnswerPrompt(_ p: PromptAnswerParams, deviceID: UUID) async throws -> RPCResponse {
        let response = record(.answerPrompt, deviceID: deviceID) { $0.answers.append(p) }
        await gate(for: .answerPrompt)?.wait()
        return response
    }

    func phoneAnswerRemotePrompt(_ p: RemoteAnswerParams, deviceID: UUID) async throws -> RPCResponse {
        let response = record(.answerRemotePrompt, deviceID: deviceID) { $0.remoteAnswers.append(p) }
        await gate(for: .answerRemotePrompt)?.wait()
        return response
    }

    func phoneSend(_ p: TerminalSendParams, deviceID: UUID) async throws -> RPCResponse {
        record(.send, deviceID: deviceID) { $0.sends.append(p) }
    }

    func phoneWake(_ p: TerminalWakeParams, deviceID: UUID) async throws -> RPCResponse {
        record(.wake, deviceID: deviceID) { $0.wakes.append(p) }
    }

    func phoneSwapProfile(_ p: TerminalSwapProfileParams, deviceID: UUID) async throws -> RPCResponse {
        record(.swapProfile, deviceID: deviceID) { $0.swaps.append(p) }
    }

    func phoneCreateWorktree(_ p: WorktreeCreateParams, deviceID: UUID) async throws -> RPCResponse {
        record(.createWorktree, deviceID: deviceID) { $0.worktreeCreates.append(p) }
    }

    func phoneSpawnsOnHolder() async -> Bool {
        spawnsOnHolder
    }

    func phoneRemoteProviders() async throws -> RPCResponse {
        record(.remoteProviders, deviceID: nil)
    }

    /// Answers what `phoneRemoteProviders` is set to answer, since both read
    /// one roster, and is recorded as a call of its own.
    func phoneCachedRemoteProviders() async throws -> RPCResponse {
        record(.cachedRemoteProviders, deviceID: nil, answering: .remoteProviders)
    }

    func phoneRemoteSessions() async throws -> RPCResponse {
        record(.remoteSessions, deviceID: nil)
    }

    func phoneRemoteCreate(_ p: RemoteCreateParams, deviceID: UUID) async throws -> RPCResponse {
        record(.remoteCreate, deviceID: deviceID) { $0.remoteCreates.append(p) }
    }

    func phoneRemoteSendMessage(_ p: RemoteSendMessageParams, deviceID: UUID) async throws -> RPCResponse {
        record(.remoteSendMessage, deviceID: deviceID) { $0.remoteSends.append(p) }
    }

    func phoneRemoteTranscriptSync(_ p: RemoteTranscriptSyncParams) async throws -> RPCResponse {
        record(.remoteTranscriptSync, deviceID: nil) { $0.remoteSyncs.append(p) }
    }

    func phoneRemoteTranscriptLoadEarlier(_ p: RemoteTranscriptLoadEarlierParams) async throws -> RPCResponse {
        record(.remoteTranscriptLoadEarlier, deviceID: nil) { $0.remoteLoadEarliers.append(p) }
    }
}

// MARK: - CapturingOutbox

/// A `PhoneAppOutbox` that keeps every app body sent through it, in order.
/// `send` returns true unless `phoneGone` is set; the body is kept either way.
final class CapturingOutbox: PhoneAppOutbox, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [Data] = []
    private var gone = false

    init() {}

    var bodies: [Data] { lock.withLock { sent } }

    var phoneGone: Bool {
        get { lock.withLock { gone } }
        set { lock.withLock { gone = newValue } }
    }

    func send(appBody: Data) async -> Bool {
        lock.withLock {
            sent.append(appBody)
            return !gone
        }
    }

    /// The body sent `index`th (from 0), once it has arrived. The service
    /// sends from tasks of its own, so a test waits here rather than reading
    /// `bodies` straight away. Throws a `BoundedWaitTimeout` when the body
    /// has not arrived within `TestDeadlines.saturatedPass`, so a missing
    /// reply fails the test instead of hanging it.
    func body(at index: Int) async throws -> Data {
        let deadline = TestDeadlines.saturatedPass
        switch await pollUntilTrue(timeout: deadline, { self.bodies.count > index }) {
        case .satisfied:
            return bodies[index]
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            throw BoundedWaitTimeout(what: "app body #\(index)", observed: "\(bodies.count) bodies", deadline: deadline)
        }
    }
}

// MARK: - CapturingRecorder

/// A `PhoneActionRecording` that keeps every record, in order.
final class CapturingRecorder: PhoneActionRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [PhoneActionRecord] = []

    init() {}

    var records: [PhoneActionRecord] { lock.withLock { kept } }

    func record(_ r: PhoneActionRecord) {
        lock.withLock { kept.append(r) }
    }
}

// MARK: - PhoneTestGate

/// Holds a stand-in handler until the test opens the gate, or until the
/// handler's task is cancelled. Each waiter gets an `AsyncStream` of its own,
/// so any number can wait at once.
final class PhoneTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [AsyncStream<Void>.Continuation] = []

    init() {}

    /// Returns once the gate is open or the calling task is cancelled.
    func wait() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let alreadyOpen = lock.withLock { () -> Bool in
            if !isOpen { waiters.append(continuation) }
            return isOpen
        }
        if alreadyOpen { return }
        for await _ in stream {}
    }

    func open() {
        let pending = lock.withLock { () -> [AsyncStream<Void>.Continuation] in
            isOpen = true
            let pending = waiters
            waiters = []
            return pending
        }
        for continuation in pending { continuation.finish() }
    }
}

// MARK: - HeldPhoneControlRead

/// A phone control read for `PhoneAppService(readPhoneControl:)` whose first
/// call waits until `gate` opens, so a test can act while a request is
/// suspended in it. Every call, the first included, then reads the flag from
/// the database it is given.
final class HeldPhoneControlRead: @unchecked Sendable {
    let gate = PhoneTestGate()
    private let lock = NSLock()
    private var count = 0

    init() {}

    /// How many reads have started, the held one included.
    var reads: Int { lock.withLock { count } }

    func read(_ db: TBDDatabase) async throws -> Bool {
        let isFirst = lock.withLock { () -> Bool in
            count += 1
            return count == 1
        }
        if isFirst {
            await gate.wait()
        }
        return try await db.config.get().phoneControlEnabled
    }
}

// MARK: - HeldPairingRead

/// A pairing read for `PhoneAppService(readPairing:)` whose first call reads
/// the device's row and then waits until `gate` opens before answering what
/// it read, so a test can revoke the phone between a request's pairing read
/// and its handler, as a revoke that deletes the row just after the read
/// does. Every later call reads the row and answers at once.
final class HeldPairingRead: @unchecked Sendable {
    let gate = PhoneTestGate()
    private let lock = NSLock()
    private var count = 0

    init() {}

    /// How many reads have started, the held one included.
    var reads: Int { lock.withLock { count } }

    func read(_ db: TBDDatabase, _ deviceID: UUID) async throws -> Bool {
        let paired = try await db.phoneDevices.device(id: deviceID) != nil
        let isFirst = lock.withLock { () -> Bool in
            count += 1
            return count == 1
        }
        if isFirst {
            await gate.wait()
        }
        return paired
    }
}

// MARK: - FailingPairingRead

/// A pairing read for `PhoneAppService(readPairing:)` that throws on its
/// first `failures` calls, as a database read that fails does, and reads the
/// device's row on every call after them.
final class FailingPairingRead: @unchecked Sendable {
    struct ReadFailed: Error {}

    private let lock = NSLock()
    private var remaining: Int
    private var count = 0

    init(failures: Int) {
        remaining = failures
    }

    /// How many reads have started, the failed ones included.
    var reads: Int { lock.withLock { count } }

    func read(_ db: TBDDatabase, _ deviceID: UUID) async throws -> Bool {
        let fails = lock.withLock { () -> Bool in
            count += 1
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        if fails {
            throw ReadFailed()
        }
        return try await db.phoneDevices.device(id: deviceID) != nil
    }
}

// MARK: - Waiting

/// Waits until `condition` holds, or throws naming `what`.
func waitUntil(_ what: String, _ condition: () async -> Bool) async throws {
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

// MARK: - Requests and replies

/// A reply as a test reads it: its request ID, and its error when it has one.
struct PhoneTestReply: Decodable, Equatable {
    let kind: String
    let requestID: String
    let error: PhoneAppError?
}

enum PhoneTestRequests {
    /// The app body of a request.
    static func body<P: Codable>(_ method: PhoneAppMethod, id: String, params: P) throws -> Data {
        try PhoneAppCoding.makeEncoder().encode(
            PhoneRequestEnvelope(requestID: id, method: method.rawValue, params: params))
    }
}

/// A provider's error that quotes a URL with an access token in it, for the
/// tests that prove a provider's words never reach a phone.
enum PhoneProviderSecret {
    static let error = "POST https://acme-control.example/v1?access_token=sk-test"

    /// Whether `bytes`, a body sent to a phone, hold any part of the secret.
    static func leaks(_ bytes: Data) -> Bool {
        let text = String(decoding: bytes, as: UTF8.self)
        return text.contains("access_token") || text.contains("sk-test")
    }
}

// MARK: - PhoneServiceHarness

/// A `PhoneAppService` over an in-memory database with phone control on and
/// one paired phone named "Acme Phone", with fakes for everything it calls
/// and an `EventDrivenTestClock` for its timers. `subscriptions` and
/// `pendingPrompts` are the service's own, so a test can open prompts and
/// broadcast state deltas to it.
struct PhoneServiceHarness: Sendable {
    let db: TBDDatabase
    let actions: FakeSessionActions
    let recorder: CapturingRecorder
    let clock: EventDrivenTestClock
    let subscriptions: StateSubscriptionManager
    let pendingPrompts: PendingPromptStore
    let service: PhoneAppService
    let peer: PhonePeer

    /// With `phoneControlRead`, the service reads the phone control flag
    /// through it, so a test can hold the first read still; with
    /// `phoneControlAlwaysOn`, the flag reads on without a database read, so
    /// a request still reaches its handler once a test has made the config
    /// row unreadable (`makeConfigUnreadable()`); with `pairingRead`, it
    /// reads each request's pairing through it, so a test can hold that
    /// read still; with `failingPairingRead`, each request's pairing read goes
    /// through it, so a test can make the first reads fail; with `dates`,
    /// the service's date seam (`now`) reads it, so a test can move the date.
    static func make(
        phoneControlRead: HeldPhoneControlRead? = nil, phoneControlAlwaysOn: Bool = false,
        pairingRead: HeldPairingRead? = nil, failingPairingRead: FailingPairingRead? = nil,
        dates: TestDateSource? = nil
    ) async throws -> PhoneServiceHarness {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPhoneControlEnabled(true)
        let peer = PhonePeer(deviceID: UUID(), deviceName: "Acme Phone")
        try await db.phoneDevices.insert(PhoneDevice(
            id: peer.deviceID, name: peer.deviceName, publicKey: Data(repeating: 7, count: 32),
            roomID: UUID().uuidString, pairedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let actions = FakeSessionActions()
        let recorder = CapturingRecorder()
        let clock = EventDrivenTestClock()
        let subscriptions = StateSubscriptionManager()
        let pendingPrompts = PendingPromptStore()
        var readPhoneControl: (@Sendable () async throws -> Bool)?
        if let phoneControlRead {
            readPhoneControl = { try await phoneControlRead.read(db) }
        } else if phoneControlAlwaysOn {
            readPhoneControl = { true }
        }
        var readPairing: (@Sendable (UUID) async throws -> Bool)?
        if let pairingRead {
            readPairing = { deviceID in try await pairingRead.read(db, deviceID) }
        } else if let failingPairingRead {
            readPairing = { deviceID in try await failingPairingRead.read(db, deviceID) }
        }
        let now: @Sendable () -> Date
        if let dates { now = dates.provider } else { now = { Date() } }
        let service = PhoneAppService(
            db: db, actions: actions, subscriptions: subscriptions,
            pendingPrompts: pendingPrompts, locateTranscript: Self.locateTranscript,
            recorder: recorder, readPhoneControl: readPhoneControl, readPairing: readPairing, now: now, clock: clock)
        return PhoneServiceHarness(
            db: db, actions: actions, recorder: recorder, clock: clock, subscriptions: subscriptions,
            pendingPrompts: pendingPrompts, service: service, peer: peer)
    }

    /// The production locator over a `projects/` root that does not exist,
    /// so a terminal's transcript is the `transcriptPath` a test stores on
    /// its row (`db.terminals.updateSession`), or none.
    static let locateTranscript: @Sendable (TBDShared.Terminal, String) -> String? = { terminal, worktreePath in
        ClaudeTranscriptLocator.filePath(
            terminal: terminal, worktreePath: worktreePath,
            projectsBase: URL(fileURLWithPath: "/acme-no-projects", isDirectory: true))
    }

    /// Drops the config table, so every later read of the config row fails,
    /// as a database read that fails does. A request then stops at the phone
    /// control check unless the harness was made with `phoneControlAlwaysOn`.
    func makeConfigUnreadable() async throws {
        try await db.writerForTests.write { conn in
            try conn.execute(sql: "DROP TABLE config")
        }
    }

    /// Connects the phone through a fresh outbox and returns it.
    func connect() async -> CapturingOutbox {
        let outbox = CapturingOutbox()
        await service.phoneConnected(peer, outbox: outbox)
        return outbox
    }

    /// Hands the service one request and returns the reply, which must be the
    /// next body `outbox` receives.
    func request<P: Codable>(_ method: PhoneAppMethod, id: String = UUID().uuidString, params: P,
                             on outbox: CapturingOutbox) async throws -> (reply: PhoneTestReply, bytes: Data) {
        try await send(PhoneTestRequests.body(method, id: id, params: params), on: outbox)
    }

    /// Hands the service one raw app body and returns the reply, which must be
    /// the next body `outbox` receives.
    func send(_ body: Data, on outbox: CapturingOutbox) async throws -> (reply: PhoneTestReply, bytes: Data) {
        let index = outbox.bodies.count
        await service.handleAppMessage(body, from: peer)
        let bytes = try await outbox.body(at: index)
        return (try JSONDecoder().decode(PhoneTestReply.self, from: bytes), bytes)
    }

    // MARK: Seeded sessions

    /// A terminal of `kind` in a new worktree of a new repo: a local
    /// worktree, or with `inRemoteLane` a remote lane's row, whose location
    /// is a provider's session. A Claude terminal has a Claude session ID, so
    /// it can be parked. `profileID` is the terminal's model profile, and
    /// `transport` the one it was born on; a holder row has empty tmux IDs,
    /// as it does when TBD makes one.
    func seedTerminal(
        kind: TerminalKind = .claude, inRemoteLane: Bool = false, profileID: UUID? = nil,
        transport: TerminalTransport = .tmux
    ) async throws -> TBDShared.Terminal {
        let repo = try await db.repos.create(
            path: "/acme/widgets-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktreeID: UUID
        if inRemoteLane {
            worktreeID = try await db.worktrees.createRemote(
                repoID: repo.id, name: "acme-remote", branch: "main",
                provider: "acme-cloud", sessionID: "rs-1").id
        } else {
            worktreeID = try await db.worktrees.create(
                repoID: repo.id, name: "acme-one", displayName: "Acme one", branch: "acme-one",
                path: "/acme/widgets-one-\(UUID().uuidString)", tmuxServer: "tbd-acme").id
        }
        let onHolder = transport == .holder
        return try await db.terminals.create(
            worktreeID: worktreeID, tmuxWindowID: onHolder ? "" : "@1", tmuxPaneID: onHolder ? "" : "%1",
            claudeSessionID: kind == .claude ? "acme-session" : nil, profileID: profileID, kind: kind,
            transport: transport)
    }

    /// Parks `terminalID` as the idle sweep does.
    func park(_ terminalID: UUID) async throws {
        try await db.terminals.setHibernated(
            id: terminalID, sessionID: "acme-session", reason: .auto,
            at: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// Records a permission dialog on `terminalID`'s screen, reported by the
    /// agent itself, with `message` as its text.
    func showPrompt(on terminalID: UUID, message: String) async throws {
        _ = try await db.terminals.setActivityState(
            id: terminalID,
            activityState: .waitingForUser,
            source: .programStatus,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            awaitingInputReason: AwaitingInputReason(
                message: message, programStatusBlock: ProgramStatusBlock(kind: .permission, taskID: nil)))
    }
}
