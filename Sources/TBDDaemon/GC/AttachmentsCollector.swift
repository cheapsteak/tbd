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
        guard !liveWorktreeIDs.contains(id) else {
            return .keep(reason: "live-worktree")
        }
        let floor = now().addingTimeInterval(-Double(floorDays) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        // An empty orphan directory is reapable: there is nothing left to protect.
        for file in files {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let modified = attrs[.modificationDate] as? Date else {
                // A file whose age cannot be read is a file whose age is unknown,
                // and unknown is not old.
                return .keep(reason: "age-unreadable")
            }
            if modified > floor { return .keep(reason: "younger-than-floor") }
        }
        return .reap
    }

    /// Unlink the directory and everything in it. Returns whether it went.
    func reap(_ directory: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: directory)
            return true
        } catch {
            return false
        }
    }
}
