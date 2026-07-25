import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// Task 9 (Remote sidebar section). Covers the pure, view-independent parts:
/// - `RemoteSectionView.sessions(in:forProvider:)` — per-provider filtering
///   with dismissed tombstones excluded.
/// - `RowStatusIndicator.leading(isPending:hasPRStatus:isRemote:)` — the
///   new `.remote` case and its precedence under the existing leading slot.
/// - `RemoteSessionRowView.caption(state:gone:exitCode:)` — the starting/
///   exited/gone captions, including the gone-wins-over-exited precedence.
/// - `AppState.remoteUnreadType(kind:exitCode:)` — the pure kind→
///   `NotificationType` mapping feeding `unreadByRemoteSession`.
/// - `AppState.remoteSectionVisible(providers:)` — section-hidden-when-no-
///   providers.
@Suite("Remote section view — pure helpers")
struct RemoteSectionViewTests {

    private func session(
        provider: String,
        id: String,
        state: RemoteProcessState = .running,
        gone: Bool = false,
        dismissed: Bool = false
    ) -> RemoteSessionInfo {
        RemoteSessionInfo(
            provider: provider,
            payload: RemoteSessionPayload(id: id, state: state),
            gone: gone, dismissed: dismissed, lastSeen: Date()
        )
    }

    // MARK: - sessions(in:forProvider:)

    @Test func filtersToOnlyTheRequestedProvider() {
        let sessions = [
            session(provider: "acme", id: "s1"),
            session(provider: "other", id: "s2"),
        ]
        let result = RemoteSectionView.sessions(in: sessions, forProvider: "acme")
        #expect(result.map(\.payload.id) == ["s1"])
    }

    @Test func excludesDismissedSessions() {
        let sessions = [
            session(provider: "acme", id: "s1", dismissed: true),
            session(provider: "acme", id: "s2", dismissed: false),
        ]
        let result = RemoteSectionView.sessions(in: sessions, forProvider: "acme")
        #expect(result.map(\.payload.id) == ["s2"])
    }

    @Test func includesGoneButNotDismissedSessions() {
        // `gone` sessions still render (dimmed, with a Dismiss action) —
        // only `dismissed` (the user's tombstone action) removes a row.
        let sessions = [session(provider: "acme", id: "s1", gone: true, dismissed: false)]
        let result = RemoteSectionView.sessions(in: sessions, forProvider: "acme")
        #expect(result.map(\.payload.id) == ["s1"])
    }

    @Test func emptyWhenNoSessionsMatchProvider() {
        let sessions = [session(provider: "other", id: "s1")]
        #expect(RemoteSectionView.sessions(in: sessions, forProvider: "acme").isEmpty)
    }

    // MARK: - RowStatusIndicator.leading — `.remote` case + precedence

    @Test func leading_remoteWhenNeitherPendingNorPRStatus() {
        #expect(RowStatusIndicator.leading(isPending: false, hasPRStatus: false, isRemote: true) == .remote)
    }

    @Test func leading_pendingBeatsRemote() {
        #expect(RowStatusIndicator.leading(isPending: true, hasPRStatus: false, isRemote: true) == .pending)
    }

    @Test func leading_prStatusBeatsRemote() {
        #expect(RowStatusIndicator.leading(isPending: false, hasPRStatus: true, isRemote: true) == .prStatus)
    }

    @Test func leading_prStatusBeatsPendingAndRemote() {
        #expect(RowStatusIndicator.leading(isPending: true, hasPRStatus: true, isRemote: true) == .prStatus)
    }

    @Test func leading_nilWhenNothingApplies() {
        #expect(RowStatusIndicator.leading(isPending: false, hasPRStatus: false) == nil)
    }

    @Test func leading_defaultsIsRemoteToFalse() {
        // Existing (local-row) call sites don't pass `isRemote` — confirm
        // the default keeps them at `nil`, not `.remote`.
        #expect(RowStatusIndicator.leading(isPending: false, hasPRStatus: false) == nil)
    }

    // MARK: - RemoteSessionRowView.caption(state:gone:exitCode:)

    @Test func caption_startingIsStartingEllipsis() {
        #expect(RemoteSessionRowView.caption(state: .starting, gone: false, exitCode: nil) == "Starting…")
    }

