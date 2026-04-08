import Foundation

public enum TBDConstants {
    public static let version = "0.1.0"
    public static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("tbd")
    public static let socketPath = configDir.appendingPathComponent("sock").path
    public static let databasePath = configDir.appendingPathComponent("state.db").path
    public static let pidFilePath = configDir.appendingPathComponent("tbdd.pid").path
    public static let portFilePath = configDir.appendingPathComponent("port").path
    public static let conductorsDir = configDir.appendingPathComponent("conductors")
    public static let reposDir = configDir.appendingPathComponent("repos")

    public static func hookPath(repoID: UUID, eventName: String) -> String {
        reposDir
            .appendingPathComponent(repoID.uuidString)
            .appendingPathComponent("hooks")
            .appendingPathComponent(eventName)
            .path
    }
    public static let conductorsTmuxServer = "tbd-conductor"
    /// Well-known UUID for the synthetic "conductors" pseudo-repo.
    /// Inserted by migration v9. Used as repoID for all conductor worktrees.
    public static let conductorsRepoID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}
