import Foundation
import Testing
@testable import TBDApp

@Suite("Daemon launch process")
struct DaemonLaunchProcessTests {
    @Test("sets no QoS clamp, so sessions inherit default scheduling")
    func noQualityOfServiceClamp() {
        let process = DaemonClient.makeDaemonProcess(executablePath: "/opt/acme/tbdd")
        #expect(process.qualityOfService == .default)
    }

    @Test("targets the given executable with output sent to the null device")
    func executableAndOutput() {
        let process = DaemonClient.makeDaemonProcess(executablePath: "/opt/acme/tbdd")
        #expect(process.executableURL == URL(fileURLWithPath: "/opt/acme/tbdd"))
        #expect((process.standardOutput as? FileHandle) === FileHandle.nullDevice)
        #expect((process.standardError as? FileHandle) === FileHandle.nullDevice)
    }
}
