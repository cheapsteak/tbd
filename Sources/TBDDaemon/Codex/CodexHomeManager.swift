import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "codex-hooks")

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

    @discardableResult
    func ensureHomeWithHooks(forRepoID repoID: UUID) throws -> URL {
        let home = try ensureHome(forRepoID: repoID)
        // Hook setup is best-effort: log failures, but do not block Codex launch.
        CodexHookOverlay.writeOverlay(in: home)
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
            logger.info("Wrote Codex hooks at \(path.path, privacy: .public)")
            return true
        } catch {
            logger.error("Failed to write Codex hooks: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

enum CodexSpawnCommandBuilder {
    static let command = "unset CODEX_CI CODEX_THREAD_ID; codex --dangerously-bypass-approvals-and-sandbox"
}
