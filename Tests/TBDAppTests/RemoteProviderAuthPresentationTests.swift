import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Tier 1. The pure presentation decision behind the provider-auth CTA,
/// covering every combination of what a provider may or may not supply.
/// Fixtures use a neutral placeholder provider — nothing in TBD's side of
/// this feature knows or names a particular backend.
@Suite("RemoteProviderAuthPresentation")
struct RemoteProviderAuthPresentationTests {
    private func status(
        health: ProviderHealth = .needsAuth,
        describeName: String? = nil,
        message: String? = nil,
        label: String? = nil,
        command: String? = nil
    ) -> RemoteProviderStatus {
        RemoteProviderStatus(
            config: RemoteProviderConfig(name: "acme", exec: "/usr/bin/true"),
            describe: describeName.map { ProviderDescribe(name: $0) },
            health: health,
            errorMessage: message,
            remediationLabel: label,
            remediationCommand: command
        )
    }

    // MARK: - Health gate

    @Test func noProviderMeansNoCTA() {
        #expect(RemoteProviderAuthPresentation.make(from: nil) == nil)
    }

    @Test func healthyProviderMeansNoCTA() {
        #expect(RemoteProviderAuthPresentation.make(from: status(health: .ok)) == nil)
    }

    /// The other unhealthy states are NOT auth states — a stale or errored
    /// provider must not get an authentication CTA it can't act on.
    @Test func staleAndErrorProvidersMeanNoCTA() {
        #expect(RemoteProviderAuthPresentation.make(from: status(health: .stale)) == nil)
        #expect(RemoteProviderAuthPresentation.make(from: status(health: .error)) == nil)
    }

    /// Health is the ONLY gate: a provider that supplied nothing at all
    /// still gets a CTA, just an entirely generic one.
    @Test func needsAuthWithNothingSuppliedStillProducesACTA() throws {
        let cta = try #require(RemoteProviderAuthPresentation.make(from: status()))
        #expect(cta.message == RemoteProviderAuthPresentation.fallbackMessage)
        #expect(cta.actionLabel == RemoteProviderAuthPresentation.fallbackActionLabel)
        #expect(cta.command == nil)
    }

    // MARK: - Message

    @Test func providerMessageIsUsedWhenPresent() throws {
        let cta = try #require(RemoteProviderAuthPresentation.make(from: status(message: "credentials expired")))
        #expect(cta.message == "credentials expired")
    }

    @Test func blankProviderMessageFallsBack() throws {
        let cta = try #require(RemoteProviderAuthPresentation.make(from: status(message: "   ")))
        #expect(cta.message == RemoteProviderAuthPresentation.fallbackMessage)
    }

    // MARK: - Action label

    @Test func remediationLabelIsUsedWhenPresent() throws {
        let cta = try #require(RemoteProviderAuthPresentation.make(from: status(label: "Sign in")))
        #expect(cta.actionLabel == "Sign in")
    }

    @Test func blankRemediationLabelFallsBack() throws {
        let cta = try #require(RemoteProviderAuthPresentation.make(from: status(label: "")))
        #expect(cta.actionLabel == RemoteProviderAuthPresentation.fallbackActionLabel)
    }

    // MARK: - Command

    /// The command is opaque: carried through verbatim, never parsed,
    /// split, or rewritten.
    @Test func remediationCommandIsCarriedVerbatim() throws {
        let raw = "acme-provider login --profile 'team ops' && echo done"
        let cta = try #require(RemoteProviderAuthPresentation.make(from: status(command: raw)))
        #expect(cta.command == raw)
    }

    @Test func absentCommandStaysNil() throws {
        let cta = try #require(RemoteProviderAuthPresentation.make(from: status(label: "Sign in")))
        #expect(cta.command == nil)
    }

    @Test func blankCommandIsTreatedAsAbsent() throws {
        let cta = try #require(RemoteProviderAuthPresentation.make(from: status(command: "  ")))
        #expect(cta.command == nil)
    }

    // MARK: - Provider name

    @Test func describeNameWinsOverTheRegistryName() throws {
        let cta = try #require(RemoteProviderAuthPresentation.make(from: status(describeName: "Acme Cloud")))
        #expect(cta.providerName == "Acme Cloud")
    }

    @Test func registryNameIsUsedWhenDescribeIsMissing() throws {
        let cta = try #require(RemoteProviderAuthPresentation.make(from: status()))
        #expect(cta.providerName == "acme")
    }

    // MARK: - Full combination

    @Test func everythingSuppliedIsEverythingRendered() throws {
        let cta = try #require(RemoteProviderAuthPresentation.make(from: status(
            describeName: "Acme Cloud", message: "credentials expired",
            label: "Sign in", command: "acme-provider login")))
        #expect(cta == RemoteProviderAuthPresentation(
            providerName: "Acme Cloud", message: "credentials expired",
            actionLabel: "Sign in", command: "acme-provider login"))
    }
}

/// Tier 1. Argv construction for the remediation command. The command is the
/// provider's, opaque — the only thing TBD adds is the login shell.
@Suite("RemoteRemediationCommand")
struct RemoteRemediationCommandTests {
    @Test func usesTheUsersLoginShellWhenExecutable() {
        let argv = RemoteRemediationCommand.loginShellArgv(
            command: "acme-provider login",
            environment: ["SHELL": "/opt/example/bin/fish"],
            isExecutable: { $0 == "/opt/example/bin/fish" }
        )
        #expect(argv == ["/opt/example/bin/fish", "-lc", "acme-provider login"])
    }

    @Test func fallsBackWhenShellIsUnset() {
        let argv = RemoteRemediationCommand.loginShellArgv(
            command: "acme-provider login", environment: [:], isExecutable: { $0 == "/bin/zsh" })
        #expect(argv == ["/bin/zsh", "-lc", "acme-provider login"])
    }

    @Test func fallsBackAgainWhenNoPreferredShellIsExecutable() {
        let argv = RemoteRemediationCommand.loginShellArgv(
            command: "acme-provider login",
            environment: ["SHELL": "/nonexistent/shell"],
            isExecutable: { $0 == "/bin/sh" }
        )
        #expect(argv == ["/bin/sh", "-lc", "acme-provider login"])
    }

    /// The command rides as ONE argv element — never split on spaces, never
    /// re-quoted, never interpolated into a larger shell string.
    @Test func commandIsASingleArgvElementWhateverItContains() {
        let raw = #"acme-provider login --profile "team ops" ; echo $HOME"#
        let argv = RemoteRemediationCommand.loginShellArgv(
            command: raw, environment: ["SHELL": "/bin/zsh"], isExecutable: { _ in true })
        #expect(argv.count == 3)
        #expect(argv.last == raw)
    }
}
