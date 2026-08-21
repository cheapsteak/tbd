import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("ProviderRunner timeout (live)")
struct ProviderRunnerTimeoutTests {
    @Test func deadlineKillsHungProvider() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("hang.sh")
        try "#!/bin/bash\nsleep 60\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        let config = RemoteProviderConfig(name: "hang", exec: path.path)
        await #expect(throws: ProviderRunError.self) {
            _ = try await ProviderRunner().run(
                config, verb: ["list"], stdin: nil, timeout: 1, contractVersion: 1)
        }
    }
}
