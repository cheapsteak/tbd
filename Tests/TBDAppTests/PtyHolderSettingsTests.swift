import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The Settings surface for the pty-holder transport gate — the flag that had
/// no user-facing control at all, so its soak could not be started by any
/// ordinary gesture.
///
/// Every test that constructs `AppState` does so against a unique throwaway
/// `UserDefaults` suite and tears it down — TBDApp ships as an unbundled SPM
/// executable, so `UserDefaults.standard` is the running developer's real
/// `TBDApp.plist`.
@MainActor
@Suite("PtyHolderSettings")
struct PtyHolderSettingsTests {

    private func withAppState(_ body: (AppState) async -> Void) async {
        let name = "tbd-pty-holder-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        await body(AppState(userDefaults: defaults))
        defaults.removePersistentDomain(forName: name)
    }

    // MARK: - The setter, both directions and both branches

    @Test func setterPersistsOnAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            var refreshes = 0
            state.ptyHolderFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return DaemonCapabilitiesResult(
                    controlModeEnabled: false, ptyHolderEnabled: true, ptyHolderSupported: true)
            }

            await state.setPtyHolderEnabled(true)

            #expect(written == [true])
            #expect(refreshes == 1)
            #expect(state.daemonCapabilities?.ptyHolderEnabled == true)
        }
    }

    /// The off branch is its own test rather than a second assertion, because
    /// turning the transport OFF is the operator's exit from the soak and a
    /// setter that ignored its argument would pass the on-only test.
    @Test func setterPersistsOffAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            state.ptyHolderFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                DaemonCapabilitiesResult(
                    controlModeEnabled: false, ptyHolderEnabled: false, ptyHolderSupported: true)
            }

            await state.setPtyHolderEnabled(false)

            #expect(written == [false])
            #expect(state.daemonCapabilities?.ptyHolderEnabled == false)
        }
    }

    @Test func setterSurfacesAFailureAndLeavesCapabilitiesAlone() async {
        struct Boom: Error {}
        await withAppState { state in
            var refreshes = 0
            state.ptyHolderFlagSetter = { @MainActor _ in throw Boom() }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return nil
            }

            await state.setPtyHolderEnabled(true)

            #expect(refreshes == 0, "a failed write must not be followed by a refresh")
            #expect(state.alertMessage != nil)
        }
    }

    // MARK: - The holder-hibernation setter, both directions

    @Test func holderHibernationSetterPersistsOnAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            var refreshes = 0
            state.holderHibernationFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return DaemonCapabilitiesResult(
                    controlModeEnabled: false, holderHibernationEnabled: true)
            }

            await state.setHolderHibernationEnabled(true)

            #expect(written == [true])
            #expect(refreshes == 1)
            #expect(state.daemonCapabilities?.holderHibernationEnabled == true)
        }
    }

    /// The off branch is its own test rather than a second assertion, for the
    /// same reason as `setterPersistsOffAndRefreshesCapabilities` above: a
    /// setter that ignored its argument would pass the on-only test.
    @Test func holderHibernationSetterPersistsOffAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            state.holderHibernationFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                DaemonCapabilitiesResult(
                    controlModeEnabled: false, holderHibernationEnabled: false)
            }

            await state.setHolderHibernationEnabled(false)

            #expect(written == [false])
            #expect(state.daemonCapabilities?.holderHibernationEnabled == false)
        }
    }

    // MARK: - The help text

    /// The one claim the design spec forbids. Its §"why" is explicit that the
    /// justification is scaling headroom, not current latency — there is no
    /// measured win on a quiet machine — so a rewrite that promised speed
    /// would tell the operator something untrue about their own machine. This
    /// assertion fails on exactly that rewrite and on nothing else a faithful
    /// edit would do.
    @Test func theHelpTextMakesNoSpeedClaim() {
        let help = AppState.ptyHolderHelp.lowercased()
        for word in ["faster", "fast", "speed", "quicker", "latency", "snappier", "responsive"] {
            #expect(!help.contains(word), "the help text must not promise speed: found \"\(word)\"")
        }
    }

    /// The four things an operator has to know before flipping it, each of
    /// which is a fact about their sessions rather than a description of the
    /// implementation. Pinned by substring per fact, so a rewording that keeps
    /// a fact passes and a rewrite that drops one fails.
    @Test func theHelpTextCarriesEveryFactAnOperatorNeeds() {
        let help = AppState.ptyHolderHelp
        #expect(help.contains("Each new session runs on its own terminal rather than inside a tmux window."),
                "what changes, and that it is per-session")
        #expect(help.contains("Sessions already running stay on tmux; the change takes effect as they end and respawn."),
                "that it is not retroactive")
        #expect(help.contains("Attached sessions keep running uninterrupted across daemon restarts."),
                "what the operator gains")
        #expect(help.contains("Less scrollback is kept than tmux retains."),
                "what the operator gives up")
        #expect(help.contains("Off by default (soaking)."))
    }

    /// The disabled-state caption. It exists because the spawn gate asks two
    /// questions, not one: with no `TBDHolder` helper the flag is honored by
    /// falling back to tmux every single time, so a switch offered there would
    /// change nothing. The caption has to name the missing helper — "not
    /// available" alone would leave the operator with nothing to fix.
    @Test func theUnsupportedCaptionNamesTheMissingHelper() {
        #expect(AppState.ptyHolderUnsupportedCaption ==
            "Requires the TBDHolder helper beside the daemon binary; this daemon could not find it.")
    }

    // MARK: - What the toggle renders from

    /// Capabilities are nil until the first successful fetch, and the toggle
    /// must read OFF and greyed rather than claiming a transport the daemon has
    /// not confirmed.
    @Test func anUnfetchedCapabilityReadsOffAndUnsupported() async {
        await withAppState { state in
            #expect(state.daemonCapabilities == nil)
            #expect((state.daemonCapabilities?.ptyHolderEnabled ?? false) == false)
            #expect((state.daemonCapabilities?.ptyHolderSupported ?? false) == false)
        }
    }
}
