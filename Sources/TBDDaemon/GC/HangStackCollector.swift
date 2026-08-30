import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "gc")

/// One hang-stack file the sweep has selected for deletion, carrying the
/// resource values already read while enumerating so `reap` needs no second
/// `stat` and no `du` subprocess.
public struct HangStackCandidate: Sendable, Equatable {
    public var url: URL
    /// Modification date, or creation date when the modification date could not
    /// be read. A file with neither is never a candidate at all.
    public var modifiedAt: Date
    /// Apparent size, from the enumeration's prefetched `fileSizeKey`. `0` when
    /// the key was unreadable — the byte total is a report, never a gate, so an
    /// unknown size costs an under-count and nothing else.
    public var sizeBytes: Int64

    public init(url: URL, modifiedAt: Date, sizeBytes: Int64) {
        self.url = url
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
    }
}

/// Enumerates and deletes hang-stack diagnostic files under
/// `~/Library/Logs/TBD/hang-stacks/` — the named reconciler for that resource
/// class (`docs/specs/2026-08-29-hang-stack-reclaimer-design.md`).
///
/// Unlike `ProfileDirCollector` this deletes outright rather than quarantining:
/// a hang stack is a machine-generated backtrace with no credentials and no
/// user content, a misclassified one costs a sample nobody was reading, and a
/// `.reaped/` directory of hang stacks would just relocate the unbounded
/// directory this collector exists to bound.
///
/// It holds no database access — the caller (`OrphanGC`) owns the gating and
/// the reporting, the same division of labor `ScratchpadCollector` keeps.
///
/// Every failure direction fails toward KEEPING: an unreadable directory, an
/// unreadable resource value, a file with neither a modification nor a creation
/// date, and a failed `removeItem` all leave the file where it is for the next
/// sweep to reconsider.
public struct HangStackCollector: Sendable {
    let base: URL

    public init(base: URL) {
        self.base = base
    }

    /// The files this sweep should delete, in the order they were ranked.
    ///
    /// Selection, in order:
    /// 1. **Whitelist.** Immediate children that are regular files whose name
    ///    has the writer's `hang-` prefix and `.txt` suffix. Never a blacklist:
    ///    the directory is not TBD's to empty, so a user's notes, a copied
    ///    sample, and a subdirectory are all invisible to this collector.
    /// 2. **Grace.** Anything modified within `graceSeconds` is dropped from
    ///    consideration before either policy test — the app may hold the newest
    ///    file open, appending resamples, and silently discarding the stack of a
    ///    hang in progress is a bad trade for nothing.
    /// 3. **Order.** What remains is sorted newest-first by modification date
    ///    (creation date when that is missing), with the filename as a
    ///    tiebreaker so equal timestamps rank deterministically.
    /// 4. **Policy.** A file is selected when it is older than
    ///    `HangStackRetention.maxAge` **or** sits at index
    ///    `>= HangStackRetention.maxFiles` in that order. Age matches how the
    ///    artifacts are used; the count cap is the bound age cannot give during
    ///    a hang storm.
    ///
    /// A missing or unreadable base directory yields nothing — a machine where
    /// the app has never hung has no directory, and creating one to sweep it
    /// would be absurd.
    public func candidates(now: Date, graceSeconds: Int) -> [HangStackCandidate] {
        let keys: [URLResourceKey] = [
            .contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey,
        ]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return []
        }

        var eligible: [HangStackCandidate] = []
        for url in entries {
            guard HangStackRetention.isHangStackFilename(url.lastPathComponent) else { continue }
            // An unreadable entry is evidence of nothing, so it is kept.
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            // Neither date readable: keep. Absence of evidence, not evidence of
            // absence — the file could have been written seconds ago.
            guard let modified = values.contentModificationDate ?? values.creationDate else {
                continue
            }
            guard now.timeIntervalSince(modified) >= Double(graceSeconds) else { continue }
            eligible.append(HangStackCandidate(
                url: url, modifiedAt: modified,
                sizeBytes: Int64(values.fileSize ?? 0)))
        }

        eligible.sort {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.url.lastPathComponent > $1.url.lastPathComponent
        }

        return eligible.enumerated().compactMap { index, candidate in
            let tooOld = now.timeIntervalSince(candidate.modifiedAt) > HangStackRetention.maxAge
            let beyondCap = index >= HangStackRetention.maxFiles
            return (tooOld || beyondCap) ? candidate : nil
        }
    }

    /// Deletes the selected files, returning what was ACTUALLY removed — never
    /// what was planned. A failed delete logs and moves on; the next sweep
    /// retries it.
    ///
    /// Every delete is anchored first, the same discipline
    /// `ScratchpadCollector.cleanUp` follows and for the same reason: the path
    /// must resolve to an immediate child of `base`. `candidates()` only ever
    /// produces anchored candidates, but `HangStackCandidate` is a public value
    /// type anyone can construct, so the invariant is checked rather than
    /// assumed this close to `removeItem`.
    public func reap(_ candidates: [HangStackCandidate]) -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        for candidate in candidates {
            guard HangStackRetention.isImmediateChild(candidate.url, of: base) else {
                logger.warning("""
                gc: refusing to remove \(candidate.url.path, privacy: .public) — not an \
                immediate child of hang-stacks base \(self.base.path, privacy: .public)
                """)
                continue
            }
            do {
                try FileManager.default.removeItem(at: candidate.url)
            } catch {
                logger.warning("""
                gc: rm failed for \(candidate.url.path, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
                continue
            }
            files += 1
            bytes += candidate.sizeBytes
        }
        return (files, bytes)
    }
}
