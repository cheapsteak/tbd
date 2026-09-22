import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// The reproduced confusion, pinned end to end.
///
/// Two registrations of the SAME provider kind, reporting the SAME box
/// handle: `agentbox` (management, zero sessions) and `agentbox-staging`
/// (three sessions, one of them blocked at a prompt). Everything a user reads
/// while deciding "which one am I looking at, and is anything happening" is
/// asserted here against that one fixture, because the failure was never in
/// any single surface — it was that every surface answered a slightly
/// different question and none of them answered this one.
@Suite("Provider disambiguation scenario")
struct ProviderDisambiguationScenarioTests {
    private let now = Date(timeIntervalSince1970: 1_800_000)
    private let managementName = "agentbox"
    private let stagingName = "agentbox-staging"

    /// Both registrations run the same binary and report the same kind and
    /// the same box handle — the worst case, where only the registry key and
    /// the identity pairs can tell them apart.
    private var management: RemoteProviderStatus {
        provider(
            registryName: managementName,
            args: ["--control-plane", "management"],
            identity: ["box": "i-0abc123", "environment": "management", "account": "acme-1234"],
            snapshotAt: now.addingTimeInterval(-30))
    }

    private var staging: RemoteProviderStatus {
        provider(
            registryName: stagingName,
            args: ["--control-plane", "staging"],
            identity: ["box": "i-0abc123", "environment": "staging", "account": "acme-1234"],
            snapshotAt: now.addingTimeInterval(-45))
    }

    private var sessions: [RemoteSessionInfo] {
        [
            session(provider: stagingName, id: "fix-flaky-ci", terminal: .running, agent: .working),
            session(
                provider: stagingName, id: "deploy-checks", terminal: .running, agent: .waitingInput,
                question: RemotePendingQuestion(id: "q-4f2a1c", questions: [
                    RemotePendingQuestionItem(
                        prompt: "Which environment should this deploy to?",
                        options: [
                            RemotePendingQuestionOption(label: "staging"),
                            RemotePendingQuestionOption(label: "production"),
                        ]),
                ])),
            session(provider: stagingName, id: "opaque-build", terminal: .running, agent: .unknown),
        ]
    }

    // MARK: - Which provider am I looking at

    @Test("two registrations of the same kind never render as the same provider")
    func registrationsAreDistinguishable() {
        #expect(RemoteProviderIdentityPresentation.headline(management) == "agentbox")
        #expect(RemoteProviderIdentityPresentation.headline(staging) == "agentbox-staging")

        let managementRows = RemoteProviderIdentityPresentation.rows(management, homeDirectory: "/Users/dev")
        let stagingRows = RemoteProviderIdentityPresentation.rows(staging, homeDirectory: "/Users/dev")

        // The shared box handle is shown — it is true of both — but it is
        // never the only thing shown, which is what made the two look alike.
        #expect(managementRows.first { $0.label == "Box" }?.value == "i-0abc123")
        #expect(stagingRows.first { $0.label == "Box" }?.value == "i-0abc123")
        #expect(managementRows.first { $0.label == "Environment" }?.value == "management")
        #expect(stagingRows.first { $0.label == "Environment" }?.value == "staging")
        #expect(managementRows != stagingRows)
    }

    @Test("the shared kind is stated as a kind, beside the registry key")
    func kindIsSubordinateToTheRegistryKey() {
        #expect(RemoteProviderIdentityPresentation.kindSubtitle(management) == nil)
        #expect(RemoteProviderIdentityPresentation.kindSubtitle(staging) == "reports as agentbox")
    }

    @Test("no credential ever reaches the identity block")
    func identityCarriesNoCredentials() {
        let leaky = provider(
            registryName: managementName,
            args: ["--token", "sk-live-1"],
            identity: ["account": "acme-1234", "session_token": "AQoDYXdz", "api_key": "sk-live-2"],
            snapshotAt: now)

        let rendered = RemoteProviderIdentityPresentation.rows(leaky, homeDirectory: "/Users/dev")
            .map(\.value).joined(separator: " ")

        #expect(rendered.contains("AQoDYXdz") == false)
        #expect(rendered.contains("sk-live-1") == false)
        #expect(rendered.contains("sk-live-2") == false)
        #expect(rendered.contains("acme-1234"))
    }

    // MARK: - Zero inventory here, live sessions there

