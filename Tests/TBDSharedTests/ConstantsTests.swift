import Testing
import Foundation
@testable import TBDShared

@Test func hookPathSetup() {
    let repoID = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
    let path = TBDConstants.hookPath(repoID: repoID, eventName: "setup")
    #expect(path.hasSuffix("/repos/12345678-1234-1234-1234-123456789ABC/hooks/setup"))
}

@Test func hookPathArchive() {
    let repoID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let path = TBDConstants.hookPath(repoID: repoID, eventName: "archive")
    #expect(path.hasSuffix("/repos/AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA/hooks/archive"))
}

/// Run env-mutating tests serialized so they don't race each other. Each test
/// snapshots the prior env value and restores it via defer.
@Suite(.serialized)
struct ConfigDirEnvOverrideTests {
    private func withEnv(_ key: String, _ value: String?, _ body: () -> Void) {
        let prior = ProcessInfo.processInfo.environment[key]
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
        defer {
            if let prior {
                setenv(key, prior, 1)
            } else {
                unsetenv(key)
            }
        }
        body()
    }

    @Test func configDirFallsBackToHomeTbdWhenEnvUnset() {
        withEnv("TBD_HOME", nil) {
            let path = TBDConstants.configDir.path
            #expect(path.hasSuffix("/tbd"))
            #expect(path.contains(FileManager.default.homeDirectoryForCurrentUser.path))
        }
    }

    @Test func configDirHonorsTBDHome() {
        withEnv("TBD_HOME", "/tmp/tbd-test-config") {
            #expect(TBDConstants.configDir.path == "/tmp/tbd-test-config")
        }
    }

    @Test func emptyTBDHomeIsTreatedAsUnset() {
        withEnv("TBD_HOME", "") {
            let path = TBDConstants.configDir.path
            #expect(path.hasSuffix("/tbd"))
        }
    }

    @Test func derivedPathsFollowTBDHome() {
        withEnv("TBD_HOME", "/tmp/tbd-derived") {
            withEnv("TBD_SOCKET_PATH", nil) {
                #expect(TBDConstants.databasePath == "/tmp/tbd-derived/state.db")
                #expect(TBDConstants.pidFilePath == "/tmp/tbd-derived/tbdd.pid")
                #expect(TBDConstants.portFilePath == "/tmp/tbd-derived/port")
                #expect(TBDConstants.reposDir.path == "/tmp/tbd-derived/repos")
                #expect(TBDConstants.socketPath == "/tmp/tbd-derived/sock")
            }
        }
    }

    @Test func socketPathOverrideWinsOverTBDHome() {
        withEnv("TBD_HOME", "/tmp/tbd-some-home") {
            withEnv("TBD_SOCKET_PATH", "/tmp/short.sock") {
                #expect(TBDConstants.socketPath == "/tmp/short.sock")
                // Other paths still follow TBD_HOME — only socket is redirected.
                #expect(TBDConstants.databasePath == "/tmp/tbd-some-home/state.db")
            }
        }
    }

    @Test func socketPathOverrideAloneWorks() {
        withEnv("TBD_HOME", nil) {
            withEnv("TBD_SOCKET_PATH", "/tmp/lone.sock") {
                #expect(TBDConstants.socketPath == "/tmp/lone.sock")
                // Other paths still resolve to ~/tbd.
                #expect(TBDConstants.databasePath.hasSuffix("/tbd/state.db"))
            }
        }
    }
}
