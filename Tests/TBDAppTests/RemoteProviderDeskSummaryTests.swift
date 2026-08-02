import Foundation
import Testing
import TBDShared
@testable import TBDApp

@Suite("Provider Desk summary")
struct RemoteProviderDeskSummaryTests {
    private let provider = "acme-cloud"

    @Test("terminal and agent states are counted independently")
    func countsIndependentStateAxes() {
        let now = Date(timeIntervalSince1970: 2_000)
        let sessions = [
            session(id: "working", terminal: .running, agent: .working, seen: now),
            session(id: "waiting", terminal: .running, agent: .waitingInput, seen: now.addingTimeInterval(-1)),
            session(id: "finished", terminal: .exited, agent: .exited, seen: now.addingTimeInterval(-2)),
            session(id: "unknown", terminal: .starting, agent: .unknown, seen: now.addingTimeInterval(-3)),
        ]

        let summary = RemoteProviderDeskSummary(provider: provider, sessions: sessions)

        #expect(summary.terminal.starting == 1)
        #expect(summary.terminal.running == 2)
        #expect(summary.terminal.exited == 1)
        #expect(summary.terminal.gone == 0)
        #expect(summary.agent.working == 1)
        #expect(summary.agent.waitingInput == 1)
        #expect(summary.agent.exited == 1)
        #expect(summary.agent.unknown == 1)
    }

    @Test("gone overrides the payload terminal state")
    func goneOverridesTerminalPayload() {
        let mirror = session(id: "gone", terminal: .running, agent: .unknown, gone: true)

        let summary = RemoteProviderDeskSummary(provider: provider, sessions: [mirror])

        #expect(summary.terminal.running == 0)
        #expect(summary.terminal.gone == 1)
        #expect(summary.agent.unknown == 1)
    }

    @Test("only visible sessions from the selected provider contribute")
    func filtersProviderAndDismissedRows() {
        let visible = session(id: "visible", terminal: .running, agent: .idle)
        let dismissed = session(id: "dismissed", terminal: .exited, agent: .exited, dismissed: true)
        let other = session(id: "other", provider: "other-cloud", terminal: .running, agent: .working)

        let summary = RemoteProviderDeskSummary(provider: provider, sessions: [dismissed, other, visible])

        #expect(summary.sessions.map(\.payload.id) == ["visible"])
        #expect(summary.total == 1)
    }

    @Test("freshness is the latest visible mirror update")
    func derivesLatestMirrorUpdate() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let hidden = Date(timeIntervalSince1970: 3_000)

        let summary = RemoteProviderDeskSummary(provider: provider, sessions: [
            session(id: "older", terminal: .running, agent: .idle, seen: older),
            session(id: "newer", terminal: .running, agent: .working, seen: newer),
            session(id: "hidden", terminal: .running, agent: .working, dismissed: true, seen: hidden),
        ])

        #expect(summary.latestMirrorUpdate == newer)
        #expect(summary.sessions.map(\.payload.id) == ["newer", "older"])
    }

    @Test("an empty provider reports no mirror timestamp rather than inventing one")
    func emptyProviderHasNoMirrorUpdate() {
        let summary = RemoteProviderDeskSummary(provider: provider, sessions: [])

        #expect(summary.latestMirrorUpdate == nil)
        #expect(summary.total == 0)
    }

    @Test("age phrasing carries a direction and never reads 'just now ago'")
    func agePhraseMatchesTheAppsFreshnessVocabulary() {
        let now = Date(timeIntervalSince1970: 100_000)

        #expect(RemoteProviderDeskSummary.agePhrase(
            since: now.addingTimeInterval(-5), now: now) == "just now")
        #expect(RemoteProviderDeskSummary.agePhrase(
            since: now.addingTimeInterval(-5 * 60), now: now) == "5m ago")
        #expect(RemoteProviderDeskSummary.agePhrase(
            since: now.addingTimeInterval(-2 * 3600), now: now) == "2h ago")
        #expect(RemoteProviderDeskSummary.agePhrase(
            since: now.addingTimeInterval(-3 * 86_400), now: now) == "3d ago")
    }

    @Test("freshness prefers the provider-wide inventory timestamp over row lastSeen")
    func freshnessPrefersTheSuccessfulSnapshot() {
        let now = Date(timeIntervalSince1970: 100_000)

        // The trap #571 exists to close: rows can look recent while the last
        // COMPLETE inventory is hours old. The desk must quote the inventory.
        #expect(RemoteProviderDeskSummary.freshnessLabel(
            lastSuccessfulSnapshotAt: now.addingTimeInterval(-2 * 3600),
            latestMirrorUpdate: now.addingTimeInterval(-60),
            now: now
        ) == "Inventory as of 2h ago")
    }

    @Test("freshness falls back to row lastSeen without calling it an inventory")
    func freshnessFallsBackToMirrorRows() {
        let now = Date(timeIntervalSince1970: 100_000)

        #expect(RemoteProviderDeskSummary.freshnessLabel(
            lastSuccessfulSnapshotAt: nil,
            latestMirrorUpdate: now.addingTimeInterval(-5 * 60),
            now: now
        ) == "Latest mirror update 5m ago")
    }

    @Test("freshness invents no timestamp when nothing has ever succeeded")
    func freshnessInventsNothing() {
        #expect(RemoteProviderDeskSummary.freshnessLabel(
            lastSuccessfulSnapshotAt: nil, latestMirrorUpdate: nil
        ) == "No successful inventory yet")
    }

    /// A successful EMPTY snapshot is exactly the case row `lastSeen` cannot
    /// represent: zero rows to derive an age from, yet the inventory is current.
    @Test("an empty but successful inventory still reports its own freshness")
    func emptySuccessfulInventoryReportsFreshness() {
        let now = Date(timeIntervalSince1970: 100_000)

        #expect(RemoteProviderDeskSummary.freshnessLabel(
            lastSuccessfulSnapshotAt: now.addingTimeInterval(-30),
            latestMirrorUpdate: nil,
            now: now
        ) == "Inventory as of just now")
    }

    private func session(
        id: String,
        provider: String? = nil,
        terminal: RemoteProcessState,
        agent: RemoteAgentState,
        gone: Bool = false,
        dismissed: Bool = false,
        seen: Date = Date(timeIntervalSince1970: 1_000)
    ) -> RemoteSessionInfo {
        RemoteSessionInfo(
            provider: provider ?? self.provider,
            payload: RemoteSessionPayload(
                id: id,
                title: id.capitalized,
                createdAt: "2026-08-01T12:00:00Z",
                state: terminal,
                agentState: agent,
                meta: ["repo": "acme/api", "branch": "feature/\(id)"]
            ),
            gone: gone,
            dismissed: dismissed,
            lastSeen: seen
        )
    }
}
