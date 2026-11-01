import Testing
import TestProcessDefaults

// The test host's SIGPIPE handler (`Tests/TestProcessDefaults/SIGPIPEHandler.c`)
// is installed by a constructor when the test bundle loads, and every CI pass
// is a process of its own. These two suites check the handler in each of the
// two passes this target is split across. Which pass runs a suite is decided
// by the first letter of its type name: pass 1a filters
// `^TBDDaemonTests\.[A-O]` and pass 1b takes the rest. Renaming either suite
// can move it, so keep one name in each half.

/// Checks the handler in fast pass 1a (`TBDDaemonTests` A–O): the type name
/// starts with H.
@Suite("Test host SIGPIPE handler, TBDDaemonTests A–O")
struct HostSIGPIPECheckAToOTests {
    @Test("SIGPIPE is caught by the test host's handler in this pass's process")
    func sigpipeIsCaughtByTheHostHandler() {
        let disposition = String(cString: TBDTestHostSIGPIPEDisposition())
        #expect(disposition == "test host handler")
    }
}

/// Checks the handler in fast pass 1b (the rest of `TBDDaemonTests`): the type
/// name starts with S.
@Suite("Test host SIGPIPE handler, TBDDaemonTests P–Z")
struct SIGPIPECheckPToZTests {
    @Test("SIGPIPE is caught by the test host's handler in this pass's process")
    func sigpipeIsCaughtByTheHostHandler() {
        let disposition = String(cString: TBDTestHostSIGPIPEDisposition())
        #expect(disposition == "test host handler")
    }
}
