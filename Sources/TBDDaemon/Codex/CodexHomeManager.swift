import Foundation
import os
import TBDShared

private let hooksLogger = Logger(subsystem: "com.tbd.daemon", category: "codex-hooks")
private let skillLogger = Logger(subsystem: "com.tbd.daemon", category: "codex-skill")

/// Manages per-repo isolated `CODEX_HOME` directories under
/// `~/.tbd/agents/codex/<repoID>/`. This keeps TBD-launched codex sessions
/// from touching the user's real `~/.codex/` — so config, hooks, and
/// sessions stay scoped per repo and TBD never pollutes global codex state.
struct CodexHomeManager: Sendable {
    let baseDirectory: URL

    init(baseDirectory: URL? = nil) {
        // See HookResolver — keep cross-module `TBDConstants.configDir` access
        // inside this module to avoid Xcode 26.3 unsafeMutableAddressor link
        // failures in test targets that call this initializer with defaults.
        self.baseDirectory = baseDirectory
            ?? TBDConstants.configDir.appendingPathComponent("agents/codex", isDirectory: true)
    }

    func homeDirectory(forRepoID repoID: UUID) -> URL {
        baseDirectory.appendingPathComponent(repoID.uuidString.lowercased(), isDirectory: true)
    }

    @discardableResult
    func ensureHome(forRepoID repoID: UUID) throws -> URL {
        let home = homeDirectory(forRepoID: repoID)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// Ensure TBD's Codex integration files exist in the isolated CODEX_HOME.
    ///
    /// The method name is retained because existing call sites use it as the
    /// launch-time setup point, but it now writes both hooks and the TBD skill.
    @discardableResult
    func ensureHomeWithHooks(forRepoID repoID: UUID) throws -> URL {
        let home = try ensureHome(forRepoID: repoID)
        // Integration setup is best-effort: log failures, but do not block Codex launch.
        CodexHookOverlay.writeOverlay(in: home)
        CodexSkillWriter.writeSkill(in: home)
        return home
    }
}

/// Generates TBD-owned Codex hook configuration inside the isolated CODEX_HOME.
///
/// Codex reads hooks from `$CODEX_HOME/hooks.json`; unlike Claude's
/// `--settings` overlay, the CODEX_HOME itself is already TBD-owned per repo,
/// so writing the file there avoids touching the user's global `~/.codex`.
enum CodexHookOverlay {
    static let fileName = "hooks.json"

    static let sessionStartCommand =
        #"tbd session-event 2>/dev/null || true"#

    static let stopCommand =
        #"MSG=$(jq -r '.last_assistant_message // empty' 2>/dev/null); tbd notify --type response_complete --message "$MSG" 2>/dev/null || true"#

    static let stopRenameCheckCommand =
        #"tbd hooks stop-rename-check 2>/dev/null || true"#

    static func overlayPath(in codexHome: URL) -> URL {
        codexHome.appendingPathComponent(fileName, isDirectory: false)
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
                    ],
                    [
                        "hooks": [
                            ["type": "command", "command": stopRenameCheckCommand]
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

    @discardableResult
    static func writeOverlay(in codexHome: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: codexHome,
                withIntermediateDirectories: true
            )
            let data = try generateBody()
            let path = overlayPath(in: codexHome)
            try data.write(to: path, options: .atomic)
            hooksLogger.info("Wrote Codex hooks at \(path.path, privacy: .public)")
            return true
        } catch {
            hooksLogger.error("Failed to write Codex hooks: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

/// Writes the TBD skill into the isolated CODEX_HOME for TBD-spawned Codex
/// sessions. Codex loads local skills from `$CODEX_HOME/skills/<name>/SKILL.md`,
/// so this mirrors the Claude plugin skill without relying on Codex plugin
/// hook support.
enum CodexSkillWriter {
    static let relativePath = "skills/tbd/SKILL.md"

    static func skillPath(in codexHome: URL) -> URL {
        codexHome.appendingPathComponent(relativePath, isDirectory: false)
    }

    @discardableResult
    static func writeSkill(in codexHome: URL) -> Bool {
        do {
            let path = skillPath(in: codexHome)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try TBDSkillContent.body.write(
                to: path,
                atomically: true,
                encoding: .utf8
            )
            skillLogger.info("Wrote Codex skill at \(path.path, privacy: .public)")
            return true
        } catch {
            skillLogger.error("Failed to write Codex skill: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

enum CodexSpawnCommandBuilder {
    static let command = "unset CODEX_CI CODEX_THREAD_ID; codex --dangerously-bypass-approvals-and-sandbox"
}
