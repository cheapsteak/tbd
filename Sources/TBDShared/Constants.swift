import Foundation

public enum TBDConstants {
    public static let version = "0.1.0"

    /// Base config directory resolved from the given environment dictionary.
    /// Honors `TBD_HOME`; falls back to `~/tbd` when the key is absent or empty.
    public static func configDir(environment: [String: String]) -> URL {
        if let override = environment["TBD_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("tbd")
    }

    /// Base config directory. Resolves `TBD_HOME` env var on every access so a
    /// process that sets the env after first read (e.g. a SwiftTesting suite
    /// trait) gets the new value. Falls back to `~/tbd` when the env is unset
    /// or empty, preserving production behavior.
    public static var configDir: URL { configDir(environment: ProcessInfo.processInfo.environment) }

    /// Unix socket path resolved from the given environment dictionary.
    /// Honors `TBD_SOCKET_PATH` independently of `TBD_HOME` — darwin caps
    /// `sun_path` at ~104 bytes, so a deep `TBD_HOME` can overflow even though
    /// `$configDir/sock` would fit a shallow override.
    public static func socketPath(environment: [String: String]) -> String {
        if let override = environment["TBD_SOCKET_PATH"], !override.isEmpty {
            return override
        }
        return configDir(environment: environment).appendingPathComponent("sock").path
    }

    /// Unix socket path. Honors `TBD_SOCKET_PATH` independently of `TBD_HOME`
    /// — darwin caps `sun_path` at ~104 bytes, so a deep `TBD_HOME` can
    /// overflow even though `$configDir/sock` would fit a shallow override.
    public static var socketPath: String { socketPath(environment: ProcessInfo.processInfo.environment) }

    /// Sidecar Unix socket over which the daemon vends file descriptors to
    /// the app (SCM_RIGHTS). Sibling of `socketPath`.
    public static func vendSocketPath(environment: [String: String]) -> String {
        configDir(environment: environment).appendingPathComponent("vend.sock").path
    }

    /// Sidecar Unix socket over which the daemon vends file descriptors to
    /// the app (SCM_RIGHTS). Sibling of `socketPath`.
    public static var vendSocketPath: String { vendSocketPath(environment: ProcessInfo.processInfo.environment) }

    public static func databasePath(environment: [String: String]) -> String {
        configDir(environment: environment).appendingPathComponent("state.db").path
    }
    public static var databasePath: String { databasePath(environment: ProcessInfo.processInfo.environment) }

    public static func pidFilePath(environment: [String: String]) -> String {
        configDir(environment: environment).appendingPathComponent("tbdd.pid").path
    }
    public static var pidFilePath: String { pidFilePath(environment: ProcessInfo.processInfo.environment) }

    public static func portFilePath(environment: [String: String]) -> String {
        configDir(environment: environment).appendingPathComponent("port").path
    }
    public static var portFilePath: String { portFilePath(environment: ProcessInfo.processInfo.environment) }

    public static func reposDir(environment: [String: String]) -> URL {
        configDir(environment: environment).appendingPathComponent("repos")
    }
    public static var reposDir: URL { reposDir(environment: ProcessInfo.processInfo.environment) }

    /// Base directory holding all scratch spaces: `~/tbd/scratch`. Honors TBD_HOME.
    public static func scratchDir(environment: [String: String]) -> URL {
        configDir(environment: environment).appendingPathComponent("scratch")
    }
    public static var scratchDir: URL { scratchDir(environment: ProcessInfo.processInfo.environment) }

    /// Base directory for Claude Code scratchpads resolved from the given environment dictionary.
    /// Honors `TBD_CLAUDE_SCRATCH_BASE`; falls back to `/private/tmp/claude-<uid>` when the key
    /// is absent or empty.
    public static func claudeScratchpadBase(environment: [String: String]) -> URL {
        if let override = environment["TBD_CLAUDE_SCRATCH_BASE"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let uid = getuid()
        return URL(fileURLWithPath: "/private/tmp/claude-\(uid)", isDirectory: true)
    }

    /// Base directory for Claude Code scratchpads. Resolves `TBD_CLAUDE_SCRATCH_BASE` env var
    /// on every access so a process that sets the env after first read (e.g. a SwiftTesting
    /// suite trait) gets the new value. Falls back to `/private/tmp/claude-<uid>` when the env
    /// is unset or empty, preserving production behavior.
    public static var claudeScratchpadBase: URL { claudeScratchpadBase(environment: ProcessInfo.processInfo.environment) }

    public static func hookPath(repoID: UUID, eventName: String, environment: [String: String]) -> String {
        reposDir(environment: environment)
            .appendingPathComponent(repoID.uuidString)
            .appendingPathComponent("hooks")
            .appendingPathComponent(eventName)
            .path
    }

    public static func hookPath(repoID: UUID, eventName: String) -> String {
        hookPath(repoID: repoID, eventName: eventName, environment: ProcessInfo.processInfo.environment)
    }

    /// Base directory holding per-worktree config (e.g. scratch-worktree
    /// notepads): `~/tbd/worktrees`. Honors TBD_HOME.
    public static func worktreesDir(environment: [String: String]) -> URL {
        configDir(environment: environment).appendingPathComponent("worktrees")
    }
    public static var worktreesDir: URL { worktreesDir(environment: ProcessInfo.processInfo.environment) }

    /// Path to a repo's shared notepad file: `~/tbd/repos/<repoID>/notes.md`.
    /// Shared by every worktree of the repo. Honors TBD_HOME.
    public static func notesPath(repoID: UUID, environment: [String: String]) -> String {
        reposDir(environment: environment)
            .appendingPathComponent(repoID.uuidString)
            .appendingPathComponent("notes.md")
            .path
    }
    public static func notesPath(repoID: UUID) -> String {
        notesPath(repoID: repoID, environment: ProcessInfo.processInfo.environment)
    }

    /// Path to a scratch worktree's notepad file:
    /// `~/tbd/worktrees/<worktreeID>/notes.md`. Honors TBD_HOME.
    public static func notesPath(worktreeID: UUID, environment: [String: String]) -> String {
        worktreesDir(environment: environment)
            .appendingPathComponent(worktreeID.uuidString)
            .appendingPathComponent("notes.md")
            .path
    }
    public static func notesPath(worktreeID: UUID) -> String {
        notesPath(worktreeID: worktreeID, environment: ProcessInfo.processInfo.environment)
    }
}
