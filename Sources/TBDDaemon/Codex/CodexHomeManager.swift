import Foundation
import os
import TBDShared

private let codexLogger = Logger(subsystem: "com.tbd.daemon", category: "codex-integration")

/// Installs TBD's Codex integration into the user's global Codex home.
///
/// TBD uses a file-backed `tbd` Codex profile overlay instead of an
/// isolated per-repo `CODEX_HOME`, so user auth/config/plugins continue to
/// merge with TBD's runtime integration while the TBD plugin remains
/// profile-scoped.
struct CodexHomeManager: Sendable {
    let codexHome: URL

    init(codexHome: URL? = nil) {
        self.codexHome = codexHome
            ?? Self.testCodexHomeOverride()
            // swiftlint:disable:next no_home_relative_store_path - THE Codex-store resolver; the override is consulted on the line above
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
        #"tbd session-event 2>/dev/null || true; tbd terminal-activity idle 2>/dev/null || true"#

    static let responseCompleteCommand =
        #"MSG=$(printf '%s' "$PAYLOAD" | jq -r '.last_assistant_message // empty' 2>/dev/null); tbd notify --type response_complete --message "$MSG" 2>/dev/null || true; SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null); SESSION_ID_SQL=$(printf '%s' "$SESSION_ID" | sed "s/'/''/g"); GOAL_STATUS=$(sqlite3 -readonly "$CODEX_HOME/goals_1.sqlite" "SELECT status FROM thread_goals WHERE thread_id = '$SESSION_ID_SQL' ORDER BY updated_at_ms DESC LIMIT 1;" 2>/dev/null); [ "$GOAL_STATUS" = active ] || tbd terminal-activity idle 2>/dev/null || true"#

    static let stopRenameCheckCommand =
        #"tbd hooks stop-rename-check 2>/dev/null || true"#

    static let stopCommand =
        #"PAYLOAD=$(cat); RENAME_RESULT=$(printf '%s' "$PAYLOAD" | \#(stopRenameCheckCommand)); if [ -n "$RENAME_RESULT" ]; then printf '%s\n' "$RENAME_RESULT"; else \#(responseCompleteCommand); fi"#

    static let workingCommand =
        #"tbd terminal-activity working 2>/dev/null || true"#

    static let waitingForUserCommand =
        #"tbd terminal-activity waiting_for_user 2>/dev/null || true"#
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
                            // Run rename-check, and only publish
                            // response_complete/idle when it does not block.
                            ["type": "command", "command": stopCommand]
                        ]
                    ]
                ],
                "UserPromptSubmit": [
                    [
                        "hooks": [
                            ["type": "command", "command": workingCommand]
                        ]
                    ]
                ],
                "PermissionRequest": [
                    [
                        "hooks": [
                            ["type": "command", "command": waitingForUserCommand]
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
        return ensureSettings(
            in: toml,
            header: header,
            settings: [("enabled", "true")]
        )
    }

    private static func ensureSettings(
        in toml: String,
        header: String,
        settings: [(key: String, value: String)]
    ) -> String {
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
            let settingLines = settings.map { "\($0.key) = \($0.value)" }
            updated += ([header] + settingLines).joined(separator: "\n") + "\n"
            return updated
        }

        var nextSectionIndex = lines[(headerIndex + 1)...]
            .firstIndex { line in
                // A section header is a line that trims to `[...]` and is not
                // a key/value assignment — reject lines containing `=` so a
                // multi-line array value or `[[table]]` element inside the
                // section is not misread as the next section boundary.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && !trimmed.contains("=")
            } ?? lines.endIndex

        var missingSettings: [(key: String, value: String)] = []
        for setting in settings {
            let matchingIndices = lines[(headerIndex + 1)..<nextSectionIndex]
                .indices
                .filter { index in
                    // Match the exact key, not prefixes like
                    // `enabled_features` which would otherwise be clobbered.
                    let key = lines[index].trimmingCharacters(in: .whitespaces)
                        .prefix { $0 != "=" }
                        .trimmingCharacters(in: .whitespaces)
                    return key == setting.key
                }

            guard let firstIndex = matchingIndices.first else {
                missingSettings.append(setting)
                continue
            }

            lines[firstIndex] = "\(setting.key) = \(setting.value)"
            for duplicateIndex in matchingIndices.dropFirst().reversed() {
                lines.remove(at: duplicateIndex)
                nextSectionIndex -= 1
            }
        }

        if !missingSettings.isEmpty {
            lines.insert(
                contentsOf: missingSettings.map { "\($0.key) = \($0.value)" },
                at: headerIndex + 1
            )
        }

        return lines.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
    }
}

