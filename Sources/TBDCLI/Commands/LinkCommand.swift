import ArgumentParser
import Foundation
import TBDShared

struct LinkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link",
        abstract: "Print a tbd:// deep link for a worktree",
        discussion: """
        With no arguments, prints a link to the current worktree, read from
        the TBD_WORKTREE_ID environment variable that TBD-spawned terminals
        inherit. With an argument, accepts a worktree UUID, name, or
        display name (matches the same conventions as other tbd commands).
        """
    )

    @Argument(help: "Worktree UUID, name, or display name (optional)")
    var worktree: String?

    mutating func run() async throws {
        let id = try resolveWorktreeID()
        let url = DeepLink.makeOpenWorktreeURL(id)
        print(url.absoluteString)
    }

    private func resolveWorktreeID() throws -> UUID {
        if let arg = worktree {
            let client = SocketClient()
            return try resolveWorktreeNameOrID(arg, client: client)
        }
        guard
            let envValue = ProcessInfo.processInfo.environment["TBD_WORKTREE_ID"],
            let id = UUID(uuidString: envValue)
        else {
            throw CLIError.invalidArgument(
                "not inside a TBD terminal; pass a worktree name or UUID"
            )
        }
        return id
    }
}
