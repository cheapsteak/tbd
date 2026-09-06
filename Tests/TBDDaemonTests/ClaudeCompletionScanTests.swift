import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// The degraded answer: when the probe fails or times out, the same directories
/// are read directly. It lists everything except built-ins, because only the
/// binary knows those — and the app renders it identically, which is the whole
/// point of returning one shape.
///
/// Tier 2: a real temp directory tree, no process, no `~`.
@Suite("ClaudeCompletionScan")
struct ClaudeCompletionScanTests {
    private let fm = FileManager.default

    // MARK: - Frontmatter

    @Test func itReadsTheThreeFieldsItNeeds() {
        let text = """
            ---
            name: code-review
            description: Review the current diff for correctness bugs
            argument-hint: "[low|medium|high]"
            ---

            # Body that must not be read
            """
        let parsed = ClaudeCompletionScan.parseFrontmatter(text)
        #expect(parsed.name == "code-review")
        #expect(parsed.description == "Review the current diff for correctness bugs")
        #expect(parsed.argumentHint == "[low|medium|high]")
    }

    @Test func aFileWithNoFrontmatterYieldsNothing() {
        #expect(ClaudeCompletionScan.parseFrontmatter("# just a heading")
            == ClaudeCompletionScan.Frontmatter())
    }

    /// Descriptions routinely wrap and quote. Both spellings must survive.
    @Test func itStripsQuotesAndTrims() {
        let text = """
            ---
            description:   'Use when the user asks about X'
            argument-hint: "<path>"
            ---
            """
        let parsed = ClaudeCompletionScan.parseFrontmatter(text)
        #expect(parsed.description == "Use when the user asks about X")
        #expect(parsed.argumentHint == "<path>")
    }

    // MARK: - Plugin enablement

    /// The manifest's real shape: a `plugins` map keyed by the full
    /// `name@marketplace` string, each value an array of install records.
    @Test func onlyEnabledInstalledPluginsCount() {
        let settings = Data(#"{"enabledPlugins":{"alpha@market":true,"beta@market":false}}"#.utf8)
        let installed = Data("""
            {"version":2,"plugins":{
              "alpha@market":[{"installPath":"/tmp/a","version":"1.0"}],
              "beta@market":[{"installPath":"/tmp/b","version":"1.0"}],
              "gamma@market":[{"installPath":"/tmp/g","version":"1.0"}]}}
            """.utf8)
        let enabled = ClaudeCompletionScan.enabledPlugins(
            settingsJSON: settings, installedPluginsJSON: installed)
        #expect(enabled == ["alpha@market"])
    }

    @Test func missingFilesEnableNothing() {
        #expect(ClaudeCompletionScan.enabledPlugins(
            settingsJSON: nil, installedPluginsJSON: nil).isEmpty)
    }

    /// Each key's value is an array; the newest install is the last record, and
    /// a record with no `installPath` names no tree to read.
    @Test func rootsTakeTheNewestRecordAndSkipPathlessOnes() {
        let installed = Data("""
            {"version":2,"plugins":{
              "alpha@market":[
                {"installPath":"/tmp/alpha-old","version":"1.0"},
                {"installPath":"/tmp/alpha-new","version":"2.0"}],
              "beta@market":[{"version":"1.0"}],
              "gamma@market":[]}}
            """.utf8)
        let roots = ClaudeCompletionScan.installedPluginRoots(installedPluginsJSON: installed)
        #expect(roots["alpha@market"] == "/tmp/alpha-new")
        #expect(roots["beta@market"] == nil)
        #expect(roots["gamma@market"] == nil)
    }

    // MARK: - The scan

    @Test func itFindsCommandsSkillsAndAgentsInBothTrees() throws {
        let root = try makeTree()
        defer { try? fm.removeItem(at: root) }

        let result = ClaudeCompletionScan.scan(
            configDir: root.appendingPathComponent("cfg").path,
            worktreePath: root.appendingPathComponent("wt").path)

        let names = Set(result.commands.map(\.name))
        #expect(names.contains("user-cmd"))
        #expect(names.contains("user-skill"))
        #expect(names.contains("project-cmd"))
        #expect(result.agents.map(\.name).contains("scout"))
    }

    /// A disabled plugin's commands must not be offered: typing one costs an
    /// "unknown command" reply from a plugin that is not loaded.
    @Test func aDisabledPluginContributesNothing() throws {
        let root = try makeTree()
        defer { try? fm.removeItem(at: root) }

        // The fixture really does write beta's command to disk, so the absence
        // below is enablement filtering and not a missing file.
        #expect(fm.fileExists(atPath: root.appendingPathComponent(
            "cfg/plugins/cache/market/beta/1.0/commands/disabled-cmd.md").path))

        let result = ClaudeCompletionScan.scan(
            configDir: root.appendingPathComponent("cfg").path,
            worktreePath: root.appendingPathComponent("wt").path)

        let names = Set(result.commands.map(\.name))
        #expect(names.contains("alpha:enabled-cmd"))
        #expect(!names.contains("beta:disabled-cmd"),
                "a disabled plugin's commands must not be offered: \(names.sorted())")
    }

    @Test func anEmptyTreeYieldsAnEmptyInventory() throws {
        let root = fm.temporaryDirectory
            .appendingPathComponent("tbd-scan-empty-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let result = ClaudeCompletionScan.scan(
            configDir: root.appendingPathComponent("nope").path,
            worktreePath: root.appendingPathComponent("also-nope").path)
        #expect(result.commands.isEmpty)
        #expect(result.agents.isEmpty)
    }

    // MARK: - Fixture tree

    private func write(_ url: URL, _ contents: String) throws {
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func makeTree() throws -> URL {
        let root = fm.temporaryDirectory
            .appendingPathComponent("tbd-scan-\(UUID().uuidString.prefix(8))")
        let cfg = root.appendingPathComponent("cfg")
        let wt = root.appendingPathComponent("wt")

        try write(cfg.appendingPathComponent("commands/user-cmd.md"), """
            ---
            description: A user command
            argument-hint: "<thing>"
            ---
            """)
        try write(cfg.appendingPathComponent("skills/user-skill/SKILL.md"), """
            ---
            name: user-skill
            description: A user skill
            ---
            """)
        try write(cfg.appendingPathComponent("agents/scout.md"), """
            ---
            name: scout
            description: A subagent
            ---
            """)
        try write(wt.appendingPathComponent(".claude/commands/project-cmd.md"), """
            ---
            description: A project command
            ---
            """)

        // The real manifest shape: `plugins` keyed by `name@marketplace`, each
        // value an array of install records whose `installPath` is absolute.
        let alphaRoot = cfg.appendingPathComponent("plugins/cache/market/alpha/1.0")
        let betaRoot = cfg.appendingPathComponent("plugins/cache/market/beta/1.0")
        try write(cfg.appendingPathComponent("plugins/installed_plugins.json"), """
            {"version":2,"plugins":{
              "alpha@market":[{"scope":"user","installPath":"\(alphaRoot.path)","version":"1.0"}],
              "beta@market":[{"scope":"user","installPath":"\(betaRoot.path)","version":"1.0"}]}}
            """)
        try write(cfg.appendingPathComponent("settings.json"), """
            {"enabledPlugins":{"alpha@market":true,"beta@market":false}}
            """)
        try write(alphaRoot.appendingPathComponent("commands/enabled-cmd.md"), """
            ---
            description: From the enabled plugin
            ---
            """)
        try write(betaRoot.appendingPathComponent("commands/disabled-cmd.md"), """
            ---
            description: From the disabled plugin
            ---
            """)
        return root
    }
}
