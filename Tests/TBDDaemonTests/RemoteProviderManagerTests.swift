import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// One scripted outcome for a `FakeProviderInvoker` call: either a canned
/// `ProviderResult` or a simulated provider timeout. Not `private` for the
/// same reason `FakeProviderInvoker` isn't.
enum FakeProviderOutcome: Sendable {
    case result(ProviderResult)
    /// Throws `ProviderRunError.timeout(verb:)` for this call — scripts the
    /// create-retry path (RPCRouterRemoteTests), which needs the FIRST
    /// invocation to time out and the SECOND to succeed with the SAME stdin.
    case timeout
}

/// Scriptable fake provider: each verb invocation pops the next canned
/// outcome. Intentionally NOT `private` — a later task's RPC-handler tests
/// reuse this against the same `RemoteProviderInvoking` protocol.
final class FakeProviderInvoker: RemoteProviderInvoking, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [FakeProviderOutcome]
    private(set) var calls: [[String]] = []
    /// stdin bytes for each call, same index as `calls`. `nil` entries are
    /// calls made with no stdin (e.g. `stop`/`log`).
    private(set) var stdins: [Data?] = []

    init(script: [ProviderResult]) {
        self.script = script.map { .result($0) }
    }

    /// Scriptable with timeouts interleaved among results.
    init(outcomes: [FakeProviderOutcome]) {
        self.script = outcomes
    }

    func run(
        _ config: RemoteProviderConfig, verb: [String], stdin: Data?,
        timeout: TimeInterval
    ) async throws -> ProviderResult {
        try popScript(verb, stdin: stdin)
    }

    /// Synchronous helper so the NSLock critical section isn't taken from an
    /// `async` context (recent Foundation marks `NSLock.lock`/`unlock` as
    /// unavailable from async contexts to discourage blocking there).
    private func popScript(_ verb: [String], stdin: Data?) throws -> ProviderResult {
        lock.lock()
        defer { lock.unlock() }
        calls.append(verb)
        stdins.append(stdin)
        precondition(!script.isEmpty, "FakeProviderInvoker script exhausted for verb \(verb)")
        switch script.removeFirst() {
        case .result(let result):
            return result
        case .timeout:
            throw ProviderRunError.timeout(verb: verb.first ?? "?")
        }
    }

    /// Locked snapshot of `calls`, for tests that read it while a manager's
    /// background poll `Task` may still be writing (the plain `calls`
    /// getter is fine only when nothing concurrent is running).
    func callsSnapshot() -> [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    /// Locked snapshot of `stdins`, same rationale as `callsSnapshot()`.
    func stdinsSnapshot() -> [Data?] {
        lock.lock()
        defer { lock.unlock() }
        return stdins
    }
}

/// Not `private` — reused by later provider-RPC tests in this target.
func providerOK(_ json: String) -> ProviderResult {
    ProviderResult(exitCode: 0, stdout: Data(json.utf8), stderr: "")
}

/// Thread-safe collector for broadcast StateDeltas, mirroring the pattern in
/// `RPCRouterWorktreeCreateBroadcastTests` / `GCHandlersTests`.
private final class BroadcastDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [StateDelta] = []

    func append(_ delta: StateDelta) {
        lock.lock()
        defer { lock.unlock() }
        deltas.append(delta)
    }

    func snapshot() -> [StateDelta] {
        lock.lock()
        defer { lock.unlock() }
        return deltas
    }
}

@Suite("RemoteProviderManager")
struct RemoteProviderManagerTests {
    let db: TBDDatabase
    let subs: StateSubscriptionManager
    let registryURL: URL

