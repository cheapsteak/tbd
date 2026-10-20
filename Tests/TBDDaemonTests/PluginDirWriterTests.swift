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
        try writer.writePlugin(sessionModFeatures: [])

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
        try writer.writePlugin(sessionModFeatures: [])

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
        try writer.writePlugin(sessionModFeatures: [])

        let written = try String(contentsOfFile: tempRoot + "/TBD/plugin/skills/tbd/SKILL.md", encoding: .utf8)
        #expect(written == TBDSkillContent.body)
    }

    @Test("writePlugin is idempotent — repeated calls succeed and do not duplicate")
    func idempotent() throws {
        let tempRoot = NSTemporaryDirectory() + "tbd-plugin-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }

        let writer = PluginDirWriter(applicationSupportRoot: tempRoot)
        for features in [[], [SessionModFeature.composerDraft]] {
            try writer.writePlugin(sessionModFeatures: features)
            try writer.writePlugin(sessionModFeatures: features)  // must not throw
        }

        let written = try String(contentsOfFile: tempRoot + "/TBD/plugin/skills/tbd/SKILL.md", encoding: .utf8)
        #expect(written == TBDSkillContent.body)
    }

    @Test("bundles the nightwatch skill — SKILL.md, executable tick.py, configs")
    func writesNightwatchSkill() throws {
        let tempRoot = NSTemporaryDirectory() + "tbd-plugin-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }

        try PluginDirWriter(applicationSupportRoot: tempRoot).writePlugin(sessionModFeatures: [])

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

    @Test("wake.py --selftest passes: classification fail-closed matrix (no git/gh/sqlite invoked)")
    func wakePySelftest() throws {
        let tempRoot = NSTemporaryDirectory() + "tbd-plugin-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        try PluginDirWriter(applicationSupportRoot: tempRoot).writePlugin(sessionModFeatures: [])

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", tempRoot + "/TBD/plugin/skills/nightwatch/scripts/wake.py", "--selftest"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(proc.terminationStatus == 0, "wake.py --selftest failed:\n\(output)")
        #expect(output.contains("scenarios passed"))
    }

    /// Executable coverage for the composer ghost-guard, which sits on the path
    /// that types text into live tmux panes across the fleet. String-presence
    /// assertions on `tickPy` (in TBDSharedTests) prove the guard is *shipped*;
    /// only running it proves the guard *works* — a regex or an index-alignment
    /// edit could leave every pinned substring intact and still fire ghost
    /// suggestions as if a human had typed them.
    ///
    /// `--selftest` short-circuits before tick.py's machine-global flock, so a
    /// live tick running concurrently can't turn this into a silent exit 0.
    /// The `scenarios passed` assertion is the backstop for that regardless.
    @Test("tick.py --selftest passes: agent-state matrix (no DB/tmux invoked)")
    func tickPySelftest() throws {
        let tempRoot = NSTemporaryDirectory() + "tbd-plugin-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        try PluginDirWriter(applicationSupportRoot: tempRoot).writePlugin(sessionModFeatures: [])

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", tempRoot + "/TBD/plugin/skills/nightwatch/scripts/tick.py", "--selftest"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(proc.terminationStatus == 0, "tick.py --selftest failed:\n\(output)")
        #expect(output.contains("agent-state scenarios passed"), "unexpected output:\n\(output)")
    }

    /// The relay decides whether a desk shift survives its context ceiling, so
    /// its arithmetic and its fail-closed paths get executable coverage rather
    /// than string-presence checks — same standard as `tick.py`/`wake.py`.
    @Test("handoff.py --selftest passes: ceiling arithmetic + fail-closed paths")
    func handoffPySelftest() throws {
        let tempRoot = NSTemporaryDirectory() + "tbd-plugin-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        try PluginDirWriter(applicationSupportRoot: tempRoot).writePlugin(sessionModFeatures: [])

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", tempRoot + "/TBD/plugin/skills/nightwatch/scripts/handoff.py", "--selftest"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(proc.terminationStatus == 0, "handoff.py --selftest failed:\n\(output)")
        #expect(output.contains("handoff ceiling scenarios passed"), "unexpected output:\n\(output)")
    }

    @Test("handoff.py is installed alongside the other nightwatch scripts")
    func handoffPyInstalled() throws {
        let tempRoot = NSTemporaryDirectory() + "tbd-plugin-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        try PluginDirWriter(applicationSupportRoot: tempRoot).writePlugin(sessionModFeatures: [])

        let scripts = tempRoot + "/TBD/plugin/skills/nightwatch/scripts"
        for entry in NightwatchSkillContent.scripts {
            let path = scripts + "/" + entry.name
            #expect(FileManager.default.fileExists(atPath: path), "\(entry.name) not installed")
            #expect(try String(contentsOfFile: path, encoding: .utf8) == entry.body)
        }
        #expect(FileManager.default.fileExists(atPath: scripts + "/handoff.py"))
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

    @Test("overwrites stale skill body on update, and only that file")
    func overwritesStaleBody() throws {
        let tempRoot = NSTemporaryDirectory() + "tbd-plugin-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let writer = PluginDirWriter(applicationSupportRoot: tempRoot)
        try writer.writePlugin(sessionModFeatures: [])
        let dir = tempRoot + "/TBD/plugin/skills/tbd"
        try "stale".write(toFile: dir + "/SKILL.md", atomically: true, encoding: .utf8)

        #expect(try writer.writePlugin(sessionModFeatures: []) == 1)

        let written = try String(contentsOfFile: dir + "/SKILL.md", encoding: .utf8)
        #expect(written == TBDSkillContent.body)
    }

    // MARK: - Session mod presence (docs/specs/2026-10-19-tbd-session-mod-design.md, "Presence")

    private static func makeTempRoot() -> String {
        NSTemporaryDirectory() + "tbd-plugin-test-\(UUID().uuidString)"
    }

    private static func manifest(in pluginDir: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: pluginDir + "/.claude-plugin/plugin.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Each file under `dir`, by relative path, with its inode and mode. An
    /// atomic write replaces the inode, so an unchanged snapshot means no file
    /// was rewritten, whatever `writePlugin` returned.
    private static func snapshot(_ dir: String) throws -> [String: [Int]] {
        let fm = FileManager.default
        var result: [String: [Int]] = [:]
        let enumerator = try #require(fm.enumerator(atPath: dir))
        while let relative = enumerator.nextObject() as? String {
            let attributes = try fm.attributesOfItem(atPath: dir + "/" + relative)
            result[relative] = [
                (attributes[.systemFileNumber] as? NSNumber)?.intValue ?? -1,
                (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            ]
        }
        return result
    }

    @Test func hooksPresentWhenAFeatureIsOn() throws {
        let tempRoot = Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let writer = PluginDirWriter(applicationSupportRoot: tempRoot)

        try writer.writePlugin(sessionModFeatures: [.composerDraft])

        let pluginDir = writer.pluginDirPath()
        #expect(!SessionModContent.files.isEmpty)
        for file in SessionModContent.files {
            let written = try? String(contentsOfFile: pluginDir + "/" + file.path, encoding: .utf8)
            #expect(written == file.body, "\(file.path) missing or wrong")
            // Turning every feature off removes these folders wholesale, so a
            // file outside them would outlive the mod.
            #expect(PluginDirWriter.sessionModDirectories.contains(where: { file.path.hasPrefix($0 + "/") }),
                    "\(file.path) is outside the folders the writer removes")
        }
        let types = try #require(try Self.manifest(in: pluginDir)["types"] as? String)
        #expect(types == PluginDirWriter.sessionModTypesPath)
        #expect(FileManager.default.fileExists(atPath: pluginDir + "/" + types),
                "the manifest's types entry names a file the writer did not write")
        #expect(FileManager.default.fileExists(atPath: pluginDir + "/skills/tbd/SKILL.md"))
    }

    @Test func hooksAbsentWhenEveryFeatureIsOff() throws {
        let tempRoot = Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let writer = PluginDirWriter(applicationSupportRoot: tempRoot)

        try writer.writePlugin(sessionModFeatures: [])

        let pluginDir = writer.pluginDirPath()
        #expect(!FileManager.default.fileExists(atPath: pluginDir + "/hooks"))
        #expect(!FileManager.default.fileExists(atPath: pluginDir + "/types"))
        let manifest = try Self.manifest(in: pluginDir)
        #expect(!manifest.keys.contains("types"))
        #expect(manifest["name"] as? String == "tbd")
        #expect(FileManager.default.fileExists(atPath: pluginDir + "/skills/tbd/SKILL.md"))
    }

    @Test func turningTheLastFeatureOffRemovesHooks() throws {
        let tempRoot = Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let writer = PluginDirWriter(applicationSupportRoot: tempRoot)
        let pluginDir = writer.pluginDirPath()
        try writer.writePlugin(sessionModFeatures: [.composerDraft])
        #expect(FileManager.default.fileExists(atPath: pluginDir + "/hooks/hooks.json"))

        let changed = try writer.writePlugin(sessionModFeatures: [])

        // Every session-mod file goes, plus the manifest losing `types`.
        #expect(changed == SessionModContent.files.count + 1)
        #expect(!FileManager.default.fileExists(atPath: pluginDir + "/hooks"))
        #expect(!FileManager.default.fileExists(atPath: pluginDir + "/types"))
        #expect(try !Self.manifest(in: pluginDir).keys.contains("types"))
        #expect(try String(contentsOfFile: pluginDir + "/skills/tbd/SKILL.md", encoding: .utf8)
                == TBDSkillContent.body)
    }

    @Test(arguments: [[SessionModFeature](), [.composerDraft]])
    func unchangedSecondWriteWritesNothing(features: [SessionModFeature]) throws {
        let tempRoot = Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let writer = PluginDirWriter(applicationSupportRoot: tempRoot)
        #expect(try writer.writePlugin(sessionModFeatures: features) > 0)
        let before = try Self.snapshot(writer.pluginDirPath())

        #expect(try writer.writePlugin(sessionModFeatures: features) == 0)

        #expect(try Self.snapshot(writer.pluginDirPath()) == before)
    }

    @Test func manifestBytesAreDeterministic() throws {
        for enabled in [false, true] {
            #expect(try PluginDirWriter.manifestData(sessionModEnabled: enabled)
                    == PluginDirWriter.manifestData(sessionModEnabled: enabled))
        }
        #expect(try PluginDirWriter.manifestData(sessionModEnabled: true)
                != PluginDirWriter.manifestData(sessionModEnabled: false))
    }

    @Test func aStaleHooksFileIsRemoved() throws {
        let tempRoot = Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let writer = PluginDirWriter(applicationSupportRoot: tempRoot)
        let pluginDir = writer.pluginDirPath()
        try writer.writePlugin(sessionModFeatures: [.composerDraft])
        let stale = pluginDir + "/hooks/features/retired-feature.tsx"
        try "export const FEATURE = 'retired'".write(toFile: stale, atomically: true, encoding: .utf8)

        #expect(try writer.writePlugin(sessionModFeatures: [.composerDraft]) == 1)

        #expect(!FileManager.default.fileExists(atPath: stale))
        for file in SessionModContent.files {
            #expect(FileManager.default.fileExists(atPath: pluginDir + "/" + file.path))
        }
    }

    @Test func aScriptWithTheWrongModeIsChmodded() throws {
        let tempRoot = Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let writer = PluginDirWriter(applicationSupportRoot: tempRoot)
        try writer.writePlugin(sessionModFeatures: [])
        let tick = writer.pluginDirPath() + "/skills/nightwatch/scripts/tick.py"
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tick)

        #expect(try writer.writePlugin(sessionModFeatures: []) == 1)

        let mode = try FileManager.default.attributesOfItem(atPath: tick)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o755)
    }

    @Test func engineTypesAndSkillRuntimeFoldersSurvive() throws {
        let tempRoot = Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let writer = PluginDirWriter(applicationSupportRoot: tempRoot)
        let pluginDir = writer.pluginDirPath()
        let fm = FileManager.default
        let engineTypes = pluginDir + "/.claude-plugin/types/claude-code/index.d.ts"
        let skillRuntime = pluginDir + "/skills/tbd/runtime/x"
        for path in [engineTypes, skillRuntime] {
            try fm.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try "kept".write(toFile: path, atomically: true, encoding: .utf8)
        }

        try writer.writePlugin(sessionModFeatures: [.composerDraft])
        try writer.writePlugin(sessionModFeatures: [])

        for path in [engineTypes, skillRuntime] {
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "kept", "\(path) was touched")
        }
    }
}
