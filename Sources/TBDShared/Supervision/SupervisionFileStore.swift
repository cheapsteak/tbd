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

    /// Writes the file atomically: a fresh temporary in the **same directory**,
    /// then `rename(2)` over the target.
    ///
    /// Two consequences a caller may rely on. A crash mid-write leaves the
    /// previous bytes in place — never a half-written file the loader would
    /// reject on next start. And a file that would not load is refused before
    /// anything touches the disk, so `save` can never produce a file `load`
    /// rejects.
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
            try data.write(to: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        guard rename(temporary.path, fileURL.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(code)
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
