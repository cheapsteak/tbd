import Foundation
import TBDShared
import os

/// Writes the TBD-owned Claude Code plugin to a fixed Application Support
/// path. The plugin contains the `tbd` skill (CLI driver). Loaded into
/// Claude sessions per-spawn via `--plugin-dir`, so the skill is only
/// available in TBD-spawned sessions.
///
/// Layout:
///   <applicationSupportRoot>/TBD/plugin/.claude-plugin/plugin.json
///   <applicationSupportRoot>/TBD/plugin/skills/tbd/SKILL.md
///
/// Both files are derived from `TBDSkillContent.body` (single source of
/// truth). Atomic writes; idempotent.
struct PluginDirWriter {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "plugin")

    let applicationSupportRoot: String

    init(applicationSupportRoot: String? = nil) {
        if let explicit = applicationSupportRoot {
            self.applicationSupportRoot = explicit
        } else {
            let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            self.applicationSupportRoot = urls.first?.path
                ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support")
        }
    }

    /// Absolute path to the plugin directory, e.g.
    /// `/Users/chang/Library/Application Support/TBD/plugin`.
    /// Used by `writePlugin()` and by tests that inject a custom root.
    func pluginDirPath() -> String {
        applicationSupportRoot + "/TBD/plugin"
    }

    /// Static convenience for production callers (spawn builder), evaluated once
    /// at load time. Mirrors `ClaudeHookOverlay.overlayPath`. Tests that inject
    /// `applicationSupportRoot` still go through the instance method.
    static let pluginDirPath: String = {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let root = urls.first?.path
            ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support")
        return root + "/TBD/plugin"
    }()

    /// Write the plugin manifest and bundled skill body. Creates parent
    /// directories as needed. Atomic.
    func writePlugin() throws {
        let pluginDir = pluginDirPath()
        let manifestDir = pluginDir + "/.claude-plugin"
        let skillDir = pluginDir + "/skills/tbd"
        try FileManager.default.createDirectory(atPath: manifestDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: skillDir, withIntermediateDirectories: true)

        // Manifest
        let manifest: [String: String] = [
            "name": "tbd",
            "version": TBDConstants.version,
            "description": "TBD worktree + terminal driver"
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(
            to: URL(fileURLWithPath: manifestDir + "/plugin.json"),
            options: .atomic
        )

        // Skill body
        try TBDSkillContent.body.write(
            toFile: skillDir + "/SKILL.md",
            atomically: true,
            encoding: .utf8
        )

        Self.logger.info("Wrote TBD plugin at \(pluginDir, privacy: .public)")
    }
}
