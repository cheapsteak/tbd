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

    public static func hookPath(repoID: UUID, eventName: String) -> String {
        reposDir
            .appendingPathComponent(repoID.uuidString)
            .appendingPathComponent("hooks")
            .appendingPathComponent(eventName)
            .path
    }
}
