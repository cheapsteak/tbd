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

    private func makeWorktree(
        isScratch: Bool, path: String, prNumber: Int? = nil, foreignHead: Bool = false
    ) -> Worktree {
        Worktree(
            repoID: isScratch ? nil : UUID(),
            name: "wt",
            displayName: "wt",
            branch: "main",
            path: path,
            tmuxServer: "srv",
            prNumber: prNumber,
            foreignHead: foreignHead
        )
    }

    private func readClaudeJSON(_ configDir: URL) -> [String: Any]? {
        let file = configDir.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    /// True when `.claude.json` in `configDir` marks `path` as trusted.
    private func isTrusted(_ path: String, in configDir: URL) -> Bool {
        let projects = readClaudeJSON(configDir)?["projects"] as? [String: Any]
        let entry = projects?[path] as? [String: Any]
        return entry?["hasTrustDialogAccepted"] as? Bool == true
    }

    // MARK: - Scratch tier: seeds regardless of the toggle

    @Test("scratch worktree seeds hasTrustDialogAccepted=true")
    func gateOnSeedsTrust() async {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        let wtPath = "/private/tmp/tbd-scratch-\(UUID().uuidString)"
        let wt = makeWorktree(isScratch: true, path: wtPath)

        await ClaudeTrustSeeder.ensureTrusted(
            worktree: wt, autoTrustNonScratch: true, profileConfigDir: configDir.path)

        #expect(isTrusted(wtPath, in: configDir))
    }

    @Test("toggle OFF: scratch worktree is still seeded (unconditional tier)")
    func toggleOffStillSeedsScratch() async {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        let wtPath = "/private/tmp/tbd-scratch-\(UUID().uuidString)"
        let wt = makeWorktree(isScratch: true, path: wtPath)

        await ClaudeTrustSeeder.ensureTrusted(
            worktree: wt, autoTrustNonScratch: false, profileConfigDir: configDir.path)

        #expect(isTrusted(wtPath, in: configDir),
                "scratch spaces are TBD-owned empty dirs — the toggle must not gate them")
    }

    // MARK: - Non-scratch tier: both branches of the toggle

    @Test("toggle ON: non-scratch TBD-created worktree is seeded")
    func toggleOnSeedsNonScratch() async {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        let wtPath = "/private/tmp/tbd-real-\(UUID().uuidString)"
        let wt = makeWorktree(isScratch: false, path: wtPath)

        await ClaudeTrustSeeder.ensureTrusted(
            worktree: wt, autoTrustNonScratch: true, profileConfigDir: configDir.path)

        #expect(isTrusted(wtPath, in: configDir),
                "the spawn-stall fix: TBD created this worktree, so pre-seed the known answer")
    }

    @Test("toggle OFF: non-scratch worktree writes nothing")
    func toggleOffWritesNothingForNonScratch() async {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        let wtPath = "/private/tmp/tbd-real-\(UUID().uuidString)"
        let wt = makeWorktree(isScratch: false, path: wtPath)

        await ClaudeTrustSeeder.ensureTrusted(
            worktree: wt, autoTrustNonScratch: false, profileConfigDir: configDir.path)

        let file = configDir.appendingPathComponent(".claude.json")
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    @Test("toggle OFF leaves an existing .claude.json untouched for non-scratch")
    func toggleOffLeavesExistingConfigUntouched() async throws {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let file = configDir.appendingPathComponent(".claude.json")
        let sentinel = "{\"hasCompletedOnboarding\":true,\"projects\":{}}"
        try sentinel.write(to: file, atomically: true, encoding: .utf8)

        let wtPath = "/private/tmp/tbd-real-\(UUID().uuidString)"
        let wt = makeWorktree(isScratch: false, path: wtPath)
        await ClaudeTrustSeeder.ensureTrusted(
            worktree: wt, autoTrustNonScratch: false, profileConfigDir: configDir.path)

        #expect(try String(contentsOf: file, encoding: .utf8) == sentinel)
    }

    // MARK: - Foreign-head tier: contents TBD cannot vouch for

    @Test("toggle ON: foreign-head worktree is NOT seeded")
    func foreignHeadIsNotSeededWithToggleOn() async {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        let wtPath = "/private/tmp/tbd-fork-pr-\(UUID().uuidString)"
        let wt = makeWorktree(isScratch: false, path: wtPath, prNumber: 42, foreignHead: true)

        await ClaudeTrustSeeder.ensureTrusted(
            worktree: wt, autoTrustNonScratch: true, profileConfigDir: configDir.path)

        #expect(isTrusted(wtPath, in: configDir) == false,
                "a fork contributor authored these contents — the dialog must render")
        let file = configDir.appendingPathComponent(".claude.json")
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    @Test("toggle OFF: foreign-head worktree is NOT seeded either")
    func foreignHeadIsNotSeededWithToggleOff() async {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        let wtPath = "/private/tmp/tbd-fork-pr-\(UUID().uuidString)"
        let wt = makeWorktree(isScratch: false, path: wtPath, prNumber: 42, foreignHead: true)

        await ClaudeTrustSeeder.ensureTrusted(
            worktree: wt, autoTrustNonScratch: false, profileConfigDir: configDir.path)

        #expect(isTrusted(wtPath, in: configDir) == false)
    }

    /// Over-exclusion guard: a *decorated* same-repo PR row carries `prNumber`
    /// for status tracking but checks out an ordinary local branch, so
    /// `foreignHead` stays false and it must still seed. Gating on `prNumber`
    /// instead of `foreignHead` would fail the originally reported bug.
    @Test("toggle ON: same-repo PR worktree (prNumber set, not foreign) IS seeded")
    func decoratedPRWorktreeIsStillSeeded() async {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        let wtPath = "/private/tmp/tbd-same-repo-pr-\(UUID().uuidString)"
        let wt = makeWorktree(isScratch: false, path: wtPath, prNumber: 9, foreignHead: false)

        await ClaudeTrustSeeder.ensureTrusted(
            worktree: wt, autoTrustNonScratch: true, profileConfigDir: configDir.path)

        #expect(isTrusted(wtPath, in: configDir),
                "a PR-review worktree on a same-repo branch is the exact case the seeder exists for")
    }

    /// The scratch tier is absolute: a scratch space has no git contents that
    /// could be foreign, so even a (nonsensical) `foreignHead` stamp must not
    /// reintroduce the guaranteed first-spawn stall.
    @Test("scratch + foreignHead is still seeded (scratch tier is unconditional)")
    func scratchIgnoresForeignHead() async {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        let wtPath = "/private/tmp/tbd-scratch-\(UUID().uuidString)"
        let wt = makeWorktree(isScratch: true, path: wtPath, foreignHead: true)

        await ClaudeTrustSeeder.ensureTrusted(
            worktree: wt, autoTrustNonScratch: false, profileConfigDir: configDir.path)

        #expect(isTrusted(wtPath, in: configDir))
    }

    // MARK: - Preserve top-level keys

    @Test("preserves unrelated top-level keys and other project entries")
    func preservesTopLevelKeys() async throws {
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
        await ClaudeTrustSeeder.ensureTrusted(
            worktree: wt, autoTrustNonScratch: true, profileConfigDir: configDir.path)

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
    func preservesIntraProjectKeys() async throws {
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
        await ClaudeTrustSeeder.ensureTrusted(
            worktree: wt, autoTrustNonScratch: true, profileConfigDir: configDir.path)

        let json = readClaudeJSON(configDir)
        let projects = json?["projects"] as? [String: Any]
        let entry = projects?[wtPath] as? [String: Any]
        #expect(entry?["existingKey"] as? String == "survive")
        #expect(entry?["hasTrustDialogAccepted"] as? Bool == true)
    }

    // MARK: - Idempotent

    @Test("running twice produces identical valid JSON")
    func idempotent() async throws {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        let wtPath = "/private/tmp/tbd-scratch-\(UUID().uuidString)"
        let wt = makeWorktree(isScratch: true, path: wtPath)

        await ClaudeTrustSeeder.ensureTrusted(
            worktree: wt, autoTrustNonScratch: true, profileConfigDir: configDir.path)
        let firstData = try Data(contentsOf: configDir.appendingPathComponent(".claude.json"))

        await ClaudeTrustSeeder.ensureTrusted(
            worktree: wt, autoTrustNonScratch: true, profileConfigDir: configDir.path)
        let secondData = try Data(contentsOf: configDir.appendingPathComponent(".claude.json"))

        #expect(firstData == secondData)
        // And still valid + correct.
        let json = readClaudeJSON(configDir)
        let entry = (json?["projects"] as? [String: Any])?[wtPath] as? [String: Any]
        #expect(entry?["hasTrustDialogAccepted"] as? Bool == true)
    }

    // MARK: - Malformed JSON

    @Test("malformed .claude.json is left untouched and no throw")
    func malformedJSONLeftUntouched() async throws {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let file = configDir.appendingPathComponent(".claude.json")

        let garbage = "{ this is not valid json ]["
        try garbage.write(to: file, atomically: true, encoding: .utf8)

        let wtPath = "/private/tmp/tbd-scratch-\(UUID().uuidString)"
        let wt = makeWorktree(isScratch: true, path: wtPath)
        await ClaudeTrustSeeder.ensureTrusted(
            worktree: wt, autoTrustNonScratch: true, profileConfigDir: configDir.path)

        let after = try String(contentsOf: file, encoding: .utf8)
        #expect(after == garbage)
    }

    // MARK: - Config-dir fallback branches

    @Test("nil profileConfigDir falls back to environment CLAUDE_CONFIG_DIR")
    func fallsBackToEnvConfigDir() async {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        let wtPath = "/private/tmp/tbd-scratch-\(UUID().uuidString)"
        let wt = makeWorktree(isScratch: true, path: wtPath)

        // homeDirectory points somewhere else to prove CLAUDE_CONFIG_DIR wins.
        let homeDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: homeDir) }

        await ClaudeTrustSeeder.ensureTrusted(
            worktree: wt,
            autoTrustNonScratch: true,
            profileConfigDir: nil,
            homeDirectory: homeDir.path,
            environment: ["CLAUDE_CONFIG_DIR": configDir.path])

        // Seeded into the env dir, NOT the home dir.
        let entry = (readClaudeJSON(configDir)?["projects"] as? [String: Any])?[wtPath] as? [String: Any]
        #expect(entry?["hasTrustDialogAccepted"] as? Bool == true)
        #expect(FileManager.default.fileExists(atPath: homeDir.appendingPathComponent(".claude.json").path) == false)
    }

    @Test("nil profileConfigDir + no CLAUDE_CONFIG_DIR falls back to homeDirectory")
    func fallsBackToHomeDirectory() async {
        // Use a temp dir as homeDirectory so the real ~/.claude.json is never touched.
        let homeDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: homeDir) }
        let wtPath = "/private/tmp/tbd-scratch-\(UUID().uuidString)"
        let wt = makeWorktree(isScratch: true, path: wtPath)

        await ClaudeTrustSeeder.ensureTrusted(
            worktree: wt,
            autoTrustNonScratch: true,
            profileConfigDir: nil,
            homeDirectory: homeDir.path,
            environment: [:])

        let entry = (readClaudeJSON(homeDir)?["projects"] as? [String: Any])?[wtPath] as? [String: Any]
        #expect(entry?["hasTrustDialogAccepted"] as? Bool == true)
    }

    // MARK: - Skip-if-already-trusted (no clobbering a concurrent writer)

    @Test("already-trusted key: file is not rewritten (byte-identical)")
    func alreadyTrustedSkipsWrite() async throws {
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
        await ClaudeTrustSeeder.ensureTrusted(
            worktree: wt, autoTrustNonScratch: true, profileConfigDir: configDir.path)

        let after = try String(contentsOf: file, encoding: .utf8)
        #expect(after == sentinel)
    }

    // MARK: - Concurrent seeds (TBD racing itself)

    /// Tier 2 (real concurrency, real filesystem).
    ///
    /// `.claude.json` is ONE shared file that every worktree targets whenever no
    /// per-profile config dir resolves, and the six seed call sites fire from
    /// unrelated `RepoSerializer` lanes — wake / revive / terminal-create are not
    /// serialized against creates at all. Without `ClaudeTrustSeeder.writer`, two
    /// seeds read the same base and the loser's key vanishes under the winner's
    /// atomic rename, leaving that worktree stalled on the trust dialog: exactly
    /// the machine-invisible failure the seeder exists to prevent, and most likely
    /// right after ship when every existing worktree is simultaneously unseeded.
    ///
    /// This asserts the serialization, not just the happy path — it goes red if
    /// the critical section stops being serialized.
    @Test("concurrent seeds into one .claude.json: every key survives")
    func concurrentSeedsAllSurvive() async throws {
        let configDir = tempConfigDir()
        defer { try? FileManager.default.removeItem(at: configDir) }
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let file = configDir.appendingPathComponent(".claude.json")

        // Pre-existing payload with some bulk, so the read → parse → merge →
        // serialize → rename window is wide enough for an unserialized version to
        // lose the race. A real `~/.claude.json` carries conversation history and
        // is far larger than this.
        let filler = String(repeating: "x", count: 2048)
        let existing: [String: Any] = [
            "hasCompletedOnboarding": true,
            "history": (0..<150).map { ["display": "\(filler)-\($0)"] },
            "projects": [String: Any](),
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: file)

        let worktrees = (0..<40).map { i in
            makeWorktree(isScratch: false, path: "/private/tmp/tbd-concurrent-\(i)-\(UUID().uuidString)")
        }
        let configDirPath = configDir.path

        await withTaskGroup(of: Void.self) { group in
            for wt in worktrees {
                group.addTask {
                    await ClaudeTrustSeeder.ensureTrusted(
                        worktree: wt, autoTrustNonScratch: true, profileConfigDir: configDirPath)
                }
            }
        }

        let missing = worktrees.map(\.path).filter { !isTrusted($0, in: configDir) }
        #expect(
            missing.isEmpty,
            // Each lost key is a worktree that will stall on the trust dialog.
            "\(missing.count) of \(worktrees.count) seeds were lost to a concurrent rename")
        // The unrelated top-level state a merge must never drop is still there.
        let json = readClaudeJSON(configDir)
        #expect(json?["hasCompletedOnboarding"] as? Bool == true)
        #expect((json?["history"] as? [Any])?.count == 150)
    }
}