enum CodexExecutableResolutionError: LocalizedError, Equatable {
    case invalidOverride(environmentKey: String, value: String, reason: String)
    case notFound(searchPath: String, fallbackPath: String)

    var errorDescription: String? {
        switch self {
        case .invalidOverride(let environmentKey, let value, let reason):
            return """
                Invalid \(environmentKey) override "\(value)": \(reason). Set \
                \(environmentKey) to the absolute path of an executable Codex \
                CLI, or unset it, then restart TBD.
                """
        case .notFound(let searchPath, let fallbackPath):
            let renderedSearchPath = searchPath.isEmpty ? "(empty)" : searchPath
            return """
                Could not find an executable Codex CLI. Searched PATH \
                (\(renderedSearchPath)) and \(fallbackPath). Set \
                \(CodexExecutableResolver.executableOverrideEnvironmentKey) to \
                an absolute Codex executable path, install or update \
                ChatGPT.app, or add the Codex CLI to PATH, then restart TBD.
                """
        }
    }
}

/// Resolves the Codex CLI before TBD creates a tmux window or terminal row.
///
/// A configured `TBD_CODEX_EXECUTABLE` absolute path wins, followed by every
/// absolute PATH entry in order. Relative and empty PATH entries are ignored:
/// resolving them against the daemon's current directory could execute an
/// untrusted worktree-local `codex`. ChatGPT.app's bundled CLI is the fallback because
/// GUI-launched daemons often have a minimal PATH that cannot name it even
/// though the app (and the user's existing global Codex login) is installed.
/// The returned path is always absolute so the later interactive shell does
/// not repeat PATH lookup with a different environment.
enum CodexExecutableResolver {
    static let executableOverrideEnvironmentKey = "TBD_CODEX_EXECUTABLE"
    static let chatGPTBundlePath = "/Applications/ChatGPT.app/Contents/Resources/codex"

    static func resolve(
        configuredOverride: String? = ProcessInfo.processInfo.environment["TBD_CODEX_EXECUTABLE"],
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        fallbackPath: String = chatGPTBundlePath,
        isExecutable: (String) -> Bool = {
            isUsableExecutable(atPath: $0)
        }
    ) throws -> String {
        let currentDirectoryURL = URL(
            fileURLWithPath: currentDirectory,
            isDirectory: true
        ).standardizedFileURL

        func absolutePath(_ path: String) -> String {
            if path.hasPrefix("/") {
                return URL(fileURLWithPath: path).standardizedFileURL.path
            }
            return URL(
                fileURLWithPath: path,
                relativeTo: currentDirectoryURL
            ).standardizedFileURL.path
        }

        var seen = Set<String>()
        if let configuredOverride, !configuredOverride.isEmpty {
            guard (configuredOverride as NSString).isAbsolutePath else {
                throw CodexExecutableResolutionError.invalidOverride(
                    environmentKey: executableOverrideEnvironmentKey,
                    value: configuredOverride,
                    reason: "the path must be absolute"
                )
            }

            let absoluteOverride = absolutePath(configuredOverride)
            guard isExecutable(absoluteOverride) else {
                throw CodexExecutableResolutionError.invalidOverride(
                    environmentKey: executableOverrideEnvironmentKey,
                    value: configuredOverride,
                    reason: "the path is not executable"
                )
            }
            return absoluteOverride
        }

        let pathEntries = searchPath.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        for entry in pathEntries {
            let directory = String(entry)
            guard !directory.isEmpty,
                  (directory as NSString).isAbsolutePath else {
                continue
            }
            let candidate = absolutePath(
                (directory as NSString).appendingPathComponent("codex")
            )
            guard seen.insert(candidate).inserted else { continue }
            if isExecutable(candidate) {
                return candidate
            }
        }

        let absoluteFallback = absolutePath(fallbackPath)
        if seen.insert(absoluteFallback).inserted, isExecutable(absoluteFallback) {
            return absoluteFallback
        }

        throw CodexExecutableResolutionError.notFound(
            searchPath: searchPath,
            fallbackPath: absoluteFallback
        )
    }

