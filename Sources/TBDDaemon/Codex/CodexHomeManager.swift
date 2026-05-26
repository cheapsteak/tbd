import Foundation
import os
import TBDShared

private let codexLogger = Logger(subsystem: "com.tbd.daemon", category: "codex-integration")

/// Installs TBD's Codex integration into the user's global Codex home.
///
/// TBD uses the file-backed `codex --profile-v2 tbd` overlay instead of an
/// isolated per-repo `CODEX_HOME`, so user auth/config/plugins continue to
/// merge with TBD's runtime integration while the TBD plugin remains
/// profile-scoped.
struct CodexHomeManager: Sendable {
    let codexHome: URL

    init(codexHome: URL? = nil) {
        self.codexHome = codexHome
            ?? Self.testCodexHomeOverride()
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
    }

    @discardableResult
    func ensureProfilePlugin() throws -> URL {
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try CodexPluginWriter.writePlugin(in: codexHome)
        try CodexProfileWriter.ensureProfile(in: codexHome)
        codexLogger.info("Ensured Codex TBD profile plugin in \(codexHome.path, privacy: .public)")
        return codexHome
    }

    private static func testCodexHomeOverride() -> URL? {
        guard let rawValue = getenv("TBD_TEST_CODEX_HOME"),
              let path = String(validatingCString: rawValue),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

enum CodexPlugin {
    static let profileName = "tbd"
    static let marketplaceName = "tbd"
    static let pluginName = "tbd"
    static let pluginVersion = "local"
    static let pluginKey = "\(pluginName)@\(marketplaceName)"

    static let relativeRoot =
        "plugins/cache/\(marketplaceName)/\(pluginName)/\(pluginVersion)"
}

/// Generates TBD-owned Codex hook configuration for the TBD plugin.
enum CodexHookOverlay {
    static let relativePath = "hooks/hooks.json"

    static let sessionStartCommand =
        #"tbd session-event 2>/dev/null || true"#

    static let responseCompleteCommand =
        #"MSG=$(printf '%s' "$PAYLOAD" | jq -r '.last_assistant_message // empty' 2>/dev/null); tbd notify --type response_complete --message "$MSG" 2>/dev/null || true"#

    static let stopRenameCheckCommand =
        #"tbd hooks stop-rename-check 2>/dev/null || true"#

    static let stopCommand =
        #"PAYLOAD=$(cat); RENAME_RESULT=$(printf '%s' "$PAYLOAD" | \#(stopRenameCheckCommand)); if [ -n "$RENAME_RESULT" ]; then printf '%s\n' "$RENAME_RESULT"; else \#(responseCompleteCommand); fi"#

    static func hookPath(in pluginRoot: URL) -> URL {
        pluginRoot.appendingPathComponent(relativePath, isDirectory: false)
    }

    static func generateBody() throws -> Data {
        let body: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    [
                        "matcher": "startup|resume|clear",
                        "hooks": [
                            ["type": "command", "command": sessionStartCommand]
                        ]
                    ]
                ],
                "Stop": [
                    [
                        "hooks": [
                            ["type": "command", "command": stopCommand]
                        ]
                    ]
                ]
            ]
        ]

        return try JSONSerialization.data(
            withJSONObject: body,
            options: [.prettyPrinted, .sortedKeys]
        )
    }
}

/// On-disk layout of the TBD skill inside the Codex plugin cache. This is a
/// pure path helper — the actual write happens in `CodexPluginWriter.writeSkill`.
enum CodexSkillLayout {
    static let relativePath = "skills/tbd/SKILL.md"

    static func skillPath(in pluginRoot: URL) -> URL {
        pluginRoot.appendingPathComponent(relativePath, isDirectory: false)
    }
}

enum CodexPluginWriter {
    static func pluginRoot(in codexHome: URL) -> URL {
        codexHome.appendingPathComponent(CodexPlugin.relativeRoot, isDirectory: true)
    }

    static func writePlugin(in codexHome: URL) throws {
        let root = pluginRoot(in: codexHome)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeManifest(in: root)
        try writeHooks(in: root)
        try writeSkill(in: root)
    }

