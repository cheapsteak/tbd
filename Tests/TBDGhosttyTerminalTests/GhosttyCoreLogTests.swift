@testable import TBDGhosttyCore
import TestSupport
import Testing

/// `GhosttyCoreLog`: the engine logs under the app's subsystem until a host configures another.
///
/// Serialized because the setting is process-wide. The test that changes it puts the default back
/// before it returns, so no other suite logs under a test's subsystem for longer than that.
@Suite(.serialized, .fastPassBounded)
struct GhosttyCoreLogTests {
    /// The default is the app's subsystem, which is where the engine logged before a host could
    /// choose.
    @Test func theDefaultIsTheAppsSubsystem() {
        #expect(GhosttyCoreLog.defaultSubsystem == "com.tbd.app")
    }

    @Test func configureChangesTheSubsystem() {
        defer { GhosttyCoreLog.configure(subsystem: GhosttyCoreLog.defaultSubsystem) }
        GhosttyCoreLog.configure(subsystem: "com.tbd.daemon")
        #expect(GhosttyCoreLog.subsystem == "com.tbd.daemon")
        GhosttyCoreLog.configure(subsystem: GhosttyCoreLog.defaultSubsystem)
        #expect(GhosttyCoreLog.subsystem == GhosttyCoreLog.defaultSubsystem)
    }
}
