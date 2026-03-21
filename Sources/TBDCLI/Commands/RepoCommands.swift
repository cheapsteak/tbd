import ArgumentParser
import Foundation
import TBDShared

struct RepoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repo",
        abstract: "Manage repositories",
        subcommands: [RepoAdd.self, RepoRemove.self, RepoList.self]
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
            let header = String(format: "%-36s  %-20s  %s", "ID", "NAME", "PATH")
            print(header)
            print(String(repeating: "-", count: 80))
            for repo in repos {
                let line = String(format: "%-36s  %-20s  %s",
                    repo.id.uuidString as NSString,
                    repo.displayName as NSString,
                    repo.path as NSString)
                print(line)
            }
        }
    }
}
