import ArgumentParser
import Foundation
import TBDShared

/// Top-level `tbd hooks` group. Today exposes only `status`; over time
/// other subcommands (e.g. `regenerate`, `clean-repo`) can land here.
struct HooksCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hooks",
        abstract: "Inspect and manage TBD's Claude Code hook integration",
        subcommands: [HooksStatusCommand.self],
        defaultSubcommand: HooksStatusCommand.self
    )
}

/// Prints the overlay path, active entries (parsed from the overlay file),
/// and any legacy entries the daemon detects in ~/.claude/settings.json or
/// per-repo settings files. Useful for users to verify state without
/// inspecting JSON manually.
struct HooksStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show TBD's Claude hook overlay state and any legacy entries"
    )

    mutating func run() async throws {
        // 1. Overlay block (parsed from the file we own).
        let overlayPath = TBDConstants.configDir
            .appendingPathComponent("runtime")
            .appendingPathComponent("claude-overlay.json")
            .path
        print("Overlay file: \(overlayPath)")
        if FileManager.default.fileExists(atPath: overlayPath) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: overlayPath)),
               let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let hooks = dict["hooks"] as? [String: Any] {
                let events = hooks.keys.sorted()
                if events.isEmpty {
                    print("  (no hooks registered in overlay)")
                } else {
                    for event in events {
                        let matchers = (hooks[event] as? [[String: Any]]) ?? []
                        let count = matchers.reduce(0) { acc, m in
                            acc + ((m["hooks"] as? [[String: Any]])?.count ?? 1)
                        }
                        print("  \(event): \(count) hook\(count == 1 ? "" : "s")")
                    }
                }
            } else {
                print("  (overlay file present but unparseable)")
            }
        } else {
            print("  (not yet written — start the daemon to generate it)")
        }

        // 2. Legacy block — query the daemon. The scanner lives in TBDDaemon
        //    and isn't reachable from this module, so when the daemon is down
        //    we just print a hint to start it rather than re-implementing the
        //    scan locally.
        print("")
        print("Legacy entries in user settings.json files:")
        let client = SocketClient()
        if client.isDaemonRunning {
            do {
                let result: LegacyHooksStatusResult = try client.call(
                    method: RPCMethod.daemonLegacyHooksStatus,
                    params: EmptyParams(),
                    resultType: LegacyHooksStatusResult.self
                )
                printLegacyResult(result)
            } catch {
                print("  daemon RPC failed: \(error)")
            }
        } else {
            print("  (daemon not running — run `tbdd` to enable full status)")
        }
    }

    private func printLegacyResult(_ result: LegacyHooksStatusResult) {
        if result.globalEntries.isEmpty && result.repoEntries.isEmpty {
            print("  (none — your settings.json is clean)")
            return
        }
        if !result.globalEntries.isEmpty {
            print("  Global (~/.claude/settings.json): \(result.globalEntries.count) entr\(result.globalEntries.count == 1 ? "y" : "ies")")
            for e in result.globalEntries {
                print("    [\(e.event)] \(truncate(e.command))")
            }
        }
        if !result.repoEntries.isEmpty {
            print("  Repo-level entries:")
            for path in result.repoEntries.keys.sorted() {
                let entries = result.repoEntries[path] ?? []
                print("    \(path): \(entries.count) entr\(entries.count == 1 ? "y" : "ies")")
                for e in entries {
                    print("      [\(e.event)] \(truncate(e.command))")
                }
            }
        }
        print("")
        print("  Use the TBD app menu (\"Migrate Claude Hooks…\") to remove global entries safely.")
    }

    private func truncate(_ s: String, max: Int = 80) -> String {
        s.count > max ? String(s.prefix(max)) + "…" : s
    }
}

/// Empty params struct for RPCs that take no parameters but for which the
/// generic `call` helper still expects an Encodable.
private struct EmptyParams: Codable {}
