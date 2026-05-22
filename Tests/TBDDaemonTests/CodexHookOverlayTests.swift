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
        let stopCommands: [String] = (stop ?? []).flatMap { entry -> [String] in
            let inner = entry["hooks"] as? [[String: Any]] ?? []
            return inner.compactMap { $0["command"] as? String }
        }
        #expect(stopCommands.contains {
            $0.contains("tbd notify --type response_complete")
                && $0.contains("last_assistant_message")
        })
        #expect(stopCommands.contains { $0.contains("stop-rename-check") })
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
}
