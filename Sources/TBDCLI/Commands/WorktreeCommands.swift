import ArgumentParser
import Foundation
import TBDShared

struct WorktreeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "worktree",
        abstract: "Manage worktrees",
        subcommands: [
            WorktreeCreate.self,
            WorktreeList.self,
            WorktreeArchive.self,
            WorktreeRevive.self,
            WorktreeRename.self,
            WorktreeReparent.self,
        ]
    )
}

// MARK: - worktree create

struct WorktreeCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new worktree (waits for git setup to complete)"
    )

    @Option(name: .long, help: "Directory name for the worktree (default: auto-generated)")
    var folder: String?

    @Option(name: .long, help: "Full git branch name (default: tbd/<folder>)")
    var branch: String?

    @Option(name: .long, help: "Display name shown in TBD UI (default: same as folder)")
    var name: String?

    @Option(name: .long, help: "Repository path or ID")
    var repo: String?

    @Option(name: .long, help: "Initial prompt for the auto-created Claude session")
    var prompt: String?

    @Option(name: .long, help: "Read initial prompt from a file (use - for stdin)")
    var promptFile: String?

    @Option(
        name: .customLong("position"),
        help: ArgumentHelp(
            "Position of the new worktree in the tree, relative to the caller (TBD_WORKTREE_ID).",
            discussion: """
                child   (default) New worktree is a child of the caller.
                sibling          New worktree is a peer of the caller (same parent).
                root             New worktree has no parent (top-level).
                """
        )
    )
    var position: WorktreePosition = .child

    @Flag(name: .long, help: "Return immediately without waiting for the worktree to become active")
    var noWait = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func validate() throws {
        if let folder = folder {
            if folder.isEmpty {
                throw ValidationError("Folder name must not be empty.")
            }
            if folder == "." || folder == ".." {
                throw ValidationError("Folder name cannot be '.' or '..'.")
            }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
            if folder.unicodeScalars.contains(where: { !allowed.contains($0) }) {
                throw ValidationError(
                    "Invalid folder name '\(folder)'. Use only letters, digits, hyphens, underscores, or dots."
                )
            }
        }
    }

    mutating func run() async throws {
        let client = SocketClient()
        let repoID: UUID

        if let repo = repo {
            if let id = UUID(uuidString: repo) {
                repoID = id
            } else {
                let resolver = PathResolver(client: client)
                repoID = try resolver.resolveRepoID(path: repo)
            }
        } else {
            let resolver = PathResolver(client: client)
            repoID = try resolver.resolveRepoID()
        }

        let resolvedPrompt = try resolvePrompt(inline: prompt, file: promptFile)

        let callerEnvID = ProcessInfo.processInfo.environment["TBD_WORKTREE_ID"]
            .flatMap { UUID(uuidString: $0) }
        if let warning = position.unmetIntentWarning(callerEnvID: callerEnvID) {
            FileHandle.standardError.write(Data("\(warning)\n".utf8))
        }
        let parentingFields = position.rpcFields(callerEnvID: callerEnvID)

        let pending: Worktree = try client.call(
            method: RPCMethod.worktreeCreate,
            params: WorktreeCreateParams(
                repoID: repoID,
                folder: folder,
                branch: branch,
                displayName: name,
                prompt: resolvedPrompt,
                parentWorktreeID: nil,
                siblingOfWorktreeID: parentingFields.siblingOfWorktreeID,
                callerWorktreeID: parentingFields.callerWorktreeID,
                suppressAutoParent: parentingFields.suppressAutoParent
            ),
            resultType: Worktree.self
        )

        let worktree: Worktree
        if noWait {
            worktree = pending
        } else {
            worktree = try waitForActive(pending: pending, client: client)
        }

        if json {
            printJSON(worktree)
        } else {
            print("Created worktree: \(worktree.displayName)")
            print("  ID:     \(worktree.id)")
            print("  Branch: \(worktree.branch)")
            print("  Path:   \(worktree.path)")
        }
    }

    private func waitForActive(pending: Worktree, client: SocketClient) throws -> Worktree {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let worktrees: [Worktree] = try client.call(
                method: RPCMethod.worktreeList,
                params: WorktreeListParams(repoID: pending.repoID),
                resultType: [Worktree].self
            )
            if let updated = worktrees.first(where: { $0.id == pending.id }) {
                if updated.status == .active || updated.status == .main {
                    return updated
                }
            } else {
                throw CLIError.invalidArgument("Worktree creation failed (see daemon logs)")
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw CLIError.invalidArgument("Timed out waiting for worktree to become active")
    }
}

