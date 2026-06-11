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

/// Tests for the environment-parameterized TBDConstants path functions.
///
/// These tests pass explicit environment dictionaries instead of mutating the
/// process-global TBD_HOME env var because all SPM test targets link into ONE
/// process and Swift Testing runs suites in parallel. An unserialized setenv
/// call in any target races TBDDaemonTests/TBDHomeSerializedSuites.swift
/// (the only permitted TBD_HOME-mutation domain in this process). Using
/// env dictionaries makes these tests fully race-immune.
@Suite struct ConfigDirEnvOverrideTests {
    @Test func configDirFallsBackToHomeTbdWhenEnvEmpty() {
        let url = TBDConstants.configDir(environment: [:])
        let path = url.path
        #expect(path.contains(FileManager.default.homeDirectoryForCurrentUser.path))
        #expect(path.hasSuffix("/tbd"))
    }

    @Test func configDirHonorsTBDHome() {
        let url = TBDConstants.configDir(environment: ["TBD_HOME": "/tmp/tbd-test-config"])
        #expect(url.path == "/tmp/tbd-test-config")
    }

    @Test func emptyTBDHomeIsTreatedAsUnset() {
        let url = TBDConstants.configDir(environment: ["TBD_HOME": ""])
        #expect(url.path.hasSuffix("/tbd"))
    }

    @Test func derivedPathsFollowTBDHome() {
        let env = ["TBD_HOME": "/tmp/tbd-derived"]
        #expect(TBDConstants.databasePath(environment: env) == "/tmp/tbd-derived/state.db")
        #expect(TBDConstants.pidFilePath(environment: env) == "/tmp/tbd-derived/tbdd.pid")
        #expect(TBDConstants.portFilePath(environment: env) == "/tmp/tbd-derived/port")
        #expect(TBDConstants.reposDir(environment: env).path == "/tmp/tbd-derived/repos")
        #expect(TBDConstants.socketPath(environment: env) == "/tmp/tbd-derived/sock")
    }

    @Test func socketPathOverrideWinsOverTBDHome() {
        let env = ["TBD_HOME": "/tmp/tbd-some-home", "TBD_SOCKET_PATH": "/tmp/short.sock"]
        #expect(TBDConstants.socketPath(environment: env) == "/tmp/short.sock")
        // Other paths still follow TBD_HOME — only socket is redirected.
        #expect(TBDConstants.databasePath(environment: env) == "/tmp/tbd-some-home/state.db")
    }

    @Test func socketPathOverrideAloneWorks() {
        let env = ["TBD_SOCKET_PATH": "/tmp/lone.sock"]
        #expect(TBDConstants.socketPath(environment: env) == "/tmp/lone.sock")
        // Other paths still resolve to ~/tbd.
        #expect(TBDConstants.databasePath(environment: env).hasSuffix("/tbd/state.db"))
    }
}

/// Smoke-tests that the production computed vars are correctly wired to the
/// parameterized functions. Uses suffix-only assertions so these hold under ANY
/// concurrent TBD_HOME value — other suites in TBDDaemonTests legitimately
/// set TBD_HOME in parallel, so absolute-path assertions on production vars
/// would be a race condition.
@Suite struct ProductionVarSmokeSuite {
    @Test func databasePathSuffix() {
        #expect(TBDConstants.databasePath.hasSuffix("/state.db"))
    }

    @Test func pidFilePathSuffix() {
        #expect(TBDConstants.pidFilePath.hasSuffix("/tbdd.pid"))
    }

    @Test func portFilePathSuffix() {
        #expect(TBDConstants.portFilePath.hasSuffix("/port"))
    }

    @Test func reposDirSuffix() {
        #expect(TBDConstants.reposDir.path.hasSuffix("/repos"))
    }
}
