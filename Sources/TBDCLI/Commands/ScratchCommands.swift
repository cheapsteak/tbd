import ArgumentParser
import Foundation
import TBDShared

struct ScratchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scratch",
        abstract: "Manage repo-less scratch spaces",
        subcommands: [ScratchNew.self, ScratchList.self, ScratchPromote.self]
    )
}

struct ScratchNew: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "new", abstract: "Create a scratch space")

    @Option(name: .long, help: "Optional name (auto-generated if omitted)")
    var name: String?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let wt: Worktree = try client.call(
            method: RPCMethod.scratchCreate,
            params: ScratchCreateParams(name: name),
            resultType: Worktree.self)
        if json { printJSON(wt) } else {
            print("Created scratch space: \(wt.displayName)")
            print("  ID:   \(wt.id)")
            print("  Path: \(wt.path)")
        }
    }
}

struct ScratchList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List scratch spaces")

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let all: [Worktree] = try client.call(
            method: RPCMethod.worktreeList,
            params: WorktreeListParams(),
            resultType: [Worktree].self)
        let scratch = all.filter { $0.isScratch }
        if json { printJSON(scratch); return }
        if scratch.isEmpty { print("No scratch spaces. Use 'tbd scratch new' to create one."); return }
        for wt in scratch {
            let promoted = wt.promotedToRepoID != nil ? "  [promoted]" : ""
            print("\(wt.id)  \(wt.displayName)\(promoted)  \(wt.path)")
        }
    }
}

struct ScratchPromote: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "promote",
        abstract: "Promote the current scratch space into a real TBD repo (move-on-promote)")

    @Argument(help: "Destination path for the new repo (must not exist)")
    var dest: String

    @Option(name: .long, help: "Repo display name (overrides the scratch name / folder name)")
    var displayName: String?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        // Prefer TBD_WORKTREE_ID (set in every TBD terminal); else resolve cwd.
        let worktreeID: UUID
        if let env = ProcessInfo.processInfo.environment["TBD_WORKTREE_ID"], let id = UUID(uuidString: env) {
            worktreeID = id
        } else {
            worktreeID = try PathResolver(client: client).resolveWorktreeID()
        }
        let result: ScratchPromoteResult = try client.call(
            method: RPCMethod.scratchPromote,
            params: ScratchPromoteParams(worktreeID: worktreeID, destPath: resolvePath(dest), displayName: displayName),
            resultType: ScratchPromoteResult.self)
        if json { printJSON(result) } else {
            print("Promoted scratch space to repo: \(result.repoDisplayName)")
            print("  Repo ID: \(result.repoID)")
            print("  Path:    \(result.repoPath)")
        }
    }
}
