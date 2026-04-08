import ArgumentParser
import Foundation
import TBDShared

struct RepoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repo",
        abstract: "Manage repositories",
        subcommands: [RepoAdd.self, RepoRemove.self, RepoList.self, RepoRelocate.self]
    )
}

// MARK: - repo add

struct RepoAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a repository to TBD"
    )

    @Argument(help: "Path to git repository (defaults to current directory)")
    var path: String = "."

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let resolved = resolvePath(path)
        let client = SocketClient()
        let repo: Repo = try client.call(
            method: RPCMethod.repoAdd,
            params: RepoAddParams(path: resolved),
            resultType: Repo.self
        )

        if json {
            printJSON(repo)
        } else {
            print("Added repository: \(repo.displayName)")
            print("  ID:   \(repo.id)")
            print("  Path: \(repo.path)")
        }
    }
}

// MARK: - repo remove

struct RepoRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a repository from TBD"
    )

    @Argument(help: "Repository ID")
    var id: String

    @Flag(name: .long, help: "Force removal even with active worktrees")
    var force = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        guard let repoID = UUID(uuidString: id) else {
            throw CLIError.invalidArgument("Invalid repository ID: \(id)")
        }
        let client = SocketClient()
        try client.callVoid(
            method: RPCMethod.repoRemove,
            params: RepoRemoveParams(repoID: repoID, force: force)
        )

        if json {
            printJSON(["status": "removed", "id": id])
        } else {
            print("Repository removed.")
        }
    }
}

// MARK: - repo list

struct RepoList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List repositories"
    )

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let repos: [Repo] = try client.call(
            method: RPCMethod.repoList,
            resultType: [Repo].self
        )

        if json {
            printJSON(repos)
        } else {
            if repos.isEmpty {
                print("No repositories. Use 'tbd repo add <path>' to add one.")
                return
            }
            let header = String(format: "%-36s  %-20s  %-9s  %s", "ID", "NAME", "STATUS", "PATH")
            print(header)
            print(String(repeating: "-", count: 90))
            for repo in repos {
                let tag = repo.status == .missing ? "[missing]" : "[ok]"
                let line = String(format: "%-36s  %-20s  %-9s  %s",
                    repo.id.uuidString as NSString,
                    repo.displayName as NSString,
                    tag as NSString,
                    repo.path as NSString)
                print(line)
            }
        }
    }
}

// MARK: - repo relocate

struct RepoRelocate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "relocate",
        abstract: "Update a repository's filesystem path after moving it on disk"
    )

    @Argument(help: "Repository ID")
    var id: String

    @Argument(help: "New path to the git repository")
    var newPath: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        guard let repoID = UUID(uuidString: id) else {
            throw CLIError.invalidArgument("Invalid repository ID: \(id)")
        }
        let resolved = resolvePath(newPath)
        let client = SocketClient()
        let result: RepoRelocateResult = try client.call(
            method: RPCMethod.repoRelocate,
            params: RepoRelocateParams(repoID: repoID, newPath: resolved),
            resultType: RepoRelocateResult.self
        )
        if json {
            printJSON(result)
        } else {
            print("Relocated \(result.repo.displayName) → \(result.repo.path)")
            if !result.worktreesRepaired.isEmpty {
                print("  Repaired worktrees: \(result.worktreesRepaired.count)")
            }
            if !result.worktreesFailed.isEmpty {
                print("  Failed worktrees:   \(result.worktreesFailed.count) (marked .failed; manual cleanup required)")
            }
        }
    }
}
