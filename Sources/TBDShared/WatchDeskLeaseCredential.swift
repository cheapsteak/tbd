import Darwin
import Foundation

/// Opaque capability material for one Watch Desk judge terminal.
///
/// This intentionally lives outside the shared Watch Desk worktree and never
/// rides status RPCs. The daemon writes it mode 0600; the owning terminal passes
/// only this path to lease commands, keeping the token out of argv, prompts, and
/// transcripts.
public struct WatchDeskLeaseCredential: Codable, Sendable, Equatable {
    public let worktreeID: UUID
    public let terminalID: UUID
    public let token: UUID
    public let generation: Int64

    public init(worktreeID: UUID, terminalID: UUID, token: UUID, generation: Int64) {
        self.worktreeID = worktreeID
        self.terminalID = terminalID
        self.token = token
        self.generation = generation
    }
}

public enum WatchDeskLeaseCredentialFile {
    public static func directory(environment: [String: String]) -> URL {
        TBDConstants.configDir(environment: environment)
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("nightwatch-leases", isDirectory: true)
    }

    public static func read(path: String) throws -> WatchDeskLeaseCredential {
        try JSONDecoder().decode(
            WatchDeskLeaseCredential.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    public static func write(
        _ credential: WatchDeskLeaseCredential,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        let destination = directory(environment: environment)
            .appendingPathComponent(
                "\(credential.terminalID.uuidString)-\(UUID().uuidString).json")
        try write(credential, to: destination, environment: environment)
        return destination.path
    }

    /// Refresh the sole capability already issued to a terminal, or repair an
    /// ambiguous/stale set by replacing it with one fresh locator. The locator
    /// is deliberately independent of the secret token so a path may safely be
    /// mentioned in judge instructions and transcripts.
    public static func ensure(
        _ credential: WatchDeskLeaseCredential,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        let existing = paths(terminalID: credential.terminalID, environment: environment)
        let destination: URL
        if existing.count == 1 {
            destination = URL(fileURLWithPath: existing[0])
        } else {
            remove(terminalID: credential.terminalID, environment: environment)
            destination = directory(environment: environment)
                .appendingPathComponent(
                    "\(credential.terminalID.uuidString)-\(UUID().uuidString).json")
        }
        try write(credential, to: destination, environment: environment)
        return destination.path
    }

    public static func paths(
        terminalID: UUID,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let directory = directory(environment: environment)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        let prefix = terminalID.uuidString + "-"
        return entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .map(\.path)
            .sorted()
    }

    private static func write(
        _ credential: WatchDeskLeaseCredential,
        to destination: URL,
        environment: [String: String]
    ) throws {
        let directory = directory(environment: environment)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // createDirectory does not apply attributes to an existing directory.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)

        // Foundation's generic atomic writer does not promise the temporary
        // file's mode. Create the temporary capability as 0600 first, then use
        // an atomic rename so the secret is never visible through a 0644 window.
        let encoded = try JSONEncoder().encode(credential)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporary.path, contents: encoded,
            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(code)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    public static func remove(
        path: String
    ) {
        try? FileManager.default.removeItem(atPath: path)
    }

    public static func remove(
        terminalID: UUID,
        except retainedPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let directory = directory(environment: environment)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        let prefix = terminalID.uuidString + "-"
        let retainedCanonical = retainedPath.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
        for entry in entries
        where entry.lastPathComponent.hasPrefix(prefix)
            && entry.resolvingSymlinksInPath().path != retainedCanonical {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
