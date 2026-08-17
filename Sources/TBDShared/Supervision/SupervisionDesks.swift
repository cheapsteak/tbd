import Foundation

// MARK: - One desk

/// The hosted desk TBD is running for one project: the session it spawned, the
/// scratch space that session lives in, when it was spawned, and the conduct
/// hash of the playbook it stands on.
///
/// **Tracked by id, never by display string.** A desk is found again by its
/// terminal and worktree ids, so renaming the scratch space — an operator
/// gesture, or the agent's own rename nudge — cannot orphan it. The Watch
/// Desk's `displayName == "Watch Desk"` lookup is exactly the shape this
/// avoids: the moment somebody renames that space, the desk becomes
/// unreclaimable and the next ensure spawns a second one beside it.
///
/// `conductHash` is the SHA-256 of the playbook bytes installed as this
/// session's standing layer at spawn (`SupervisionPlaybook.conductHash`). It is
/// recorded so a later build can tell that the file has moved on from what this
/// session stands on; nothing in this slice reads it to make a decision.
public struct SupervisionDeskEntry: Codable, Sendable, Equatable {
    /// The TBD terminal running the desk agent.
    public let terminal: UUID
    /// The scratch worktree that terminal lives in.
    public let worktree: UUID
    public let spawnedAt: SupervisionInstant
    /// SHA-256, lowercase hex, of the playbook installed at spawn.
    public let conductHash: String

    public init(terminal: UUID, worktree: UUID, spawnedAt: SupervisionInstant,
                conductHash: String) {
        self.terminal = terminal
        self.worktree = worktree
        self.spawnedAt = spawnedAt
        self.conductHash = conductHash
    }
}

// MARK: - The file

/// `~/tbd/supervision/desks.json` — which hosted desk serves which project.
///
/// **This is TBD-owned derived state, not operator selections, and that is
/// exactly why it is not in `supervision.json`.** That file holds what an
/// operator chose (design §7, §8): the topology, the marks, the mode
/// selections, and the *appointed* supervisor bindings. A hosted desk is
/// nobody's choice — TBD spawns one because a project was turned on and no
/// supervisor stood — and it is rewritten by the daemon with no gesture behind
/// it. Keeping the two apart means a hand edit to the operator's file can never
/// be clobbered by a desk spawn, and a corrupt desks file can never take the
/// fleet's topology offline.
///
/// An absent file is the empty value, not an error: a fleet that has never
/// turned a project on has no desks, and so does one whose desks all died.
public struct SupervisionDesksFile: Codable, Sendable, Equatable {
    /// The only version this build reads and writes.
    public static let currentVersion = 1

    public var version: Int
    /// Hosted desks by project name.
    public var desks: [String: SupervisionDeskEntry]

    public init(version: Int = SupervisionDesksFile.currentVersion,
                desks: [String: SupervisionDeskEntry] = [:]) {
        self.version = version
        self.desks = desks
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case desks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        desks = try container.decodeIfPresent(
            [String: SupervisionDeskEntry].self, forKey: .desks) ?? [:]
    }

    /// An empty map is omitted, so an installation with no desks keeps a
    /// one-line file rather than accumulating scaffolding it never asked for —
    /// the same shape `SupervisionFile` writes.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        if !desks.isEmpty { try container.encode(desks, forKey: .desks) }
    }

    /// The desk serving a project, if one is recorded.
    public func desk(for project: String) -> SupervisionDeskEntry? { desks[project] }

    /// The same file with a project's desk recorded.
    public func recording(_ entry: SupervisionDeskEntry, for project: String)
        -> SupervisionDesksFile {
        var copy = self
        copy.desks[project] = entry
        return copy
    }

    /// The same file with a project's desk forgotten. Forgetting one that is
    /// not there returns an equal value, so a caller can decline to write.
    public func forgetting(_ project: String) -> SupervisionDesksFile {
        guard desks[project] != nil else { return self }
        var copy = self
        copy.desks.removeValue(forKey: project)
        return copy
    }

    public func validate() throws {
        guard version == Self.currentVersion else {
            throw SupervisionDesksError.unsupportedVersion(
                found: version, supported: Self.currentVersion)
        }
    }
}

// MARK: - The store

/// Reads and writes `desks.json`, with the same durability `SupervisionFileStore`
/// gives `supervision.json`: a fresh temporary in the **same directory**,
/// flushed, `rename(2)` over the target, then the directory flushed.
///
/// The store holds the file URL it was given. There is deliberately **no static
/// helper that builds its own path**: a static twin added "for convenience"
/// makes every caller's injected seam decorative, which is how a test suite ends
/// up writing into the developer's real `~/tbd` (root `CLAUDE.md`).
public struct SupervisionDesksStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Resolves `~/tbd/supervision/desks.json` through `TBDConstants`, honoring
    /// `TBD_HOME`.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(fileURL: URL(
            fileURLWithPath: TBDConstants.supervisionDesksPath(environment: environment)))
    }

    public var directoryURL: URL { fileURL.deletingLastPathComponent() }

    /// The recorded desks, or the empty value when there is no file.
    public func load() throws -> SupervisionDesksFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return SupervisionDesksFile()
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw SupervisionDesksError.malformed(
                path: fileURL.path, detail: error.localizedDescription)
        }
        let file: SupervisionDesksFile
        do {
            file = try JSONDecoder().decode(SupervisionDesksFile.self, from: data)
        } catch let error as DecodingError {
            throw SupervisionDesksError.malformed(
                path: fileURL.path, detail: String(describing: error))
        }
        try file.validate()
        return file
    }

    /// Writes durably: temp in the same directory, `fsync`, `rename(2)`, then
    /// `fsync` on the directory. A crash mid-write leaves the previous bytes;
    /// power loss after the rename leaves either the previous file or the whole
    /// new one, never an empty file where the desk record used to be.
    public func save(_ file: SupervisionDesksFile) throws {
        try file.validate()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(file)
        data.append(0x0A)

        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)

        let temporary = temporaryURL()
        do {
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }

        guard rename(temporary.path, fileURL.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(code)
        }

        let directory = open(directoryURL.path, O_RDONLY)
        if directory >= 0 {
            fsync(directory)
            close(directory)
        }
    }

    /// The write-temp for one save, in the target's own directory: `rename(2)`
    /// is atomic only within a filesystem.
    func temporaryURL() -> URL {
        directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
    }
}

// MARK: - Errors

/// Why the desk record was refused. Reaches a human through the daemon log and,
/// for a spawn that could not be recorded, an operator notification.
public enum SupervisionDesksError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case unsupportedVersion(found: Int, supported: Int)
    case malformed(path: String, detail: String)

    public var description: String {
        switch self {
        case .unsupportedVersion(let found, let supported):
            return "The hosted-desk record is version \(found); this build reads version "
                + "\(supported)."
        case .malformed(let path, let detail):
            return "The hosted-desk record at \(path) could not be read: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}
