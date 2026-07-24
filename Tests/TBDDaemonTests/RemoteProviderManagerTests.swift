import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

/// Scriptable fake provider: each verb invocation pops the next canned result.
final class FakeInvoker: RemoteProviderInvoking, @unchecked Sendable {
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
        precondition(!script.isEmpty, "FakeInvoker script exhausted for verb \(verb)")
        return script.removeFirst()
    }
}

func ok(_ json: String) -> ProviderResult {
    ProviderResult(exitCode: 0, stdout: Data(json.utf8), stderr: "")
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

    private func manager(_ invoker: FakeInvoker) -> RemoteProviderManager {
        RemoteProviderManager(db: db, subscriptions: subs, runner: invoker, registryURL: registryURL)
    }

    @Test func pollOnceAppliesSnapshotToMirror() async throws {
        let invoker = FakeInvoker(script: [
            ok(#"{"sessions": [{"id": "a", "state": "running", "agent_state": "working"}]}"#)
        ])
        let m = manager(invoker)
        await m.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))
        let rows = try await db.remoteSessions.list()
        #expect(rows.map(\.sessionID) == ["a"])
        #expect(invoker.calls == [["list"]])
    }

    @Test func authFailureMarksNeedsAuthAndSuccessClears() async throws {
        let invoker = FakeInvoker(script: [
            ProviderResult(
                exitCode: 4,
                stdout: Data(#"{"error": {"code": "auth_expired", "message": "expired", "remediation": {"label": "login", "command": "aws sso login"}}}"#.utf8),
                stderr: ""),
            ok(#"{"sessions": []}"#),
        ])
        let m = manager(invoker)
        let provider = RemoteProviderConfig(name: "fake", exec: "/x")
        await m.pollOnce(provider: provider)
        var statuses = await m.providerStatuses()
        #expect(statuses.first?.health == "needs_auth")
        #expect(statuses.first?.remediationCommand == "aws sso login")
        await m.pollOnce(provider: provider)
        statuses = await m.providerStatuses()
        #expect(statuses.first?.health == "ok")
    }

    @Test func transientFailureMarksStaleNotAuth() async throws {
        let invoker = FakeInvoker(script: [
            ProviderResult(exitCode: 3, stdout: Data(), stderr: "flaky network")
        ])
        let m = manager(invoker)
        await m.pollOnce(provider: RemoteProviderConfig(name: "fake", exec: "/x"))
        let statuses = await m.providerStatuses()
        #expect(statuses.first?.health == "stale")
        // Stale poll must NOT touch the mirror (unreachable ≠ sessions dead).
        let rows = try await db.remoteSessions.list()
        #expect(rows.isEmpty)
    }

    @Test func invokeByNameRoutesToConfiguredProvider() async throws {
        // start() runs `describe` per registered provider before any invoke,
        // so the script needs a leading describe result or `describe` would
        // consume the `stop` verb's canned result and `invoke` would hit the
        // script-exhausted precondition. start() also spawns the 60s poll
        // loop, which fires an immediate first `list` call racing this
        // test's explicit `stop` invoke for whichever script entry comes
        // next — two spare entries (order-independent content) cover both
        // regardless of which wins, so #expect(...contains...) below stays a
        // membership check, not an ordering one.
        let invoker = FakeInvoker(script: [
            ok(#"{"contract_versions": [1], "name": "fake"}"#),
            ok(#"{"sessions": []}"#),
            ok(#"{"sessions": []}"#),
        ])
        let m = manager(invoker)
        await m.start()
        _ = try await m.invoke(providerName: "fake", verb: ["stop", "a"], stdin: nil, timeout: 30)
        await m.stopAll()   // cancel the poll loop so it can't fire again once the script is exhausted
        #expect(invoker.calls.first == ["describe"])
        #expect(invoker.calls.contains(["stop", "a"]))
    }

    @Test func invokeUnknownProviderThrows() async throws {
        let m = manager(FakeInvoker(script: []))
        await #expect(throws: (any Error).self) {
            _ = try await m.invoke(providerName: "nope", verb: ["list"], stdin: nil, timeout: 30)
        }
    }
}
