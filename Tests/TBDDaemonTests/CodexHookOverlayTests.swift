import Foundation
import Testing
import TBDShared
import TestSupport
@testable import TBDDaemonLib

@Suite struct CodexHookOverlayTests {

    /// Runs the Stop hook against a stub `tbd` that logs each invocation's
    /// arguments, and the message `notify` received, one per line.
    private func runStopHook(assistantMessage: String = "done") async throws -> [String] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-stop-hook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let logPath = directory.appendingPathComponent("tbd-invocations.log")
        let tbdPath = directory.appendingPathComponent("tbd")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$TBD_HOOK_TEST_LOG"
        if [ "$1" = notify ]; then
          printf 'notify-message=%s\\n' "$5" >> "$TBD_HOOK_TEST_LOG"
        fi
        """.write(to: tbdPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tbdPath.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", CodexHookOverlay.stopCommand]
        var environment = ProcessInfo.processInfo.environment
        let inheritedPath = environment["PATH"] ?? ""
        environment["PATH"] = ([
            directory.path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ] + inheritedPath.split(separator: ":").map(String.init)).joined(separator: ":")
        environment["CODEX_HOME"] = directory.path
        environment["TBD_HOOK_TEST_LOG"] = logPath.path
        process.environment = environment

        let payload = """
        {"session_id":"a1b2c3d4-e5f6-4789-abcd-0123456789ab","hook_event_name":"Stop","last_assistant_message":"\(assistantMessage)"}
        """
        // Feeds the payload, closes the hook's stdin, and waits without
        // parking a cooperative-pool thread.
        let output = try await collectOutput(of: process, stdin: Data(payload.utf8))
        #expect(output.status == 0)

        let log = (try? String(contentsOf: logPath, encoding: .utf8)) ?? ""
        return log.split(separator: "\n").map(String.init)
    }

    private func stopCommands(_ hooks: [String: Any]?) -> [String] {
        let stop = hooks?["Stop"] as? [[String: Any]]
        return (stop ?? []).flatMap { entry -> [String] in
            let inner = entry["hooks"] as? [[String: Any]] ?? []
            return inner.compactMap { $0["command"] as? String }
        }
    }

    @Test func generateBodyHasExpectedShape() throws {
        let data = try CodexHookOverlay.generateBody()
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = parsed?["hooks"] as? [String: Any]
        #expect(hooks != nil)

        let sessionStart = hooks?["SessionStart"] as? [[String: Any]]
        #expect(sessionStart?.first?["matcher"] as? String == "startup|resume|clear")
        let sessionHooks = sessionStart?.first?["hooks"] as? [[String: Any]]
        let sessionCommand = sessionHooks?.first?["command"] as? String
        #expect(sessionCommand?.contains("TBD_CLI_PATH-tbd") == true)
        #expect(sessionCommand?.contains("session-event") == true)

        #expect((hooks?["Stop"] as? [[String: Any]])?.count == 1)
        let stop = stopCommands(hooks)
        #expect(stop.count == 1)
        #expect(stop.contains {
            $0.contains("tbd hooks stop-rename-check")
                && $0.contains("tbd notify --type response_complete")
                && $0.contains("if [ -n \"$RENAME_RESULT\" ]")
        })
    }

    /// Codex reports its own state over OSC 7501, so only the two entries that
    /// report something else are registered, and nothing writes state.
    @Test func onlySessionStartAndStop() throws {
        let data = try CodexHookOverlay.generateBody()
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = try #require(parsed?["hooks"] as? [String: Any])
        #expect(hooks.keys.sorted() == ["SessionStart", "Stop"])
        let body = try #require(String(data: data, encoding: .utf8))
        #expect(!body.contains("terminal-activity"))
        #expect(!body.contains("sqlite3"))
    }

    @Test func sessionStartForwardsTheExactPayloadToSessionEventOnly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-session-hook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tbdPath = directory.appendingPathComponent("matched tbd cli")
        let fallbackPath = directory.appendingPathComponent("tbd")
        try """
        #!/bin/sh
        if [ "$1" = session-event ]; then
          cat > "$TBD_SESSION_STDIN"
        else
          printf '%s\n' "$*" > "$TBD_OTHER_ARGS"
        fi
        """.write(to: tbdPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tbdPath.path)
        try "#!/bin/sh\nexit 91\n".write(to: fallbackPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fallbackPath.path)
        let sessionInput = directory.appendingPathComponent("session-input")
        let otherArgs = directory.appendingPathComponent("other-args")
        let payload = #"{"session_id":"session-current","value":"$(touch should-not-run); ' \""}"#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", CodexHookOverlay.sessionStartCommand]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(directory.path):/usr/bin:/bin"
        environment["TBD_CLI_PATH"] = tbdPath.path
        environment["TBD_SESSION_STDIN"] = sessionInput.path
        environment["TBD_OTHER_ARGS"] = otherArgs.path
        process.environment = environment
        let output = try await collectOutput(of: process, stdin: Data(payload.utf8))

        #expect(output.status == 0)
        #expect(try String(contentsOf: sessionInput, encoding: .utf8) == payload)
        // No second bridge: the hook runs `session-event` and nothing else.
        #expect(!FileManager.default.fileExists(atPath: otherArgs.path))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("should-not-run").path))
    }

    @Test func sessionStartFallsBackToPathWhenMatchedCLIIsAbsent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-session-hook-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fallback = directory.appendingPathComponent("tbd")
        try "#!/bin/sh\nprintf '%s' \"$1\" > \"$TBD_FALLBACK_MARKER\"\n"
            .write(to: fallback, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fallback.path)
        let marker = directory.appendingPathComponent("marker")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", CodexHookOverlay.sessionStartCommand]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(directory.path):/usr/bin:/bin"
        environment.removeValue(forKey: "TBD_CLI_PATH")
        environment["TBD_FALLBACK_MARKER"] = marker.path
        process.environment = environment
        // An empty stdin: the hook reads end-of-file at once.
        let output = try await collectOutput(of: process, stdin: Data())

        #expect(output.status == 0)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "session-event")
    }

    @Test func stopHookGatesTheNotificationBehindRenameCheck() throws {
        let data = try CodexHookOverlay.generateBody()
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let stop = stopCommands(parsed?["hooks"] as? [String: Any])
        #expect(stop.count == 1)
        let stopCommand = stop.first
        #expect(stopCommand?.contains("RENAME_RESULT=") == true)
        #expect(stopCommand?.contains("printf '%s\\n' \"$RENAME_RESULT\"") == true)
        #expect(stopCommand?.contains("tbd notify --type response_complete") == true)
    }

    /// The Stop hook runs the rename check and the response-complete
    /// notification, and nothing else — no goal lookup, no state write.
    @Test func stopHookRunsOnlyTheRenameCheckAndTheNotification() async throws {
        let invocations = try await runStopHook()

        #expect(invocations == [
            "hooks stop-rename-check",
            "notify --type response_complete --message done",
            "notify-message=done",
        ])
    }

    @Test func stopHookReadsAssistantMessageFromPayloadJSON() async throws {
        let invocations = try await runStopHook(assistantMessage: "goal work finished")

        #expect(invocations.contains("notify-message=goal work finished"))
    }

    @Test func roundtripsAsValidJSON() throws {
        let data = try CodexHookOverlay.generateBody()
        _ = try JSONSerialization.jsonObject(with: data, options: [])
    }

    @Test func writePluginCreatesHooksJSONInCodexPlugin() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-hooks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        try CodexPluginWriter.writePlugin(in: codexHome)

        let path = CodexPluginWriter.pluginRoot(in: codexHome)
            .appendingPathComponent("hooks/hooks.json")
        let data = try Data(contentsOf: path)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = parsed?["hooks"] as? [String: Any]
        #expect(hooks?.keys.sorted() == ["SessionStart", "Stop"])
    }

    @Test func writePluginCreatesTBDSkillInCodexPlugin() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-skill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        try CodexPluginWriter.writePlugin(in: codexHome)

        let path = CodexPluginWriter.pluginRoot(in: codexHome)
            .appendingPathComponent("skills/tbd/SKILL.md")
        let written = try String(contentsOf: path, encoding: .utf8)
        #expect(written == TBDSkillContent.body)
    }

    @Test func ensureProfilePluginCreatesProfileAndPlugin() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let home = try CodexHomeManager(codexHome: codexHome).ensureProfilePlugin()
        let pluginRoot = CodexPluginWriter.pluginRoot(in: codexHome)

        #expect(home == codexHome)
        #expect(FileManager.default.fileExists(atPath: pluginRoot.appendingPathComponent(".codex-plugin/plugin.json").path))
        #expect(FileManager.default.fileExists(atPath: pluginRoot.appendingPathComponent("hooks/hooks.json").path))
        #expect(FileManager.default.fileExists(atPath: pluginRoot.appendingPathComponent("skills/tbd/SKILL.md").path))

        let profile = try String(
            contentsOf: codexHome.appendingPathComponent("tbd.config.toml"),
            encoding: .utf8
        )
        #expect(profile.contains(#"[plugins."tbd@tbd"]"#))
        #expect(profile.contains("enabled = true"))
    }

    @Test func ensurePluginEnabledPreservesProfileAndEnablesExistingSection() {
        let input = """
        model = "gpt-5.1"

