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

        let manifestPath = tempRoot + "/TBD/plugin/.claude-plugin/plugin.json"
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

        let data = try Data(contentsOf: URL(fileURLWithPath: tempRoot + "/TBD/plugin/.claude-plugin/plugin.json"))
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

    @Test("bundles the nightwatch skill — SKILL.md, executable tick.py, configs")
    func writesNightwatchSkill() throws {
        let tempRoot = NSTemporaryDirectory() + "tbd-plugin-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }

        try PluginDirWriter(applicationSupportRoot: tempRoot).writePlugin()

        let nw = tempRoot + "/TBD/plugin/skills/nightwatch"
        let tick = nw + "/scripts/tick.py"
        #expect(FileManager.default.fileExists(atPath: nw + "/SKILL.md"))
        #expect(FileManager.default.fileExists(atPath: tick))
        #expect(FileManager.default.fileExists(atPath: nw + "/scripts/wake.py"))
        #expect(FileManager.default.fileExists(atPath: nw + "/scripts/judge.py"))
        #expect(FileManager.default.fileExists(atPath: nw + "/scripts/scheduler.sh"))
        #expect(FileManager.default.fileExists(atPath: nw + "/scripts/tick-cron.sh"))
        #expect(FileManager.default.fileExists(atPath: nw + "/config/priorities.txt"))
        #expect(FileManager.default.fileExists(atPath: nw + "/config/safe_wedges.txt"))
        #expect(FileManager.default.fileExists(atPath: nw + "/config/dont_touch.txt"))

        // content matches the single source of truth
        let writtenTick = try String(contentsOfFile: tick, encoding: .utf8)
        #expect(writtenTick == NightwatchSkillContent.tickPy)

        // tick.py is executable (cron/launchd run it directly)
        let perms = try FileManager.default.attributesOfItem(atPath: tick)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value ?? 0 & 0o111 != 0)
    }

    @Test("nightwatch SKILL.md has a valid skill name in frontmatter")
    func nightwatchSkillNamed() {
        #expect(NightwatchSkillContent.skillMd.contains("name: nightwatch"))
    }

    @Test("pluginDirPath has expected shape")
    func pluginDirPathShape() {
        let writer = PluginDirWriter(applicationSupportRoot: "/var/test")
        #expect(writer.pluginDirPath() == "/var/test/TBD/plugin")
    }

    @Test("static pluginDirPath matches default-init instance")
    func staticPluginDirPathMatchesDefaultInstance() {
        // Guards against drift between the static `let` (used by spawn callers)
        // and the instance `pluginDirPath()` (used by tests + writePlugin) — both
        // must resolve to the same path for the production root.
        let defaultInstance = PluginDirWriter()
        #expect(PluginDirWriter.pluginDirPath == defaultInstance.pluginDirPath())
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
