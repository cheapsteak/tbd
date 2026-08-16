import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

// Tier 2: spawns short-lived local stub scripts it fully controls.
@Suite("ProviderRunner")
struct ProviderRunnerTests: ~Copyable {
    let dir: URL
    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func stub(_ body: String) throws -> RemoteProviderConfig {
        let path = dir.appendingPathComponent("stub-\(UUID().uuidString).sh")
        try "#!/bin/bash\n\(body)\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return RemoteProviderConfig(name: "stub", exec: path.path)
    }

    @Test func successCapturesStdoutAndContractVersionEnv() async throws {
        let config = try stub(#"echo "{\"ok\": true, \"v\": \"$TBD_CONTRACT_VERSION\"}""#)
        let result = try await ProviderRunner().run(
            config, verb: ["list"], stdin: nil, timeout: 10, contractVersion: 1)
        #expect(result.exitCode == 0)
        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        #expect(text.contains(#""v": "1""#))
    }

    @Test func stdinIsDelivered() async throws {
        let config = try stub("cat")
        let result = try await ProviderRunner().run(
            config, verb: ["create"], stdin: Data("hello".utf8), timeout: 10, contractVersion: 1)
        #expect(String(data: result.stdout, encoding: .utf8) == "hello")
    }

    @Test func exitCodesClassify() async throws {
        let auth = try stub(#"echo '{"error": {"code": "auth_expired", "message": "x"}}'; exit 4"#)
        let result = try await ProviderRunner().run(
            auth, verb: ["list"], stdin: nil, timeout: 10, contractVersion: 1)
        #expect(result.failureClass == .authNeeded)
        #expect(result.decodedError?.code == "auth_expired")

        let transient = try stub("exit 3")
        let t = try await ProviderRunner().run(
            transient, verb: ["list"], stdin: nil, timeout: 10, contractVersion: 1)
        #expect(t.failureClass == .transient)
        #expect(t.decodedError == nil)   // unparseable stdout → class-only fallback

        let weird = try stub("exit 17")
        let w = try await ProviderRunner().run(
            weird, verb: ["list"], stdin: nil, timeout: 10, contractVersion: 1)
        #expect(w.failureClass == .permanent)
    }

    @Test func stderrIsCapturedSeparately() async throws {
        let config = try stub(#"echo '{"sessions": []}'; echo "diag" 1>&2"#)
        let result = try await ProviderRunner().run(
            config, verb: ["list"], stdin: nil, timeout: 10, contractVersion: 1)
        #expect(String(data: result.stdout, encoding: .utf8) == "{\"sessions\": []}\n")
        #expect(result.stderr.contains("diag"))
    }

    @Test func missingExecutableThrows() async throws {
        let config = RemoteProviderConfig(name: "gone", exec: dir.appendingPathComponent("nope").path)
        await #expect(throws: (any Error).self) {
            _ = try await ProviderRunner().run(
                config, verb: ["list"], stdin: nil, timeout: 10, contractVersion: 1)
        }
    }

    /// Required deviation from the brief: `readDataToEndOfFile()` inside
    /// `terminationHandler` deadlocks once a child writes more than the OS
    /// pipe buffer (~64KB on darwin) — the child blocks on the full pipe, so
    /// it never exits, so the termination handler never fires to drain it.
    /// This reproduces that with 300KB of stdout — well over the buffer —
    /// and asserts every byte comes back, proving the concurrent-drain fix
    /// (readabilityHandler draining while the child runs) actually works.
    /// Without the fix this test hangs until the 10s timeout, then fails.
    @Test func largeStdoutIsFullyCapturedWithoutDeadlock() async throws {
        let expectedByteCount = 300_000
        let config = try stub(#"yes "0123456789abcdef" | head -c \#(expectedByteCount)"#)
        let result = try await ProviderRunner().run(
            config, verb: ["log"], stdin: nil, timeout: 10, contractVersion: 1)
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == expectedByteCount)
    }
}