        [plugins."tbd@tbd"]
        enabled = false
        custom = "keep"

        [tools]
        web_search = true
        """

        let output = CodexProfileWriter.ensurePluginEnabled(in: input)

        #expect(output.contains(#"model = "gpt-5.1""#))
        #expect(output.contains(#"custom = "keep""#))
        #expect(output.contains(#"[tools]"#))
        #expect(output.contains("enabled = true"))
        #expect(!output.contains("enabled = false"))
    }

    @Test func ensurePluginEnabledIsIdempotent() {
        let inputs = [
            "",
            """
            model = "gpt-5.1"

            [plugins."tbd@tbd"]
            enabled = false
            custom = "keep"

            [tools]
            web_search = true
            """,
            """
            model = "gpt-5.1"

            [plugins."tbd@tbd"]
            enabled = true

            """
        ]
        for input in inputs {
            let first = CodexProfileWriter.ensurePluginEnabled(in: input)
            let second = CodexProfileWriter.ensurePluginEnabled(in: first)
            #expect(first == second, "ensurePluginEnabled must be idempotent")
        }
    }

    @Test func ensureProfileIsIdempotentAndDoesNotRewrite() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-profile-idem-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        try CodexProfileWriter.ensureProfile(in: codexHome)
        let path = CodexProfileWriter.profilePath(in: codexHome)
        let firstContent = try String(contentsOf: path, encoding: .utf8)
        let firstModified = try FileManager.default
            .attributesOfItem(atPath: path.path)[.modificationDate] as? Date

        try CodexProfileWriter.ensureProfile(in: codexHome)
        let secondContent = try String(contentsOf: path, encoding: .utf8)
        let secondModified = try FileManager.default
            .attributesOfItem(atPath: path.path)[.modificationDate] as? Date

        #expect(firstContent == secondContent, "profile content must be byte-identical after second run")
        #expect(firstModified == secondModified, "second ensureProfile run must not rewrite the file")
    }

    @Test func ensurePluginEnabledPreservesEnabledPrefixedKeys() {
        let input = """
        [plugins."tbd@tbd"]
        enabled_features = ["x"]
        enabled = false
        """

        let output = CodexProfileWriter.ensurePluginEnabled(in: input)

        #expect(output.contains(#"enabled_features = ["x"]"#))
        #expect(output.contains("enabled = true"))
        #expect(!output.contains("enabled = false"))
    }

    /// A CRLF-terminated profile must not get a duplicate `[plugins."tbd@tbd"]`
    /// table appended: the `\r` left on each split line must be stripped so the
    /// header matcher recognizes the existing section and flips `enabled` in
    /// place. The rewrite normalizes to LF (TBD owns the section).
    @Test func ensurePluginEnabledHandlesCRLFWithoutDuplicatingSection() {
        let input = "model = \"gpt-5.1\"\r\n\r\n[plugins.\"tbd@tbd\"]\r\nenabled = false\r\n"

        let output = CodexProfileWriter.ensurePluginEnabled(in: input)

        let headerCount = output.components(separatedBy: #"[plugins."tbd@tbd"]"#).count - 1
        #expect(headerCount == 1, "exactly one [plugins.\"tbd@tbd\"] table expected, got \(headerCount)")
        #expect(output.contains("enabled = true"))
        #expect(!output.contains("enabled = false"))
        #expect(!output.contains("\r"), "output must be normalized to LF line endings")

        // Second run must be byte-identical (idempotent).
        let second = CodexProfileWriter.ensurePluginEnabled(in: output)
        #expect(second == output, "ensurePluginEnabled must be idempotent on a CRLF-sourced profile")
    }

    /// A CRLF section with a custom `enabled_features` key must survive the
    /// rewrite (the `\r` must not defeat the exact-`enabled` key matcher and
    /// clobber the prefixed key).
    @Test func ensurePluginEnabledPreservesCustomKeysFromCRLFProfile() {
        let input = "[plugins.\"tbd@tbd\"]\r\nenabled_features = [\"x\"]\r\nenabled = false\r\n"

        let output = CodexProfileWriter.ensurePluginEnabled(in: input)

        #expect(output.contains(#"enabled_features = ["x"]"#))
        #expect(output.contains("enabled = true"))
        #expect(!output.contains("enabled = false"))
        let headerCount = output.components(separatedBy: #"[plugins."tbd@tbd"]"#).count - 1
        #expect(headerCount == 1)
    }

    /// CRLF idempotency through the full `ensureProfile` file path: a CRLF
    /// `tbd.config.toml` with `enabled = false` must be rewritten to a single
    /// LF table with `enabled = true`, and a second `ensureProfile` run must
    /// leave the file byte-identical.
    @Test func ensureProfileHandlesCRLFFileIdempotently() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-crlf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)

        let path = CodexProfileWriter.profilePath(in: codexHome)
        let crlf = "model = \"gpt-5.1\"\r\n\r\n[plugins.\"tbd@tbd\"]\r\nenabled = false\r\n"
        try crlf.write(to: path, atomically: true, encoding: .utf8)

        try CodexProfileWriter.ensureProfile(in: codexHome)
        let firstContent = try String(contentsOf: path, encoding: .utf8)

        let headerCount = firstContent.components(separatedBy: #"[plugins."tbd@tbd"]"#).count - 1
        #expect(headerCount == 1, "exactly one [plugins.\"tbd@tbd\"] table after rewrite")
        #expect(firstContent.contains("enabled = true"))
        #expect(!firstContent.contains("enabled = false"))
        #expect(!firstContent.contains("\r"), "rewritten profile must use LF endings")

        try CodexProfileWriter.ensureProfile(in: codexHome)
        let secondContent = try String(contentsOf: path, encoding: .utf8)
        #expect(secondContent == firstContent, "second ensureProfile run must be byte-identical")
    }

    /// Happy-path: `ensureProfilePlugin` against a fresh writable Codex home
    /// must succeed without throwing and produce a valid profile + plugin.
    /// (The `throws` path is fatal-to-launch by design; making the home
    /// unwritable is impractical in a unit test, so this asserts the
    /// successful-setup contract instead — see code-review note.)
    @Test func ensureProfilePluginSucceedsOnWritableHome() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-writable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let home = try CodexHomeManager(codexHome: codexHome).ensureProfilePlugin()
        #expect(home == codexHome)
        #expect(FileManager.default.fileExists(
            atPath: CodexProfileWriter.profilePath(in: codexHome).path))
    }

    @Test func codexSpawnCommandUsesFileBackedProfileOverlay() {
        #expect(
            CodexSpawnCommandBuilder.profileFlag(
                codexHelpOutput: "      --profile-v2 <CONFIG_PROFILE_V2>",
                codexVersionOutput: nil
            ) == "--profile-v2"
        )
        #expect(
            CodexSpawnCommandBuilder.profileFlag(
                codexHelpOutput: "  -p, --profile <CONFIG_PROFILE_V2>",
                codexVersionOutput: nil
            ) == "--profile"
        )
    }
}
