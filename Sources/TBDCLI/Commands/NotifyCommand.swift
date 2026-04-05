import ArgumentParser
import Foundation
import TBDShared

struct NotifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify",
        abstract: "Send a notification to TBD"
    )

    @Option(name: .long, help: "Notification type (response_complete, error, task_complete, attention_needed)")
    var type: String

    @Option(name: .long, help: "Notification message")
    var message: String?

    @Option(name: .long, help: "Worktree ID (auto-detected from PWD if not specified)")
    var worktree: String?

    mutating func run() async throws {
        guard let notificationType = NotificationType(rawValue: type) else {
            // Exit silently for unknown types (be lenient for hook usage)
            return
        }

        let client = SocketClient()

        // Exit silently if daemon is not running
        guard client.isDaemonRunning else {
            return
        }

        // Resolve worktree ID
        var worktreeID: UUID?
        if let worktree = worktree {
            guard let id = UUID(uuidString: worktree) else {
                // Exit silently if invalid worktree ID
                return
            }
            worktreeID = id
        } else if let envID = ProcessInfo.processInfo.environment["TBD_WORKTREE_ID"],
                  let id = UUID(uuidString: envID) {
            worktreeID = id
        } else {
            // Try to resolve from PWD; exit silently if not in a worktree
            do {
                let resolver = PathResolver(client: client)
                let result = try resolver.resolve()
                worktreeID = result.worktreeID
            } catch {
                // Exit silently - not in a worktree or daemon unreachable
                return
            }
        }

        // If we couldn't determine a worktree, exit silently
        guard let resolvedWorktreeID = worktreeID else {
            return
        }

        do {
            try client.callVoid(
                method: RPCMethod.notify,
                params: NotifyParams(
                    worktreeID: resolvedWorktreeID,
                    type: notificationType,
                    message: message
                )
            )
        } catch {
            // Exit silently on any error
            return
        }
    }
}
