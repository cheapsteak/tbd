import Foundation
import Testing
import TBDShared
@testable import TBDDaemonLib

@Suite struct CodexHookOverlayTests {

    @Test func generateBodyHasExpectedShape() throws {
        let data = try CodexHookOverlay.generateBody()
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = parsed?["hooks"] as? [String: Any]
        #expect(hooks != nil)

        let sessionStart = hooks?["SessionStart"] as? [[String: Any]]
        #expect(sessionStart?.first?["matcher"] as? String == "startup|resume|clear")
        let sessionHooks = sessionStart?.first?["hooks"] as? [[String: Any]]
        let sessionCommand = sessionHooks?.first?["command"] as? String
        #expect(sessionCommand?.contains("tbd session-event") == true)

        let stop = hooks?["Stop"] as? [[String: Any]]
        #expect(stop?.count == 1)
        let stopHooks = stop?.first?["hooks"] as? [[String: Any]]
        #expect(stopHooks?.count == 1)
        let stopCommand = stopHooks?.first?["command"] as? String
        #expect(stopCommand?.contains("tbd hooks stop-rename-check") == true)
        #expect(stopCommand?.contains("tbd notify --type response_complete") == true)
        #expect(stopCommand?.contains("last_assistant_message") == true)
    }

    @Test func stopHookRunsRenameCheckBeforeResponseComplete() throws {
        let data = try CodexHookOverlay.generateBody()
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = parsed?["hooks"] as? [String: Any]
        let stop = hooks?["Stop"] as? [[String: Any]]
        let stopHooks = stop?.first?["hooks"] as? [[String: Any]]
        let stopCommand = stopHooks?.first?["command"] as? String

        let renameIndex = stopCommand?.range(of: "tbd hooks stop-rename-check")?.lowerBound
        let notifyIndex = stopCommand?.range(of: "tbd notify --type response_complete")?.lowerBound

        #expect(renameIndex != nil)
        #expect(notifyIndex != nil)
        if let renameIndex, let notifyIndex {
            #expect(renameIndex < notifyIndex)
        }
        #expect(stopCommand?.contains("if [ -n \"$RENAME_RESULT\" ]") == true)
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
        #expect(hooks?["SessionStart"] != nil)
        #expect(hooks?["Stop"] != nil)
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
