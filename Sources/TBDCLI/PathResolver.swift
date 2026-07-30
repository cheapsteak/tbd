import Foundation
import TBDShared

/// Resolves the current working directory to a repo/worktree ID
/// by querying the daemon via the resolve.path RPC.
struct PathResolver {
    let client: SocketClient

    init(client: SocketClient = SocketClient()) {
        self.client = client
    }

    /// Resolve a path to its repo and worktree IDs.
    /// Returns nil for both if the path is not inside a known repo/worktree.
    func resolve(path: String? = nil) throws -> ResolvedPathResult {
        let resolvedPath = resolvePath(path)
        return try client.call(
            method: RPCMethod.resolvePath,
            params: ResolvePathParams(path: resolvedPath),
            resultType: ResolvedPathResult.self
        )
    }

    /// Resolve a path to a repo ID, throwing if not found.
    ///
    /// The failure message names what was actually resolved. `--repo` takes a
    /// UUID or a path; a bare repo *name* is neither, so it gets resolved as a
    /// relative path and fails with a message about path detection — which
    /// reads like a detection bug and sends people looking for one. Reported
    /// from the field as "`--repo acme-app` is ambiguous between two registered
    /// repos of that name"; it isn't ambiguous, because there is no name lookup
    /// here to be ambiguous about.
    func resolveRepoID(path: String? = nil) throws -> UUID {
        let result = try resolve(path: path)
        guard let repoID = result.repoID else {
            let target = path.map { "'\($0)'" } ?? "the current directory"
            throw CLIError.invalidArgument("""
                No registered repository at \(target).
                --repo takes a repository UUID or a path, not a repo name. \
                Run `tbd repo list` for the registered repos and their IDs.
                """)
        }
        return repoID
    }

    /// Resolve a path to a worktree ID, throwing if not found.
    func resolveWorktreeID(path: String? = nil) throws -> UUID {
        let result = try resolve(path: path)
        guard let worktreeID = result.worktreeID else {
            throw CLIError.invalidArgument("Could not determine worktree from path. Use --worktree to specify.")
        }
        return worktreeID
    }

    /// Resolve a relative or nil path to an absolute path.
    private func resolvePath(_ path: String?) -> String {
        guard let path = path else {
            return FileManager.default.currentDirectoryPath
        }
        if path.hasPrefix("/") {
            return path
        }
        return URL(
            fileURLWithPath: path,
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ).standardized.path
    }
}
