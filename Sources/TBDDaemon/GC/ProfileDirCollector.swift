import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "gc")

/// A directory under the profiles base whose name parses as a profile UUID.
public struct ProfileDirCandidate: Sendable, Equatable {
    public var profileID: UUID
    public var path: String
    /// Directory creation date, or `nil` when it could not be read — which the
    /// grace gate treats as "too young to touch".
    public var createdAt: Date?

    public init(profileID: UUID, path: String, createdAt: Date?) {
        self.profileID = profileID
        self.path = path
        self.createdAt = createdAt
    }
}

/// Outcome of gating one candidate. `reason` is one of `"row-exists"`,
/// `"terminal-reference"`, `"grace"`, `"unknown-age"`.
public enum ProfileDirDecision: Sendable, Equatable {
    case keep(reason: String)
    case reap
}

/// Enumerates, gates, quarantines and expires per-profile config directories
/// under `~/tbd/profiles/` — the named reconciler for that resource class
/// (`docs/specs/2026-08-15-profile-dir-gc-design.md`).
///
/// Reaping does NOT delete: the directory is renamed into `.reaped/` and only
/// purged after the retention window, because unlike agent worktrees
/// (restorable from a snapshot ref) and scratchpads (disposable tmp) these
/// directories hold per-profile credentials and user content with no other
/// copy. Every failure path fails toward KEEPING — an unreadable creation
/// date, an unreadable listing, a failed rename and an undatable quarantine
/// entry all leave the directory where it is for the next sweep to reconsider.
///
/// This type never reads the database: the caller supplies `knownProfileIDs`
/// and `referencedProfileIDs`, the same division of labor `DeletionQueueCollector`
/// keeps with `OrphanGC`.
public struct ProfileDirCollector: Sendable {
    /// Quarantine directory name, an immediate child of the profiles base.
    /// Not a UUID, so it is never itself a candidate.
    public static let quarantineDirName = ".reaped"

    let base: URL
    let now: @Sendable () -> Date

    public init(base: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.base = base
        self.now = now
    }

    var quarantineBase: URL {
        base.appendingPathComponent(Self.quarantineDirName, isDirectory: true)
    }

