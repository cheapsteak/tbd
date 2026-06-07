import Foundation
import Testing
@testable import TBDDaemonLib

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
        setenv("TBD_HOME", tmp.path, 1)
        defer {
            unsetenv("TBD_HOME")
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
        setenv("TBD_HOME", tmp.path, 1)
        defer {
            unsetenv("TBD_HOME")
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
        setenv("TBD_HOME", tmp.path, 1)
        defer {
            unsetenv("TBD_HOME")
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
        setenv("TBD_HOME", tmp.path, 1)
        defer {
            unsetenv("TBD_HOME")
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
        setenv("TBD_HOME", tmp.path, 1)
        defer {
            unsetenv("TBD_HOME")
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
        setenv("TBD_HOME", tmp.path, 1)
        defer {
            unsetenv("TBD_HOME")
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

    @Test func roundtripsAsValidJSON() throws {
        let data = try ClaudeHookOverlay.generateBody()
        // Must round-trip — a malformed overlay file would crash Claude
        // Code's settings loader. JSONSerialization throws on invalid JSON.
        _ = try JSONSerialization.jsonObject(with: data, options: [])
    }
}
}