// MARK: - worktree list

struct WorktreeList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List worktrees"
    )

    @Option(name: .long, help: "Filter by repository path or ID")
    var repo: String?

    @Option(name: .long, help: "Filter by status (active or archived)")
    var status: String?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()

        var repoID: UUID?
        if let repo = repo {
            if let id = UUID(uuidString: repo) {
                repoID = id
            } else {
                let resolver = PathResolver(client: client)
                repoID = try resolver.resolveRepoID(path: repo)
            }
        }

        var worktreeStatus: WorktreeStatus?
        if let status = status {
            worktreeStatus = WorktreeStatus(rawValue: status)
            guard worktreeStatus != nil else {
                throw CLIError.invalidArgument("Invalid status '\(status)'. Use 'active' or 'archived'.")
            }
        }

        let worktrees: [Worktree] = try client.call(
            method: RPCMethod.worktreeList,
            params: WorktreeListParams(repoID: repoID, status: worktreeStatus),
            resultType: [Worktree].self
        )

        if json {
            printJSON(worktrees)
        } else {
            if worktrees.isEmpty {
                print("No worktrees found.")
                return
            }
            let repos: [Repo] = try client.call(method: RPCMethod.repoList, resultType: [Repo].self)
            let missingRepoIDs = Set(repos.filter { $0.status == .missing }.map { $0.id })
            let header = String(format: "%-36s  %-24s  %-8s  %s", "ID", "NAME", "STATUS", "BRANCH")
            print(header)
            print(String(repeating: "-", count: 100))
            for wt in worktrees {
                let line = String(format: "%-36s  %-24s  %-8s  %s",
                    wt.id.uuidString as NSString,
                    wt.displayName as NSString,
                    wt.status.rawValue as NSString,
                    wt.branch as NSString)
                let tag = missingRepoIDs.contains(wt.repoID) ? "  [missing]" : ""
                print(line + tag)
            }
        }
    }
}

// MARK: - worktree archive

struct WorktreeArchive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive",
        abstract: "Archive a worktree"
    )

    @Argument(help: "Worktree name or ID")
    var nameOrID: String

    @Flag(name: .long, help: "Force archive even with uncommitted changes")
    var force = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try resolveWorktreeNameOrID(nameOrID, client: client)

        try client.callVoid(
            method: RPCMethod.worktreeArchive,
            params: WorktreeArchiveParams(worktreeID: worktreeID, force: force)
        )

        if json {
            printJSON(["status": "archived", "id": worktreeID.uuidString])
        } else {
            print("Worktree archived.")
        }
    }
}

// MARK: - worktree revive

struct WorktreeRevive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "revive",
        abstract: "Revive an archived worktree"
    )

    @Argument(help: "Worktree name or ID")
    var nameOrID: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try resolveWorktreeNameOrID(nameOrID, client: client)

        let worktree: Worktree = try client.call(
            method: RPCMethod.worktreeRevive,
            params: WorktreeReviveParams(worktreeID: worktreeID),
            resultType: Worktree.self
        )

        if json {
            printJSON(worktree)
        } else {
            print("Worktree revived: \(worktree.displayName)")
            print("  Path: \(worktree.path)")
        }
    }
}

// MARK: - worktree rename

struct WorktreeRename: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a worktree"
    )

    @Argument(help: "Worktree name or ID")
    var nameOrID: String

    @Argument(help: "New display name")
    var newName: String

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try resolveWorktreeNameOrID(nameOrID, client: client)

        try client.callVoid(
            method: RPCMethod.worktreeRename,
            params: WorktreeRenameParams(worktreeID: worktreeID, displayName: newName)
        )

        print("Worktree renamed to: \(newName)")
    }
}

// MARK: - worktree reparent

