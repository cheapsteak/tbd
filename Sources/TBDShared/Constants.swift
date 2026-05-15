import Foundation

public enum TBDConstants {
    public static let version = "0.1.0"

    /// Base config directory. Resolves `TBD_HOME` env var on every access so a
    /// process that sets the env after first read (e.g. a SwiftTesting suite
    /// trait) gets the new value. Falls back to `~/tbd` when the env is unset
    /// or empty, preserving production behavior.
    public static var configDir: URL {
        if let override = ProcessInfo.processInfo.environment["TBD_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("tbd")
    }

    /// Unix socket path. Honors `TBD_SOCKET_PATH` independently of `TBD_HOME`
    /// — darwin caps `sun_path` at ~104 bytes, so a deep `TBD_HOME` can
    /// overflow even though `$configDir/sock` would fit a shallow override.
    public static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["TBD_SOCKET_PATH"], !override.isEmpty {
            return override
        }
        return configDir.appendingPathComponent("sock").path
    }
    public static var databasePath: String { configDir.appendingPathComponent("state.db").path }
    public static var pidFilePath: String { configDir.appendingPathComponent("tbdd.pid").path }
    public static var portFilePath: String { configDir.appendingPathComponent("port").path }
    public static var reposDir: URL { configDir.appendingPathComponent("repos") }

    public static func hookPath(repoID: UUID, eventName: String) -> String {
        reposDir
            .appendingPathComponent(repoID.uuidString)
            .appendingPathComponent("hooks")
            .appendingPathComponent(eventName)
            .path
    }
}
