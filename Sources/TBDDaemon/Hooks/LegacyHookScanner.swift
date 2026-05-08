import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "legacy-hook-scanner")

/// Detects and (optionally) removes legacy TBD-installed hook entries from
/// `~/.claude/settings.json` and per-repo `<repo>/.claude/settings.json`.
///
/// "Legacy" means: any hook entry whose `command` string contains
/// `"tbd notify"` or `"tbd session-event"`. We can't tell from the
/// settings.json alone whether the entry was installed by `tbd setup-hooks`,
/// hand-edited by the user, or sourced elsewhere — but the substring is a
/// good-enough signal for surfacing a one-time migration prompt, and the
/// removal path only ever runs when the user clicks "Remove" in the dialog.
///
/// All removals run through `SettingsJSONSafety` (pristine backup, atomic
/// write, roundtrip validation).
public enum LegacyHookScanner {

    /// Substrings that identify a TBD-installed hook entry.
    static let markerSubstrings: [String] = ["tbd notify", "tbd session-event"]

    /// Walk a parsed settings dict and return every hook entry whose
    /// `command` contains one of the marker substrings.
    public static func detectEntries(in settings: [String: Any]) -> [LegacyHookEntry] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        var found: [LegacyHookEntry] = []
        for (event, raw) in hooks {
            guard let matchers = raw as? [[String: Any]] else { continue }
            for matcher in matchers {
                if let inner = matcher["hooks"] as? [[String: Any]] {
                    for entry in inner {
                        if let cmd = entry["command"] as? String,
                           markerSubstrings.contains(where: { cmd.contains($0) }) {
                            found.append(LegacyHookEntry(event: event, command: cmd))
                        }
                    }
                } else if let cmd = matcher["command"] as? String,
                          markerSubstrings.contains(where: { cmd.contains($0) }) {
                    // Older bare-format entries.
                    found.append(LegacyHookEntry(event: event, command: cmd))
                }
            }
        }
        return found
    }

    /// Read a settings.json from disk and return detected entries, or [] if
    /// the file is missing/unreadable/non-JSON.
    public static func detectEntries(at path: String) -> [LegacyHookEntry] {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        return detectEntries(in: dict)
    }

    /// Mutate a parsed settings dict in place, removing every hook entry
    /// matching our marker substrings. Returns the number of entries
    /// removed (count of `entry` objects, not matcher groups).
    @discardableResult
    public static func stripEntries(from settings: inout [String: Any]) -> Int {
        guard var hooks = settings["hooks"] as? [String: Any] else { return 0 }
        var removed = 0
        for (event, raw) in hooks {
            guard let matchers = raw as? [[String: Any]] else { continue }
            var newMatchers: [[String: Any]] = []
            for matcher in matchers {
                if let inner = matcher["hooks"] as? [[String: Any]] {
                    let kept = inner.filter { entry in
                        guard let cmd = entry["command"] as? String else { return true }
                        let drop = markerSubstrings.contains(where: { cmd.contains($0) })
                        if drop { removed += 1 }
                        return !drop
                    }
                    if !kept.isEmpty {
                        var copy = matcher
                        copy["hooks"] = kept
                        newMatchers.append(copy)
                    }
                } else if let cmd = matcher["command"] as? String,
                          markerSubstrings.contains(where: { cmd.contains($0) }) {
                    removed += 1
                    // drop entirely
                } else {
                    newMatchers.append(matcher)
                }
            }
            if newMatchers.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = newMatchers
            }
        }
        // If we stripped every event, drop the empty `hooks: {}` rather
        // than leaving a vestigial section in the user's settings.json.
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        return removed
    }

    /// Path to the user's global Claude settings.
    public static var globalSettingsPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("settings.json")
            .path
    }

    /// Repo-level settings paths for every repo registered in the TBD DB.
    /// Returns only paths that actually exist on disk.
    public static func repoSettingsPaths(repoPaths: [String],
                                         fileManager: FileManager = .default) -> [String] {
        repoPaths.compactMap { repoPath in
            let candidate = URL(fileURLWithPath: repoPath)
                .appendingPathComponent(".claude")
                .appendingPathComponent("settings.json")
                .path
            return fileManager.fileExists(atPath: candidate) ? candidate : nil
        }
    }

    /// Remove every detected legacy entry from the global settings file. No-op
    /// if there's nothing to remove. Wraps the write in `SettingsJSONSafety`
    /// (pristine backup, atomic write, roundtrip validation). Returns the
    /// number of entries removed and the backup file path (if a backup was
    /// just created — nil means a prior backup already existed or the file
    /// was missing).
    @discardableResult
    public static func removeGlobalEntries(at path: String = globalSettingsPath) throws -> RemoveLegacyGlobalHooksResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return RemoveLegacyGlobalHooksResult(removedCount: 0, backupPath: nil)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard var settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // File exists but isn't a JSON object — refuse to touch it.
            throw SettingsJSONSafety.Error.roundtripFailed("Existing settings.json is not a JSON object")
        }
        let removed = stripEntries(from: &settings)
        if removed == 0 {
            return RemoveLegacyGlobalHooksResult(removedCount: 0, backupPath: nil)
        }
        let createdBackup = try SettingsJSONSafety.ensureBackup(of: path)
        let proposed = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try SettingsJSONSafety.atomicWriteValidated(
            proposedBytes: proposed,
            targetPath: path
        ) { dict in
            // Invariant: the marker substrings must be GONE from any
            // `command` field in the resulting structure. Belt-and-braces
            // against a future regression in stripEntries.
            let leftover = detectEntries(in: dict)
            if !leftover.isEmpty {
                throw SettingsJSONSafety.Error.invariantFailed(
                    "Strip pass left \(leftover.count) marker entries behind"
                )
            }
        }
        logger.info("Removed \(removed, privacy: .public) legacy global hook entries from \(path, privacy: .public)")
        return RemoveLegacyGlobalHooksResult(
            removedCount: removed,
            backupPath: createdBackup ? path + SettingsJSONSafety.backupSuffix : nil
        )
    }
}
