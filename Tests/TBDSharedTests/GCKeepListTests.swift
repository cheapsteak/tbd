import Darwin
import Foundation
import Testing

@testable import TBDShared

/// The keep-list parser, matcher and file handling. Every case that touches
/// disk uses a fresh temp directory, never the real `~/tbd`.
@Suite("GC keep-list")
struct GCKeepListTests {
    private static func withTempDir<T>(_ body: (URL) throws -> T) rethrows -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gckeep-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            // A mode-000 fixture would block removal.
            _ = chmod(dir.appendingPathComponent("keep").path, 0o700)
            try? FileManager.default.removeItem(at: dir)
        }
        return try body(dir)
    }

    @Test func theShippedPatternsAreTheSix() {
        #expect(GCKeepList.shippedPatterns == [
            "claude daemon run", "--bg-pty-host", "gpg-agent", "dirmngr", "keyboxd", "codex app-server",
        ])
    }

    @Test func parseTrimsAndSkipsBlankAndCommentLines() {
        #expect(GCKeepList.parse("  # c\n\n gpg-agent \r\nfoo\r\n").patterns == ["gpg-agent", "foo"])
    }

    @Test func substringMatching() {
        let shipped = GCKeepList.shipped
        #expect(shipped.matches("/x/claude --bg-pty-host --y"))
        #expect(shipped.matches("/opt/homebrew/bin/dirmngr --daemon"))
        #expect(!shipped.matches("claude --resume abc"))
    }

    @Test func anEmptyPatternNeverMatches() {
        #expect(GCKeepList(patterns: [""]).matches("x") == false)
    }

    @Test func aMissingFileMeansShippedDefaults() {
        Self.withTempDir { dir in
            let loaded = GCKeepList.load(path: dir.appendingPathComponent("keep").path)
            #expect(loaded == .list(.shipped, .shippedDefaults))
        }
    }

    @Test func aFileReplacesTheDefaults() throws {
        try Self.withTempDir { dir in
            let path = dir.appendingPathComponent("keep").path
            try "foo\n".write(toFile: path, atomically: true, encoding: .utf8)
            #expect(GCKeepList.load(path: path) == .list(GCKeepList(patterns: ["foo"]), .file))
        }
    }

    @Test func anEmptyFileIsAnEmptyList() throws {
        try Self.withTempDir { dir in
            let path = dir.appendingPathComponent("keep").path
            try "".write(toFile: path, atomically: true, encoding: .utf8)
            #expect(GCKeepList.load(path: path) == .list(GCKeepList(patterns: []), .file))
        }
    }

    @Test func anUnreadableFileIsUnreadable() throws {
        try Self.withTempDir { dir in
            let path = dir.appendingPathComponent("keep").path
            try "foo\n".write(toFile: path, atomically: true, encoding: .utf8)
            #expect(chmod(path, 0o000) == 0)
            guard case .unreadable = GCKeepList.load(path: path) else {
                Issue.record("a mode-000 file did not load as unreadable")
                return
            }
        }
        try Self.withTempDir { dir in
            let path = dir.appendingPathComponent("keep").path
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            guard case .unreadable = GCKeepList.load(path: path) else {
                Issue.record("a directory did not load as unreadable")
                return
            }
        }
    }

    @Test func customizeWritesOnceAndNeverOverwrites() throws {
        try Self.withTempDir { dir in
            let path = dir.appendingPathComponent("sub", isDirectory: true)
                .appendingPathComponent("keep").path
            #expect(try GCKeepList.customize(path: path) == true)
            #expect(GCKeepList.load(path: path) == .list(.shipped, .file))
            try "mine\n".write(toFile: path, atomically: true, encoding: .utf8)
            #expect(try GCKeepList.customize(path: path) == false)
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "mine\n")
        }
    }

    @Test func thePathFollowsTBDHome() {
        let h = "/tmp/some-tbd-home"
        #expect(
            TBDConstants.gcKeepProcessesPath(environment: ["TBD_HOME": h])
                == TBDConstants.configDir(environment: ["TBD_HOME": h])
                .appendingPathComponent("gc-keep-processes").path)
    }
}
