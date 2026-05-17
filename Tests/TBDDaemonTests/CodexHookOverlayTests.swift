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
        #expect(stop?.count == 2)
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

    @Test func writeOverlayCreatesHooksJSONInCodexHome() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-hooks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        #expect(CodexHookOverlay.writeOverlay(in: codexHome))

        let path = codexHome.appendingPathComponent("hooks.json")
        let data = try Data(contentsOf: path)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = parsed?["hooks"] as? [String: Any]
        #expect(hooks?["SessionStart"] != nil)
        #expect(hooks?["Stop"] != nil)
    }

    @Test func writeSkillCreatesTBDSkillInCodexHome() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-skill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        #expect(CodexSkillWriter.writeSkill(in: codexHome))

        let path = codexHome.appendingPathComponent("skills/tbd/SKILL.md")
        let written = try String(contentsOf: path, encoding: .utf8)
        #expect(written == TBDSkillContent.body)
    }

    @Test func ensureHomeWithHooksCreatesHooksAndSkill() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let repoID = UUID()
        let home = try CodexHomeManager(baseDirectory: base)
            .ensureHomeWithHooks(forRepoID: repoID)

        #expect(home == base.appendingPathComponent(repoID.uuidString.lowercased(), isDirectory: true))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("hooks.json").path))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("skills/tbd/SKILL.md").path))
    }
}
