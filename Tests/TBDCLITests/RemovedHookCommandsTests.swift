import ArgumentParser
import Testing
@testable import TBDCLI

/// A live session's overlay predates the current one until the session is
/// relaunched, so it still runs `tbd terminal-activity …` and
/// `tbd hooks notification`. Both must fail to parse — a usage error, which
/// ArgumentParser writes to stderr with a nonzero exit — rather than reach a
/// subcommand that prints to stdout. `UserPromptSubmit`'s stdout becomes model
/// context, and `hooks` has a default subcommand (`status`) that prints.
@Suite struct RemovedHookCommandsTests {
    @Test("the hook commands an old overlay still calls fail to parse")
    func removedHookCommandsFailToParse() {
        let removed: [[String]] = [
            ["terminal-activity", "idle"],
            ["terminal-activity", "working", "--session-title"],
            ["terminal-activity", "waiting_for_user", "--read-hook-payload"],
            ["hooks", "notification"],
        ]
        for arguments in removed {
            do {
                let parsed = try TBDCommand.parseAsRoot(arguments)
                Issue.record("\(arguments) parsed as \(type(of: parsed))")
            } catch {
                // A help or version request also throws, but exits 0 and
                // prints to stdout; a usage error does neither.
                #expect(TBDCommand.exitCode(for: error) != .success, "\(arguments)")
            }
        }
    }
}
