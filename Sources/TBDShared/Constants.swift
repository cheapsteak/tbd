import Foundation

public enum TBDConstants {
    public static let version = "0.1.0"
    public static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("tbd")
    public static let socketPath = configDir.appendingPathComponent("sock").path
    public static let databasePath = configDir.appendingPathComponent("state.db").path
    public static let pidFilePath = configDir.appendingPathComponent("tbdd.pid").path
    public static let portFilePath = configDir.appendingPathComponent("port").path
    public static let reposDir = configDir.appendingPathComponent("repos")

    public static func hookPath(repoID: UUID, eventName: String) -> String {
        reposDir
            .appendingPathComponent(repoID.uuidString)
            .appendingPathComponent("hooks")
            .appendingPathComponent(eventName)
            .path
    }
}
