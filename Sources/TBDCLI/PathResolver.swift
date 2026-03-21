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
    func resolveRepoID(path: String? = nil) throws -> UUID {
        let result = try resolve(path: path)
        guard let repoID = result.repoID else {
            throw CLIError.invalidArgument("Could not determine repository from path. Use --repo to specify.")
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
