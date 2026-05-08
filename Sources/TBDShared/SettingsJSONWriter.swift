import Foundation

/// Safety layers for any TBD code path that mutates a Claude Code-style
/// `settings.json` file. The helpers are pure — no I/O on construction —
/// so they are safe to use from CLI commands, the daemon, and unit tests.
///
/// Three layers:
/// 1. **Pristine backup**: before the FIRST mutation TBD ever makes to
///    the target file, we copy it to `<path>.tbd-backup`. The backup is
///    only created if it does not already exist, so a user's true
///    pre-TBD original is preserved forever, immune to repeated bugs.
/// 2. **Roundtrip validation**: callers serialize their proposed JSON
///    and pass the bytes here; we re-parse them and run the caller's
///    invariant closure. If it throws, the write is aborted — the
///    original file stays untouched.
/// 3. **Atomic write**: `Data.write(options: .atomic)` so a crash mid-
///    write can't leave a half-written file.
public enum SettingsJSONSafety {

    public enum Error: Swift.Error, Equatable, Sendable {
        case backupFailed(String)
        case roundtripFailed(String)
        case writeFailed(String)
        case invariantFailed(String)
    }

    /// Suffix appended to settings.json paths to derive the backup path.
    public static let backupSuffix = ".tbd-backup"

    /// Copy `sourcePath` to `sourcePath + backupSuffix` only if the backup
    /// file does not already exist. Returns true if a new backup was
    /// created, false if a prior backup already existed (or if the
    /// source itself is missing — there's nothing to back up).
    @discardableResult
    public static func ensureBackup(of sourcePath: String,
                                    fileManager: FileManager = .default) throws -> Bool {
        let backupPath = sourcePath + backupSuffix
        if fileManager.fileExists(atPath: backupPath) { return false }
        guard fileManager.fileExists(atPath: sourcePath) else { return false }
        do {
            try fileManager.copyItem(atPath: sourcePath, toPath: backupPath)
            return true
        } catch {
            throw Error.backupFailed("Could not copy \(sourcePath) to \(backupPath): \(error.localizedDescription)")
        }
    }

    /// Atomic-write the proposed bytes to `targetPath` after running both
    /// JSON-roundtrip validation and a caller-supplied invariant closure
    /// over the parsed dictionary. The invariant closure should throw on
    /// any structural mismatch; that throw is mapped into
    /// `Error.invariantFailed` and the on-disk file is NOT modified.
    ///
    /// `fileManager` is used only for parent-directory existence checks and
    /// `createDirectory`; the final write goes through `Data.write(to:)`,
    /// which always hits real I/O. Tests can pass an in-memory file manager
    /// to mock the directory probe but should still expect real bytes on
    /// disk afterwards.
    public static func atomicWriteValidated(
        proposedBytes: Data,
        targetPath: String,
        fileManager: FileManager = .default,
        invariant: ([String: Any]) throws -> Void
    ) throws {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: proposedBytes, options: [])
        } catch {
            throw Error.roundtripFailed(error.localizedDescription)
        }
        guard let dict = parsed as? [String: Any] else {
            throw Error.roundtripFailed("Top-level value is not a JSON object")
        }
        do {
            try invariant(dict)
        } catch let e as Error {
            throw e
        } catch {
            throw Error.invariantFailed(error.localizedDescription)
        }
        do {
            // Ensure parent directory exists.
            let parent = (targetPath as NSString).deletingLastPathComponent
            if !fileManager.fileExists(atPath: parent) {
                try fileManager.createDirectory(
                    atPath: parent,
                    withIntermediateDirectories: true
                )
            }
            try proposedBytes.write(to: URL(fileURLWithPath: targetPath), options: .atomic)
        } catch {
            throw Error.writeFailed(error.localizedDescription)
        }
    }
}
