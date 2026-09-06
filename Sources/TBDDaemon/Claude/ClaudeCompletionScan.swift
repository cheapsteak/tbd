import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "completions.scan")

/// The degraded answer when the probe fails or times out: read the same
/// directories the probe's binary would have read.
///
/// It lists everything except built-ins, because only the running program knows
/// those. The caller marks the result `.fallback` / `.scan`; the app renders it
/// identically, which is why there is one result shape and not two.
///
/// **A best-effort reader, never a validator.** A file it cannot parse
/// contributes nothing and stops nothing — the whole point of this path is that
/// it answers when the authoritative source did not.
///
/// **Reconciler note.** This creates nothing durable: it opens files for reading
/// and spawns no process, so there is no orphan for a sweep to reclaim.
enum ClaudeCompletionScan {

    /// The three frontmatter fields a completion row needs.
    struct Frontmatter: Equatable, Sendable {
        var name: String?
        var description: String?
        var argumentHint: String?
    }

    /// Read a markdown file's leading YAML frontmatter block.
    ///
    /// Deliberately a line scanner over three known keys rather than a YAML
    /// parser: the fields are single-line scalars in every file Claude Code
    /// ships or accepts, and pulling in a parser to read three strings would
    /// widen the failure surface of a fallback path whose whole job is to
    /// degrade gracefully. A multi-line or block scalar simply yields nil for
    /// that field.
    static func parseFrontmatter(_ text: String) -> Frontmatter {
        var result = Frontmatter()
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---" else { return result }
        lines.removeFirst()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[trimmed.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let rawValue = trimmed[trimmed.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            let value = unquote(rawValue)
            guard !value.isEmpty else { continue }
            switch key {
            case "name": result.name = value
            case "description": result.description = value
            case "argument-hint", "argumentHint": result.argumentHint = value
            default: continue
            }
        }
        return result
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let first = value.first, last = value.last
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Which plugins are both installed and enabled, as the full
    /// `name@marketplace` keys both files agree on.
    ///
    /// Two files answer half the question each: `settings.json`'s `enabledPlugins`
    /// says which entries the user turned on, and `plugins/installed_plugins.json`
    /// says which are actually present. A plugin enabled but not installed
    /// contributes nothing, and one installed but not enabled must contribute
    /// nothing — offering its commands costs an "unknown command" reply from a
    /// plugin that is not loaded.
    ///
    /// Both files key by the whole `name@marketplace` string, so the key is
    /// carried around whole and only split when a display prefix is needed; two
    /// marketplaces may ship a plugin of the same name. A bare key with no `@` is
    /// taken as written. An unreadable manifest is not treated as "nothing is
    /// installed": enablement alone then decides, and `installedPluginRoots`
    /// finds no tree to read, so the scan still contributes nothing.
    static func enabledPlugins(settingsJSON: Data?, installedPluginsJSON: Data?) -> Set<String> {
        guard let settingsJSON,
              let settings = try? JSONSerialization.jsonObject(with: settingsJSON)
                as? [String: Any],
              let enabled = settings["enabledPlugins"] as? [String: Any]
        else { return [] }

        var installed: Set<String> = []
        if let installedPluginsJSON,
           let manifest = try? JSONSerialization.jsonObject(with: installedPluginsJSON)
            as? [String: Any],
           let plugins = manifest["plugins"] as? [String: Any] {
            installed.formUnion(plugins.keys)
        }

        var result: Set<String> = []
        for (key, value) in enabled where (value as? Bool) == true {
            guard installed.isEmpty || installed.contains(key) else { continue }
            result.insert(key)
        }
        return result
    }

    /// Where each installed plugin's tree lives, keyed by `name@marketplace`.
    ///
    /// The manifest records an absolute `installPath` per install rather than a
    /// path the reader can compose, so the tree is looked up and never guessed.
    /// Each key holds an array — one record per install of that plugin — and the
    /// last is the newest, which is the one a session loads. A record without a
    /// path names no tree and is skipped.
    static func installedPluginRoots(installedPluginsJSON: Data?) -> [String: String] {
        guard let installedPluginsJSON,
              let manifest = try? JSONSerialization.jsonObject(with: installedPluginsJSON)
                as? [String: Any],
              let plugins = manifest["plugins"] as? [String: Any]
        else { return [:] }

        var roots: [String: String] = [:]
        for (key, value) in plugins {
            guard let records = value as? [[String: Any]] else { continue }
            guard let path = records.reversed().lazy
                .compactMap({ $0["installPath"] as? String })
                .first(where: { !$0.isEmpty })
            else { continue }
            roots[key] = path
        }
        return roots
    }

    /// Scan a profile config directory and a worktree for completable items.
    static func scan(
        configDir: String, worktreePath: String
    ) -> (commands: [CompletionCommand], agents: [CompletionAgent]) {
        let config = URL(fileURLWithPath: configDir, isDirectory: true)
        let project = URL(fileURLWithPath: worktreePath, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)

        var commands: [CompletionCommand] = []
        var agents: [CompletionAgent] = []

        for root in [config, project] {
            commands += commandsInDirectory(root.appendingPathComponent("commands"), prefix: nil)
            commands += skillsInDirectory(root.appendingPathComponent("skills"), prefix: nil)
            agents += agentsInDirectory(root.appendingPathComponent("agents"))
        }

        let installedJSON = try? Data(
            contentsOf: config.appendingPathComponent("plugins/installed_plugins.json"))
        let enabled = enabledPlugins(
            settingsJSON: try? Data(contentsOf: config.appendingPathComponent("settings.json")),
            installedPluginsJSON: installedJSON)
        if !enabled.isEmpty {
            let roots = installedPluginRoots(installedPluginsJSON: installedJSON)
            for key in enabled.sorted() {
                guard let path = roots[key] else {
                    logger.debug(
                        "enabled plugin has no install path: \(key, privacy: .public)")
                    continue
                }
                // Items are namespaced by the plugin's name, which is what the
                // user types — the marketplace half of the key never appears.
                let prefix = key.split(separator: "@").first.map(String.init) ?? key
                let root = URL(fileURLWithPath: path, isDirectory: true)
                commands += commandsInDirectory(
                    root.appendingPathComponent("commands"), prefix: prefix)
                commands += skillsInDirectory(
                    root.appendingPathComponent("skills"), prefix: prefix)
                agents += agentsInDirectory(root.appendingPathComponent("agents"))
            }
        }

        // Last writer wins on a duplicate name, matching what the binary does
        // when a project command shadows a user one.
        var seen: [String: CompletionCommand] = [:]
        for command in commands { seen[command.name] = command }
        var seenAgents: [String: CompletionAgent] = [:]
        for agent in agents { seenAgents[agent.name] = agent }
        return (
            seen.values.sorted { $0.name < $1.name },
            seenAgents.values.sorted { $0.name < $1.name })
    }

    // MARK: - Directory readers

    private static func subdirectories(of url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    }

    private static func markdownFiles(in url: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }
    }

    private static func qualify(_ name: String, prefix: String?) -> String {
        guard let prefix, !prefix.isEmpty else { return name }
        return "\(prefix):\(name)"
    }

    private static func commandsInDirectory(_ url: URL, prefix: String?) -> [CompletionCommand] {
        markdownFiles(in: url).compactMap { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let front = parseFrontmatter(text)
            let name = front.name ?? file.deletingPathExtension().lastPathComponent
            guard !name.isEmpty else { return nil }
            return CompletionCommand(
                name: qualify(name, prefix: prefix),
                description: front.description ?? "",
                argumentHint: front.argumentHint)
        }
    }

    /// A skill is a directory holding `SKILL.md`; its name is the directory's,
    /// unless the frontmatter says otherwise.
    private static func skillsInDirectory(_ url: URL, prefix: String?) -> [CompletionCommand] {
        subdirectories(of: url).compactMap { dir in
            let skill = dir.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: skill, encoding: .utf8) else { return nil }
            let front = parseFrontmatter(text)
            let name = front.name ?? dir.lastPathComponent
            guard !name.isEmpty else { return nil }
            return CompletionCommand(
                name: qualify(name, prefix: prefix),
                description: front.description ?? "",
                argumentHint: front.argumentHint)
        }
    }

    private static func agentsInDirectory(_ url: URL) -> [CompletionAgent] {
        markdownFiles(in: url).compactMap { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let front = parseFrontmatter(text)
            let name = front.name ?? file.deletingPathExtension().lastPathComponent
            guard !name.isEmpty else { return nil }
            return CompletionAgent(name: name, description: front.description ?? "")
        }
    }
}
