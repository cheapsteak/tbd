import Foundation

/// Resolves the vendor `claude` executable daemon-side, in the shape
/// `CodexExecutableResolver` establishes for the other vendor CLI.
///
/// A configured `TBD_CLAUDE_EXECUTABLE` absolute path wins, followed by every
/// ABSOLUTE `PATH` entry in order. Relative and empty entries are ignored on
/// both inputs: resolving them against the daemon's current directory could
/// execute an untrusted worktree-local `claude`. The returned path is always
/// absolute, so nothing downstream repeats the lookup under a different
/// environment.
enum ClaudeExecutableResolver {
    static let executableOverrideEnvironmentKey = "TBD_CLAUDE_EXECUTABLE"

    enum ResolveError: LocalizedError, Equatable {
        case notFound(searchPath: String)

        var errorDescription: String? {
            switch self {
            case .notFound(let searchPath):
                return "no executable `claude` found on PATH (\(searchPath)); "
                    + "set \(executableOverrideEnvironmentKey) to an absolute path"
            }
        }
    }

    static func resolve(
        configuredOverride: String? = ProcessInfo.processInfo
            .environment[executableOverrideEnvironmentKey],
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) throws -> String {
        if let configuredOverride, configuredOverride.hasPrefix("/"),
           isExecutable(configuredOverride) {
            return URL(fileURLWithPath: configuredOverride).standardizedFileURL.path
        }
        for entry in searchPath.split(separator: ":", omittingEmptySubsequences: false) {
            let dir = String(entry)
            guard dir.hasPrefix("/") else { continue }
            let candidate = URL(fileURLWithPath: dir)
                .appendingPathComponent("claude").standardizedFileURL.path
            if isExecutable(candidate) { return candidate }
        }
        throw ResolveError.notFound(searchPath: searchPath)
    }
}
