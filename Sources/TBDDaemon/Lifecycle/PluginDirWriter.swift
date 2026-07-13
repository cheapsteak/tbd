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
        self.applicationSupportRoot = applicationSupportRoot ?? Self.defaultApplicationSupportRoot()
    }

    /// Resolve `~/Library/Application Support` (or the home-dir fallback if
    /// the system query returns nothing). Shared by `init` and the static
    /// `pluginDirPath` so they can't drift.
    private static func defaultApplicationSupportRoot() -> String {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        return urls.first?.path
            ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support")
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
    static let pluginDirPath: String = defaultApplicationSupportRoot() + "/TBD/plugin"

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

        // Bundled `nightwatch` skill (quota-lean fleet babysitter). Ships its
        // SKILL.md + scripts/tick.py + config/* so it works against a TBD fleet
        // out of the box. Dormant until its description matches a babysitting task.
        try writeNightwatch(pluginDir: pluginDir)

        Self.logger.info("Wrote TBD plugin at \(pluginDir, privacy: .public)")
    }

    /// Install the `nightwatch` skill into the plugin's skills dir. `tick.py`
    /// is written with the executable bit so cron/launchd can run it directly.
    private func writeNightwatch(pluginDir: String) throws {
        let fm = FileManager.default
        let root = pluginDir + "/skills/nightwatch"
        let scripts = root + "/scripts"
        let config = root + "/config"
        try fm.createDirectory(atPath: scripts, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: config, withIntermediateDirectories: true)

        try NightwatchSkillContent.skillMd.write(toFile: root + "/SKILL.md", atomically: true, encoding: .utf8)
        try NightwatchSkillContent.prioritiesTxt.write(toFile: config + "/priorities.txt", atomically: true, encoding: .utf8)
        try NightwatchSkillContent.safeWedgesTxt.write(toFile: config + "/safe_wedges.txt", atomically: true, encoding: .utf8)
        try NightwatchSkillContent.dontTouchTxt.write(toFile: config + "/dont_touch.txt", atomically: true, encoding: .utf8)

        // Scripts ship executable. NOTE: the scheduler (scheduler.sh / tick-cron.sh)
        // is installed but NEVER auto-loaded — durable scheduling is opt-in via
        // `scheduler.sh enable`.
        for (name, body) in [("tick.py", NightwatchSkillContent.tickPy),
                             ("wake.py", NightwatchSkillContent.wakePy),
                             ("judge.py", NightwatchSkillContent.judgePy),
                             ("tick-cron.sh", NightwatchSkillContent.tickCronSh),
                             ("scheduler.sh", NightwatchSkillContent.schedulerSh)] {
            let path = scripts + "/" + name
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }
}
