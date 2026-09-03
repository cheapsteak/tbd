import Testing
import Foundation
@testable import TBDShared

@Test func hookPathSetup() {
    let repoID = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
    let path = TBDConstants.hookPath(repoID: repoID, eventName: "setup", environment: ["TBD_HOME": "/tmp/tbd-hooks"])
    #expect(path == "/tmp/tbd-hooks/repos/12345678-1234-1234-1234-123456789ABC/hooks/setup")
}

@Test func hookPathPreSession() {
    let repoID = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
    let path = TBDConstants.hookPath(repoID: repoID, eventName: "preSession", environment: ["TBD_HOME": "/tmp/tbd-hooks"])
    #expect(path == "/tmp/tbd-hooks/repos/12345678-1234-1234-1234-123456789ABC/hooks/preSession")
}

@Test func hookPathArchive() {
    let repoID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let path = TBDConstants.hookPath(repoID: repoID, eventName: "archive", environment: ["TBD_HOME": "/tmp/tbd-hooks"])
    #expect(path == "/tmp/tbd-hooks/repos/AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA/hooks/archive")
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
    @Test func configDirFallsBackToHomeTbdWhenKeyAbsent() {
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
        #expect(TBDConstants.actuationLogPath(environment: env) == "/tmp/tbd-derived/actuations.jsonl")
    }

    @Test func actuationLogPathFallsBackToHomeTbdWhenKeyAbsent() {
        let path = TBDConstants.actuationLogPath(environment: [:])
        #expect(path.hasSuffix("/tbd/actuations.jsonl"))
        #expect(path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
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

    @Test func scratchDirFollowsTBDHome() {
        let env = ["TBD_HOME": "/tmp/tbd-scratch-test"]
        #expect(TBDConstants.scratchDir(environment: env).path == "/tmp/tbd-scratch-test/scratch")
    }

    @Test func scratchDirFallsBackToHomeTbdScratch() {
        let path = TBDConstants.scratchDir(environment: [:]).path
        #expect(path.hasSuffix("/tbd/scratch"))
    }

    @Test func claudeScratchpadBaseDefaultsToPrivateTmpClaudeUID() {
        let url = TBDConstants.claudeScratchpadBase(environment: [:])
        #expect(url.path == "/private/tmp/claude-\(getuid())")
    }

    @Test func claudeScratchpadBaseHonorsOverride() {
        let url = TBDConstants.claudeScratchpadBase(
            environment: ["TBD_CLAUDE_SCRATCH_BASE": "/tmp/claude-scratch-test"]
        )
        #expect(url.path == "/tmp/claude-scratch-test")
    }

    @Test func emptyClaudeScratchpadBaseOverrideIsTreatedAsUnset() {
        let url = TBDConstants.claudeScratchpadBase(environment: ["TBD_CLAUDE_SCRATCH_BASE": ""])
        #expect(url.path == "/private/tmp/claude-\(getuid())")
    }

    /// The host Claude store's single resolution point. `TBDApp` reads it too
    /// (`LegacyHookSettingsPath`), so it lives here rather than in the daemon.
    @Test func claudeHostHomeHonorsOverride() {
        let url = TBDConstants.claudeHostHome(
            environment: ["TBD_CLAUDE_HOST_HOME": "/tmp/acme-claude-host"]
        )
        #expect(url.path == "/tmp/acme-claude-host")
    }

    /// The other branch, plus the empty-is-unset rule the other overrides
    /// follow. Asserted with `homeDirectoryForCurrentUser` rather than a
    /// literal so it holds under the wrapper's `CFFIXED_USER_HOME`.
    @Test func claudeHostHomeFallsBackToDotClaude() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true).path
        #expect(TBDConstants.claudeHostHome(environment: [:]).path == expected)
        #expect(TBDConstants.claudeHostHome(environment: ["TBD_CLAUDE_HOST_HOME": ""]).path == expected)
    }
}

/// Smoke-tests that the production computed vars are correctly wired to the
/// parameterized functions. Uses suffix-only assertions so these hold under ANY
/// concurrent TBD_HOME value — other suites in TBDDaemonTests legitimately
/// set TBD_HOME in parallel, so absolute-path assertions on production vars
/// would be a race condition.
///
/// `configDir` is deliberately not smoke-tested here: it returns a URL whose
/// path has no stable suffix under a concurrent TBD_HOME override (the value
/// IS the override), so any suffix assertion would itself be a race condition.
/// Its wiring is covered transitively by the derived-path vars below.
///
/// `socketPath` is safe to check with a suffix because no suite in this
/// process sets TBD_SOCKET_PATH, and `scripts/test.sh` — which does set it for
/// the whole run — deliberately pins it to `$TBD_HOME/sock` so this suffix
/// still holds.
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

    @Test func socketPathSuffix() {
        #expect(TBDConstants.socketPath.hasSuffix("/sock"))
    }
}

@Test func worktreesDirFollowsTBDHome() {
    let env = ["TBD_HOME": "/tmp/tbd-wt"]
    #expect(TBDConstants.worktreesDir(environment: env).path == "/tmp/tbd-wt/worktrees")
}

