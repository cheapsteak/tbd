import Testing
import TestProcessDefaults

/// Checks the test host's SIGPIPE handler (`Tests/TestProcessDefaults/SIGPIPEHandler.c`)
/// in the quiet pass, which runs this target in a process of its own. The
/// handler is installed by a constructor when the test bundle loads, so each
/// pass's process needs its own check. Tier 1: it reads one disposition and
/// spawns nothing; it lives here only because this target is a pass.
@Suite("Test host SIGPIPE handler, TBDDaemonLiveTests")
struct HostSIGPIPECheckLiveTests {
    @Test("SIGPIPE is caught by the test host's handler in this pass's process")
    func sigpipeIsCaughtByTheHostHandler() {
        let disposition = String(cString: TBDTestHostSIGPIPEDisposition())
        #expect(disposition == "test host handler")
    }
}
