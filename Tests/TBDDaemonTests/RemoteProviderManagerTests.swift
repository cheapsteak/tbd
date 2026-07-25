import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

/// Scriptable fake provider: each verb invocation pops the next canned
/// result. Intentionally NOT `private` — a later task's RPC-handler tests
/// reuse this against the same `RemoteProviderInvoking` protocol.
final class FakeProviderInvoker: RemoteProviderInvoking, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [ProviderResult]
    private(set) var calls: [[String]] = []
    init(script: [ProviderResult]) { self.script = script }
    func run(_ config: RemoteProviderConfig, verb: [String], stdin: Data?,
             timeout: TimeInterval) async throws -> ProviderResult {
        popScript(verb)
    }

    /// Synchronous helper so the NSLock critical section isn't taken from an
    /// `async` context (recent Foundation marks `NSLock.lock`/`unlock` as
    /// unavailable from async contexts to discourage blocking there).
    private func popScript(_ verb: [String]) -> ProviderResult {
        lock.lock(); defer { lock.unlock() }
        calls.append(verb)
        precondition(!script.isEmpty, "FakeProviderInvoker script exhausted for verb \(verb)")
        return script.removeFirst()
    }

    /// Locked snapshot of `calls`, for tests that read it while a manager's
    /// background poll `Task` may still be writing (the plain `calls`
    /// getter is fine only when nothing concurrent is running).
    func callsSnapshot() -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return calls
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
        lock.lock(); defer { lock.unlock() }
        deltas.append(delta)
    }

    func snapshot() -> [StateDelta] {
        lock.lock(); defer { lock.unlock() }
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
    }

    @Test func authFailureMarksNeedsAuthAndSuccessClears() async throws {
        let invoker = FakeProviderInvoker(script: [
            ProviderResult(
                exitCode: 4,
                stdout: Data(#"{"error": {"code": "auth_expired", "message": "expired", "remediation": {"label": "login", "command": "aws sso login"}}}"#.utf8),
                stderr: ""),
            providerOK(#"{"sessions": []}"#),
        ])
        let m = manager(invoker)
        let provider = RemoteProviderConfig(name: "fake", exec: "/x")
        await m.pollOnce(provider: provider)
        var statuses = await m.providerStatuses()
        #expect(statuses.first?.health == .needsAuth)
        #expect(statuses.first?.remediationCommand == "aws sso login")
        await m.pollOnce(provider: provider)
        statuses = await m.providerStatuses()
        #expect(statuses.first?.health == .ok)
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
        let invoker = FakeProviderInvoker(script: Array(
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
        #expect(healthBroadcasts.count == 1,
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
                stdout: Data(#"{"error": {"code": "auth_expired", "message": "expired", "remediation": {"label": "login", "command": "fake login"}}}"#.utf8),
                stderr: ""),
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
            providerOK(#"{"sessions": []}"#),   // in case the 60s poll's first tick fires before teardown
        ])
        let m = manager(invoker)
        await m.start()
        #expect(await m.hasSupervisor(named: "fake"),
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
        #expect(await !m.hasSupervisor(named: "fake"),
                "describe without the events capability must not spawn a supervisor")

        // The poll loop's first tick fires with no initial delay but runs on
        // a background Task, so bound-poll for it rather than asserting
        // immediately.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if invoker.callsSnapshot().contains(["list"]) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(invoker.callsSnapshot().contains(["list"]),
                "provider without events capability must still be covered by the 60s list poll; observed calls=\(invoker.callsSnapshot())")
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
