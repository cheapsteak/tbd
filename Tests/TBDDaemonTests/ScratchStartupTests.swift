import Testing
import TestSupport
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

extension TBDHomeSerialized {
@Suite("scratch startup")
struct ScratchStartupTests {
    @Test func ensureScratchDirCreatesBaseWhenMissing() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let priorTBDHome = setTBDHome(home.path)
        defer { restoreTBDHome(priorTBDHome); try? FileManager.default.removeItem(at: home) }

        let scratch = TBDConstants.scratchDir.path
        #expect(!FileManager.default.fileExists(atPath: scratch))
        Daemon.ensureScratchDir()   // pure static helper, no server needed
        #expect(FileManager.default.fileExists(atPath: scratch))
    }
}
}
