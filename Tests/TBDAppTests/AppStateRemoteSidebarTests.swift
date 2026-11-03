import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// `AppState`'s pure remote sidebar helpers:
/// - `remoteUnreadType(kind:exitCode:)` — the kind to `NotificationType`
///   mapping feeding `unreadByRemoteSession`.
/// - `remoteSectionVisible(providers:)` — the section hidden when there is no
///   provider.
@Suite("AppState — remote sidebar helpers")
struct AppStateRemoteSidebarTests {

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
