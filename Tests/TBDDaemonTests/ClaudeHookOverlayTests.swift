import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
import TBDShared

// Nested under TBDHomeSerialized: the per-session overlay tests mutate the
// process-global `TBD_HOME` env var to isolate the runtime dir. Nesting (rather
// than a bare per-suite `.serialized`) prevents cross-suite races with the other
// TBD_HOME-mutating suites. See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {
@Suite struct ClaudeHookOverlayTests {

    @Test func generateBodyHasExpectedShape() throws {
        let data = try ClaudeHookOverlay.generateBody()
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = parsed?["hooks"] as? [String: Any]
        #expect(hooks != nil)
        // SessionStart entry registers `tbd session-event` with a `*` matcher.
        let sessionStart = hooks?["SessionStart"] as? [[String: Any]]
        let matcher0 = sessionStart?.first?["matcher"] as? String
        #expect(matcher0 == "*")
        let inner = sessionStart?.first?["hooks"] as? [[String: Any]]
        let cmd0 = inner?.first?["command"] as? String
        #expect(cmd0?.contains("tbd session-event") == true)

        // Stop entry registers `tbd notify` as the first matcher and
        // `tbd hooks stop-rename-check` as a sibling matcher.
        let stop = hooks?["Stop"] as? [[String: Any]]
        #expect(stop?.count == 2)
        let stopHooks = stop?.first?["hooks"] as? [[String: Any]]
        let stopCmd = stopHooks?.first?["command"] as? String
        #expect(stopCmd?.contains("tbd notify") == true)
        let allStopCommands: [String] = (stop ?? []).flatMap { entry -> [String] in
            let inner = entry["hooks"] as? [[String: Any]] ?? []
            return inner.compactMap { $0["command"] as? String }
        }
        #expect(allStopCommands.contains(where: { $0.contains("stop-rename-check") }))
    }