    /// Best-effort lookup for non-launching features such as usage display.
    ///
    /// Spawn paths must call the throwing `resolve` API so an invalid override
    /// or missing CLI reaches the user as an actionable error. Usage probing
    /// can degrade to an unavailable state, and also checks common absolute
    /// user/package-manager locations that a launchd PATH may omit.
    static func resolveIfAvailable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        isExecutable: (String) -> Bool = {
            isUsableExecutable(atPath: $0)
        }
    ) -> String? {
        let fallbackDirectories = [
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/.volta/bin",
            "\(homeDirectory)/.cargo/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        let augmentedSearchPath = ([environment["PATH"]].compactMap { $0 }
            + fallbackDirectories).joined(separator: ":")

        return try? resolve(
            configuredOverride: environment[executableOverrideEnvironmentKey],
            searchPath: augmentedSearchPath,
            fallbackPath: chatGPTBundlePath,
            isExecutable: isExecutable
        )
    }

    private static func isUsableExecutable(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: path, isDirectory: &isDirectory
        ), !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}

struct CodexLaunchPreparation: Sendable {
    let executablePath: String
    let codexHome: URL

    static func prepare(
        executableResolver: @Sendable () throws -> String,
        homeEnsurer: @Sendable () throws -> URL
    ) throws -> CodexLaunchPreparation {
        // Keep this order explicit: executable resolution is read-only and
        // should fail before the profile writer touches the global Codex home.
        let executablePath = try executableResolver()
        let codexHome = try homeEnsurer()
        return CodexLaunchPreparation(
            executablePath: executablePath,
            codexHome: codexHome
        )
    }
}

enum CodexSpawnCommandBuilder {
    private static let detectedProfileFlag = detectProfileFlag { arguments in
        commandOutput(arguments: arguments, timeout: 3)
    }

    static var command: String {
        baseCommand(profileFlag: detectedProfileFlag)
    }

    static func build(initialPrompt: String?) -> String {
        build(initialPrompt: initialPrompt, profileFlag: detectedProfileFlag)
    }

    static func command(executablePath: String) -> String {
        let profileFlag = detectProfileFlag(executablePath: executablePath) { arguments in
            commandOutput(arguments: arguments, timeout: 3)
        }
        return baseCommand(executablePath: executablePath, profileFlag: profileFlag)
    }

    static func build(
        initialPrompt: String?,
        resumeThreadID: String? = nil,
        executablePath: String
    ) -> String {
        let profileFlag = detectProfileFlag(executablePath: executablePath) { arguments in
            commandOutput(arguments: arguments, timeout: 3)
        }
        return build(
            initialPrompt: initialPrompt,
            resumeThreadID: resumeThreadID,
            executablePath: executablePath,
            profileFlag: profileFlag
        )
    }

    static func build(
        initialPrompt: String?,
        codexHelpOutput: String? = nil,
        codexVersionOutput: String? = nil,
        resumeThreadID: String? = nil,
        executablePath: String = "codex"
    ) -> String {
        build(
            initialPrompt: initialPrompt,
            resumeThreadID: resumeThreadID,
            executablePath: executablePath,
            profileFlag: profileFlag(codexHelpOutput: codexHelpOutput, codexVersionOutput: codexVersionOutput)
        )
    }

    private static func build(initialPrompt: String?, profileFlag: String) -> String {
        let command = baseCommand(profileFlag: profileFlag)
        guard let initialPrompt, !initialPrompt.isEmpty else {
            return command
        }
        return "\(command) \(SystemPromptBuilder.shellEscape(initialPrompt))"
    }