    @Test func caption_runningIsNil() {
        #expect(RemoteSessionRowView.caption(state: .running, gone: false, exitCode: nil) == nil)
    }

    @Test func caption_unknownIsNil() {
        #expect(RemoteSessionRowView.caption(state: .unknown, gone: false, exitCode: nil) == nil)
    }

    @Test func caption_exitedWithKnownCodeIncludesCode() {
        #expect(RemoteSessionRowView.caption(state: .exited, gone: false, exitCode: 1) == "exited (code 1)")
    }

    @Test func caption_exitedWithoutKnownCodeOmitsCode() {
        #expect(RemoteSessionRowView.caption(state: .exited, gone: false, exitCode: nil) == "exited")
    }

    @Test func caption_goneWinsOverExitedCode() {
        #expect(RemoteSessionRowView.caption(state: .exited, gone: true, exitCode: 1) == "no longer reported")
    }

    @Test func caption_goneWinsOverStarting() {
        #expect(RemoteSessionRowView.caption(state: .starting, gone: true, exitCode: nil) == "no longer reported")
    }

    // MARK: - AppState.remoteUnreadType(kind:exitCode:)

    @Test func remoteUnreadType_waitingInputIsAttentionNeeded() {
        #expect(AppState.remoteUnreadType(kind: "waiting_input", exitCode: nil) == .attentionNeeded)
    }

    @Test func remoteUnreadType_exitedWithNonzeroCodeIsError() {
        #expect(AppState.remoteUnreadType(kind: "exited", exitCode: 1) == .error)
    }

    @Test func remoteUnreadType_exitedWithZeroCodeIsResponseComplete() {
        #expect(AppState.remoteUnreadType(kind: "exited", exitCode: 0) == .responseComplete)
    }

    @Test func remoteUnreadType_exitedWithUnknownCodeIsResponseComplete() {
        #expect(AppState.remoteUnreadType(kind: "exited", exitCode: nil) == .responseComplete)
    }

    @Test func remoteUnreadType_unrecognizedKindIsNil() {
        #expect(AppState.remoteUnreadType(kind: "idle", exitCode: nil) == nil)
    }

    // MARK: - RemoteSessionRowView.suffixIndicator(agentState:) — steady-state mapping

    @Test func suffixIndicator_workingIsWorking() {
        #expect(RemoteSessionRowView.suffixIndicator(agentState: .working) == .working)
    }

    /// The steady-state divergence: `waitingInput` maps to `.attention` on
    /// every call, purely from `agentState` — there is no edge/latch here,
    /// unlike the `unreadByRemoteSession` bookkeeping (which is edge-
    /// triggered and clears on select). Calling this twice in a row for the
    /// same still-waiting session must keep returning `.attention`.
    @Test func suffixIndicator_waitingInputIsAttentionSteadily() {
        #expect(RemoteSessionRowView.suffixIndicator(agentState: .waitingInput) == .attention)
        #expect(RemoteSessionRowView.suffixIndicator(agentState: .waitingInput) == .attention)
    }

    @Test func suffixIndicator_idleIsNil() {
        #expect(RemoteSessionRowView.suffixIndicator(agentState: .idle) == nil)
    }

    @Test func suffixIndicator_unknownIsNil() {
        #expect(RemoteSessionRowView.suffixIndicator(agentState: .unknown) == nil)
    }

    @Test func suffixIndicator_exitedIsNil() {
        // `.exited` agentState produces no suffix glyph — the exited/gone
        // presentation is secondary-toned text + a caption, not a suffix icon.
        #expect(RemoteSessionRowView.suffixIndicator(agentState: .exited) == nil)
    }

    // MARK: - AppState.remoteSectionVisible(providers:)

    @Test func remoteSectionVisible_falseWhenNoProviders() {
        #expect(AppState.remoteSectionVisible(providers: []) == false)
    }

    @Test func remoteSectionVisible_trueWhenAtLeastOneProvider() {
        let provider = RemoteProviderStatus(
            config: RemoteProviderConfig(name: "acme", exec: "/usr/bin/true"),
            describe: nil, health: .ok,
            errorMessage: nil, remediationLabel: nil, remediationCommand: nil
        )
        #expect(AppState.remoteSectionVisible(providers: [provider]) == true)
    }
}
