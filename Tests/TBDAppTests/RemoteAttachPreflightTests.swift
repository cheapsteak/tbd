import Foundation
import Testing
import TBDShared
@testable import TBDApp

@Suite("Remote attach preflight")
struct RemoteAttachPreflightTests {
    private func provider(
        _ name: String,
        exec: String = "/opt/agentbox/bin/agentbox",
        capabilities: [String] = ["attach", "log"]
    ) -> RemoteProviderStatus {
        RemoteProviderStatus(
            config: RemoteProviderConfig(name: name, exec: exec),
            describe: ProviderDescribe(name: "agentbox", capabilities: capabilities),
            health: .ok, errorMessage: nil, remediationLabel: nil, remediationCommand: nil)
    }

    private func session(provider: String, id: String) -> RemoteSessionInfo {
        RemoteSessionInfo(
            provider: provider,
            payload: RemoteSessionPayload(id: id, state: .running, agentState: .working),
            gone: false, dismissed: false, lastSeen: Date(timeIntervalSince1970: 1_000))
    }

    private func resolve(
        provider selected: String,
        sessionID: String = "s1",
        providers: [RemoteProviderStatus],
        sessions: [RemoteSessionInfo],
        probe: @escaping (RemoteProviderConfig) -> RemoteAttachPreflight.ExecutableStatus = { _ in .runnable }
    ) -> RemoteAttachPreflight.Diagnosis {
        RemoteAttachPreflight.resolve(
            selection: RemoteSessionSelection(provider: selected, sessionID: sessionID),
            providers: providers, sessions: sessions, probe: probe)
    }

    // MARK: - Routing

    @Test("attach resolves through the selected provider and no other")
    func resolvesThroughTheSelectedProvider() {
        // Two registrations of the same kind, both healthy, both declaring
        // attach. Only the selected one may ever be spawned.
        let diagnosis = resolve(
            provider: "agentbox-staging",
            providers: [provider("agentbox"), provider("agentbox-staging", exec: "/opt/staging/agentbox")],
            sessions: [session(provider: "agentbox-staging", id: "s1")])

        #expect(diagnosis.readyConfig?.name == "agentbox-staging")
        #expect(diagnosis.readyConfig?.exec == "/opt/staging/agentbox")
    }