    /// Immediate children whose name parses as a UUID and which are directories.
    /// Non-UUID entries, files, and the quarantine directory are never
    /// candidates; an unreadable or missing base yields none.
    public func candidates() -> [ProfileDirCandidate] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else {
            return []
        }
        return names.compactMap { name -> ProfileDirCandidate? in
            guard let id = UUID(uuidString: name) else { return nil }
            let url = base.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return ProfileDirCandidate(
                profileID: id, path: url.path,
                createdAt: attributes?[.creationDate] as? Date)
        }.sorted { $0.path < $1.path }
    }

    /// Gate order: live row → terminal reference → grace. Every gate fails
    /// toward keeping, and an unreadable creation date keeps too.
    public func decide(
        _ candidate: ProfileDirCandidate,
        knownProfileIDs: Set<UUID>,
        referencedProfileIDs: Set<UUID>,
        graceSeconds: Int
    ) -> ProfileDirDecision {
        if knownProfileIDs.contains(candidate.profileID) {
            return .keep(reason: "row-exists")
        }
        if referencedProfileIDs.contains(candidate.profileID) {
            return .keep(reason: "terminal-reference")
        }
        guard let created = candidate.createdAt else {
            return .keep(reason: "unknown-age")
        }
        if now().timeIntervalSince(created) < Double(graceSeconds) {
            return .keep(reason: "grace")
        }
        return .reap
    }

    /// Renames the candidate into `.reaped/<uuid>-<timestamp>/`. The rename is
    /// the commit point; a failure leaves the candidate untouched for the next
    /// sweep and returns `nil`.
    public func reap(_ candidate: ProfileDirCandidate) async -> ReapRecord? {
        let reapedAt = now()
        // Measure before the rename — the last moment the size is readable at
        // the original path, which is the path the record names.
        let bytes = await GCDiskUsage.apparentBytes(path: candidate.path)
        let destination = quarantineBase.appendingPathComponent(
            "\(candidate.profileID.uuidString.lowercased())-\(Self.stamp(reapedAt))",
            isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: quarantineBase, withIntermediateDirectories: true)
            try FileManager.default.moveItem(
                at: URL(fileURLWithPath: candidate.path), to: destination)
        } catch {
            logger.warning("""
            gc: quarantine failed for \(candidate.path, privacy: .public): \
            \(String(describing: error), privacy: .public)
            """)
            return nil
        }
        logger.info("""
        gc: quarantined profile dir \(candidate.path, privacy: .public) -> \
        \(destination.path, privacy: .public)
        """)
        return ReapRecord(
            kind: .profileDir,
            repoPath: "",
            worktreePath: candidate.path,
            apparentBytes: bytes,
            quarantinePath: destination.path,
            reapedAt: reapedAt
        )
    }

    /// Quarantine entries older than the retention window. Age comes from the
    /// timestamp this collector stamped into the entry's own name; a name that
    /// does not carry one falls back to the entry's own filesystem dates, and
    /// an entry with no readable date at all is kept — visible in
    /// `tbd gc list`, never silently destroyed.
    public func expiredQuarantineEntries(retentionDays: Int) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: quarantineBase.path) else {
            return []
        }
        let formatter = Self.makeStampFormatter()
        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86_400)
        return names.compactMap { name -> String? in
            let url = quarantineBase.appendingPathComponent(name, isDirectory: true)
            guard let stamped = Self.timestamp(fromEntryName: name, formatter: formatter)
                ?? Self.filesystemDate(ofItemAtPath: url.path),
                stamped < cutoff
            else { return nil }
            return url.path
        }.sorted()
    }

    /// Deletes one quarantine entry. Refuses any path not strictly under the
    /// quarantine directory — the same anchor guard `ScratchpadCollector` keeps
    /// in front of its recursive delete, and for the same reason: never trust
    /// the caller's path blindly this close to `removeItem`.
    public func purge(quarantinePath: String) -> Bool {
        guard quarantinePath.hasPrefix(self.quarantineBase.path + "/") else {
            logger.warning("""
            gc: refusing to purge \(quarantinePath, privacy: .public) — not strictly under \
            \(self.quarantineBase.path, privacy: .public)
            """)
            return false
        }
        do {
            try FileManager.default.removeItem(atPath: quarantinePath)
        } catch {
            logger.warning("""
            gc: purge failed for \(quarantinePath, privacy: .public): \
            \(String(describing: error), privacy: .public)
            """)
            return false
        }
        logger.info("gc: purged expired quarantine \(quarantinePath, privacy: .public)")
        return true
    }

    // MARK: - Quarantine naming

    /// `yyyyMMdd'T'HHmmss'Z'` in UTC — sortable, filesystem-safe, and
    /// round-trippable by `timestamp(fromEntryName:)`.
    static func stamp(_ date: Date) -> String {
        makeStampFormatter().string(from: date)
    }

    static func timestamp(fromEntryName name: String) -> Date? {
        timestamp(fromEntryName: name, formatter: makeStampFormatter())
    }

    /// The stamp is everything after the final `-`: the UUID prefix contains
    /// dashes, the stamp itself contains none.
    private static func timestamp(fromEntryName name: String, formatter: DateFormatter) -> Date? {
        guard let dash = name.lastIndex(of: "-") else { return nil }
        return formatter.date(from: String(name[name.index(after: dash)...]))
    }

    /// Newest of the entry's own creation and modification dates — the
    /// keep-favoring reading, used only when the name carries no stamp.
    /// `nil` when neither is readable, which keeps the entry.
    private static func filesystemDate(ofItemAtPath path: String) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        let dates = [attributes[.creationDate], attributes[.modificationDate]]
            .compactMap { $0 as? Date }
        return dates.max()
    }

    /// Built per use rather than shared: `DateFormatter` is not `Sendable`, and
    /// this type is. The cost is once per reap and once per expiry pass.
    private static func makeStampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }
}
