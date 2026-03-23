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
        let tbdNotifyCommand = "tbd notify --type response_complete 2>/dev/null || true"

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
                // Correct format — check if it's ours
                if innerHooks.contains(where: { ($0["command"] as? String)?.contains("tbd notify") == true }) {
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

        // Write back
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }
}