    init() throws {
        db = try TBDDatabase(inMemory: true)
        subs = StateSubscriptionManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        registryURL = dir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "fake", "exec": "/nonexistent/fake"}]"#
            .write(to: registryURL, atomically: true, encoding: .utf8)
    }

    private func manager(_ invoker: FakeProviderInvoker) -> RemoteProviderManager {
        RemoteProviderManager(db: db, subscriptions: subs, runner: invoker, registryURL: registryURL)
    }

    @Test func pollOnceAppliesSnapshotToMirror() async throws {
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"sessions": [{"id": "a", "state": "running", "agent_state": "working"}]}"#)
        ])
        let m = manager(invoker)
        await m.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))
        let rows = try await db.remoteSessions.list()
        #expect(rows.map(\.sessionID) == ["a"])
        #expect(invoker.calls == [["list"]])
        let status = await m.providerStatuses().first
        #expect(status?.health == .ok)
        #expect(status?.lastSuccessfulSnapshotAt != nil)
    }

    @Test func authFailureMarksNeedsAuthAndSuccessClears() async throws {
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(
                exitCode: 4,
                stdout: Data(
                    #"{"error": {"code": "auth_expired", "message": "expired", "remediation": {"label": "login", "command": "acme-provider login"}}}"#
                        .utf8),
                stderr: ""),
            providerOK(#"{"sessions": []}"#),
        ])
        let m = manager(invoker)
        let provider = RemoteProviderConfig(name: "fake", exec: "/x")
        await m.pollOnce(provider: provider)
        var statuses = await m.providerStatuses()
        #expect(statuses.first?.health == .needsAuth)
        #expect(statuses.first?.remediationCommand == "acme-provider login")
        await m.pollOnce(provider: provider)
        statuses = await m.providerStatuses()
        #expect(statuses.first?.health == .ok)
    }

    /// The error object's `code` adds precision the exit class lacks: a
    /// provider that names `auth_expired` while exiting 1 must still land in
    /// `needs_auth` WITH its remediation, not in the dead-end `error` state
    /// exit 1 alone would produce.
    @Test func nonFourExitCarryingAnAuthCodeStillLandsNeedsAuthWithRemediation() async throws {
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(
                exitCode: 1,
                stdout: Data(
                    #"{"error": {"code": "auth_expired", "message": "credentials expired", "remediation": {"label": "Sign in", "command": "acme-provider login"}}}"#
                        .utf8),
                stderr: "")
        ])
        let m = manager(invoker)
        await m.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))
        let statuses = await m.providerStatuses()
        #expect(statuses.first?.health == .needsAuth)
        #expect(statuses.first?.errorMessage == "credentials expired")
        #expect(statuses.first?.remediationLabel == "Sign in")
        #expect(statuses.first?.remediationCommand == "acme-provider login")
    }

    /// A non-auth `code` on a non-auth exit must NOT be widened into an auth
    /// state — the union rule only covers the contract's auth codes.
    @Test func nonAuthCodeOnExitOneStaysErrorNotNeedsAuth() async throws {
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(
                exitCode: 1,
                stdout: Data(
                    #"{"error": {"code": "credential_unresolvable", "message": "no such credential"}}"#.utf8),
                stderr: "")
        ])
        let m = manager(invoker)
        await m.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))
        let statuses = await m.providerStatuses()
        #expect(statuses.first?.health == .error)
        #expect(statuses.first?.errorMessage == "no such credential")
    }

    // MARK: - attach-exit correlation

    /// An auth-class `attach` exit (reported by the app, since the daemon
    /// never spawns attach itself) marks the provider `needs_auth` and fires
    /// exactly ONE out-of-band `list` — the authoritative probe that turns a
    /// bare exit code into a message + remediation.
    @Test func authAttachExitMarksNeedsAuthAndProbesOnce() async throws {
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(
                exitCode: 4,
                stdout: Data(
                    #"{"error": {"code": "auth_expired", "message": "expired", "remediation": {"label": "Sign in", "command": "acme-provider login"}}}"#
                        .utf8),
                stderr: "")
        ])
        let m = manager(invoker)
        try await m.recordAttachExit(provider: "fake", exitCode: 4)
        let statuses = await m.providerStatuses()
        #expect(statuses.first?.health == .needsAuth)
        #expect(
            statuses.first?.remediationCommand == "acme-provider login",
            "the out-of-band probe is what turns an exit code into a remediation")
        #expect(invoker.calls == [["list"]], "exactly one probe per health transition")
    }

    /// The other branch of the same gate: an attach exit arriving while the
    /// provider is ALREADY `needs_auth` must not fire another probe (a
    /// flapping session would otherwise turn into a poll flood), and must
    /// preserve the remediation already on file rather than clobbering it
    /// with the nothing an attach exit carries.
    @Test func authAttachExitWhileAlreadyNeedsAuthPreservesRemediationAndDoesNotReprobe() async throws
    {
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(
                exitCode: 4,
                stdout: Data(
                    #"{"error": {"code": "auth_expired", "message": "expired", "remediation": {"label": "Sign in", "command": "acme-provider login"}}}"#
                        .utf8),
                stderr: "")
        ])
        let m = manager(invoker)
        await m.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))
        #expect(invoker.calls == [["list"]])

        try await m.recordAttachExit(provider: "fake", exitCode: 4)

        let statuses = await m.providerStatuses()
        #expect(statuses.first?.health == .needsAuth)
        #expect(statuses.first?.errorMessage == "expired", "must not clobber a parsed message with nil")
        #expect(statuses.first?.remediationCommand == "acme-provider login")
        #expect(invoker.calls == [["list"]], "no second probe while already needs_auth")
    }

    /// Non-auth attach exits are the app's business (reconnect backoff), not
    /// provider health's: one flaky viewer must never speak for the whole
    /// provider.
    @Test func nonAuthAttachExitChangesNothing() async throws {
        let invoker = FakeProviderInvoker(script: [])
        let m = manager(invoker)
        try await m.recordAttachExit(provider: "fake", exitCode: 1)
        let statuses = await m.providerStatuses()
        #expect(statuses.first?.health == .ok)
        #expect(invoker.calls.isEmpty, "a transport-class attach exit must not trigger a probe")
    }

    /// Recovery: the poll loop keeps running while `needs_auth`, and the
    /// first successful `list` clears the state — no user gesture, no
    /// persisted flag.
    @Test func successfulPollAfterAnAttachAuthExitClearsNeedsAuth() async throws {
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(exitCode: 4, stdout: Data(), stderr: ""),  // the probe confirms
            providerOK(#"{"sessions": []}"#),  // the next poll succeeds
        ])
        let m = manager(invoker)
        try await m.recordAttachExit(provider: "fake", exitCode: 4)
        #expect(await m.providerStatuses().first?.health == .needsAuth)

        await m.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))

        #expect(await m.providerStatuses().first?.health == .ok)
    }

    /// Inheritance branch A — previous state IS `.needsAuth`, so the text on
    /// file is carried across. `recordAttachExit` preserves the remediation
    /// already on file, and the probe it fires must not undo that: a probe
    /// whose `list` also exits 4 but returns nothing parseable supplies no
    /// message/remediation of its own, and `recordFailure`'s auth branch
    /// falls back to what's on file rather than clobbering it with nil.
    @Test func aProbeWithUnparseableStdoutPreservesTheRemediationOnFile() async throws {
        let invoker = FakeProviderInvoker(script: [
            // First poll parses a full error object → message + remediation.
            ProviderResult(
                exitCode: 4,
                stdout: Data(
                    #"{"error": {"code": "auth_expired", "message": "expired", "remediation": {"label": "Sign in", "command": "acme-provider login"}}}"#
                        .utf8),
                stderr: ""),
            // The attach-exit probe re-confirms auth-needed but says nothing.
            ProviderResult(exitCode: 4, stdout: Data(), stderr: ""),
        ])
        let m = manager(invoker)
        let provider = RemoteProviderConfig(name: "fake", exec: "/x")
        await m.pollOnce(provider: provider)
        #expect(await m.providerStatuses().first?.remediationCommand == "acme-provider login")

        // Health is already `.needsAuth`, so `recordAttachExit` fires no
        // probe of its own — drive the probe-shaped call directly.
        await m.pollOnce(provider: provider)

        let statuses = await m.providerStatuses()
        #expect(statuses.first?.health == .needsAuth)
        #expect(
            statuses.first?.errorMessage == "expired",
            "an empty probe must not clobber the message on file")
        #expect(
            statuses.first?.remediationCommand == "acme-provider login",
            "an empty probe must not clobber the remediation on file")
    }

    /// Inheritance branch B — previous state is NOT `.needsAuth`, so nothing
    /// is carried across. A transport failure leaves a message like
    /// "connection timed out" on file under `.stale`; the auth failure that
    /// follows must not relabel that sentence as the provider's
    /// AUTHENTICATION explanation. With no parsed error of its own the CTA
    /// falls back to the app's neutral copy, which is correct-but-vague
    /// rather than confidently wrong.
    @Test func anAuthFailureFromStaleDoesNotInheritTheTransportMessage() async throws {
        let invoker = FakeProviderInvoker(script: [
            // Transient → .stale, message taken from stderr.
            ProviderResult(exitCode: 3, stdout: Data(), stderr: "connection timed out"),
            // Auth failure with nothing parseable in stdout.
            ProviderResult(exitCode: 4, stdout: Data(), stderr: ""),
        ])
        let m = manager(invoker)
        let provider = RemoteProviderConfig(name: "fake", exec: "/x")
        await m.pollOnce(provider: provider)
        #expect(await m.providerStatuses().first?.errorMessage == "connection timed out")

        await m.pollOnce(provider: provider)

        let statuses = await m.providerStatuses()
        #expect(statuses.first?.health == .needsAuth)
        #expect(
            statuses.first?.errorMessage == nil,
            "a transport message must not become the authentication explanation")
        #expect(statuses.first?.remediationCommand == nil)
    }

    /// Same branch, entered from `.error` rather than `.stale` — the two
    /// non-auth states reach the auth branch by different paths (permanent
    /// vs transient classification), and neither may donate its text.
    @Test func anAuthFailureFromErrorDoesNotInheritTheErrorMessage() async throws {
        let invoker = FakeProviderInvoker(script: [
            // Permanent → .error, with a parsed message on file.
            ProviderResult(
                exitCode: 1,
                stdout: Data(
                    #"{"error": {"code": "credential_unresolvable", "message": "no such credential"}}"#.utf8),
                stderr: ""),
            ProviderResult(exitCode: 4, stdout: Data(), stderr: ""),
        ])
        let m = manager(invoker)
        let provider = RemoteProviderConfig(name: "fake", exec: "/x")
        await m.pollOnce(provider: provider)
        #expect(await m.providerStatuses().first?.health == .error)

        await m.pollOnce(provider: provider)

        let statuses = await m.providerStatuses()
        #expect(statuses.first?.health == .needsAuth)
        #expect(
            statuses.first?.errorMessage == nil,
            "a provisioning error must not become the authentication explanation")
        #expect(statuses.first?.remediationCommand == nil)
    }

    /// The same gate on the attach path, whose `setHealth` is itself a
    /// transition into `.needsAuth`. Were it to carry the stale transport
    /// text across, the probe it fires would then inherit that text back
    /// through `recordFailure` (which now sees a previous state of
    /// `.needsAuth`) and the wrong words would survive the fix anyway.
    @Test func attachExitFromStaleDoesNotLaunderTheTransportMessageThroughTheProbe() async throws {
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(exitCode: 3, stdout: Data(), stderr: "connection timed out"),
            // The out-of-band probe re-confirms auth-needed but says nothing.
            ProviderResult(exitCode: 4, stdout: Data(), stderr: ""),
        ])
        let m = manager(invoker)
        await m.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))
        #expect(await m.providerStatuses().first?.health == .stale)

        try await m.recordAttachExit(provider: "fake", exitCode: 4)

        let statuses = await m.providerStatuses()
        #expect(statuses.first?.health == .needsAuth)
        #expect(
            statuses.first?.errorMessage == nil,
            "the transport message must not survive into the auth CTA via the probe")
        #expect(statuses.first?.remediationCommand == nil)
        #expect(
            invoker.calls == [["list"], ["list"]],
            "the transition off .stale still fires exactly one probe")
    }

    /// The other branch of the same fallback: a newly parsed value always
    /// wins over what's on file, so a provider that changes its remediation
    /// mid-outage is reflected rather than pinned to the first one seen.
    @Test func aFreshlyParsedRemediationWinsOverTheOneOnFile() async throws {
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(
                exitCode: 4,
                stdout: Data(
                    #"{"error": {"code": "auth_expired", "message": "expired", "remediation": {"label": "Sign in", "command": "acme-provider login"}}}"#
                        .utf8),
                stderr: ""),
            ProviderResult(
                exitCode: 4,
                stdout: Data(
                    #"{"error": {"code": "auth_expired", "message": "still expired", "remediation": {"label": "Sign in again", "command": "acme-provider login --renew"}}}"#
                        .utf8),
                stderr: ""),
        ])
        let m = manager(invoker)
        let provider = RemoteProviderConfig(name: "fake", exec: "/x")
        await m.pollOnce(provider: provider)
        await m.pollOnce(provider: provider)

        let statuses = await m.providerStatuses()
        #expect(statuses.first?.errorMessage == "still expired")
        #expect(statuses.first?.remediationCommand == "acme-provider login --renew")
    }

    // MARK: - Health broadcasting

    /// The payload of this whole feature reaches the app on a
    /// `needs_auth → needs_auth` transition: `recordAttachExit` flips health
    /// off a bare exit code carrying no message, and its probe is what lands
    /// the parsed message + remediation. Broadcasting on the health STATE
    /// alone dropped that second step silently, leaving the app on a
    /// command-less fallback CTA for the whole outage (every later poll is
    /// also needs_auth → needs_auth).
    @Test func addingARemediationWithoutAStateChangeStillBroadcasts() async throws {
        let deltas = BroadcastDeltas()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let withRemediation = ProviderResult(
            exitCode: 4,
            stdout: Data(
                #"{"error": {"code": "auth_expired", "message": "expired", "remediation": {"label": "Sign in", "command": "acme-provider login"}}}"#
                    .utf8),
            stderr: "")
        let invoker = FakeProviderInvoker(script: [
            // ok → needs_auth, message only, no remediation.
            ProviderResult(
                exitCode: 4,
                stdout: Data(#"{"error": {"code": "auth_expired", "message": "expired"}}"#.utf8),
                stderr: ""),
            // needs_auth → needs_auth, ADDING a remediation.
            withRemediation,
            // needs_auth → needs_auth, identical in all three fields.
            withRemediation,
        ])
        let m = manager(invoker)
        let provider = RemoteProviderConfig(name: "fake", exec: "/x")

        await m.pollOnce(provider: provider)
        #expect(healthBroadcastCount(deltas) == 1, "ok → needs_auth broadcasts")

        await m.pollOnce(provider: provider)
        #expect(
            healthBroadcastCount(deltas) == 2,
            "a remediation arriving on an already-needs_auth provider must reach the app")

        await m.pollOnce(provider: provider)
        #expect(
            healthBroadcastCount(deltas) == 2,
            "a genuinely unchanged re-set must not broadcast (60s polls would flood the wire)")
    }

    private func healthBroadcastCount(_ deltas: BroadcastDeltas) -> Int {
        deltas.snapshot().filter {
            if case .remoteSessionsChanged = $0 { return true }
            return false
        }.count
    }

    @Test func attachExitForAnUnknownProviderThrows() async throws {
        let m = manager(FakeProviderInvoker(script: []))
        await #expect(throws: (any Error).self) {
            try await m.recordAttachExit(provider: "nope", exitCode: 4)
        }
    }

    @Test func transientFailureMarksStaleNotAuth() async throws {
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(exitCode: 3, stdout: Data(), stderr: "flaky network")
        ])
        let m = manager(invoker)
        await m.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))
        let statuses = await m.providerStatuses()
        #expect(statuses.first?.health == .stale)
        // Stale poll must NOT touch the mirror (unreachable ≠ sessions dead).
        let rows = try await db.remoteSessions.list()
        #expect(rows.isEmpty)
    }

    /// Tier 1: in-memory GRDB and a scripted provider only.
    @Test func structuredTransientPollPreservesTheLastSuccessfulSnapshot() async throws {
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"sessions": [{"id": "a", "state": "running", "agent_state": "working"}]}"#),
            ProviderResult(
                exitCode: 3,
                stdout: Data(
                    #"{"error": {"code": "unreachable", "message": "provider transport overloaded", "retryable": true}}"#
                        .utf8),
                stderr: ""),
        ])
        let m = manager(invoker)
        let provider = RemoteProviderConfig(name: "fake", exec: "/x")

        await m.pollOnce(provider: provider)
        let firstSuccess = await m.providerStatuses().first?.lastSuccessfulSnapshotAt
        await m.pollOnce(provider: provider)

        let rows = try await db.remoteSessions.list()
        #expect(rows.map(\.sessionID) == ["a"])
        #expect(rows.first?.decodedPayload?.state == .running)
        #expect(rows.first?.gone == false)

        let status = await m.providerStatuses().first
        #expect(status?.health == .stale)
        #expect(status?.errorMessage == "provider transport overloaded")
        #expect(status?.lastSuccessfulSnapshotAt == firstSuccess)
        #expect(status?.hasStaleSnapshot == true)
        #expect(invoker.calls == [["list"], ["list"]])
    }

    @Test func truncatedInventoryErrorIsBoundedAndDoesNotExposeEmbeddedPayload() async throws {
        let embedded = String(repeating: #"{"prompt":"sensitive"}"#, count: 100)
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"sessions": [{"id": "a", "state": "running"}]}"#),
            ProviderResult(
                exitCode: 2, stdout: Data(),
                stderr: "unparseable remote output: \(embedded)--output truncated--"),
        ])
        let m = manager(invoker)
        let provider = RemoteProviderConfig(name: "fake", exec: "/x")
        await m.pollOnce(provider: provider)
        await m.pollOnce(provider: provider)

        let message = await m.providerStatuses().first?.errorMessage
        #expect(
            message
                == "Provider inventory was truncated or malformed; showing the last successful snapshot.")
        #expect(message?.contains("sensitive") == false)
    }

    @Test func firstTruncatedInventoryIsHonestWithoutSnapshot() async throws {
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(
                exitCode: 2, stdout: Data(),
                stderr: "unparseable remote output: private--output truncated--")
        ])
        let m = manager(invoker)
        await m.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))

        let message = await m.providerStatuses().first?.errorMessage
        #expect(
            message
                == "Provider inventory was truncated or malformed; no successful snapshot is available yet."
        )
        #expect(message?.contains("private") == false)
    }

    @Test func arbitraryProviderErrorIsCappedToTheWireLimit() async throws {
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(exitCode: 3, stdout: Data(), stderr: String(repeating: "x", count: 1_000))
        ])
        let m = manager(invoker)
        await m.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))
        let message = await m.providerStatuses().first?.errorMessage
        #expect(message?.count == 240)
        #expect(message?.hasSuffix("…") == true)
    }

    @Test func successfulInventoryAfterFailureRestoresFreshHealthAndAdvancesTimestamp() async throws {
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"sessions": [{"id": "a", "state": "running"}]}"#),
            ProviderResult(exitCode: 3, stdout: Data(), stderr: "temporary"),
            providerOK(#"{"sessions": [{"id": "a", "state": "running", "agent_state": "working"}]}"#),
        ])
        let m = manager(invoker)
        let provider = RemoteProviderConfig(name: "fake", exec: "/x")
        await m.pollOnce(provider: provider)
        let firstSuccess = await m.providerStatuses().first?.lastSuccessfulSnapshotAt
        await m.pollOnce(provider: provider)
        #expect(await m.hasStaleSnapshot(provider: "fake"))

        await m.pollOnce(provider: provider)

        let recovered = await m.providerStatuses().first
        #expect(recovered?.health == .ok)
        #expect(recovered?.hasStaleSnapshot == false)
        #expect(recovered?.lastSuccessfulSnapshotAt != nil)
        if let firstSuccess, let recoveredAt = recovered?.lastSuccessfulSnapshotAt {
            #expect(recoveredAt >= firstSuccess)
        }
    }

    /// Tier 1. An unreadable freshness row must gate mutations, because the
    /// daemon cannot prove the cached mirror was never authoritative. Contrast
    /// `eventUpsertCannotMasqueradeAsFullSnapshotAfterRestart`, where the read
    /// SUCCEEDS and returns "never" — that is positive knowledge and is allowed
    /// to fail open. Dropping `tbd_meta` makes the SELECT throw, which is the
    /// only way to reach the catch branch through the real store.
    @Test func unreadableFreshnessStateGatesMutationsInsteadOfFailingOpen() async throws {
        _ = try await db.remoteSessions.applySnapshot(
            provider: "fake",
            sessions: [RemoteSessionPayload(id: "a", state: .running)],
            now: Date(timeIntervalSince1970: 1_700_000_000))
        try await db.writerForTests.write { conn in
            try conn.execute(sql: "DROP TABLE tbd_meta")
        }
        let m = manager(
            FakeProviderInvoker(script: [
                ProviderResult(exitCode: 3, stdout: Data(), stderr: "offline")
            ]))

        await m.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))

        #expect(await m.hasStaleSnapshot(provider: "fake"))
        let status = await m.providerStatuses().first
        #expect(status?.health == .stale)
        // No timestamp is claimed — the daemon must not invent an age it
        // could not read.
        #expect(status?.lastSuccessfulSnapshotAt == nil)
    }

    /// Tier 1. The unreadable state is not sticky: it is a cache of one failed
    /// read, so a later successful snapshot must clear the gate rather than
    /// wedging the provider until daemon restart.
    @Test func unreadableFreshnessStateClearsOnceASnapshotSucceeds() async throws {
        try await db.writerForTests.write { conn in
            try conn.execute(sql: "DROP TABLE tbd_meta")
        }
        let m = manager(
            FakeProviderInvoker(script: [
                ProviderResult(exitCode: 3, stdout: Data(), stderr: "offline")
            ]))
        await m.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))
        #expect(await m.hasStaleSnapshot(provider: "fake"))

        try await db.writerForTests.write { conn in
            try conn.execute(
                sql: "CREATE TABLE tbd_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
        }
        try await m.apply(
            snapshot: [RemoteSessionPayload(id: "a", state: .running)],
            provider: "fake",
            now: Date(timeIntervalSince1970: 1_700_000_500))

        #expect(await m.hasStaleSnapshot(provider: "fake") == false)
        let status = await m.providerStatuses().first
        #expect(status?.health == .ok)
        #expect(status?.lastSuccessfulSnapshotAt == Date(timeIntervalSince1970: 1_700_000_500))
    }

    @Test func failureAfterManagerRestartRecoversLastSuccessTimeFromMirror() async throws {
        let lastGood = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "fake",
            sessions: [RemoteSessionPayload(id: "a", state: .running)],
            now: lastGood)
        let m = manager(
            FakeProviderInvoker(script: [
                ProviderResult(exitCode: 3, stdout: Data(), stderr: "offline")
            ]))

        await m.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))

        let status = await m.providerStatuses().first
        #expect(status?.health == .stale)
        #expect(status?.lastSuccessfulSnapshotAt == lastGood)
        #expect(status?.hasStaleSnapshot == true)
    }

    @Test func restartHydratesAndGatesBeforeTheInitialProviderPoll() async throws {
        let lastGood = Date(timeIntervalSince1970: 1_700_000_123)
        _ = try await db.remoteSessions.applySnapshot(
            provider: "fake",
            sessions: [RemoteSessionPayload(id: "a", state: .running)],
            now: lastGood)
        let invoker = FakeProviderInvoker(script: [])
        let m = manager(invoker)

        // Do not call start() or pollOnce(). RPC is deliberately available
        // before either can finish during daemon boot.
        let status = await m.providerStatuses().first

        #expect(status?.health == .stale)
        #expect(status?.lastSuccessfulSnapshotAt == lastGood)
        #expect(status?.hasStaleSnapshot == true)
        #expect(await m.hasStaleSnapshot(provider: "fake"))
        #expect(invoker.callsSnapshot().isEmpty)
    }

    @Test func eventUpsertCannotMasqueradeAsFullSnapshotAfterRestart() async throws {
        let eventTime = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await db.remoteSessions.upsertOne(
            provider: "fake",
            session: RemoteSessionPayload(id: "event-only", state: .running),
            now: eventTime)
        let m = manager(
            FakeProviderInvoker(script: [
                ProviderResult(exitCode: 3, stdout: Data(), stderr: "offline")
            ]))

        await m.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))

        let status = await m.providerStatuses().first
        #expect(status?.health == .stale)
        #expect(status?.lastSuccessfulSnapshotAt == nil)
        #expect(status?.hasStaleSnapshot == false)
    }

    @Test func invokeByNameRoutesToConfiguredProvider() async throws {
        // Only exercises verb routing, so it calls loadRegistryAndDescribe()
        // (registry + describe, no poll loop) rather than start() — no
        // background task exists, so the script needs exactly one describe
        // result plus the invoked verb's result, in that exact order.
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"contract_versions": [1], "name": "fake"}"#),
            providerOK(#"{"ok": true}"#),
        ])
        let m = manager(invoker)
        await m.loadRegistryAndDescribe()
        _ = try await m.invoke(providerName: "fake", verb: ["stop", "a"], stdin: nil, timeout: 30)
        #expect(invoker.calls == [["describe"], ["stop", "a"]])
    }

    @Test func invokeUnknownProviderThrows() async throws {
        let m = manager(FakeProviderInvoker(script: []))
        await #expect(throws: (any Error).self) {
            _ = try await m.invoke(providerName: "nope", verb: ["list"], stdin: nil, timeout: 30)
        }
    }

    @Test func repeatedIdenticalFailureBroadcastsHealthOnce() async throws {
        let deltas = BroadcastDeltas()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let invoker = FakeProviderInvoker(
            script: Array(
                repeating: ProviderResult(exitCode: 3, stdout: Data(), stderr: "flaky network"),
                count: 4))
        let m = manager(invoker)
        let provider = RemoteProviderConfig(name: "fake", exec: "/x")
        for _ in 0..<4 {
            await m.pollOnce(provider: provider)
        }
        let statuses = await m.providerStatuses()
        #expect(statuses.first?.health == .stale)
        let healthBroadcasts = deltas.snapshot().filter {
            if case .remoteSessionsChanged = $0 { return true }
            return false
        }
        #expect(
            healthBroadcasts.count == 1,
            "four identical failures must broadcast exactly once (ok→stale), not on every poll")
    }

    @Test func describeExitFourRoutesThroughFailurePathWithRemediation() async throws {
        // A provider that rejects credentials on its very first contact
        // (describe itself, before any poll ever runs) must still surface
        // needs_auth with remediation — describeProvider routes exit-4
        // through the same recordFailure path pollOnce/invoke use, not a
        // generic "couldn't parse describe" error.
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(
                exitCode: 4,
                stdout: Data(
                    #"{"error": {"code": "auth_expired", "message": "expired", "remediation": {"label": "login", "command": "fake login"}}}"#
                        .utf8),
                stderr: "")
        ])
        let m = manager(invoker)
        await m.loadRegistryAndDescribe()
        let statuses = await m.providerStatuses()
        #expect(statuses.first?.health == .needsAuth)
        #expect(statuses.first?.remediationLabel == "login")
        #expect(statuses.first?.remediationCommand == "fake login")
        #expect(invoker.calls == [["describe"]])
    }

    @Test func eventsCapabilityCreatesSupervisor() async throws {
        // A provider whose `describe` declares the `events` capability must
        // get a supervisor spawned for it alongside the always-on poll loop
        // — the low-latency path is entirely gated on this string match, so
        // a typo here would silently disable it for real providers.
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"contract_versions": [1], "name": "fake", "capabilities": ["events"]}"#),
            providerOK(#"{"sessions": []}"#),  // in case the 60s poll's first tick fires before teardown
        ])
        let m = manager(invoker)
        await m.start()
        #expect(
            await m.hasSupervisor(named: "fake"),
            "describe declaring the events capability must spawn a supervisor")
        await m.stopAll()
    }

    @Test func noEventsCapabilityPollsWithoutSupervisor() async throws {
        // The mirror-image branch: no `events` capability means no
        // supervisor, but the 60s `list` poll fallback must still cover the
        // provider (it's the universal floor, events-capable or not).
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"contract_versions": [1], "name": "fake"}"#),
            providerOK(#"{"sessions": []}"#),
        ])
        let m = manager(invoker)
        await m.start()
        #expect(
            await !m.hasSupervisor(named: "fake"),
            "describe without the events capability must not spawn a supervisor")

        // The poll loop's first tick fires with no initial delay but runs on
        // a background Task, so bound-poll for it rather than asserting
        // immediately.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if invoker.callsSnapshot().contains(["list"]) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            invoker.callsSnapshot().contains(["list"]),
            "provider without events capability must still be covered by the 60s list poll; observed calls=\(invoker.callsSnapshot())"
        )
        await m.stopAll()
    }

    @Test func versionMismatchNeverPolls() async throws {
        // describe negotiates no common contract version (provider only
        // speaks v2) — start() must surface a health error and must never
        // spawn a poll loop for this provider, so no `list` call is ever
        // recorded, not even after start() returns and would otherwise have
        // spawned loops for every successfully-described provider.
        let invoker = FakeProviderInvoker(script: [
            providerOK(#"{"contract_versions": [2], "name": "fake"}"#)
        ])
        let m = manager(invoker)
        await m.start()
        let statuses = await m.providerStatuses()
        #expect(statuses.first?.health == .error)
        #expect(statuses.first?.errorMessage == "no common contract version")
        #expect(invoker.calls == [["describe"]])
    }
}
