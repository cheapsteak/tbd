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

    // MARK: - The two independent signals
    //
    // Health and the caller's own attach-exit class are a union: either one
    // alone lights the CTA. The local signal exists because reporting the
    // exit to the daemon is fire-and-forget, so health lags it — and never
    // arrives at all if the report failed. Without it the session pane falls
    // back to the "Detached / Reattach" prompt whose button bypasses both
    // backoff and the health gate.

    @Test func healthAloneLightsTheCTA() throws {
        let cta = try #require(RemoteProviderAuthPresentation.make(
            from: status(health: .needsAuth), localAuthExit: false))
        #expect(cta.providerName == "acme")
    }

    /// The gap case: the app saw an auth-class attach exit but the daemon
    /// hasn't republished health yet (or never will).
    @Test func localAuthExitAloneLightsTheCTAWhileHealthStillReadsOK() throws {
        let cta = try #require(RemoteProviderAuthPresentation.make(
            from: status(health: .ok, message: "stale text"), localAuthExit: true))
        #expect(cta.providerName == "acme")
        // A healthy status's fields describe something else entirely, but
        // the message is whatever the status carries — here the provider
        // supplied one, so it is shown rather than invented.
        #expect(cta.message == "stale text")
    }

    /// With no status at all, the local signal still produces a CTA, named
    /// by the caller's fallback and entirely generic in what it says.
    @Test func localAuthExitWithNoStatusUsesTheFallbackName() throws {
        let cta = try #require(RemoteProviderAuthPresentation.make(
            from: nil, fallbackProviderName: "acme", localAuthExit: true))
        #expect(cta.providerName == "acme")
        #expect(cta.message == RemoteProviderAuthPresentation.fallbackMessage)
        #expect(cta.actionLabel == RemoteProviderAuthPresentation.fallbackActionLabel)
        #expect(cta.command == nil)
    }

    @Test func bothSignalsTogetherStillProduceExactlyOneCTA() throws {
        let cta = try #require(RemoteProviderAuthPresentation.make(
            from: status(health: .needsAuth, message: "credentials expired"),
            fallbackProviderName: "ignored", localAuthExit: true))
        #expect(cta == RemoteProviderAuthPresentation(
            providerName: "acme", message: "credentials expired",
            actionLabel: RemoteProviderAuthPresentation.fallbackActionLabel, command: nil))
    }

    @Test func neitherSignalMeansNoCTA() {
        #expect(RemoteProviderAuthPresentation.make(
            from: status(health: .ok), fallbackProviderName: "acme", localAuthExit: false) == nil)
    }

    /// Nothing to name the provider at all — no status, no fallback — so
    /// there is no CTA worth rendering.
    @Test func localAuthExitWithNothingToNameProducesNoCTA() {
        #expect(RemoteProviderAuthPresentation.make(from: nil, localAuthExit: true) == nil)
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

    /// The registry key leads, even when `describe` supplied a prettier
    /// name. `describe.name` identifies the provider's KIND, so two
    /// registrations running the same binary against different backends
    /// report the same one — and this CTA's whole job is to send a user to
    /// re-authenticate a specific registration.
    @Test func registryNameWinsOverTheDescribeName() throws {
        let cta = try #require(RemoteProviderAuthPresentation.make(from: status(describeName: "Acme Cloud")))
        #expect(cta.providerName == "acme")
    }

    @Test func registryNameIsUsedWhenDescribeIsMissing() throws {
        let cta = try #require(RemoteProviderAuthPresentation.make(from: status()))
        #expect(cta.providerName == "acme")
    }

    /// The caller's fallback is the LAST resort — a real status always wins,
    /// so the two surfaces never label the same provider differently.
    @Test func fallbackNameLosesToBothNamesOnTheStatus() throws {
        let fromDescribe = try #require(RemoteProviderAuthPresentation.make(
            from: status(describeName: "Acme Cloud"), fallbackProviderName: "raw-name"))
        #expect(fromDescribe.providerName == "acme")

        let fromRegistry = try #require(RemoteProviderAuthPresentation.make(
            from: status(), fallbackProviderName: "raw-name"))
        #expect(fromRegistry.providerName == "acme")
    }

    // MARK: - Full combination

    @Test func everythingSuppliedIsEverythingRendered() throws {
        let cta = try #require(RemoteProviderAuthPresentation.make(from: status(
            describeName: "Acme Cloud", message: "credentials expired",
            label: "Sign in", command: "acme-provider login")))
        #expect(cta == RemoteProviderAuthPresentation(
            providerName: "acme", message: "credentials expired",
            actionLabel: "Sign in", command: "acme-provider login"))
    }
}

/// Tier 1. The sheet item both auth surfaces present. It carries the whole
/// presentation so the sheet renders without re-reading live provider
/// health — health is EXPECTED to change while the sheet is open, since
/// clearing `.needsAuth` is the point of running the command.
@Suite("RemoteRemediationRun")
struct RemoteRemediationRunTests {
    private func presentation(command: String?) -> RemoteProviderAuthPresentation {
        RemoteProviderAuthPresentation(
            providerName: "acme", message: "credentials expired",
            actionLabel: "Sign in", command: command)
    }

    @Test func carriesThePresentationAlongsideTheCommand() throws {
        let run = try #require(RemoteRemediationRun(presentation(command: "acme-provider login")))
        #expect(run.command == "acme-provider login")
        #expect(run.presentation.actionLabel == "Sign in")
        #expect(run.presentation.providerName == "acme")
    }

    /// Nothing to run means no sheet — the init refuses rather than
    /// presenting an empty one.
    @Test func aCommandlessPresentationProducesNoRun() {
        #expect(RemoteRemediationRun(presentation(command: nil)) == nil)
    }

    /// `.sheet(item:)` re-presents on id change, so the id must distinguish
    /// two providers that happen to offer the same command text.
    @Test func identityCoversBothTheProviderAndTheCommand() throws {
        let acme = try #require(RemoteRemediationRun(presentation(command: "login")))
        let other = try #require(RemoteRemediationRun(RemoteProviderAuthPresentation(
            providerName: "other", message: "m", actionLabel: "l", command: "login")))
        #expect(acme.id != other.id)
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