    private static func writeManifest(in root: URL) throws {
        let manifest: [String: Any] = [
            "name": CodexPlugin.pluginName,
            "version": CodexPlugin.pluginVersion,
            "description": "TBD integration for Codex",
            "skills": "./skills",
            "hooks": "./hooks/hooks.json"
        ]
        let manifestDir = root.appendingPathComponent(".codex-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: manifestDir.appendingPathComponent("plugin.json"), options: .atomic)
    }

    private static func writeHooks(in root: URL) throws {
        let path = CodexHookOverlay.hookPath(in: root)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try CodexHookOverlay.generateBody().write(to: path, options: .atomic)
    }

    private static func writeSkill(in root: URL) throws {
        let path = CodexSkillLayout.skillPath(in: root)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try TBDSkillContent.body.write(to: path, atomically: true, encoding: .utf8)
    }
}

enum CodexProfileWriter {
    static let profileFileName = "\(CodexPlugin.profileName).config.toml"

    static func profilePath(in codexHome: URL) -> URL {
        codexHome.appendingPathComponent(profileFileName, isDirectory: false)
    }

    static func ensureProfile(in codexHome: URL) throws {
        let path = profilePath(in: codexHome)
        let current = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        let updated = ensurePluginEnabled(in: current)

        guard updated != current else {
            return
        }

        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try updated.write(to: path, atomically: true, encoding: .utf8)
    }

    static func ensurePluginEnabled(in toml: String) -> String {
        let header = #"[plugins."\#(CodexPlugin.pluginKey)"]"#

        // Normalize line endings to `\n` before splitting. A CRLF-terminated
        // `tbd.config.toml` would otherwise leave a trailing `\r` on every
        // line: `CharacterSet.whitespaces` does NOT include `\r`, so the
        // header matcher, the exact-`enabled` key matcher, and the
        // section-boundary detector below would all silently fail — appending
        // a duplicate `[plugins."tbd@tbd"]` table and orphaning the user's
        // original section. TBD owns this profile section, so we deliberately
        // normalize the whole file to LF on rewrite; a file that was CRLF
        // becomes LF. That is intentional and acceptable (and keeps the
        // writer's output well-formed so `ensureProfile`'s `updated != current`
        // idempotency guard still short-circuits on the second run).
        let normalized = toml
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Splitting a `\n`-terminated string with `omittingEmptySubsequences:
        // false` yields a trailing empty element. Drop it so the join below
        // does not append an extra blank line on every call — otherwise the
        // file grows and `ensureProfile`'s `updated != current` guard never
        // short-circuits.
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hadTrailingNewline = normalized.hasSuffix("\n")
        if hadTrailingNewline, lines.last == "" {
            lines.removeLast()
        }

        guard let headerIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
            // Build from `normalized`, not the raw `toml`, so TBD's appended
            // section is LF-terminated even if the source file was CRLF.
            var updated = normalized
            if !updated.isEmpty, !updated.hasSuffix("\n") {
                updated += "\n"
            }
            if !updated.isEmpty {
                updated += "\n"
            }
            updated += "\(header)\nenabled = true\n"
            return updated
        }

        let nextSectionIndex = lines[(headerIndex + 1)...]
            .firstIndex { line in
                // A section header is a line that trims to `[...]` and is not
                // a key/value assignment — reject lines containing `=` so a
                // multi-line array value or `[[table]]` element inside the
                // section is not misread as the next section boundary.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && !trimmed.contains("=")
            } ?? lines.endIndex

        if let enabledIndex = lines[(headerIndex + 1)..<nextSectionIndex]
            .firstIndex(where: { line in
                // Match the exact `enabled` key, not prefixes like
                // `enabled_features` which would otherwise be clobbered.
                let key = line.trimmingCharacters(in: .whitespaces)
                    .prefix { $0 != "=" }
                    .trimmingCharacters(in: .whitespaces)
                return key == "enabled"
            }) {
            lines[enabledIndex] = "enabled = true"
        } else {
            lines.insert("enabled = true", at: headerIndex + 1)
        }

        return lines.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
    }
}

enum CodexSpawnCommandBuilder {
    static let command = "unset CODEX_CI CODEX_THREAD_ID; codex --profile-v2 tbd --dangerously-bypass-approvals-and-sandbox"

    static func build(initialPrompt: String?) -> String {
        guard let initialPrompt, !initialPrompt.isEmpty else {
            return command
        }
        return "\(command) \(SystemPromptBuilder.shellEscape(initialPrompt))"
    }
}
