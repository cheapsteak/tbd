import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("PluginDirWriter")
struct PluginDirWriterTests {

    @Test("writePlugin lays out plugin.json and skills/tbd/SKILL.md")
    func writesPluginLayout() throws {
        let tempRoot = NSTemporaryDirectory() + "tbd-plugin-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }

        let writer = PluginDirWriter(applicationSupportRoot: tempRoot)
        try writer.writePlugin()

        let manifestPath = tempRoot + "/TBD/plugin/plugin.json"
        let skillPath = tempRoot + "/TBD/plugin/skills/tbd/SKILL.md"

        #expect(FileManager.default.fileExists(atPath: manifestPath))
        #expect(FileManager.default.fileExists(atPath: skillPath))
    }

    @Test("plugin.json contains name, version, description")
    func manifestShape() throws {
        let tempRoot = NSTemporaryDirectory() + "tbd-plugin-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }

        let writer = PluginDirWriter(applicationSupportRoot: tempRoot)
        try writer.writePlugin()

        let data = try Data(contentsOf: URL(fileURLWithPath: tempRoot + "/TBD/plugin/plugin.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["name"] as? String == "tbd")
        #expect(json?["version"] as? String == TBDConstants.version)
        #expect((json?["description"] as? String)?.isEmpty == false)
    }

    @Test("skill body matches TBDSkillContent.body")
    func skillBodyMatchesSource() throws {
        let tempRoot = NSTemporaryDirectory() + "tbd-plugin-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }

        let writer = PluginDirWriter(applicationSupportRoot: tempRoot)
        try writer.writePlugin()

        let written = try String(contentsOfFile: tempRoot + "/TBD/plugin/skills/tbd/SKILL.md", encoding: .utf8)
        #expect(written == TBDSkillContent.body)
    }

    @Test("writePlugin is idempotent — repeated calls succeed and do not duplicate")
    func idempotent() throws {
        let tempRoot = NSTemporaryDirectory() + "tbd-plugin-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }

        let writer = PluginDirWriter(applicationSupportRoot: tempRoot)
        try writer.writePlugin()
        try writer.writePlugin()  // must not throw

        let written = try String(contentsOfFile: tempRoot + "/TBD/plugin/skills/tbd/SKILL.md", encoding: .utf8)
        #expect(written == TBDSkillContent.body)
    }

    @Test("pluginDirPath has expected shape")
    func pluginDirPathShape() {
        let writer = PluginDirWriter(applicationSupportRoot: "/var/test")
        #expect(writer.pluginDirPath() == "/var/test/TBD/plugin")
    }

    @Test("overwrites stale skill body on update")
    func overwritesStaleBody() throws {
        let tempRoot = NSTemporaryDirectory() + "tbd-plugin-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let dir = tempRoot + "/TBD/plugin/skills/tbd"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "stale".write(toFile: dir + "/SKILL.md", atomically: true, encoding: .utf8)

        try PluginDirWriter(applicationSupportRoot: tempRoot).writePlugin()

        let written = try String(contentsOfFile: dir + "/SKILL.md", encoding: .utf8)
        #expect(written == TBDSkillContent.body)
    }
}
