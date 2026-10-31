import Foundation
internal import TOMLKit

/// A caller-supplied Codex home is opt-in for one terminal. This preflight
/// rejects an absent or explicitly disabled guard before TBD creates a pane,
/// and again before every relaunch of Codex in that tab.
/// TBD launches every Codex terminal with `--dangerously-bypass-hook-trust`,
/// so a hook in this home skips Codex's startup trust review. This preflight
/// relies on current Codex versions defaulting hooks on when no feature value
/// is set. Older versions with hooks off by default require explicit enablement.
/// The caller owns review of the guard command's behavior and of any tools
/// outside Codex's hook surface; presence alone is not a security proof.
/// Hook `matcher` patterns are not interpreted: a hook that never matches
/// passes here, so the caller must prove denial with a live synthetic call in
/// the tab before relying on the guard, especially on older Codex versions.
/// The caller also owns the directory for the tab's lifetime, including the
/// TBD profile and plugin written into it; TBD never deletes it.
enum GuardedCodexHome {
    /// Describes itself too: the router reports a thrown error as `"\(error)"`,
    /// so a refused relaunch reads the same as a refused create.
    enum ValidationError: Error, LocalizedError, CustomStringConvertible {
        case invalid(String)

        var errorDescription: String? { description }

        var description: String {
            switch self {
            case .invalid(let reason): "Guarded Codex home: \(reason)"
            }
        }
    }

    /// A disable under either feature key can skip the guard. Keep the
    /// config-layer check and the launch-argument check on the same keys.
    static let hookFeatureKeys: Set<String> = ["hooks", "codex_hooks"]

    static func validate(_ path: String, fileManager: FileManager = .default) throws -> URL {
        guard path.hasPrefix("/"), !path.isEmpty else {
            throw ValidationError.invalid("--codex-home must be an absolute path")
        }
        let home = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard home.path == path, home.resolvingSymlinksInPath().path == path else {
            throw ValidationError.invalid("--codex-home must be a canonical directory without symlinks")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue, fileManager.isReadableFile(atPath: path) else {
            throw ValidationError.invalid("directory does not exist or is unreadable")
        }

        let hooksPath = home.appendingPathComponent("hooks.json").path
        let hooksData = try readRegularFile(hooksPath, fileManager: fileManager)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: hooksData)
        } catch {
            throw ValidationError.invalid("hooks.json is not valid JSON")
        }
        guard let root = object as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let groups = hooks["PreToolUse"] as? [[String: Any]],
              !groups.isEmpty else {
            throw ValidationError.invalid("hooks.json must contain PreToolUse command hooks")
        }
        var keys: [String] = []
        for (groupIndex, group) in groups.enumerated() {
            guard let commands = group["hooks"] as? [[String: Any]], !commands.isEmpty else {
                throw ValidationError.invalid("PreToolUse group \(groupIndex) has no hooks")
            }
            for (hookIndex, command) in commands.enumerated() {
                guard command["type"] as? String == "command",
                      let body = command["command"] as? String,
                      !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ValidationError.invalid("PreToolUse group \(groupIndex) contains a missing or non-command hook")
                }
                // Codex's own state key, as it writes it under `[hooks.state]`
                // in config.toml: `<hooks.json path>:<event>:<group>:<hook>`.
                keys.append("\(hooksPath):pre_tool_use:\(groupIndex):\(hookIndex)")
            }
        }

        // Codex layers tbd.config.toml over config.toml. Read both, since a
        // disabled state in either is an explicit refusal to run the guard.
        for name in ["config.toml", "tbd.config.toml"] {
            let configPath = home.appendingPathComponent(name).path
            guard fileManager.fileExists(atPath: configPath) else {
                if name == "config.toml" {
                    throw ValidationError.invalid("config.toml is missing")
                }
                continue // TBD creates its profile overlay after this preflight.
            }
            let data = try readRegularFile(configPath, fileManager: fileManager)
            guard let source = String(data: data, encoding: .utf8) else {
                throw ValidationError.invalid("\(name) is not UTF-8")
            }
            let table: TOMLTable
            do {
                table = try TOMLTable(string: source)
            } catch {
                throw ValidationError.invalid("\(name) is not valid TOML")
            }
            // An explicit hook-feature disable in either layer means no guard.
            if let features = table["features"] {
                guard let featuresTable = features.table else {
                    throw ValidationError.invalid("\(name) has malformed feature settings")
                }
                for feature in hookFeatureKeys {
                    if let hooksOn = featuresTable[feature], hooksOn.bool != true {
                        throw ValidationError.invalid("\(name) turns off Codex's \(feature) feature")
                    }
                }
            }
            guard let hooksValue = table["hooks"] else { continue }
            guard let hooksTable = hooksValue.table else {
                throw ValidationError.invalid("\(name) has malformed hooks settings")
            }
            if let enabled = hooksTable["enabled"], enabled.bool != true {
                throw ValidationError.invalid("\(name) disables or misconfigures hooks")
            }
            guard let stateValue = hooksTable["state"] else { continue }
            guard let state = stateValue.table else {
                throw ValidationError.invalid("\(name) has malformed hook state")
            }
            for key in keys {
                guard let stateEntry = state[key] else { continue }
                guard let entry = stateEntry.table else {
                    throw ValidationError.invalid("\(name) has malformed PreToolUse hook state")
                }
                if let enabled = entry["enabled"], enabled.bool != true {
                    throw ValidationError.invalid("\(name) disables or misconfigures a PreToolUse hook")
                }
            }
        }
        return home
    }

    /// Validates the home, writes TBD's Codex profile and plugin into it, then
    /// validates again, so TBD's own writes cannot leave the guard disabled.
    /// Nothing is written into a directory that fails the first check.
    static func ensureProfile(in path: String) throws -> URL {
        let home = try validate(path)
        try CodexHomeManager(codexHome: home).ensureProfilePlugin()
        return try validate(path)
    }

    /// Free-form env overrides must not replace a guarded home: force it into
    /// the pre-rc environment as well as the inline one.
    static func forcingHome(
        _ overrides: [String: String], _ preparation: CodexLaunchPreparation, guarded: Bool
    ) -> [String: String] {
        guard guarded else { return overrides }
        return overrides.merging(["CODEX_HOME": preparation.codexHome.path]) { _, forced in forced }
    }

    private static func readRegularFile(
        _ path: String, fileManager: FileManager
    ) throws -> Data {
        let url = URL(fileURLWithPath: path)
        guard url.resolvingSymlinksInPath().path == path,
              fileManager.isReadableFile(atPath: path),
              let attributes = try? fileManager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ValidationError.invalid("\(url.lastPathComponent) is missing, unreadable, or linked")
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ValidationError.invalid("could not read \(url.lastPathComponent)")
        }
    }
}

extension CodexLaunchPreparation {
    /// Preparation for a Codex launch in a tab with this dedicated home, or in
    /// the shared home when it has none. Every launch and relaunch of a guarded
    /// tab goes through here, so a home that lost its guard refuses the launch
    /// instead of falling back to the shared home.
    static func prepare(
        guardedHome: String?,
        executableResolver: @Sendable () throws -> String,
        sharedHomeEnsurer: @Sendable () throws -> URL
    ) throws -> CodexLaunchPreparation {
        guard let guardedHome else {
            return try prepare(
                executableResolver: executableResolver, homeEnsurer: sharedHomeEnsurer)
        }
        return try prepare(
            executableResolver: executableResolver,
            homeEnsurer: { try GuardedCodexHome.ensureProfile(in: guardedHome) })
    }
}