    static func build(
        initialPrompt: String?,
        resumeThreadID: String?,
        executablePath: String,
        profileFlag: String
    ) -> String {
        let command = baseCommand(
            executablePath: executablePath,
            profileFlag: profileFlag,
            resumeThreadID: resumeThreadID)
        guard let initialPrompt, !initialPrompt.isEmpty else {
            return command
        }
        return "\(command) \(SystemPromptBuilder.shellEscape(initialPrompt))"
    }

    private static func baseCommand(profileFlag: String) -> String {
        return "unset CODEX_CI CODEX_THREAD_ID; codex \(profileFlag) tbd --dangerously-bypass-approvals-and-sandbox"
    }

    private static func baseCommand(
        executablePath: String,
        profileFlag: String,
        resumeThreadID: String? = nil
    ) -> String {
        let executable = SystemPromptBuilder.shellEscape(executablePath)
        let base = "unset CODEX_CI CODEX_THREAD_ID; \(executable) \(profileFlag) tbd --dangerously-bypass-approvals-and-sandbox"
        guard let resumeThreadID, !resumeThreadID.isEmpty else { return base }
        return "\(base) resume \(SystemPromptBuilder.shellEscape(resumeThreadID))"
    }

    static func profileFlag(codexHelpOutput: String?, codexVersionOutput: String?) -> String {
        if let codexHelpOutput {
            if codexHelpOutput.contains("--profile-v2") {
                return "--profile-v2"
            }
            if codexHelpOutput.contains("--profile") {
                return "--profile"
            }
        }

        if let version = codexVersion(from: codexVersionOutput) {
            return version >= CodexVersion(major: 0, minor: 134, patch: 0) ? "--profile" : "--profile-v2"
        }

        return "--profile"
    }

    static func detectProfileFlag(commandOutput: ([String]) -> String?) -> String {
        let helpOutput = commandOutput(["codex", "--help"])
        if let helpOutput, helpOutput.contains("--profile-v2") || helpOutput.contains("--profile") {
            return profileFlag(codexHelpOutput: helpOutput, codexVersionOutput: nil)
        }

        return profileFlag(
            codexHelpOutput: helpOutput,
            codexVersionOutput: commandOutput(["codex", "--version"])
        )
    }

    static func detectProfileFlag(
        executablePath: String,
        commandOutput: ([String]) -> String?
    ) -> String {
        let helpOutput = commandOutput([executablePath, "--help"])
        if let helpOutput, helpOutput.contains("--profile-v2") || helpOutput.contains("--profile") {
            return profileFlag(codexHelpOutput: helpOutput, codexVersionOutput: nil)
        }

        return profileFlag(
            codexHelpOutput: helpOutput,
            codexVersionOutput: commandOutput([executablePath, "--version"])
        )
    }

    private struct CodexVersion: Comparable {
        let major: Int
        let minor: Int
        let patch: Int

        static func < (lhs: CodexVersion, rhs: CodexVersion) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
    }

    private static func codexVersion(from output: String?) -> CodexVersion? {
        guard let output else { return nil }
        let scanner = Scanner(string: output)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " \n\t")

        while !scanner.isAtEnd {
            _ = scanner.scanUpToCharacters(from: .decimalDigits)
            guard let major = scanner.scanInt(),
                  scanner.scanString(".") != nil,
                  let minor = scanner.scanInt(),
                  scanner.scanString(".") != nil,
                  let patch = scanner.scanInt()
            else {
                continue
            }
            return CodexVersion(major: major, minor: minor, patch: patch)
        }

        return nil
    }

    private final class LockedOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ newData: Data) {
            lock.lock()
            data.append(newData)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    static func commandOutput(
        executable: String = "/usr/bin/env",
        arguments: [String],
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let output = LockedOutput()
        let terminated = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        let appendOutput: @Sendable (FileHandle) -> Void = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            output.append(data)
        }
        stdout.fileHandleForReading.readabilityHandler = appendOutput
        stderr.fileHandleForReading.readabilityHandler = appendOutput
        process.terminationHandler = { _ in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            appendOutput(stdout.fileHandleForReading)
            appendOutput(stderr.fileHandleForReading)
            terminated.signal()
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        if terminated.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = terminated.wait(timeout: .now() + 1)
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        return String(data: output.snapshot(), encoding: .utf8)
    }
}