    @Test("a session belonging to another provider is named, never silently attached")
    func neverFallsBackToAnotherProvider() {
        // The failure this whole type exists to make impossible: the session
        // is right there under a sibling registration, and one healthy
        // provider is registered — a "helpful" fallback would attach to the
        // wrong control plane.
        let diagnosis = resolve(
            provider: "agentbox",
            providers: [provider("agentbox")],
            sessions: [session(provider: "agentbox-staging", id: "s1")])

        #expect(diagnosis == .sessionBelongsToAnotherProvider(
            requested: "agentbox", actual: "agentbox-staging", sessionID: "s1"))
        #expect(diagnosis.readyConfig == nil)
        #expect(diagnosis.detail.contains("agentbox-staging"))
        #expect(diagnosis.detail.contains("will not attach to another provider's session"))
    }

    @Test("an unregistered provider is reported by name, with no substitute offered")
    func reportsAnUnregisteredProvider() {
        let diagnosis = resolve(
            provider: "agentbox-staging",
            providers: [provider("agentbox")],
            sessions: [session(provider: "agentbox-staging", id: "s1")])

        // The session is only in the mirror, its registration is gone: name
        // the registration, not the sibling.
        #expect(diagnosis == .providerNotRegistered(provider: "agentbox-staging"))
        #expect(diagnosis.detail.contains("agent-providers.json"))
    }

    @Test("no provider and no other owner still names the provider that was asked for")
    func reportsAnUnknownProviderWithNoOwner() {
        let diagnosis = resolve(
            provider: "ghost", providers: [provider("agentbox")], sessions: [])

        #expect(diagnosis == .providerNotRegistered(provider: "ghost"))
    }

    @Test("a provider that does not declare attach is not invoked for it")
    func respectsTheAttachCapability() {
        let diagnosis = resolve(
            provider: "agentbox",
            providers: [provider("agentbox", capabilities: ["log"])],
            sessions: [session(provider: "agentbox", id: "s1")])

        #expect(diagnosis == .attachUnsupported(provider: "agentbox"))
        #expect(diagnosis.detail.contains("log view"))
    }

    // MARK: - Local transport dependency

    @Test("a missing local executable is an actionable diagnosis, not a blank pane")
    func reportsAMissingExecutable() {
        let diagnosis = resolve(
            provider: "agentbox",
            providers: [provider("agentbox", exec: "/opt/agentbox/bin/agentbox")],
            sessions: [session(provider: "agentbox", id: "s1")],
            probe: { _ in .missing })

        #expect(diagnosis == .executableMissing(
            provider: "agentbox", command: "/opt/agentbox/bin/agentbox"))
        #expect(diagnosis.title == "Attach command not found")
        #expect(diagnosis.detail.contains("/opt/agentbox/bin/agentbox"))
        #expect(diagnosis.detail.contains("agent-providers.json"))
    }

    @Test("a present but non-executable command is a different diagnosis")
    func reportsANonExecutableCommand() {
        let diagnosis = resolve(
            provider: "agentbox",
            providers: [provider("agentbox")],
            sessions: [session(provider: "agentbox", id: "s1")],
            probe: { _ in .notExecutable })

        #expect(diagnosis == .executableNotRunnable(
            provider: "agentbox", command: "/opt/agentbox/bin/agentbox"))
        #expect(diagnosis.detail.contains("chmod +x"))
    }

    @Test("a secret-looking registry argument never reaches an error message")
    func redactsArgumentsInDiagnostics() {
        let status = RemoteProviderStatus(
            config: RemoteProviderConfig(
                name: "agentbox", exec: "/opt/agentbox/bin/agentbox",
                args: ["--token=sk-live-1"]),
            describe: ProviderDescribe(name: "agentbox", capabilities: ["attach"]),
            health: .ok, errorMessage: nil, remediationLabel: nil, remediationCommand: nil)

        let diagnosis = resolve(
            provider: "agentbox", providers: [status],
            sessions: [session(provider: "agentbox", id: "s1")],
            probe: { _ in .missing })

        #expect(diagnosis.detail.contains("sk-live-1") == false)
    }

    // MARK: - The filesystem probe

    @Test("an absolute path is probed as a file")
    func probesAbsolutePaths() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let runnable = directory.appendingPathComponent("provider")
        try Data("#!/bin/sh\n".utf8).write(to: runnable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runnable.path)
        let plain = directory.appendingPathComponent("not-executable")
        try Data("x".utf8).write(to: plain)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)

        #expect(RemoteAttachPreflight.probeExecutable(runnable.path) == .runnable)
        #expect(RemoteAttachPreflight.probeExecutable(plain.path) == .notExecutable)
        #expect(RemoteAttachPreflight.probeExecutable(directory.appendingPathComponent("absent").path)
            == .missing)
        // A directory is not a command, however much it exists.
        #expect(RemoteAttachPreflight.probeExecutable(directory.path) == .missing)
        #expect(RemoteAttachPreflight.probeExecutable("") == .missing)
    }

    @Test("a bare command name is resolved on PATH, the way the spawn will resolve it")
    func probesBareNamesOnPath() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let onPath = directory.appendingPathComponent("agentbox")
        try Data("#!/bin/sh\n".utf8).write(to: onPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: onPath.path)

        // Never report "missing" for a provider that would in fact have run.
        #expect(RemoteAttachPreflight.probeExecutable(
            "agentbox", environment: ["PATH": "/nonexistent:\(directory.path)"]) == .runnable)
        #expect(RemoteAttachPreflight.probeExecutable(
            "agentbox", environment: ["PATH": "/nonexistent"]) == .missing)
        #expect(RemoteAttachPreflight.probeExecutable("agentbox", environment: [:]) == .missing)
    }
}