struct WorktreeReparent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reparent",
        abstract: "Move a worktree under a new parent (or promote to top-level)"
    )

    @Argument(help: "Worktree name or ID")
    var nameOrID: String

    @Option(name: .long, help: "New parent worktree (name or ID). Mutually exclusive with --root.")
    var parent: String?

    @Flag(name: .long, help: "Promote the worktree to top-level (no parent). Mutually exclusive with --parent.")
    var root = false

    @Option(name: .long, help: "Sort order within the new sibling group (default: append to end).")
    var index: Int?

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func validate() throws {
        if parent == nil && !root {
            throw ValidationError("Specify either --parent <name-or-id> or --root.")
        }
        if parent != nil && root {
            throw ValidationError("--parent and --root are mutually exclusive.")
        }
    }

    mutating func run() async throws {
        let client = SocketClient()
        let worktreeID = try resolveWorktreeNameOrID(nameOrID, client: client)

        let newParentID: UUID?
        if let parent = parent {
            newParentID = try resolveWorktreeNameOrID(parent, client: client)
        } else {
            newParentID = nil
        }

        if let newParentID, newParentID == worktreeID {
            throw CLIError.invalidArgument("A worktree cannot be its own parent.")
        }

        let allWorktrees: [Worktree] = try client.call(
            method: RPCMethod.worktreeList,
            params: WorktreeListParams(),
            resultType: [Worktree].self
        )
        guard let moving = allWorktrees.first(where: { $0.id == worktreeID }) else {
            throw CLIError.invalidArgument("Worktree not found: \(nameOrID)")
        }

        let newSortOrder: Int
        if let idx = index {
            newSortOrder = idx
        } else {
            newSortOrder = allWorktrees.filter { wt in
                wt.repoID == moving.repoID
                    && wt.id != worktreeID
                    && wt.parentWorktreeID == newParentID
                    && (wt.status == .active || wt.status == .creating)
            }.count
        }

        try client.callVoid(
            method: RPCMethod.worktreeMove,
            params: WorktreeMoveParams(
                worktreeID: worktreeID,
                newParentID: newParentID,
                newSortOrder: newSortOrder
            )
        )

        if json {
            // Custom Encodable so `newParentID` serializes as explicit `null`
            // (rather than being omitted) when the worktree is promoted to root.
            struct ReparentJSON: Encodable {
                let worktreeID: String
                let newParentID: String?
                let newSortOrder: Int

                enum CodingKeys: String, CodingKey {
                    case worktreeID, newParentID, newSortOrder
                }

                func encode(to encoder: Encoder) throws {
                    var c = encoder.container(keyedBy: CodingKeys.self)
                    try c.encode(worktreeID, forKey: .worktreeID)
                    try c.encode(newSortOrder, forKey: .newSortOrder)
                    if let newParentID {
                        try c.encode(newParentID, forKey: .newParentID)
                    } else {
                        try c.encodeNil(forKey: .newParentID)
                    }
                }
            }
            printJSON(ReparentJSON(
                worktreeID: worktreeID.uuidString,
                newParentID: newParentID?.uuidString,
                newSortOrder: newSortOrder
            ))
        } else if let pid = newParentID {
            let parentName = allWorktrees.first(where: { $0.id == pid })?.displayName ?? pid.uuidString
            print("Reparented \(moving.displayName) under \(parentName)")
        } else {
            print("Reparented \(moving.displayName) to top level")
        }
    }
}

// MARK: - Helpers

/// Try to parse as UUID first; if that fails, look up by name using worktree.list.
func resolveWorktreeNameOrID(_ nameOrID: String, client: SocketClient) throws -> UUID {
    // Try UUID first
    if let id = UUID(uuidString: nameOrID) {
        return id
    }

    // Look up by name: list all worktrees and find by name
    let worktrees: [Worktree] = try client.call(
        method: RPCMethod.worktreeList,
        params: WorktreeListParams(),
        resultType: [Worktree].self
    )

    let matches = worktrees.filter { $0.name == nameOrID || $0.displayName == nameOrID }
    guard let match = matches.first else {
        throw CLIError.invalidArgument("No worktree found with name or ID: \(nameOrID)")
    }
    if matches.count > 1 {
        throw CLIError.invalidArgument("Multiple worktrees match '\(nameOrID)'. Use the full ID instead.")
    }
    return match.id
}