@Test func worktreesDirFallsBackToHomeTbdWorktrees() {
    #expect(TBDConstants.worktreesDir(environment: [:]).path.hasSuffix("/tbd/worktrees"))
}

@Test func notesPathRepoScope() {
    let repoID = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
    let path = TBDConstants.notesPath(repoID: repoID, environment: ["TBD_HOME": "/tmp/tbd-notes"])
    #expect(path == "/tmp/tbd-notes/repos/12345678-1234-1234-1234-123456789ABC/notes.md")
}

@Test func claudeSettingsOverlayPathRepoScope() {
    let repoID = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
    let path = TBDConstants.claudeSettingsOverlayPath(repoID: repoID, environment: ["TBD_HOME": "/tmp/tbd-cso"])
    #expect(path == "/tmp/tbd-cso/repos/12345678-1234-1234-1234-123456789ABC/claude-settings.json")
}

@Test func markdownThemesDirFollowsTBDHome() {
    let env = ["TBD_HOME": "/tmp/tbd-md-themes"]
    #expect(TBDConstants.markdownThemesDir(environment: env).path == "/tmp/tbd-md-themes/markdown-themes")
}

@Test func markdownThemesDirFallsBackToHomeTbdMarkdownThemes() {
    #expect(TBDConstants.markdownThemesDir(environment: [:]).path.hasSuffix("/tbd/markdown-themes"))
}

@Test func notesPathWorktreeScope() {
    let wtID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let path = TBDConstants.notesPath(worktreeID: wtID, environment: ["TBD_HOME": "/tmp/tbd-notes"])
    #expect(path == "/tmp/tbd-notes/worktrees/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/notes.md")
}

/// `~/tbd/transcripts/<provider>/<key>.jsonl` — where a `recall` lands.
///
/// Env dictionaries throughout, for the reason `ConfigDirEnvOverrideTests`
/// gives: an unserialized `setenv` in this target races every concurrently
/// running suite in the same process.
@Suite struct RetainedTranscriptPathTests {
    private let env = ["TBD_HOME": "/tmp/tbd-transcripts"]

    @Test func transcriptsDirFollowsTBDHome() {
        #expect(TBDConstants.retainedTranscriptsDir(environment: env).path
            == "/tmp/tbd-transcripts/transcripts")
    }

    @Test func transcriptsDirFallsBackToHomeTbdWhenKeyAbsent() {
        let path = TBDConstants.retainedTranscriptsDir(environment: [:]).path
        #expect(path.contains(FileManager.default.homeDirectoryForCurrentUser.path))
        #expect(path.hasSuffix("/tbd/transcripts"))
    }

    @Test func ordinaryKeyLandsUnderItsProvider() {
        let url = TBDConstants.retainedTranscriptPath(
            provider: "agentbox", key: "abc-123", environment: env)
        #expect(url.path == "/tmp/tbd-transcripts/transcripts/agentbox/abc-123.jsonl")
    }

    /// A key is opaque and may contain anything, including a path separator.
    /// It must stay one filename rather than becoming a directory tree.
    @Test func aKeyWithSeparatorsStaysOneComponent() {
        let url = TBDConstants.retainedTranscriptPath(
            provider: "agentbox", key: "a/b/c", environment: env)
        #expect(url.path == "/tmp/tbd-transcripts/transcripts/agentbox/a%2Fb%2Fc.jsonl")
        #expect(url.deletingLastPathComponent().path == "/tmp/tbd-transcripts/transcripts/agentbox")
        #expect(url.pathComponents.count
            == TBDConstants.retainedTranscriptsDir(environment: env).pathComponents.count + 2)
    }

    /// The traversal case the escaping exists for: neither `.` nor `..` may
    /// survive as a relative path component.
    @Test func dotAndDotDotAreEscapedRatherThanTraversing() {
        let dotdot = TBDConstants.retainedTranscriptPath(
            provider: "..", key: "..", environment: env)
        #expect(dotdot.path == "/tmp/tbd-transcripts/transcripts/%2E%2E/%2E%2E.jsonl")
        let dot = TBDConstants.retainedTranscriptPath(
            provider: "agentbox", key: ".", environment: env)
        #expect(dot.path == "/tmp/tbd-transcripts/transcripts/agentbox/%2E.jsonl")
    }

    /// Injective: two distinct keys can never name one file. `%` is itself
    /// escaped, which is what rules out the collision a naive escaper has.
    @Test func escapingIsInjectiveAcrossPercentSequences() {
        let literal = TBDConstants.retainedTranscriptPath(
            provider: "p", key: "a%2Fb", environment: env)
        let separator = TBDConstants.retainedTranscriptPath(
            provider: "p", key: "a/b", environment: env)
        #expect(literal.path != separator.path)
        #expect(literal.path == "/tmp/tbd-transcripts/transcripts/p/a%252Fb.jsonl")
    }

    @Test func spacesAndUnicodeAreEncoded() {
        let url = TBDConstants.retainedTranscriptPath(
            provider: "agentbox", key: "fix flaky CI", environment: env)
        #expect(url.path == "/tmp/tbd-transcripts/transcripts/agentbox/fix%20flaky%20CI.jsonl")
    }
}
