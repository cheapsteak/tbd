import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

@Suite("ClaudeTrustSeeder")
struct ClaudeTrustSeederTests {

    /// A temp config dir passed as `profileConfigDir` so tests never touch the
    /// developer's real `~/.claude.json`.
    private func tempConfigDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-trust-seed-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeWorktree(isScratch: Bool, path: String) -> Worktree {
        Worktree(
            repoID: isScratch ? nil : UUID(),
            name: "wt",
            displayName: "wt",
            branch: "main",
            path: path,
            tmuxServer: "srv"
        )
    }

    private func readClaudeJSON(_ configDir: URL) -> [String: Any]? {
        let file = configDir.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    // MARK: - Gate ON

    @Test("scratch worktree seeds hasTrustDialogAccepted=true")
    func gateOnSeedsTrust() {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        let wtPath = "/private/tmp/tbd-scratch-\(UUID().uuidString)"
        let wt = makeWorktree(isScratch: true, path: wtPath)

        ClaudeTrustSeeder.ensureTrustedForScratch(
            worktree: wt, profileConfigDir: configDir.path)

        let json = readClaudeJSON(configDir)
        let projects = json?["projects"] as? [String: Any]
        let entry = projects?[wtPath] as? [String: Any]
        #expect(entry?["hasTrustDialogAccepted"] as? Bool == true)
    }

    // MARK: - Gate OFF (required both-branches test)

    @Test("non-scratch worktree writes nothing")
    func gateOffWritesNothing() {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        let wtPath = "/private/tmp/tbd-real-\(UUID().uuidString)"
        let wt = makeWorktree(isScratch: false, path: wtPath)

        ClaudeTrustSeeder.ensureTrustedForScratch(
            worktree: wt, profileConfigDir: configDir.path)

        let file = configDir.appendingPathComponent(".claude.json")
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    // MARK: - Preserve top-level keys

    @Test("preserves unrelated top-level keys and other project entries")
    func preservesTopLevelKeys() throws {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let file = configDir.appendingPathComponent(".claude.json")

        let existing: [String: Any] = [
            "hasCompletedOnboarding": true,
            "someUnrelatedKey": "keep-me",
            "projects": [
                "/other/project": ["hasTrustDialogAccepted": true],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: file)

        let wtPath = "/private/tmp/tbd-scratch-\(UUID().uuidString)"
        let wt = makeWorktree(isScratch: true, path: wtPath)
        ClaudeTrustSeeder.ensureTrustedForScratch(
            worktree: wt, profileConfigDir: configDir.path)

        let json = readClaudeJSON(configDir)
        #expect(json?["hasCompletedOnboarding"] as? Bool == true)
        #expect(json?["someUnrelatedKey"] as? String == "keep-me")
        let projects = json?["projects"] as? [String: Any]
        let other = projects?["/other/project"] as? [String: Any]
        #expect(other?["hasTrustDialogAccepted"] as? Bool == true)
        let mine = projects?[wtPath] as? [String: Any]
        #expect(mine?["hasTrustDialogAccepted"] as? Bool == true)
    }

    // MARK: - Preserve intra-project keys

    @Test("preserves existing keys inside the target project entry")
    func preservesIntraProjectKeys() throws {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let file = configDir.appendingPathComponent(".claude.json")

        let wtPath = "/private/tmp/tbd-scratch-\(UUID().uuidString)"
        let existing: [String: Any] = [
            "projects": [
                wtPath: ["existingKey": "survive"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: file)

        let wt = makeWorktree(isScratch: true, path: wtPath)
        ClaudeTrustSeeder.ensureTrustedForScratch(
            worktree: wt, profileConfigDir: configDir.path)

        let json = readClaudeJSON(configDir)
        let projects = json?["projects"] as? [String: Any]
        let entry = projects?[wtPath] as? [String: Any]
        #expect(entry?["existingKey"] as? String == "survive")
        #expect(entry?["hasTrustDialogAccepted"] as? Bool == true)
    }

    // MARK: - Idempotent

    @Test("running twice produces identical valid JSON")
    func idempotent() throws {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        let wtPath = "/private/tmp/tbd-scratch-\(UUID().uuidString)"
        let wt = makeWorktree(isScratch: true, path: wtPath)

        ClaudeTrustSeeder.ensureTrustedForScratch(
            worktree: wt, profileConfigDir: configDir.path)
        let firstData = try Data(contentsOf: configDir.appendingPathComponent(".claude.json"))

        ClaudeTrustSeeder.ensureTrustedForScratch(
            worktree: wt, profileConfigDir: configDir.path)
        let secondData = try Data(contentsOf: configDir.appendingPathComponent(".claude.json"))

        #expect(firstData == secondData)
        // And still valid + correct.
        let json = readClaudeJSON(configDir)
        let entry = (json?["projects"] as? [String: Any])?[wtPath] as? [String: Any]
        #expect(entry?["hasTrustDialogAccepted"] as? Bool == true)
    }

    // MARK: - Malformed JSON

    @Test("malformed .claude.json is left untouched and no throw")
    func malformedJSONLeftUntouched() throws {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let file = configDir.appendingPathComponent(".claude.json")

        let garbage = "{ this is not valid json ]["
        try garbage.write(to: file, atomically: true, encoding: .utf8)

        let wtPath = "/private/tmp/tbd-scratch-\(UUID().uuidString)"
        let wt = makeWorktree(isScratch: true, path: wtPath)
        ClaudeTrustSeeder.ensureTrustedForScratch(
            worktree: wt, profileConfigDir: configDir.path)

        let after = try String(contentsOf: file, encoding: .utf8)
        #expect(after == garbage)
    }

    // MARK: - Config-dir fallback branches

    @Test("nil profileConfigDir falls back to environment CLAUDE_CONFIG_DIR")
    func fallsBackToEnvConfigDir() {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        let wtPath = "/private/tmp/tbd-scratch-\(UUID().uuidString)"
        let wt = makeWorktree(isScratch: true, path: wtPath)

        // homeDirectory points somewhere else to prove CLAUDE_CONFIG_DIR wins.
        let homeDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: homeDir) }

        ClaudeTrustSeeder.ensureTrustedForScratch(
            worktree: wt,
            profileConfigDir: nil,
            homeDirectory: homeDir.path,
            environment: ["CLAUDE_CONFIG_DIR": configDir.path])

        // Seeded into the env dir, NOT the home dir.
        let entry = (readClaudeJSON(configDir)?["projects"] as? [String: Any])?[wtPath] as? [String: Any]
        #expect(entry?["hasTrustDialogAccepted"] as? Bool == true)
        #expect(FileManager.default.fileExists(atPath: homeDir.appendingPathComponent(".claude.json").path) == false)
    }

    @Test("nil profileConfigDir + no CLAUDE_CONFIG_DIR falls back to homeDirectory")
    func fallsBackToHomeDirectory() {
        // Use a temp dir as homeDirectory so the real ~/.claude.json is never touched.
        let homeDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: homeDir) }
        let wtPath = "/private/tmp/tbd-scratch-\(UUID().uuidString)"
        let wt = makeWorktree(isScratch: true, path: wtPath)

        ClaudeTrustSeeder.ensureTrustedForScratch(
            worktree: wt,
            profileConfigDir: nil,
            homeDirectory: homeDir.path,
            environment: [:])

        let entry = (readClaudeJSON(homeDir)?["projects"] as? [String: Any])?[wtPath] as? [String: Any]
        #expect(entry?["hasTrustDialogAccepted"] as? Bool == true)
    }

    // MARK: - Skip-if-already-trusted (no clobbering a concurrent writer)

    @Test("already-trusted key: file is not rewritten (byte-identical)")
    func alreadyTrustedSkipsWrite() throws {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let file = configDir.appendingPathComponent(".claude.json")

        let wtPath = "/private/tmp/tbd-scratch-\(UUID().uuidString)"
        // Pre-write with the trust key already true + an unrelated top-level key
        // that a concurrent ambient Claude might own. If the seeder rewrote the
        // file it would re-serialize (sorted keys, pretty-print), changing bytes.
        let sentinel = "{\"concurrentWriterState\":\"do-not-clobber\","
            + "\"projects\":{\"\(wtPath)\":{\"hasTrustDialogAccepted\":true}}}"
        try sentinel.write(to: file, atomically: true, encoding: .utf8)

        let wt = makeWorktree(isScratch: true, path: wtPath)
        ClaudeTrustSeeder.ensureTrustedForScratch(
            worktree: wt, profileConfigDir: configDir.path)

        let after = try String(contentsOf: file, encoding: .utf8)
        #expect(after == sentinel)
    }
}
