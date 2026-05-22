import Foundation
import os
import TBDShared

private let codexLogger = Logger(subsystem: "com.tbd.daemon", category: "codex-integration")

/// Installs TBD's Codex integration into the user's global Codex home.
///
/// TBD uses `codex --profile tbd` instead of an isolated per-repo
/// `CODEX_HOME`, so user auth/config/plugins continue to merge with TBD's
/// runtime integration while the TBD plugin remains profile-scoped.
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

    static let stopCommand =
        #"MSG=$(jq -r '.last_assistant_message // empty' 2>/dev/null); tbd notify --type response_complete --message "$MSG" 2>/dev/null || true; tbd hooks stop-rename-check 2>/dev/null || true"#

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

enum CodexSkillWriter {
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
        let path = CodexSkillWriter.skillPath(in: root)
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

        guard updated != current || !FileManager.default.fileExists(atPath: path.path) else {
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
        var lines = toml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard let headerIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
            var updated = toml
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
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
            } ?? lines.endIndex

        if let enabledIndex = lines[(headerIndex + 1)..<nextSectionIndex]
            .firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("enabled") }) {
            lines[enabledIndex] = "enabled = true"
        } else {
            lines.insert("enabled = true", at: headerIndex + 1)
        }

        return lines.joined(separator: "\n") + (toml.hasSuffix("\n") ? "\n" : "")
    }
}

enum CodexSpawnCommandBuilder {
    static let command = "unset CODEX_CI CODEX_THREAD_ID; codex --profile tbd --dangerously-bypass-approvals-and-sandbox"
}
