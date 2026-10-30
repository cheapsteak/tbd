import Foundation
import TBDShared
import os

/// Writes the TBD-owned Claude Code plugin to a fixed Application Support
/// path. The plugin contains the `tbd` skill (CLI driver) and, while a
/// session-mod feature flag is on, the session mod (the plugin's hooks
/// module). Loaded into Claude sessions per-spawn via `--plugin-dir`, so all of
/// it is only available in TBD-spawned sessions.
///
/// Layout:
///   <applicationSupportRoot>/TBD/plugin/.claude-plugin/plugin.json
///   <applicationSupportRoot>/TBD/plugin/skills/tbd/SKILL.md
///   <applicationSupportRoot>/TBD/plugin/hooks/...      (session mod only)
///   <applicationSupportRoot>/TBD/plugin/types/...      (session mod only)
///
/// Every file comes from a compiled source of truth (`TBDSkillContent`,
/// `SessionModContent`). Claude Code reloads the plugin in every running
/// session on any write to this folder, so a file is written only when its
/// bytes differ: an unchanged daemon restart touches nothing. The writer
/// leaves alone what others put here, such as `.claude-plugin/types/` (laid
/// down by the engine at each load) and other folders under `skills/` —
/// except the skills named in `retiredSkills`, which it removes.
///
/// Design: docs/specs/2026-10-19-tbd-session-mod-design.md, "Presence".
struct PluginDirWriter {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "plugin")

    /// The manifest's `types` entry. Claude Code validates the session mod's
    /// `$.state` names against these declarations, so the manifest names them
    /// exactly while the mod is present.
    static let sessionModTypesPath = "./types/index.d.ts"

    /// The plugin-root folders that hold only session-mod files. The writer
    /// owns them outright: it removes any regular file in them that
    /// `SessionModContent` does not list, and removes both when every feature
    /// is off.
    static let sessionModDirectories = ["hooks", "types"]

    /// The file that tells Claude Code to load the hooks module. Written last
    /// and removed first, so the engine never loads a module whose files are
    /// half there.
    private static let hooksManifestPath = "hooks/hooks.json"

    /// Skill folders this plugin does not ship. The plugin folder outlives the
    /// build that wrote it, so one of these left on disk would go on loading in
    /// every TBD session; the writer removes each one it finds.
    static let retiredSkills = ["nightwatch"]

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
    /// `/Users/me/Library/Application Support/TBD/plugin`.
    /// Used by `writePlugin(sessionModFeatures:)` and by tests that inject a
    /// custom root.
    func pluginDirPath() -> String {
        applicationSupportRoot + "/TBD/plugin"
    }

    /// Static convenience for production callers (spawn builder), evaluated once
    /// at load time. Mirrors `ClaudeHookOverlay.overlayPath`. Tests that inject
    /// `applicationSupportRoot` still go through the instance method.
    static let pluginDirPath: String = defaultApplicationSupportRoot() + "/TBD/plugin"

    /// The plugin manifest's bytes. Deterministic (sorted keys), so an
    /// unchanged manifest compares equal to the one on disk. Names
    /// `sessionModTypesPath` only while the session mod is present.
    static func manifestData(sessionModEnabled: Bool) throws -> Data {
        var manifest: [String: String] = [
            "name": "tbd",
            "version": TBDConstants.version,
            "description": "TBD worktree + terminal driver"
        ]
        if sessionModEnabled {
            manifest["types"] = sessionModTypesPath
        }
        return try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// Bring the plugin folder in line with the compiled sources: the manifest,
    /// the bundled skill and, when `sessionModFeatures` is non-empty, the
    /// session mod; with it empty, the session mod's folders are removed.
    /// Removes any folder `retiredSkills` names. Creates parent directories as
    /// needed; each write is atomic.
    ///
    /// - Returns: the number of files written or removed. Zero means the
    ///   folder already matched and nothing on disk changed.
    @discardableResult
    func writePlugin(sessionModFeatures: [SessionModFeature]) throws -> Int {
        let pluginDir = pluginDirPath()
        var changed = 0

        changed += try writeIfChanged(
            Data(TBDSkillContent.body.utf8), to: pluginDir + "/skills/tbd/SKILL.md")

        // Counted as a change, so the plugin reloads once and running sessions
        // stop offering the skill.
        changed += removeRetiredSkills(pluginDir: pluginDir)

        let sessionModEnabled = !sessionModFeatures.isEmpty
        let manifest = try Self.manifestData(sessionModEnabled: sessionModEnabled)
        if sessionModEnabled {
            changed += try writeSessionMod(pluginDir: pluginDir, manifest: manifest)
        } else {
            changed += try removeSessionMod(pluginDir: pluginDir, manifest: manifest)
        }

        let modState = sessionModEnabled ? "present" : "absent"
        if changed > 0 {
            Self.logger.info(
                "Wrote TBD plugin at \(pluginDir, privacy: .public): \(changed, privacy: .public) file(s) changed, session mod \(modState, privacy: .public)")
        } else {
            Self.logger.debug(
                "TBD plugin at \(pluginDir, privacy: .public) already current, session mod \(modState, privacy: .public)")
        }
        return changed
    }

    /// Remove each `retiredSkills` folder present under `skills/`. Returns
    /// what `removeItemIfPresent` counted, so a removal is a change and an
    /// absent folder is not. A folder that cannot be removed is logged and
    /// left: it is no reason to stop bringing the rest of the plugin current.
    private func removeRetiredSkills(pluginDir: String) -> Int {
        var changed = 0
        for name in Self.retiredSkills {
            let path = pluginDir + "/skills/" + name
            do {
                changed += try removeItemIfPresent(path)
            } catch {
                Self.logger.error(
                    "Failed to remove retired skill folder \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return changed
    }

    /// Write the session mod. Ordered so each step leaves a plugin Claude Code
    /// can load: the declarations first, then the manifest that names them,
    /// then the module's files, then `hooks/hooks.json`, which loads them.
    /// Stale files go last, once nothing written here can still import them.
    private func writeSessionMod(pluginDir: String, manifest: Data) throws -> Int {
        let files = SessionModContent.files
        let hooksFiles = files.filter { $0.path.hasPrefix("hooks/") }
        let declarations = files.filter { !$0.path.hasPrefix("hooks/") }
        let module = hooksFiles.filter { $0.path != Self.hooksManifestPath }
        let loader = hooksFiles.filter { $0.path == Self.hooksManifestPath }
        var changed = 0

        for file in declarations {
            changed += try writeIfChanged(Data(file.body.utf8), to: pluginDir + "/" + file.path)
        }
        changed += try writeIfChanged(manifest, to: pluginDir + "/.claude-plugin/plugin.json")
        for file in module + loader {
            changed += try writeIfChanged(Data(file.body.utf8), to: pluginDir + "/" + file.path)
        }

        let listed = Set(files.map { $0.path })
        for directory in Self.sessionModDirectories {
            changed += try removeUnlistedFiles(in: directory, keeping: listed, pluginDir: pluginDir)
        }
        return changed
    }

    /// Remove the session mod, in the reverse order of `writeSessionMod`:
    /// `hooks/hooks.json` first so the engine stops loading the module, then
    /// the rest of `hooks/`, then the manifest's `types` entry, then `types/`.
    private func removeSessionMod(pluginDir: String, manifest: Data) throws -> Int {
        var changed = 0
        changed += try removeItemIfPresent(pluginDir + "/" + Self.hooksManifestPath)
        changed += try removeItemIfPresent(pluginDir + "/hooks")
        changed += try writeIfChanged(manifest, to: pluginDir + "/.claude-plugin/plugin.json")
        changed += try removeItemIfPresent(pluginDir + "/types")
        return changed
    }

    /// Write `data` to `path` only when the file's bytes differ. Returns 1 when
    /// it changed the file, 0 when it already matched.
    private func writeIfChanged(_ data: Data, to path: String) throws -> Int {
        let fm = FileManager.default
        guard fm.contents(atPath: path) != data else { return 0 }
        try fm.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return 1
    }

    /// Remove every regular file under `<pluginDir>/<directory>` whose
    /// plugin-relative path is not in `listed`. Returns how many it removed.
    private func removeUnlistedFiles(in directory: String, keeping listed: Set<String>, pluginDir: String) throws -> Int {
        let root = pluginDir + "/" + directory
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return 0 }
        var stale: [String] = []
        while let relative = enumerator.nextObject() as? String {
            guard enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
            if !listed.contains(directory + "/" + relative) {
                stale.append(root + "/" + relative)
            }
        }
        for path in stale {
            try FileManager.default.removeItem(atPath: path)
        }
        return stale.count
    }

    /// Remove the file or directory at `path` if anything is there, without
    /// following a symlink. Returns how many regular files went with it, and
    /// at least 1 when something was removed.
    private func removeItemIfPresent(_ path: String) throws -> Int {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: path) else { return 0 }
        var removedFiles = 0
        if attributes[.type] as? FileAttributeType == .typeDirectory,
           let enumerator = fm.enumerator(atPath: path) {
            while enumerator.nextObject() != nil {
                if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular {
                    removedFiles += 1
                }
            }
        }
        try fm.removeItem(atPath: path)
        return max(removedFiles, 1)
    }
}
