import Foundation
import Testing
import TBDShared
@testable import TBDApp

// Tier 1: deterministic, in-process state only (see `PanelTabsTestSupport`).

/// The daemon capability fetch the app makes at connect
/// (`AppState.fetchDaemonCapabilitiesAtConnect`), and the poll's retry while
/// it holds none (`retryDaemonCapabilitiesIfMissing`).
@Suite("Daemon capabilities fetch")
@MainActor
struct DaemonCapabilitiesFetchTests {
    private typealias Fixture = PanelTabsFixture

    /// Counts capability fetches and answers each with `result` (nil: the
    /// fetch failed).
    @MainActor
    private final class CapabilitiesFetchStub {
        var result: DaemonCapabilitiesResult?
        private(set) var count = 0

        func install(on state: AppState) {
            state.daemonCapabilitiesFetcher = { @MainActor [self] in
                count += 1
                return result
            }
        }
    }

    @Test("a failed capability fetch at connect keeps the previous value, and the poll retries while none is held")
    func failedConnectCapabilityFetchKeepsPreviousAndRetries() async {
        await Fixture.withState { state in
            state.programStatusListFetcher = { @MainActor in [] }
            state.isConnected = true
            state.daemonCapabilities = DaemonCapabilitiesResult(controlModeEnabled: true)
            let fetch = CapabilitiesFetchStub()
            fetch.install(on: state)

            // A reconnect whose fetch fails keeps the capabilities it held.
            await state.fetchDaemonCapabilitiesAtConnect()
            #expect(fetch.count == 1)
            #expect(state.daemonCapabilities?.controlModeEnabled == true,
                    "a transient failure must not switch a capability off")

            // Held capabilities need no retry.
            await state.retryDaemonCapabilitiesIfMissing()
            #expect(fetch.count == 1, "the poll fetches nothing while capabilities are held")

            // A launch whose fetch fails holds none.
            state.daemonCapabilities = nil
            await state.fetchDaemonCapabilitiesAtConnect()
            #expect(fetch.count == 2)
            #expect(state.daemonCapabilities == nil)

            // Disconnected, the poll does not ask.
            state.isConnected = false
            await state.retryDaemonCapabilitiesIfMissing()
            #expect(fetch.count == 2, "the poll fetches nothing while disconnected")

            // Connected, it asks every cycle until a fetch succeeds.
            state.isConnected = true
            await state.retryDaemonCapabilitiesIfMissing()
            #expect(fetch.count == 3)
            #expect(state.daemonCapabilities == nil)

            fetch.result = DaemonCapabilitiesResult(controlModeEnabled: true)
            await state.retryDaemonCapabilitiesIfMissing()
            #expect(fetch.count == 4)
            #expect(state.daemonCapabilities?.controlModeEnabled == true)

            await state.retryDaemonCapabilitiesIfMissing()
            #expect(fetch.count == 4, "a successful retry ends the retries")
        }
    }
}
