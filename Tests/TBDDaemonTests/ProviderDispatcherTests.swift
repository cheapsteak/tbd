import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Tier 1: pure routing over two fakes.
@Suite("ProviderDispatcher")
struct ProviderDispatcherTests {
    /// A verb naming a reserved provider is served IN-PROCESS and never
    /// reaches `ProviderRunner`, so no registered-provider executable is
    /// spawned for it.
    @Test func aReservedNameIsServedInProcess() async throws {
        let subprocess = FakeProviderInvoker(script: [providerOK("{}")])
        let builtIn = FakeProviderInvoker(script: [providerOK(#"{"served":"builtin"}"#)])
        let dispatcher = ProviderDispatcher(
            subprocess: subprocess, builtIns: [ClaudeCloudProvider.name: builtIn])

        let result = try await dispatcher.run(
            RemoteProviderConfig(name: ClaudeCloudProvider.name, exec: "/opt/acme/claude"),
            verb: ["list"], stdin: nil, timeout: 30, contractVersion: 2)

        #expect(String(decoding: result.stdout, as: UTF8.self) == #"{"served":"builtin"}"#)
        #expect(builtIn.calls == [["list"]])
        #expect(subprocess.calls.isEmpty)
    }

    /// The discriminating half: a registered provider still goes through the
    /// runner, so the built-in entry did not capture everything.
    @Test func aRegisteredNameStillGoesThroughTheSubprocessArm() async throws {
        let subprocess = FakeProviderInvoker(script: [providerOK(#"{"served":"subprocess"}"#)])
        let builtIn = FakeProviderInvoker(script: [])
        let dispatcher = ProviderDispatcher(
            subprocess: subprocess, builtIns: [ClaudeCloudProvider.name: builtIn])

        let result = try await dispatcher.run(
            RemoteProviderConfig(name: "acme", exec: "/usr/bin/acme"),
            verb: ["list"], stdin: nil, timeout: 30, contractVersion: 1)

        #expect(String(decoding: result.stdout, as: UTF8.self) == #"{"served":"subprocess"}"#)
        #expect(subprocess.calls == [["list"]])
        #expect(builtIn.calls.isEmpty)
    }

    /// With no built-in registered — the cloud flag off at boot — the
    /// reserved name has no in-process entry and falls through like any other
    /// unknown provider, rather than being special-cased into a hole.
    @Test func anEmptyBuiltInTableRoutesEverythingToTheSubprocessArm() async throws {
        let subprocess = FakeProviderInvoker(script: [providerOK("{}")])
        let dispatcher = ProviderDispatcher(subprocess: subprocess, builtIns: [:])
        _ = try await dispatcher.run(
            RemoteProviderConfig(name: ClaudeCloudProvider.name, exec: "/opt/acme/claude"),
            verb: ["describe"], stdin: nil, timeout: 10, contractVersion: 2)
        #expect(subprocess.calls == [["describe"]])
    }

    /// Every argument reaches the selected arm unchanged — stdin and the
    /// negotiated major most of all, since the whole point of threading the
    /// major is that both conformances announce the value the daemon agreed
    /// to.
    @Test func stdinAndTheNegotiatedMajorReachTheBuiltInUnchanged() async throws {
        let builtIn = FakeProviderInvoker(script: [providerOK("{}")])
        let dispatcher = ProviderDispatcher(
            subprocess: FakeProviderInvoker(script: []),
            builtIns: [ClaudeCloudProvider.name: builtIn])

        _ = try await dispatcher.run(
            RemoteProviderConfig(name: ClaudeCloudProvider.name, exec: "/opt/acme/claude"),
            verb: ["send", "s"], stdin: Data("hi\r".utf8), timeout: 30, contractVersion: 2)

        #expect(builtIn.stdinsSnapshot() == [Data("hi\r".utf8)])
        #expect(builtIn.contractVersionsSnapshot() == [2])
    }

    // MARK: - Built-in registration

    private func makeRegistry(_ json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("agent-providers.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// A built-in provider must appear in `providerStatuses()` and negotiate
    /// its own major, exactly as a registered one does — the manager is what
    /// arms its poll loop and holds its health.
    @Test func aBuiltInProviderIsRegisteredAndDescribed() async throws {
        let db = try TBDDatabase(inMemory: true)
        let registryURL = try makeRegistry(#"[{"name": "acme", "exec": "/usr/bin/acme"}]"#)
        let builtIn = FakeProviderInvoker(script: [
            ProviderResult(exitCode: 0, stdout: ClaudeCloudDescribe.json, stderr: "")
        ])
        let subprocess = FakeProviderInvoker(script: [
            providerOK(#"{"contract_versions": [1], "name": "acme", "capabilities": []}"#)
        ])
        let m = RemoteProviderManager(
            db: db, subscriptions: StateSubscriptionManager(),
            runner: ProviderDispatcher(
                subprocess: subprocess, builtIns: [ClaudeCloudProvider.name: builtIn]),
            registryURL: registryURL,
            builtInProviders: [
                RemoteProviderConfig(name: ClaudeCloudProvider.name, exec: "/opt/acme/claude")
            ])

        await m.loadRegistryAndDescribe()

        let names = await m.providerStatuses().map { $0.config.name }
        #expect(Set(names) == [ClaudeCloudProvider.name, "acme"])
        // `[2]` alone negotiates 2 rather than being refused.
        #expect(await m.negotiatedContractMajor(for: ClaudeCloudProvider.name) == 2)
        #expect(await m.negotiatedContractMajor(for: "acme") == 1)
    }

    /// The discriminating half: with no built-in passed, the reserved name is
    /// simply absent — which is the shape a boot with the cloud flag off
    /// produces.
    @Test func noBuiltInMeansTheReservedNameIsAbsentEntirely() async throws {
        let db = try TBDDatabase(inMemory: true)
        let registryURL = try makeRegistry(#"[{"name": "acme", "exec": "/usr/bin/acme"}]"#)
        let m = RemoteProviderManager(
            db: db, subscriptions: StateSubscriptionManager(),
            runner: ProviderDispatcher(
                subprocess: FakeProviderInvoker(script: [
                    providerOK(#"{"contract_versions": [1], "name": "acme", "capabilities": []}"#)
                ]),
                builtIns: [:]),
            registryURL: registryURL)

        await m.loadRegistryAndDescribe()

        #expect(await m.providerStatuses().map { $0.config.name } == ["acme"])
    }

    /// A registry entry claiming the reserved name is skipped while every
    /// other entry in the file still loads — one bad entry must never
    /// silently remove every provider the user registered.
    @Test func aRegistryEntryClaimingTheReservedNameIsSkippedAndTheRestLoad() async throws {
        let db = try TBDDatabase(inMemory: true)
        let registryURL = try makeRegistry(#"""
        [{"name": "acme", "exec": "/usr/bin/acme"},
         {"name": "claude-cloud", "exec": "/usr/bin/impostor"}]
        """#)
        let m = RemoteProviderManager(
            db: db, subscriptions: StateSubscriptionManager(),
            runner: ProviderDispatcher(
                subprocess: FakeProviderInvoker(script: [
                    providerOK(#"{"contract_versions": [1], "name": "acme", "capabilities": []}"#)
                ]),
                builtIns: [:]),
            registryURL: registryURL)

        await m.loadRegistryAndDescribe()

        let statuses = await m.providerStatuses()
        #expect(statuses.map { $0.config.name } == ["acme"])
        // The impostor's exec never became a registered provider.
        #expect(!statuses.contains { $0.config.exec == "/usr/bin/impostor" })
    }
}