    @Test("the empty provider says it is empty AND says where the sessions are")
    func emptyProviderPointsAtTheOtherOne() {
        let summary = RemoteProviderDeskSummary(provider: managementName, sessions: sessions)
        let state = RemoteProviderInventoryState.make(provider: management, sessionCount: summary.total)

        #expect(summary.total == 0)
        // A green badge over an empty list is what made this read as "staging
        // is idle". Both halves of the sentence now exist.
        #expect(state == .emptySuccess(at: now.addingTimeInterval(-30)))
        #expect(state.title == "This provider reports no sessions")
        #expect(RemoteProviderInventoryState.crossProviderNote(
            currentProvider: managementName, sessions: sessions)
            == "3 sessions are registered under another provider (agentbox-staging: 3).")
    }

    @Test("the populated provider needs no notice and no cross-reference")
    func populatedProviderIsSilent() {
        let summary = RemoteProviderDeskSummary(provider: stagingName, sessions: sessions)
        let state = RemoteProviderInventoryState.make(provider: staging, sessionCount: summary.total)

        #expect(state == .populated(count: 3, at: now.addingTimeInterval(-45)))
        #expect(state.warrantsNotice == false)
        #expect(RemoteProviderInventoryState.crossProviderNote(
            currentProvider: stagingName, sessions: sessions) == nil)
    }

    @Test("a stale management provider is not confused with an empty one")
    func staleIsNotEmpty() {
        let unreachable = provider(
            registryName: managementName, args: [], identity: nil,
            snapshotAt: now.addingTimeInterval(-3 * 3600), health: .stale)

        let state = RemoteProviderInventoryState.make(provider: unreachable, sessionCount: 0)

        #expect(state == .stale(since: now.addingTimeInterval(-3 * 3600), cachedCount: 0))
        #expect(state.isCurrent == false)
    }

    // MARK: - Terminal liveness vs agent progress

    @Test("three running terminals are not three working agents")
    func liveTerminalsAreNotProgress() {
        let summary = RemoteProviderDeskSummary(provider: stagingName, sessions: sessions)

        #expect(summary.terminal.running == 3)
        #expect(summary.agent.working == 1)
        #expect(summary.agent.waitingInput == 1)
        #expect(summary.agent.unknown == 1)
        #expect(summary.unattributedRunningNotice
            == "1 running session reports no agent state — terminal liveness is not agent progress.")
    }

    @Test("the blocked session is named with what it is blocked on")
    func theBlockedSessionExplainsItself() {
        let summary = RemoteProviderDeskSummary(provider: stagingName, sessions: sessions)

        #expect(summary.needsAttention.map(\.payload.id) == ["deploy-checks"])
        #expect(summary.needsAttention.first.flatMap(RemoteAgentAttention.explanation(for:))
            == "Blocked on a question: Which environment should this deploy to? (staging / production)")
    }

    // MARK: - Attach

    @Test("attach to a staging session never routes through management")
    func attachRoutesThroughTheSelectedRegistration() {
        let ready = RemoteAttachPreflight.resolve(
            selection: RemoteSessionSelection(provider: stagingName, sessionID: "deploy-checks"),
            providers: [management, staging], sessions: sessions, probe: { _ in .runnable })

        #expect(ready.readyConfig?.name == stagingName)
        #expect(ready.readyConfig?.args == ["--control-plane", "staging"])

        // Same session id, asked of the wrong registration: named, refused.
        let wrong = RemoteAttachPreflight.resolve(
            selection: RemoteSessionSelection(provider: managementName, sessionID: "deploy-checks"),
            providers: [management, staging], sessions: sessions, probe: { _ in .runnable })

        #expect(wrong == .sessionBelongsToAnotherProvider(
            requested: managementName, actual: stagingName, sessionID: "deploy-checks"))
    }

    @Test("a missing local transport dependency is named instead of failing blank")
    func missingDependencyIsNamed() {
        let diagnosis = RemoteAttachPreflight.resolve(
            selection: RemoteSessionSelection(provider: stagingName, sessionID: "deploy-checks"),
            providers: [management, staging], sessions: sessions,
            probe: { config in config.name == stagingName ? .missing : .runnable })

        #expect(diagnosis == .executableMissing(
            provider: stagingName,
            command: "/opt/agentbox/bin/agentbox --control-plane staging"))
        #expect(diagnosis.detail.contains("does not exist on this machine"))
        // And it does not quietly attach through the registration that IS
        // installed.
        #expect(diagnosis.readyConfig == nil)
    }

    // MARK: - Fixtures

    private func provider(
        registryName: String,
        args: [String],
        identity: [String: String]?,
        snapshotAt: Date?,
        health: ProviderHealth = .ok
    ) -> RemoteProviderStatus {
        RemoteProviderStatus(
            config: RemoteProviderConfig(
                name: registryName, exec: "/opt/agentbox/bin/agentbox", args: args),
            describe: ProviderDescribe(
                name: "agentbox", providerVersion: "0.4.2", capabilities: ["attach", "log", "send"],
                identity: identity.map(ProviderIdentity.init(pairs:))),
            health: health, errorMessage: nil, remediationLabel: nil, remediationCommand: nil,
            lastSuccessfulSnapshotAt: snapshotAt, contractVersion: 2)
    }

    private func session(
        provider: String,
        id: String,
        terminal: RemoteProcessState,
        agent: RemoteAgentState,
        question: RemotePendingQuestion? = nil
    ) -> RemoteSessionInfo {
        RemoteSessionInfo(
            provider: provider,
            payload: RemoteSessionPayload(
                id: id, title: id, createdAt: "2026-08-26T07:00:00Z",
                state: terminal, agentState: agent,
                meta: ["repo": "acme/api", "branch": id], pendingQuestion: question),
            gone: false, dismissed: false, lastSeen: now.addingTimeInterval(-60))
    }
}
