import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

extension TBDHomeSerialized {
@Suite("scratch startup")
struct ScratchStartupTests {
    @Test func ensureScratchDirCreatesBaseWhenMissing() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("TBD_HOME", home.path, 1)
        defer { unsetenv("TBD_HOME"); try? FileManager.default.removeItem(at: home) }

        let scratch = TBDConstants.scratchDir.path
        #expect(!FileManager.default.fileExists(atPath: scratch))
        Daemon.ensureScratchDir()   // pure static helper, no server needed
        #expect(FileManager.default.fileExists(atPath: scratch))
    }
}
}
