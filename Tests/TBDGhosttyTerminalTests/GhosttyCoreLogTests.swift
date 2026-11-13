@testable import TBDGhosttyCore
import TestSupport
import Testing

/// `GhosttyCoreLog`: the engine logs under the app's subsystem until a host configures another.
///
/// Each test builds a `Destination` of its own, so none changes where the rest of the process
/// logs.
@Suite(.fastPassBounded)
struct GhosttyCoreLogTests {
    /// The default is the app's subsystem, which is where the engine logged before a host could
    /// choose.
    @Test func theDefaultIsTheAppsSubsystem() {
        #expect(GhosttyCoreLog.defaultSubsystem == "com.tbd.app")
        #expect(GhosttyCoreLog.Destination().subsystem == GhosttyCoreLog.defaultSubsystem)
    }

    @Test func configureChangesTheLoggersSubsystem() {
        let destination = GhosttyCoreLog.Destination()
        destination.configure(subsystem: "com.tbd.daemon")
        #expect(destination.subsystem == "com.tbd.daemon")
        destination.configure(subsystem: GhosttyCoreLog.defaultSubsystem)
        #expect(destination.subsystem == GhosttyCoreLog.defaultSubsystem)
    }
}
