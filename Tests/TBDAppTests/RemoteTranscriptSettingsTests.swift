import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// The Settings surface for `remote_transcript_enabled`, and the AppState
/// wiring a remote transcript pane reads through: the composer gate, and the
/// sync-driver registry a composer send reaches.
///
/// Every `AppState` here runs over its own throwaway `UserDefaults` suite —
/// `.standard` on this unbundled executable is the developer's real
/// `TBDApp.plist`.
@MainActor
@Suite("Remote transcript settings and wiring", .clockDriven)
struct RemoteTranscriptSettingsTests {
    private static let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")

    private func withAppState(_ body: (AppState) async -> Void) async {
        let name = "tbd-remote-transcript-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        await body(AppState(userDefaults: defaults))
        defaults.removePersistentDomain(forName: name)
    }

    private static func capabilities(
        remoteTranscript: Bool, composer: Bool
    ) -> DaemonCapabilitiesResult {
        var result = DaemonCapabilitiesResult(
            controlModeEnabled: false, transcriptComposerEnabled: composer)
        result.remoteTranscriptEnabled = remoteTranscript
        return result
    }

    private static func provider(capabilities: [String]) -> RemoteProviderStatus {
        RemoteProviderStatus(
            config: RemoteProviderConfig(name: "acme", exec: "/nonexistent"),
            describe: ProviderDescribe(
                contractVersions: [1], name: "acme", capabilities: capabilities),
            health: .ok, errorMessage: nil,
            remediationLabel: nil, remediationCommand: nil)
    }

    // MARK: - Settings toggle

    @Test func setterPersistsOnAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            var refreshes = 0
            state.remoteTranscriptFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return Self.capabilities(remoteTranscript: true, composer: false)
            }

            await state.setRemoteTranscriptEnabled(true)

            #expect(written == [true])
            #expect(refreshes == 1, "the toggle must read the daemon back, not its own guess")
            #expect(state.remoteTranscriptEnabled == true)
        }
    }

    @Test func setterPersistsOffAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            state.remoteTranscriptFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                Self.capabilities(remoteTranscript: false, composer: false)
            }

            await state.setRemoteTranscriptEnabled(false)

            #expect(written == [false])
            #expect(state.remoteTranscriptEnabled == false)
        }
    }

    @Test func setterSurfacesAFailureAndLeavesCapabilitiesAlone() async {
        struct Boom: Error {}
        await withAppState { state in
            var refreshes = 0
            state.remoteTranscriptFlagSetter = { @MainActor _ in throw Boom() }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return nil
            }

            await state.setRemoteTranscriptEnabled(true)

            #expect(refreshes == 0, "a failed write must not be followed by a refresh")
            #expect(state.daemonCapabilities == nil)
            #expect(state.alertMessage != nil)
        }
    }

    // MARK: - Composer gate

    @Test("the remote composer needs send-submit and both flags")
    func composerGate() async {
        await withAppState { state in
            state.remoteProviders = [Self.provider(capabilities: [
                RemoteCapability.transcriptRead, RemoteCapability.sendSubmit,
            ])]
            // Not in the mirror yet: hidden whatever the flags say.
            state.daemonCapabilities = Self.capabilities(remoteTranscript: true, composer: true)
            #expect(state.remoteComposerState(for: Self.selection) == .hidden)

            state.remoteSessions = [RemoteSessionInfo(
                provider: "acme",
                payload: RemoteSessionPayload(id: "s1", state: .running, agentState: .working),
                gone: false, dismissed: false, lastSeen: Date())]
            #expect(state.remoteComposerState(for: Self.selection) == .running)

            state.daemonCapabilities = Self.capabilities(remoteTranscript: false, composer: true)
            #expect(state.remoteComposerState(for: Self.selection) == .hidden)

            state.daemonCapabilities = Self.capabilities(remoteTranscript: true, composer: false)
            #expect(state.remoteComposerState(for: Self.selection) == .hidden)

            state.daemonCapabilities = Self.capabilities(remoteTranscript: true, composer: true)
            state.remoteProviders = [Self.provider(capabilities: [RemoteCapability.transcriptRead])]
            #expect(state.remoteComposerState(for: Self.selection) == .hidden)
        }
    }

    // MARK: - Sync driver registry

    @Test("a send's sync request reaches the registered, active driver at once")
    func syncRequestReachesRegisteredDriver() async throws {
        let name = "tbd-remote-transcript-registry-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let state = AppState(userDefaults: defaults)
        let clock = EventDrivenTestClock()
        let syncs = FireRecorder<Int>()
        var count = 0
        let driver = RemoteTranscriptSyncDriver(
            selection: Self.selection,
            sync: { _ in
                count += 1
                syncs.record(count)
                return RemoteTranscriptSyncResult(path: "/p", generation: 1, caughtUp: true)
            },
            clock: clock)
        defer { driver.stop() }
        state.registerRemoteTranscriptSyncDriver(driver)
        #expect(state.remoteTranscriptSyncDrivers[Self.selection]?.driver === driver)

        driver.setActive(true)
        #expect(await syncs.next() == 1)
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)

        // No virtual time passes: only the request can explain a second sync.
        state.requestRemoteTranscriptSync(Self.selection)
        #expect(await syncs.next() == 2)

        // Newer-wins: a stale driver unregistering leaves the live one.
        let stale = RemoteTranscriptSyncDriver(
            selection: Self.selection, sync: { _ in throw CancellationError() })
        state.unregisterRemoteTranscriptSyncDriver(stale)
        #expect(state.remoteTranscriptSyncDrivers[Self.selection]?.driver === driver)

        // Unregistered, the same request reaches nothing, though the driver
        // is still active and waiting on its tick.
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        state.unregisterRemoteTranscriptSyncDriver(driver)
        #expect(state.remoteTranscriptSyncDrivers[Self.selection] == nil)
        state.requestRemoteTranscriptSync(Self.selection)
        await settle()
        #expect(syncs.values == [1, 2])
    }
}
