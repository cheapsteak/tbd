import ArgumentParser
import Foundation
import TBDShared

struct SetupHooksCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup-hooks",
        abstract: "Set up Claude Code hooks for TBD notifications"
    )

    @Flag(name: .long, help: "Install hooks globally in ~/.claude/settings.json")
    var global = false

    @Option(name: .long, help: "Install hooks for a specific repo (path to repo root)")
    var repo: String?

    func validate() throws {
        if !global && repo == nil {
            throw ValidationError("Specify --global or --repo <path>")
        }
    }

    mutating func run() async throws {
        if global {
            let settingsPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude")
                .appendingPathComponent("settings.json")
            try installHooks(at: settingsPath.path)
            print("Global hooks installed at \(settingsPath.path)")
        }

        if let repo = repo {
            let repoPath = resolvePath(repo)
            let settingsPath = URL(fileURLWithPath: repoPath)
                .appendingPathComponent(".claude")
                .appendingPathComponent("settings.json")
            // Ensure .claude directory exists
            let claudeDir = URL(fileURLWithPath: repoPath).appendingPathComponent(".claude")
            try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            try installHooks(at: settingsPath.path)
            print("Repo hooks installed at \(settingsPath.path)")
        }
    }

    /// Read existing settings, merge the Stop hook, and write back.
    /// Wrapped in the SettingsJSONSafety helpers (pristine backup, roundtrip
    /// validation, atomic write) so a malformed write can't corrupt the
    /// user's settings.json mid-edit.
    private func installHooks(at path: String) throws {
        var settings: [String: Any] = [:]

        // Read existing settings if file exists
        if FileManager.default.fileExists(atPath: path) {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            if let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settings = existing
            }
        }

        // Get or create hooks dictionary
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // Get or create the Stop hooks array
        var stopHooks = hooks["Stop"] as? [[String: Any]] ?? []

        // The hook command we want to add
        let tbdNotifyCommand = #"MSG=$(jq -r '.last_assistant_message // empty' 2>/dev/null); tbd notify --type response_complete --message "$MSG" 2>/dev/null || true"#

        let correctEntry: [String: Any] = [
            "hooks": [
                [
                    "type": "command",
                    "command": tbdNotifyCommand,
                ] as [String: Any],
            ],
        ]

        // Migrate legacy bare-format entries and check if hook already exists
        var found = false
        for (i, matcher) in stopHooks.enumerated() {
            if let innerHooks = matcher["hooks"] as? [[String: Any]] {
                if innerHooks.contains(where: { ($0["command"] as? String)?.contains("tbd notify") == true }) {
                    // Update the command even if format is correct (command may have changed)
                    stopHooks[i] = correctEntry
                    found = true
                }
            } else if let command = matcher["command"] as? String, command.contains("tbd notify") {
                // Legacy bare format — migrate in place
                stopHooks[i] = correctEntry
                found = true
            }
        }

        if !found {
            stopHooks.append(correctEntry)
        }

        hooks["Stop"] = stopHooks
        settings["hooks"] = hooks

        // Pristine backup before TBD's first ever mutation. Idempotent — only
        // creates the backup if it doesn't already exist.
        try SettingsJSONSafety.ensureBackup(of: path)

        // Serialize the proposed bytes once; the safety helper round-trips
        // them and runs an invariant before atomically writing.
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try SettingsJSONSafety.atomicWriteValidated(
            proposedBytes: data,
            targetPath: path
        ) { dict in
            // Sanity-check: the result has a `hooks` dict, the Stop array
            // contains our entry, and no stray null at top-level.
            guard let parsedHooks = dict["hooks"] as? [String: Any] else {
                throw SettingsJSONSafety.Error.invariantFailed("Missing hooks dict")
            }
            guard let parsedStop = parsedHooks["Stop"] as? [[String: Any]] else {
                throw SettingsJSONSafety.Error.invariantFailed("Missing Stop hooks array")
            }
            let containsTBD = parsedStop.contains { matcher in
                let inner = matcher["hooks"] as? [[String: Any]] ?? []
                return inner.contains { ($0["command"] as? String)?.contains("tbd notify") == true }
            }
            guard containsTBD else {
                throw SettingsJSONSafety.Error.invariantFailed("tbd notify entry missing after merge")
            }
        }
    }
}
