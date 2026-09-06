import Foundation
import TBDShared

/// Decides what to do with one directory under `~/tbd/attachments`.
///
/// Pure and injectable, so every case is stated in one line of a test without a
/// filesystem walk or a database.
struct AttachmentsCollector: Sendable {
    enum Decision: Equatable, Sendable {
        case keep(reason: String)
        case reap
        /// The directory names a worktree row that still exists. The directory
        /// itself always stays — even once it holds nothing — and each staged
        /// file the floor has passed goes on its own.
        case reapFiles(stale: [URL], kept: [KeptFile])
    }

    /// One file inside a live worktree's directory that stays, and why.
    struct KeptFile: Equatable, Sendable {
        let file: URL
        let reason: String
    }

    /// How long an orphan's files must have sat untouched before they go.
    ///
    /// A soak knob, not a load-bearing number. It exists because the failure it
    /// guards against is asymmetric: a leaked image is a few hundred kilobytes a
    /// later sweep still finds, while a wrong reap destroys something a person
    /// staged for a message they have not sent yet — and a draft can sit unsent
    /// across a weekend.
    static let defaultFloorDays = 14

    let base: URL
    /// The date seam. Ages here are persisted file timestamps compared against a
    /// time, which is data rather than behavior, so this is a `Date` provider
    /// and not a `Clock` — and it is the sweep's single reading of now, handed
    /// down so a test can state a fixture's age exactly.
    let now: @Sendable () -> Date

    init(base: URL, now: @escaping @Sendable () -> Date) {
        self.base = base
        self.now = now
    }

    /// Every directory directly under the attachments base.
    ///
    /// A non-directory entry is not a candidate at all, matching
    /// `HolderRendezvousCollector.candidates()`: the wrong node type is filtered
    /// out here rather than classified by `decide`, which never considered it.
    /// Without this, a bare-UUID *file* at the top level would read as an
    /// orphan directory whose `contentsOfDirectory` comes back empty — reaped
    /// on the very first sweep past the floor.
    func candidates() -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    /// **Every branch fails toward keeping.**
    func decide(_ directory: URL, liveWorktreeIDs: Set<UUID>, floorDays: Int) -> Decision {
        // A whitelist: only a directory whose name IS a worktree UUID is a
        // candidate at all. Anything else a human or a future feature put here is
        // left alone rather than classified by a rule that never considered it.
        guard let id = UUID(uuidString: directory.lastPathComponent) else {
            return .keep(reason: "not-a-worktree-id")
        }
        let floor = now().addingTimeInterval(-Double(floorDays) * 86_400)
        if liveWorktreeIDs.contains(id) {
            return decideLiveWorktree(directory, floor: floor)
        }
        // **An unreadable directory is not an empty one.** Reading through `try?`
        // and falling back to `[]` made a directory the sweep cannot open — a
        // permissions problem, a volume that answered badly — look like a
        // directory with nothing in it, and an empty orphan is reapable. The
        // failure would have destroyed exactly the files it could not see.
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return .keep(reason: "contents-unreadable")
        }
        for file in files {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let modified = attrs[.modificationDate] as? Date else {
                // A file whose age cannot be read is a file whose age is unknown,
                // and unknown is not old.
                return .keep(reason: "age-unreadable")
            }
            if modified > floor { return .keep(reason: "younger-than-floor") }
        }
        // An EMPTY orphan directory gets the floor too, measured on its own
        // mtime: it has no file to age, and a directory minted moments ago is a
        // composer somebody has open whose first image has not landed yet. Only
        // past the floor is there nothing left to protect.
        if files.isEmpty {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: directory.path),
                  let modified = attrs[.modificationDate] as? Date else {
                return .keep(reason: "age-unreadable")
            }
            if modified > floor { return .keep(reason: "younger-than-floor") }
        }
        return .reap
    }

    /// A live worktree's directory outlives its files.
    ///
    /// The row is what makes the directory worth keeping, so the directory
    /// stays for as long as the row does — but the images inside it do not age
    /// with the worktree. A staged file is read at paste time, or at resume
    /// time on the wake path, so it is needed for minutes; one the floor has
    /// passed is spent, and the same fourteen days that govern an orphan govern
    /// it. Every branch here still fails toward keeping.
    private func decideLiveWorktree(_ directory: URL, floor: Date) -> Decision {
        // An unreadable directory is not an empty one, exactly as in the orphan
        // branch: it yields no files to classify, so nothing here may act.
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return .keep(reason: "contents-unreadable")
        }
        var stale: [URL] = []
        var kept: [KeptFile] = []
        for entry in entries {
            // Only a regular file is a staged image. A subdirectory, a symlink,
            // or anything else a later feature puts here is left alone rather
            // than classified by a rule that never considered it.
            guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true else { continue }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: entry.path),
                  let modified = attrs[.modificationDate] as? Date else {
                // A file whose age cannot be read is a file whose age is
                // unknown, and unknown is not old.
                kept.append(KeptFile(file: entry, reason: "age-unreadable"))
                continue
            }
            if modified > floor {
                kept.append(KeptFile(file: entry, reason: "younger-than-floor"))
            } else {
                stale.append(entry)
            }
        }
        return .reapFiles(stale: stale, kept: kept)
    }

    /// Unlink one node: a whole orphan directory with everything in it, or a
    /// single staged file inside a live worktree's. Returns whether it went.
    func reap(_ node: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: node)
            return true
        } catch {
            return false
        }
    }
}
