import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// The Settings row for the pty-holder transport. There is no switch: every
/// new session opens on a holder. When the daemon cannot start one, the row's
/// caption says why.
@MainActor
@Suite("PtyHolderSettings")
struct PtyHolderSettingsTests {

    /// The caption has to name the missing helper — "not available" alone
    /// would leave the operator with nothing to fix — and say what it costs.
    @Test func theUnsupportedCaptionNamesTheMissingHelper() {
        let caption = AppState.ptyHolderUnsupportedCaption
        #expect(caption.contains("TBDHolder helper"))
        #expect(caption.contains("cannot open any"))
    }

    /// Capabilities are nil until the first successful fetch, and the row must
    /// read unsupported rather than claim a transport the daemon has not
    /// confirmed.
    @Test func anUnfetchedCapabilityReadsUnsupported() {
        let suite = TestDefaultsSuite("tbd-pty-holder-settings")
        let state = AppState(userDefaults: suite.defaults)
        #expect(state.daemonCapabilities == nil)
        #expect((state.daemonCapabilities?.ptyHolderSupported ?? false) == false)
        suite.tearDown()
    }
}
