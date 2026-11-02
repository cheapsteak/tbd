import Testing
import TestProcessDefaults

/// Checks the test host's SIGPIPE handler (`Tests/TestProcessDefaults/SIGPIPEHandler.c`)
/// in the app pass that takes `TBDAppTests` A–P (`--filter '^TBDAppTests\.[A-P]'`).
/// The handler is installed by a constructor when the test bundle loads, and
/// every CI pass is a process of its own. `TestHostSIGPIPEHandlerTests`
/// starts with T, so it runs in the other app pass; this suite's type name
/// starts with H to land in this one. Renaming it can move it.
@Suite("Test host SIGPIPE handler, TBDAppTests A–P")
struct HostSIGPIPECheckAToPTests {
    @Test("SIGPIPE is caught by the test host's handler in this pass's process")
    func sigpipeIsCaughtByTheHostHandler() {
        let disposition = String(cString: TBDTestHostSIGPIPEDisposition())
        #expect(disposition == "test host handler")
    }
}
