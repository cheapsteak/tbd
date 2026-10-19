import ArgumentParser
import Foundation
import TBDShared

struct RepoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repo",
        abstract: "Manage repositories",
        subcommands: [RepoAdd.self, RepoRemove.self, RepoList.self, RepoRelocate.self, RepoRename.self]
    )
}

// MARK: - repo add

struct RepoAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a repository to TBD"
    )

    @Argument(help: "Path to a git repository, a git URL, or owner/repo (defaults to current directory)")
    var path: String = "."

    @Argument(help: "Where to clone a remote repository (defaults to ./<name>)")
    var destination: String?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let action: RepoAddAction
        do {
            action = try planRepoAdd(
                source: path,
                destination: destination,
                currentDirectory: FileManager.default.currentDirectoryPath,
                pathExists: { FileManager.default.fileExists(atPath: $0) }
            )
        } catch let usage as RepoAddUsageError {
            throw CLIError.invalidArgument(usage.description)
        }

        let client = SocketClient()
        switch action {
        case .addLocal(let resolved):
            try addRepo(client: client, at: resolved)
        case .clone(let source, let destination):
            // A stopped daemon should fail before any clone starts.
            _ = try client.call(method: RPCMethod.daemonStatus, resultType: DaemonStatusResult.self)

            let url: String
            switch source {
            case .remote(let remoteURL, _):
                url = remoteURL
            case .githubShortForm(let owner, let repo):
                url = await RepoCloner.githubCloneURL(owner: owner, repo: repo)
            case .local, .invalid:
                throw ExitCode.failure  // unreachable: planRepoAdd only clones remote sources
            }

            writeStderr("Cloning \(url) into \(destination)…\n")
            let outcome = await RepoCloner(url: url, destination: destination, mode: .attachedToTerminal)
                .run { _ in }
            switch outcome {
            case .succeeded:
                break
            case .refusedDestinationExists:
                writeStderr("Destination already exists: \(destination)\n")
                throw ExitCode.failure
            case .failed(let code, _):
                throw ExitCode(code)
            case .cancelled:
                throw ExitCode.failure
            }

            do {
                try addRepo(client: client, at: destination)
            } catch {
                writeStderr(
                    "Cloned into \(destination), but TBD could not add it: \(error). "
                        + "Run `tbd repo add \(destination)` to retry.\n")
                throw ExitCode.failure
            }
        }
    }

    private func addRepo(client: SocketClient, at resolved: String) throws {
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

    private func writeStderr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
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
            let header = tableRow([("ID", 36), ("NAME", 20), ("STATUS", 9), ("PATH", 0)])
            print(header)
            print(String(repeating: "-", count: 90))
            for repo in repos {
                let tag = repo.status == .missing ? "[missing]" : "[ok]"
                let line = tableRow([
                    (repo.id.uuidString, 36),
                    (repo.displayName, 20),
                    (tag, 9),
                    (repo.path, 0)
                ])
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

// MARK: - repo rename

struct RepoRename: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a repository's display name"
    )

    @Argument(help: "Repository ID")
    var id: String

    @Argument(help: "New display name")
    var newName: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        guard let repoID = UUID(uuidString: id) else {
            throw CLIError.invalidArgument("Invalid repository ID: \(id)")
        }
        let client = SocketClient()
        try client.callVoid(
            method: RPCMethod.repoRename,
            params: RepoRenameParams(repoID: repoID, displayName: newName)
        )

        if json {
            printJSON(["status": "renamed", "id": id, "displayName": newName])
        } else {
            print("Repository renamed to: \(newName)")
        }
    }
}
