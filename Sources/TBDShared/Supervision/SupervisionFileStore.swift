import Foundation

/// Reads and writes `supervision.json`.
///
/// The store holds the file URL it was given. There is deliberately **no static
/// helper that builds its own path**: a static twin added "for convenience"
/// makes every caller's injected seam decorative, which is exactly how a test
/// suite ends up writing into the developer's real `~/tbd` (root `CLAUDE.md`,
/// "Tests must not touch ~/tbd"). Path resolution happens once, in
/// `init(environment:)`, through `TBDConstants`.
public struct SupervisionFileStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Resolves `~/tbd/supervision/supervision.json` through `TBDConstants`,
    /// honoring `TBD_HOME`.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(fileURL: URL(
            fileURLWithPath: TBDConstants.supervisionFilePath(environment: environment)))
    }

    /// The directory the file and its write-temp live in.
    public var directoryURL: URL { fileURL.deletingLastPathComponent() }

    // MARK: - Load

    /// The operator's file, or the empty value when there is none.
    ///
    /// An absent file is not an error and not a distinguishable state: a fleet
    /// that never touched supervision and a fleet that turned everything off
    /// load as the same value.
    public func load() throws -> SupervisionFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return SupervisionFile()
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw SupervisionFileError.malformed(
                path: fileURL.path, detail: error.localizedDescription)
        }
        let file: SupervisionFile
        do {
            file = try JSONDecoder().decode(SupervisionFile.self, from: data)
        } catch let error as DecodingError {
            throw SupervisionFileError.malformed(
                path: fileURL.path, detail: Self.describe(error))
        }
        try file.validate()
        return file
    }

    // MARK: - Save

    /// Writes the file durably: a fresh temporary in the **same directory**,
    /// flushed to the platter, then `rename(2)` over the target, then the
    /// directory itself flushed.
    ///
    /// Three consequences a caller may rely on. A crash mid-write leaves the
    /// previous bytes in place — never a half-written file the loader would
    /// reject on next start. **Power loss** after the rename leaves either the
    /// previous file or the complete new one, never an empty file where the
    /// topology used to be: `rename(2)` orders the metadata, but only the two
    /// `fsync`s order the *data*, and without them the renamed file can surface
    /// with its blocks unwritten. And a file that would not load is refused
    /// before anything touches the disk, so `save` can never produce a file
    /// `load` rejects.
    ///
    /// The cost is two `fsync`s per operator gesture — `on`, `off`, `mode`, a
    /// project mutation. Nothing writes this file in a loop, and losing it
    /// silently loses the fleet's topology and every mark with it.
    public func save(_ file: SupervisionFile) throws {
        try file.validate()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(file)
        data.append(0x0A)  // a trailing newline; this file is hand-edited

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
                try handle.synchronize()  // the bytes, before the name points at them
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

        // The rename itself is a directory change, and it needs flushing too —
        // otherwise power loss can lose the new name and leave the old one.
        let directory = open(directoryURL.path, O_RDONLY)
        if directory >= 0 {
            fsync(directory)
            close(directory)
        }
    }

    /// The write-temp for one save. Its directory is the target's directory:
    /// `rename(2)` is atomic only within a filesystem, and a temp under
    /// `/tmp` (or `NSTemporaryDirectory()`) can land on another volume, where
    /// the "rename" degrades into a copy that a crash can tear in half.
    func temporaryURL() -> URL {
        directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "missing key \"\(key.stringValue)\" at \(path(of: context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context),
             .dataCorrupted(let context):
            return "\(context.debugDescription) at \(path(of: context))"
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func path(of context: DecodingError.Context) -> String {
        let joined = context.codingPath.map(\.stringValue).joined(separator: ".")
        return joined.isEmpty ? "the top level" : joined
    }
}
