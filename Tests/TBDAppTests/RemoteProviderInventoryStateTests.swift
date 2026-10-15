import Foundation
import Testing
import TBDShared
@testable import TBDApp

@Suite("Provider inventory state")
struct RemoteProviderInventoryStateTests {
    private let now = Date(timeIntervalSince1970: 100_000)

    private func status(
        name: String = "agentbox",
        health: ProviderHealth = .ok,
        snapshotAt: Date? = nil,
        freshnessUnreadable: Bool = false
    ) -> RemoteProviderStatus {
        RemoteProviderStatus(
            config: RemoteProviderConfig(name: name, exec: "/opt/agentbox/bin/agentbox"),
            describe: ProviderDescribe(name: "agentbox"),
            health: health, errorMessage: nil, remediationLabel: nil, remediationCommand: nil,
            lastSuccessfulSnapshotAt: snapshotAt, freshnessUnreadable: freshnessUnreadable)
    }

    // MARK: - The four not-simply-current readings

    @Test("a successful empty inventory is its own state, not 'nothing to show'")
    func emptySuccessIsDistinct() {
        let state = RemoteProviderInventoryState.make(
            provider: status(snapshotAt: now.addingTimeInterval(-30)), sessionCount: 0)

        #expect(state == .emptySuccess(at: now.addingTimeInterval(-30)))
        #expect(state.title == "This provider reports no sessions")
        #expect(state.detail(now: now) == "The provider answered and its inventory was empty just now.")
        // The only one of the empty readings that is evidence about the backend.
        #expect(state.isCurrent)
    }

    @Test("never having snapshotted is not evidence that a provider has no sessions")
    func noInventoryYetSaysSo() {
        let state = RemoteProviderInventoryState.make(provider: status(), sessionCount: 0)

        #expect(state == .noInventoryYet)
        #expect(state.isCurrent == false)
        #expect(state.detail(now: now).contains("not evidence"))
    }

    @Test("an unreadable freshness record is distinct from never having snapshotted")
    func freshnessUnknownIsDistinct() {
        let neverPolled = RemoteProviderInventoryState.make(
            provider: status(freshnessUnreadable: true), sessionCount: 0)
        #expect(neverPolled == .freshnessUnknown)

        // `hasStaleSnapshot` is true here with no timestamp to quote; say
        // what is unknown rather than invent an age.
        let unhealthy = RemoteProviderInventoryState.make(
            provider: status(health: .error, freshnessUnreadable: true), sessionCount: 3)
        #expect(unhealthy == .freshnessUnknown)
    }

    @Test("a stale list is history, and says so with its age")
    func staleQuotesItsAge() {
        let state = RemoteProviderInventoryState.make(
            provider: status(health: .stale, snapshotAt: now.addingTimeInterval(-2 * 3600)),
            sessionCount: 2)

        #expect(state == .stale(since: now.addingTimeInterval(-2 * 3600), cachedCount: 2))
        #expect(state.isCurrent == false)
        #expect(state.detail(now: now)
            == "2 cached rows from the inventory of 2h ago. Their states are history, not current.")
    }

    @Test("a current populated inventory needs no notice at all")
    func populatedIsSilent() {
        let state = RemoteProviderInventoryState.make(
            provider: status(snapshotAt: now.addingTimeInterval(-60)), sessionCount: 1)

        #expect(state == .populated(count: 1, at: now.addingTimeInterval(-60)))
        #expect(state.warrantsNotice == false)
        #expect(state.detail(now: now) == "1 session reported 1m ago.")
    }

    @Test("every non-current reading warrants a notice")
    func nonCurrentReadingsWarrantNotices() {
        for state: RemoteProviderInventoryState in [
            .emptySuccess(at: now), .noInventoryYet, .freshnessUnknown,
            .stale(since: now, cachedCount: 0),
        ] {
            #expect(state.warrantsNotice, "\(state) must explain itself")
        }
    }

    // MARK: - The wrong-provider cross-check

    @Test("an empty provider names where the sessions actually are")
    func crossProviderNoteNamesTheOtherProvider() {
        let sessions = [
            session(provider: "agentbox-staging", id: "a"),
            session(provider: "agentbox-staging", id: "b"),
            session(provider: "agentbox", id: "c"),
        ]

        #expect(RemoteProviderInventoryState.crossProviderNote(
            currentProvider: "agentbox", sessions: sessions)
            == "2 sessions are registered under another provider (agentbox-staging: 2).")
    }

    @Test("several other providers are listed, alphabetically")
    func crossProviderNoteListsEachProvider() {
        let sessions = [
            session(provider: "zeta", id: "z"),
            session(provider: "agentbox-staging", id: "a"),
        ]

        #expect(RemoteProviderInventoryState.crossProviderNote(
            currentProvider: "agentbox", sessions: sessions)
            == "2 sessions are registered under other providers (agentbox-staging: 1, zeta: 1).")
    }

    @Test("no note when nothing lives elsewhere, and dismissed rows never count")
    func crossProviderNoteStaysQuiet() {
        #expect(RemoteProviderInventoryState.crossProviderNote(
            currentProvider: "agentbox",
            sessions: [session(provider: "agentbox", id: "a")]) == nil)

        #expect(RemoteProviderInventoryState.crossProviderNote(
            currentProvider: "agentbox",
            sessions: [session(provider: "agentbox-staging", id: "a", dismissed: true)]) == nil)
    }

    private func session(
        provider: String, id: String, dismissed: Bool = false
    ) -> RemoteSessionInfo {
        RemoteSessionInfo(
            provider: provider,
            payload: RemoteSessionPayload(id: id, state: .running, agentState: .working),
            gone: false, dismissed: dismissed, lastSeen: now)
    }
}
