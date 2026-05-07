import ArgumentParser
import Foundation
import TBDShared

/// Deprecated. TBD now provisions Claude hooks automatically when it spawns
/// Claude Code (via the `--settings` overlay at
/// `~/tbd/runtime/claude-overlay.json`). The user's `~/.claude/settings.json`
/// is no longer touched.
///
/// We keep this command around as a no-op so external scripts and docs
/// pointing at `tbd setup-hooks --global` don't immediately break — they
/// just print a migration hint and exit 0.
struct SetupHooksCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup-hooks",
        abstract: "Deprecated — hooks are now provisioned automatically",
        shouldDisplay: false
    )

    @Flag(name: .long, help: "Deprecated; ignored.")
    var global = false

    @Option(name: .long, help: "Deprecated; ignored.")
    var repo: String?

    mutating func run() async throws {
        let stderr = FileHandle.standardError
        let msg = """
        `tbd setup-hooks` is deprecated.

        Hooks are now provisioned automatically when TBD spawns Claude — the
        daemon writes a settings overlay at ~/tbd/runtime/claude-overlay.json
        and passes it via `claude --settings <overlay>` at spawn time. Your
        ~/.claude/settings.json is no longer modified.

        Run `tbd hooks status` to verify the overlay state and check whether
        any legacy entries from previous TBD versions still need cleanup.

        """
        if let data = msg.data(using: .utf8) {
            stderr.write(data)
        }
    }
}