    @Test func postToolUseBashHookBindsPRsAndKeepsAskUserQuestion() throws {
        let data = try ClaudeHookOverlay.generateBody()
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = parsed?["hooks"] as? [String: Any]
        let postToolUse = try #require(hooks?["PostToolUse"] as? [[String: Any]])

        let bash = postToolUse.first { $0["matcher"] as? String == "Bash" }
        #expect(bash != nil)
        let command = ((bash?["hooks"] as? [[String: Any]])?.first?["command"] as? String) ?? ""
        // The grep prefilter is what keeps every other Bash call from spawning
        // tbd. What it actually matches is asserted by
        // `prefilterAdmitsEveryBindableCreateForm` below, by running grep.
        #expect(command.contains("grep -qE '\(ClaudeHookOverlay.prBindGrepPattern)'"))
        #expect(command.contains("pr bind --from-hook"))
        // A hook must never fail the tool call it observes.
        #expect(command.contains("|| true"))

        // A short, explicit timeout. This is the first TBD hook matching a
        // universally-used tool, so Claude Code's 60 s default would let one
        // wedged socket stall every Bash call across the whole fleet.
        let timeout = (bash?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int
        #expect(timeout != nil)
        #expect((timeout ?? 60) <= 5)

        // The pre-existing AskUserQuestion entry must survive alongside it.
        #expect(postToolUse.contains { $0["matcher"] as? String == "AskUserQuestion" })
        #expect(postToolUse.count == 2)
    }

    /// Does the real `grep -qE` admit a payload carrying `command`?
    ///
    /// Runs the pattern the hook actually ships — read from the constant the
    /// shell command is built from, never re-typed — through the same
    /// `/usr/bin/grep -E` the hook runs under, with the payload on stdin. The
    /// shell passes the pattern single-quoted, so handing it to grep as one
    /// argv element is exactly what the hook does.
    ///
    /// The payload is the hook's own JSON envelope rather than a bare command
    /// string, because that is what `$(cat)` holds and JSON escaping is part of
    /// what the pattern has to survive.
    private func prefilterAdmits(_ command: String) throws -> Bool {
        let payload = try #require(
            String(data: try JSONSerialization.data(withJSONObject: [
                "tool_name": "Bash",
                "tool_input": ["command": command],
                "tool_response": ["stdout": "https://github.com/acme/acme-prod/pull/7\n"]
            ]), encoding: .utf8))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = ["-qE", ClaudeHookOverlay.prBindGrepPattern]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// The prefilter is a COST OPTIMIZATION, not a gate — so it may never
    /// produce a false negative for a command the tokenizer would accept.
    ///
    /// A `gh[[:space:]]+pr[[:space:]]+create` pattern shipped once and, because
    /// of the `&&` short-circuit, meant `tbd pr bind --from-hook` never ran for
    /// any flagged form: `PRBindingExtractor`'s tokenizer — built specifically
    /// to accept `-R` / `--repo` / `--hostname` — never saw them, and hook
    /// binding was defeated for exactly the case the feature exists for. The
    /// quoted forms below are the same bug through a different door: the
    /// tokenizer strips quotes when it splits words, so `gh "pr" create` is a
    /// real create, while the raw JSON keeps the quote (and JSON's backslash
    /// before a double one) between the two words.
    ///
    /// Each command is run past BOTH sides, so the two cannot drift: the
    /// tokenizer must accept it — otherwise the case proves nothing about the
    /// invariant — and the grep must then admit it.
    ///
    /// Tier 2: spawns a real, bounded `grep`. Asserting against a Swift regex
    /// engine instead would test a different matcher than the one that ships.
    @Test("the grep prefilter admits every form the tokenizer can bind")
    func prefilterAdmitsEveryBindableCreateForm() throws {
        let bindable = [
            "gh pr create --fill",
            "gh -R acme/acme-prod pr create",
            "gh --repo acme/acme-prod pr create --fill",
            "gh --hostname github.com pr create",
            "cd /tmp && gh pr create -t x",
            "/usr/local/bin/gh pr create",
            #"gh "pr" create"#,
            #"gh pr "create""#,
            #"gh "pr" "create""#,
            "gh 'pr' create",
            "gh pr 'create'",
            "gh 'pr' 'create'",
            "gh pr\tcreate",
            "gh pr    create",
            // The GitLab half. `glab`'s verb is `mr`, and every property above
            // has to hold for it too — the prefilter is one pattern serving
            // both forges.
            "glab mr create --fill",
            "glab -R acme/acme-prod mr create",
            "glab --repo acme/acme-prod mr create --fill",
            "cd /tmp && glab mr create -t x",
            "/usr/local/bin/glab mr create",
            #"glab "mr" create"#,
            #"glab mr "create""#,
            "glab 'mr' 'create'",
            "glab mr\tcreate",
            "glab  mr   create -t x"
        ]
        for command in bindable {
            #expect(PRBindingExtractor.isPRCreateCommand(command),
                    "the tokenizer must accept this form: \(command)")
            #expect(try prefilterAdmits(command),
                    "the prefilter silently dropped a bindable create: \(command)")
        }
        // Two tokenizer-accepted shapes are deliberately absent, and the
        // limitation is stated on `prBindGrepPattern` rather than hidden: a flag
        // word BETWEEN the two subcommand words (`gh pr --draft create`), which
        // no pattern can span without matching ordinary prose, and quoting
        // inside a word (`gh p"r" create`), which never spells `pr` in the
        // payload at all. Both fail closed to a lost fast path — branch matching
        // still binds the PR on the next poll.
    }

    /// The other half of the trade: the filter still filters, so the ordinary
    /// Bash call spawns no `tbd`. Over-match is deliberate and priced in — a
    /// payload merely mentioning "pr create" spawns one short-lived process
    /// that then declines to bind, which is far cheaper than a lost binding.
    @Test("the grep prefilter still rejects unrelated Bash calls")
    func prefilterRejectsUnrelatedCommands() throws {
        #expect(try prefilterAdmits("ls -la /tmp") == false)
        #expect(try prefilterAdmits("git status --short") == false)
        #expect(try prefilterAdmits("gh pr view 12 --json state") == false)
        #expect(try prefilterAdmits("glab mr view 12") == false)
        #expect(try prefilterAdmits("glab mr list") == false)
    }

    @Test func registersStopFailureNotifyHook() throws {
        let data = try ClaudeHookOverlay.generateBody()
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = parsed?["hooks"] as? [String: Any]

        let stopFailure = hooks?["StopFailure"] as? [[String: Any]]
        #expect(stopFailure?.count == 1)
        let inner = stopFailure?.first?["hooks"] as? [[String: Any]]
        let cmd = inner?.first?["command"] as? String
        // Delegates message construction to the subcommand, then pipes into notify.
        #expect(cmd?.contains("tbd hooks stop-failure") == true)
        #expect(cmd?.contains("tbd notify --type error") == true)
    }

    @Test func generateBodyWithoutFallbackModelsOmitsKey() throws {
        // Default (no fallback) — body has hooks, no fallbackModel key.
        let data = try ClaudeHookOverlay.generateBody()
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["hooks"] != nil)
        #expect(parsed?["fallbackModel"] == nil)
    }

    @Test func generateBodyWithNilFallbackModelsOmitsKey() throws {
        let data = try ClaudeHookOverlay.generateBody(fallbackModels: nil)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["hooks"] != nil)
        #expect(parsed?["fallbackModel"] == nil)
    }

    @Test func generateBodyWithEmptyFallbackModelsOmitsKey() throws {
        let data = try ClaudeHookOverlay.generateBody(fallbackModels: [])
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["hooks"] != nil)
        #expect(parsed?["fallbackModel"] == nil)
    }

    @Test func generateBodyWithFallbackModelsIncludesOrderedArrayAndKeepsHooks() throws {
        let models = ["claude-haiku-4-5-20251001", "claude-sonnet-4-5"]
        let data = try ClaudeHookOverlay.generateBody(fallbackModels: models)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // The fallbackModel array is present, in the exact supplied order.
        let fallback = parsed?["fallbackModel"] as? [String]
        #expect(fallback == models)

        // All the existing hooks are still present.
        let hooks = parsed?["hooks"] as? [String: Any]
        #expect(hooks != nil)
        #expect(hooks?["SessionStart"] != nil)
        #expect(hooks?["Stop"] != nil)
        #expect(hooks?["StopFailure"] != nil)
        #expect(hooks?["PreToolUse"] != nil)
        #expect(hooks?["PostToolUse"] != nil)
    }

    @Test func resolveOverlayPathWithoutFallbackReturnsGlobalPath() throws {
        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil,
            sessionKey: UUID().uuidString
        )
        #expect(path == ClaudeHookOverlay.overlayPath)
    }

    @Test func resolveOverlayPathWithEmptyFallbackReturnsGlobalPath() throws {
        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: [],
            sessionKey: UUID().uuidString
        )
        #expect(path == ClaudeHookOverlay.overlayPath)
    }

    @Test func resolveOverlayPathWithFallbackWritesPerSessionFileWithMergedBody() throws {
        // Isolate from the developer's ~/tbd.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-overlay-test-\(UUID().uuidString)")
        let priorTBDHome = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: tmp)
        }

        let key = UUID().uuidString
        let models = ["claude-haiku-4-5-20251001"]
        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: models,
            sessionKey: key
        )

        // Per-session path, NOT the global overlay path.
        #expect(path != ClaudeHookOverlay.overlayPath)
        #expect(path.contains(key))
        #expect(FileManager.default.fileExists(atPath: path))

        // The written file merges hooks + fallbackModel.
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["hooks"] != nil)
        #expect((parsed?["fallbackModel"] as? [String]) == models)
    }

    @Test func resolveOverlayPathIsIdempotentForSameSessionKey() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-overlay-test-\(UUID().uuidString)")
        let priorTBDHome = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: tmp)
        }

        let key = UUID().uuidString
        let p1 = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: ["a"], sessionKey: key
        )
        let p2 = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: ["a", "b"], sessionKey: key
        )
        // Same session key → same path; second write overwrites with new content.
        #expect(p1 == p2)
        let data = try Data(contentsOf: URL(fileURLWithPath: p2))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((parsed?["fallbackModel"] as? [String]) == ["a", "b"])
    }

    @Test func resolveOverlayPathFallsBackToGlobalWhenPerSessionWriteFails() throws {
        // Force the per-session write to fail: make the `runtime` dir an
        // existing *regular file* so createDirectory(runtime) throws.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-overlay-test-\(UUID().uuidString)")
        let priorTBDHome = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: tmp)
        }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Block the `runtime` subdir by occupying its path with a file.
        let runtimeAsFile = tmp.appendingPathComponent("runtime")
        try Data("not a dir".utf8).write(to: runtimeAsFile)

        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: ["claude-haiku-4-5-20251001"],
            sessionKey: UUID().uuidString
        )
        // Degrades to the global overlay path instead of throwing/aborting.
        #expect(path == ClaudeHookOverlay.overlayPath)
    }

    @Test func removePerSessionOverlayDeletesTheFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-overlay-test-\(UUID().uuidString)")
        let priorTBDHome = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: tmp)
        }

        let key = UUID().uuidString
        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: ["claude-haiku-4-5-20251001"],
            sessionKey: key
        )
        #expect(FileManager.default.fileExists(atPath: path))

        ClaudeHookOverlay.removePerSessionOverlay(sessionKey: key)
        #expect(!FileManager.default.fileExists(atPath: path))

        // Idempotent — removing again on a missing file is a no-op (no throw).
        ClaudeHookOverlay.removePerSessionOverlay(sessionKey: key)
    }

    @Test func pruneOrphanedSessionOverlaysKeepsLiveDeletesOrphans() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-overlay-test-\(UUID().uuidString)")
        let priorTBDHome = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: tmp)
        }

        let liveKey = UUID().uuidString
        let orphanKey = UUID().uuidString
        let livePath = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: ["a"], sessionKey: liveKey
        )
        let orphanPath = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: ["b"], sessionKey: orphanKey
        )
        // Also write the global overlay; the sweep must never touch it.
        ClaudeHookOverlay.writeOverlay()
        #expect(FileManager.default.fileExists(atPath: livePath))
        #expect(FileManager.default.fileExists(atPath: orphanPath))

        ClaudeHookOverlay.pruneOrphanedSessionOverlays(liveSessionKeys: [liveKey])

        // Live key survives; orphan is gone; global overlay untouched.
        #expect(FileManager.default.fileExists(atPath: livePath))
        #expect(!FileManager.default.fileExists(atPath: orphanPath))
        #expect(FileManager.default.fileExists(atPath: ClaudeHookOverlay.overlayPath))
    }

    @Test func pruneOrphanedSessionOverlaysWithEmptyLiveSetDeletesAll() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-overlay-test-\(UUID().uuidString)")
        let priorTBDHome = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: tmp)
        }

        let p1 = ClaudeHookOverlay.resolveOverlayPath(fallbackModels: ["a"], sessionKey: UUID().uuidString)
        let p2 = ClaudeHookOverlay.resolveOverlayPath(fallbackModels: ["b"], sessionKey: UUID().uuidString)
        ClaudeHookOverlay.writeOverlay()

        ClaudeHookOverlay.pruneOrphanedSessionOverlays(liveSessionKeys: [])

        #expect(!FileManager.default.fileExists(atPath: p1))
        #expect(!FileManager.default.fileExists(atPath: p2))
        // Global overlay is not a per-session file → never pruned.
        #expect(FileManager.default.fileExists(atPath: ClaudeHookOverlay.overlayPath))
    }

    // MARK: - Extra settings passthrough (claudeSettingsOverlay)

    @Test func generateBodyWithNilExtraSettingsIsHooksOnly() throws {
        // OFF branch: byte-identical to the hooks-only default. No extra keys.
        let baseline = try ClaudeHookOverlay.generateBody()
        let data = try ClaudeHookOverlay.generateBody(extraSettings: nil)
        #expect(data == baseline)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["hooks"] != nil)
        // Only `hooks` at top level (no fallbackModel, no fragment keys).
        #expect(parsed?.keys.sorted() == ["hooks"])
    }

    @Test func generateBodyWithExtraSettingsMergesAndKeepsHooks() throws {
        let extra: [String: Any] = ["skillOverrides": ["x": "off"]]
        let data = try ClaudeHookOverlay.generateBody(extraSettings: extra)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // Fragment landed…
        let overrides = parsed?["skillOverrides"] as? [String: Any]
        #expect(overrides?["x"] as? String == "off")
        // …and the original hooks dict is intact.
        #expect(parsed?["hooks"] != nil)
        #expect((parsed?["hooks"] as? [String: Any])?["SessionStart"] != nil)
    }

    @Test func generateBodyDeepMergesNestedObjectRatherThanReplacing() throws {
        // A fragment that shares a nested object key with hooks: the merge must
        // recurse and PRESERVE the sibling keys, not replace the whole `hooks`.
        let extra: [String: Any] = ["hooks": ["MyEvent": "value"]]
        let data = try ClaudeHookOverlay.generateBody(extraSettings: extra)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = parsed?["hooks"] as? [String: Any]
        // The added key is present…
        #expect(hooks?["MyEvent"] as? String == "value")
        // …and the pre-existing hook events survive (deep merge, not replace).
        #expect(hooks?["SessionStart"] != nil)
        #expect(hooks?["Stop"] != nil)
    }

    @Test func resolveOverlayPathWithNilExtraSettingsReturnsGlobalPath() throws {
        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil,
            sessionKey: UUID().uuidString,
            extraSettingsJSON: nil
        )
        #expect(path == ClaudeHookOverlay.overlayPath)
    }

    @Test func resolveOverlayPathWithEmptyExtraSettingsReturnsGlobalPath() throws {
        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil,
            sessionKey: UUID().uuidString,
            extraSettingsJSON: "   "
        )
        #expect(path == ClaudeHookOverlay.overlayPath)
    }

    @Test func resolveOverlayPathWithExtraSettingsWritesPerSessionMergedFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-overlay-test-\(UUID().uuidString)")
        let priorTBDHome = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: tmp)
        }

        let key = UUID().uuidString
        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil,
            sessionKey: key,
            extraSettingsJSON: #"{"skillOverrides":{"longeye-code-review":"off"}}"#
        )
        // Per-session file (not the shared global overlay).
        #expect(path != ClaudeHookOverlay.overlayPath)
        #expect(path.contains(ClaudeHookOverlay.perSessionPrefix))
        #expect(FileManager.default.fileExists(atPath: path))

        // On-disk overlay merges the fragment AND keeps hooks.
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["hooks"] != nil)
        let overrides = parsed?["skillOverrides"] as? [String: Any]
        #expect(overrides?["longeye-code-review"] as? String == "off")
    }

    @Test func resolveOverlayPathWithMalformedExtraSettingsDoesNotThrowAndKeepsHooks() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-overlay-test-\(UUID().uuidString)")
        let priorTBDHome = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: tmp)
        }

        // Malformed fragment: still forces a per-session write (non-empty
        // string), degrades to hooks-only, never throws/aborts.
        let key = UUID().uuidString
        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil,
            sessionKey: key,
            extraSettingsJSON: "{not json"
        )
        #expect(path.contains(ClaudeHookOverlay.perSessionPrefix))
        #expect(FileManager.default.fileExists(atPath: path))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // Fragment ignored; hooks preserved.
        #expect(parsed?["hooks"] != nil)
        #expect(parsed?["skillOverrides"] == nil)
    }

    // MARK: - Repo settings fragment (~/tbd/repos/<repoID>/claude-settings.json)

    @Test func repoSettingsFragmentReadsFileAndIsNilWhenMissing() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-overlay-test-\(UUID().uuidString)")
        let priorTBDHome = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: tmp)
        }

        // nil repoID (scratch spaces) and a missing file are both inert.
        #expect(ClaudeHookOverlay.repoSettingsFragment(repoID: nil) == nil)
        let repoID = UUID()
        #expect(ClaudeHookOverlay.repoSettingsFragment(repoID: repoID) == nil)

        // Once the file exists, the fragment is read fresh from disk.
        let path = TBDConstants.claudeSettingsOverlayPath(repoID: repoID)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let fragment = #"{"skillOverrides":{"x":"off"}}"#
        try fragment.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(ClaudeHookOverlay.repoSettingsFragment(repoID: repoID) == fragment)

        // Fresh at every call: an edit is picked up by the next read.
        let updated = #"{"skillOverrides":{"x":"on"}}"#
        try updated.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(ClaudeHookOverlay.repoSettingsFragment(repoID: repoID) == updated)
    }

    @Test func resolveOverlayPathWithNilRepoFragmentReturnsGlobalPath() throws {
        // OFF branch of the new gate: nil repo fragment + nil per-spawn
        // fragment behaves exactly as before (shared global overlay).
        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil,
            sessionKey: UUID().uuidString,
            repoSettingsJSON: nil,
            extraSettingsJSON: nil
        )
        #expect(path == ClaudeHookOverlay.overlayPath)
    }

    @Test func resolveOverlayPathWithNilRepoFragmentAndPerSpawnMatchesPerSpawnOnly() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-overlay-test-\(UUID().uuidString)")
        let priorTBDHome = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: tmp)
        }

        // OFF branch with a per-spawn fragment: nil repo fragment must not
        // change the pre-existing per-spawn behavior.
        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil,
            sessionKey: UUID().uuidString,
            repoSettingsJSON: nil,
            extraSettingsJSON: #"{"skillOverrides":{"x":"off"}}"#
        )
        #expect(path.contains(ClaudeHookOverlay.perSessionPrefix))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["hooks"] != nil)
        #expect(((parsed?["skillOverrides"] as? [String: Any])?["x"] as? String) == "off")
    }

    @Test func resolveOverlayPathWithRepoFragmentAloneWritesPerSessionMergedFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-overlay-test-\(UUID().uuidString)")
        let priorTBDHome = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: tmp)
        }

        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil,
            sessionKey: UUID().uuidString,
            repoSettingsJSON: #"{"skillOverrides":{"heavy-skill":"off"}}"#
        )
        #expect(path != ClaudeHookOverlay.overlayPath)
        #expect(path.contains(ClaudeHookOverlay.perSessionPrefix))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["hooks"] != nil)
        let overrides = parsed?["skillOverrides"] as? [String: Any]
        #expect(overrides?["heavy-skill"] as? String == "off")
    }

    @Test func repoAndPerSpawnFragmentsMergeWithPerSpawnWinningCollisions() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-overlay-test-\(UUID().uuidString)")
        let priorTBDHome = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: tmp)
        }

        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil,
            sessionKey: UUID().uuidString,
            repoSettingsJSON: #"{"skillOverrides":{"shared":"repo","repoOnly":"on"},"repoKey":1}"#,
            extraSettingsJSON: #"{"skillOverrides":{"shared":"spawn"},"spawnKey":2}"#
        )
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // Non-colliding keys from BOTH fragments are unioned…
        #expect(parsed?["repoKey"] as? Int == 1)
        #expect(parsed?["spawnKey"] as? Int == 2)
        let overrides = parsed?["skillOverrides"] as? [String: Any]
        #expect(overrides?["repoOnly"] as? String == "on")
        // …the collision goes to the per-spawn fragment…
        #expect(overrides?["shared"] as? String == "spawn")
        // …and hooks survive.
        #expect(parsed?["hooks"] != nil)
    }

    @Test func malformedRepoFragmentDegradesButValidPerSpawnStillApplies() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-overlay-test-\(UUID().uuidString)")
        let priorTBDHome = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: tmp)
        }

        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil,
            sessionKey: UUID().uuidString,
            repoSettingsJSON: "{not json",
            extraSettingsJSON: #"{"spawnKey":"still-applies"}"#
        )
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["hooks"] != nil)
        #expect(parsed?["spawnKey"] as? String == "still-applies")
    }

    @Test func malformedPerSpawnFragmentDegradesButValidRepoStillApplies() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-overlay-test-\(UUID().uuidString)")
        let priorTBDHome = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: tmp)
        }

        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil,
            sessionKey: UUID().uuidString,
            repoSettingsJSON: #"{"repoKey":"still-applies"}"#,
            extraSettingsJSON: "{not json"
        )
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["hooks"] != nil)
        #expect(parsed?["repoKey"] as? String == "still-applies")
    }

    @Test func bothFragmentsMalformedDegradesToHooksOnlyPerSessionFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-overlay-test-\(UUID().uuidString)")
        let priorTBDHome = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(priorTBDHome)
            try? FileManager.default.removeItem(at: tmp)
        }

        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil,
            sessionKey: UUID().uuidString,
            repoSettingsJSON: "{nope",
            extraSettingsJSON: "[1,2]"
        )
        // Still per-session (non-empty fragments force it), hooks-only body.
        #expect(path.contains(ClaudeHookOverlay.perSessionPrefix))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?.keys.sorted() == ["hooks"])
    }

    // MARK: - Notification hook

    /// Renders the composed overlay body's `hooks` dict as one sorted line per
    /// registered command: `event|matcher|command`, with `matcher` rendered as
    /// `<none>` when the entry omits the key entirely. Comparing the whole
    /// rendering — rather than probing one field — is what makes a test that
    /// adds an event also prove the others are untouched.
    private func renderHookEntries(_ data: Data) throws -> [String] {
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(parsed["hooks"] as? [String: Any])
        var lines: [String] = []
        for (event, value) in hooks {
            let entries = try #require(value as? [[String: Any]])
            for entry in entries {
                let matcher = entry["matcher"] as? String ?? "<none>"
                let inner = try #require(entry["hooks"] as? [[String: Any]])
                for hook in inner {
                    let command = try #require(hook["command"] as? String)
                    lines.append("\(event)|\(matcher)|\(command)")
                }
            }
        }
        return lines.sorted()
    }

    @Test func registersNotificationHookWithoutAMatcherAndLeavesTheOthersUntouched() throws {
        let rendered = try renderHookEntries(try ClaudeHookOverlay.generateBody())
        let expected = [
            // The new entry: no matcher key at all, so Claude Code runs it for
            // EVERY notification type and the hook decides nothing.
            "Notification|<none>|\(ClaudeHookOverlay.notificationCommand)",
            "PostToolUse|AskUserQuestion|\(ClaudeHookOverlay.askUserQuestionPostCommand)",
            "PostToolUse|Bash|\(ClaudeHookOverlay.prBindCommand)",
            "PreToolUse|AskUserQuestion|\(ClaudeHookOverlay.askUserQuestionPreCommand)",
            "SessionEnd|<none>|\(ClaudeHookOverlay.sessionEndCommand)",
            "SessionStart|*|\(ClaudeHookOverlay.sessionStartCommand)",
            "Stop|<none>|\(ClaudeHookOverlay.stopCommand)",
            "Stop|<none>|\(ClaudeHookOverlay.stopRenameCheckCommand)",
            "StopFailure|<none>|\(ClaudeHookOverlay.stopFailureCommand)",
            "UserPromptSubmit|<none>|\(ClaudeHookOverlay.workingCommand)"
        ].sorted()
        #expect(rendered == expected)
    }

    @Test func sessionEndCommandClearsTheClaimAndNeverFails() throws {
        let rendered = try renderHookEntries(try ClaudeHookOverlay.generateBody())
        let entry = try #require(rendered.first { $0.hasPrefix("SessionEnd|") })
        #expect(entry.contains("tbd session-end"))
        #expect(entry.hasSuffix("2>/dev/null || true"))
    }

    /// Claude Code runs SessionEnd callbacks inside a 1.5s shutdown budget, so
    /// this entry carries an explicit short timeout rather than the 60s default.
    @Test func sessionEndCarriesAnExplicitShortTimeout() throws {
        let body = try ClaudeHookOverlay.generateBody()
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let hooks = (parsed?["hooks"] as? [String: Any])?["SessionEnd"] as? [[String: Any]]
        let inner = try #require((hooks?.first?["hooks"] as? [[String: Any]])?.first)
        #expect((inner["timeout"] as? Int) == ClaudeHookOverlay.sessionEndTimeoutSeconds)
        #expect(ClaudeHookOverlay.sessionEndTimeoutSeconds <= 2)
    }

    @Test func notificationCommandInvokesTheHookBridgeAndNeverFails() throws {
        let rendered = try renderHookEntries(try ClaudeHookOverlay.generateBody())
        let notification = try #require(rendered.first { $0.hasPrefix("Notification|") })
        #expect(notification.contains("tbd hooks notification"))
        // Silent + never-fail, like every other entry: a hook must not wedge
        // the agent when `tbd` is missing or the daemon is down.
        #expect(notification.hasSuffix("2>/dev/null || true"))
    }

    @Test func notificationHookSurvivesFragmentMergeAndFallbackModels() throws {
        // The new event must ride the same merge paths as the rest, not just
        // the default body.
        let data = try ClaudeHookOverlay.generateBody(
            fallbackModels: ["claude-haiku-4-5-20251001"],
            extraSettings: ["skillOverrides": ["x": "off"]])
        let rendered = try renderHookEntries(data)
        #expect(rendered.contains("Notification|<none>|\(ClaudeHookOverlay.notificationCommand)"))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((parsed?["fallbackModel"] as? [String]) == ["claude-haiku-4-5-20251001"])
    }

    @Test func roundtripsAsValidJSON() throws {
        let data = try ClaudeHookOverlay.generateBody()
        // Must round-trip — a malformed overlay file would crash Claude
        // Code's settings loader. JSONSerialization throws on invalid JSON.
        _ = try JSONSerialization.jsonObject(with: data, options: [])
    }
}
}
