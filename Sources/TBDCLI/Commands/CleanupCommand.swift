import ArgumentParser
import Foundation
import TBDShared

struct CleanupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Prune orphaned worktree entries and reconcile all repos"
    )

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let request = RPCRequest(method: RPCMethod.cleanup)
        let response = try client.send(request)

        guard response.success else {
            throw CLIError.rpcError(response.error ?? "Unknown error")
        }

        let result = try response.decodeResult(CleanupResult.self)

        if json {
            printJSON(result)
        } else {
            print("Cleanup complete.")
            print("  Repos processed:      \(result.reposProcessed)")
            print("  Worktrees reconciled: \(result.worktreesReconciled)")
            if !result.errors.isEmpty {
                print("  Errors:")
                for error in result.errors {
                    print("    - \(error)")
                }
            }
        }
    }
}
