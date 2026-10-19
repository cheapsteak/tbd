import Foundation
import TBDShared

/// What `tbd repo add <source> [destination]` should do.
enum RepoAddAction: Equatable {
    /// Register an existing folder (today's behavior). `path` is absolute.
    case addLocal(path: String)
    /// Clone `source` into `destination` (absolute), then register it.
    case clone(source: RepoSource, destination: String)
}

struct RepoAddUsageError: Error, Equatable, CustomStringConvertible {
    let description: String
}

/// Resolves `path` against `directory`: absolute paths are kept as they are,
/// relative ones are joined to `directory` and standardized. The directory is
/// never looked up on disk.
func resolvePath(_ path: String, relativeTo directory: String) -> String {
    if path.hasPrefix("/") {
        return path
    }
    return URL(fileURLWithPath: directory, isDirectory: true)
        .appendingPathComponent(path, isDirectory: false)
        .standardized.path
}

/// Decides between registering a local folder and cloning. `pathExists` is
/// asked about absolute paths. A source that is neither a folder nor a usable
/// remote still goes down the local path, so the daemon keeps answering with
/// today's "Not a git repository" error.
func planRepoAdd(
    source: String,
    destination: String?,
    currentDirectory: String,
    pathExists: (String) -> Bool
) throws -> RepoAddAction {
    let parsed = RepoSource.parse(source) { pathExists(resolvePath($0, relativeTo: currentDirectory)) }

    guard let folderName = parsed.cloneFolderName else {
        if destination != nil {
            throw RepoAddUsageError(description: "A destination is only used when cloning.")
        }
        let local: String
        if case .local(let path) = parsed { local = path } else { local = source }
        return .addLocal(path: resolvePath(local, relativeTo: currentDirectory))
    }

    let target = destination.map { resolvePath($0, relativeTo: currentDirectory) }
        ?? resolvePath(folderName, relativeTo: currentDirectory)
    return .clone(source: parsed, destination: target)
}
