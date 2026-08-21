import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared

/// Tier 1. Regression cover for the NSError bridge-string defect.
///
/// A Swift error that conforms only to `Error` bridges to `NSError`, and
/// `localizedDescription` on that bridge renders
/// "The operation couldn't be completed. (TBDDaemonLib.GitError error 1.)" —
/// the case name is gone and every payload it carried (command, exit status,
/// git's stderr, a worktree UUID, an errno) is gone with it. The daemon logs
/// caught errors through `os.Logger`, so that string is exactly what a
/// post-mortem finds instead of the diagnosis.
///
/// `localizedDescription` consults `LocalizedError.errorDescription` and
/// nothing else — a `CustomStringConvertible` `description` is not consulted,
/// which is why several of these types render correctly only because they
/// forward one to the other. Every value here is therefore held as `any Error`
/// and read through that existential, exercising the same dynamic-dispatch
/// path a `logger.error("…\(error.localizedDescription)")` call site takes.
/// Binding to the concrete type would let the compiler pick a different
/// overload and prove nothing about those call sites.
@Suite("LocalizedError payload rendering (TBDDaemon)")
struct LocalizedErrorPayloadTests {

    // MARK: - Assertions

    /// The NSError bridge's fixed prefix, in BOTH spellings.
    ///
    /// Foundation renders it with a typographic apostrophe (U+2019), not the
    /// ASCII one — so a check written the obvious way ("couldn't") silently
    /// never fires, and the suite passes against unconverted code on this
    /// assertion alone. Both forms are listed because the localized string is
    /// Foundation's to change, and a check that only ever matched the wrong
    /// one is worse than no check.
    private static let bridgePrefixes = [
        "The operation couldn\u{2019}t be completed",
        "The operation couldn't be completed",
    ]

    /// The bridge's parenthesised suffix, e.g. `(TBDDaemonLib.GitError error 0.)`.
    /// Matched by shape rather than by literal so a renamed module or type
    /// cannot slip a bridge string past this suite.
    private static let bridgeShape =
        #"\([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+ error -?[0-9]+\.\)"#

    /// Reads `localizedDescription` off the existential — the call-site path.
    private func assertNotBridgeString(
        _ error: any Error,
        _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let rendered = error.localizedDescription
        for prefix in Self.bridgePrefixes {
            #expect(
                !rendered.contains(prefix),
                "\(label) rendered the NSError bridge string: \(rendered)",
                sourceLocation: sourceLocation
            )
        }
        #expect(
            rendered.range(of: Self.bridgeShape, options: .regularExpression) == nil,
            "\(label) rendered the NSError bridge shape (Module.Type error N.): \(rendered)",
            sourceLocation: sourceLocation
        )
        #expect(
            !rendered.isEmpty,
            "\(label) rendered an empty description",
            sourceLocation: sourceLocation
        )
    }

    /// Asserts every payload component survives into the rendered text.
    private func assertRenders(
        _ error: any Error,
        _ components: [String],
        _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let rendered = error.localizedDescription
        for component in components {
            #expect(
                rendered.contains(component),
                "\(label) dropped payload \"\(component)\" from: \(rendered)",
                sourceLocation: sourceLocation
            )
        }
    }

    // MARK: - Fixtures

    private static let worktreeID = UUID()
    private static let repoID = UUID()
    private static let recordID = UUID()
    private static let holderID = UUID()
    private static let panelID = PanelID()
    private static let owningTabID = WorkspaceTabID()
    private static let incomingTabID = WorkspaceTabID()

    private static let gitCommand = "git worktree add /private/tmp/acme/wt-7 feature/acme-7"
    private static let gitStderr = "fatal: 'feature/acme-7' is already checked out"

    // MARK: - The table

    /// Representative values across TBDDaemon's error types, held as
    /// `any Error` so the lookup goes through the bridge.
    private func sampleErrors() -> [(String, any Error)] {
        [
            ("GitError", GitError(command: Self.gitCommand, exitCode: 128, stderr: Self.gitStderr)),
            (
                "GitTimeoutError",
                GitTimeoutError(command: "git fetch origin main", timeout: .seconds(120))
            ),
            ("WorktreeLifecycleError.repoNotFound", WorktreeLifecycleError.repoNotFound(Self.repoID)),
            ("WorktreeLifecycleError.worktreeNotFound", WorktreeLifecycleError.worktreeNotFound(Self.worktreeID)),
            (
                "WorktreeLifecycleError.worktreeHasNoRepo",
                WorktreeLifecycleError.worktreeHasNoRepo(Self.worktreeID)
            ),
            ("WorktreeLifecycleError.worktreeNotArchived", WorktreeLifecycleError.worktreeNotArchived(Self.worktreeID)),
            ("WorktreeLifecycleError.createFailed", WorktreeLifecycleError.createFailed("branch already checked out")),
            (
                "WorktreeLifecycleError.worktreePathAlreadyExists",
                WorktreeLifecycleError.worktreePathAlreadyExists("/private/tmp/acme/wt-7")
            ),
            (
                "WorktreeLifecycleError.branchMissingNoFallback",
                WorktreeLifecycleError.branchMissingNoFallback(branch: "feature/acme-7")
            ),
            ("WorktreeMoveError.cycle", WorktreeMoveError.cycle),
            ("WorktreeMoveError.parentIsArchived", WorktreeMoveError.parentIsArchived),
            ("WorktreeArchiveError.hasActiveChildren", WorktreeArchiveError.hasActiveChildren),
            (
                "WorktreeDeletionQueueError.renameFailed",
                WorktreeDeletionQueueError.renameFailed(
                    from: "/private/tmp/acme/wt-7",
                    to: "/private/tmp/acme/.deleting/\(Self.worktreeID.uuidString)",
                    errno: 18
                )
            ),
            (
                "ModelProfileKeychainError.permissionMismatch",
                ModelProfileKeychainError.permissionMismatch("0644, wanted 0600")
            ),
            ("ModelProfileKeychainError.ownerMismatch", ModelProfileKeychainError.ownerMismatch),
            ("ModelProfileKeychainError.ioFailure", ModelProfileKeychainError.ioFailure("read(2) returned EIO")),
            ("ModelProfileKeychainError.dataEncoding", ModelProfileKeychainError.dataEncoding),
            ("OrphanGCError.recordNotFound", OrphanGCError.recordNotFound(Self.recordID)),
            ("OrphanGCError.unsupportedKind", OrphanGCError.unsupportedKind(.scratchpad)),
            ("OrphanGCError.alreadyRestored", OrphanGCError.alreadyRestored(Self.recordID)),
            (
                "ReapSnapshotError.verificationFailed",
                ReapSnapshotError.verificationFailed("refs/tbd-reap/\(Self.recordID.uuidString)")
            ),
            ("ReapSnapshotError.targetExists", ReapSnapshotError.targetExists("/private/tmp/acme/wt-7")),
            ("ReapSnapshotError.nothingToRestore", ReapSnapshotError.nothingToRestore),
            (
                "PanelSurfaceStoreError.panelHistoryOwnedByOtherTab",
                PanelSurfaceStoreError.panelHistoryOwnedByOtherTab(
                    panelID: Self.panelID,
                    existingTabID: Self.owningTabID,
                    incomingTabID: Self.incomingTabID
                )
            ),
            ("PanelSurfaceStoreError.alreadyImported", PanelSurfaceStoreError.alreadyImported),
            (
                "WatchDeskLeaseError.contended",
                WatchDeskLeaseError.contended(
                    holder: Self.holderID,
                    generation: 4207,
                    expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            ),
            ("WatchDeskLeaseError.notHeld", WatchDeskLeaseError.notHeld),
            ("WatchDeskLeaseError.fenced", WatchDeskLeaseError.fenced),
            ("WatchDeskLeaseError.terminalOutsideDesk", WatchDeskLeaseError.terminalOutsideDesk),
        ]
    }

    // MARK: - Tests

    @Test("no TBDDaemon error renders the NSError bridge string")
    func noBridgeStringAnywhere() {
        for (label, error) in sampleErrors() {
            assertNotBridgeString(error, label)
        }
    }

    /// `GitError` and `GitTimeoutError` are declared in `GitManager.swift` and
    /// take their conformance from `GitErrorLocalizedDescriptions.swift`. They
    /// carry the richest payload in the daemon — the failing command, git's own
    /// exit status and its stderr — and are among the most frequently logged,
    /// so they get their own case rather than riding the table.
    @Test("git command, exit status and stderr reach the rendered description")
    func gitPayloadsRender() {
        assertRenders(
            GitError(command: Self.gitCommand, exitCode: 128, stderr: Self.gitStderr),
            [Self.gitCommand, "128", Self.gitStderr],
            "GitError"
        )
        assertRenders(
            GitTimeoutError(command: "git fetch origin main", timeout: .seconds(120)),
            ["git fetch origin main"],
            "GitTimeoutError"
        )
    }

    @Test("errno and path payloads reach the rendered description")
    func errnoAndPathPayloadsRender() {
        let from = "/private/tmp/acme/wt-7"
        let to = "/private/tmp/acme/.deleting/\(Self.worktreeID.uuidString)"
        assertRenders(
            WorktreeDeletionQueueError.renameFailed(from: from, to: to, errno: 18),
            [from, to, "18"],
            "WorktreeDeletionQueueError.renameFailed"
        )
        assertRenders(
            ReapSnapshotError.targetExists("/private/tmp/acme/wt-7"),
            ["/private/tmp/acme/wt-7"],
            "ReapSnapshotError.targetExists"
        )
        assertRenders(
            WorktreeLifecycleError.worktreePathAlreadyExists("/private/tmp/acme/wt-7"),
            ["/private/tmp/acme/wt-7"],
            "WorktreeLifecycleError.worktreePathAlreadyExists"
        )
        assertRenders(
            ModelProfileKeychainError.permissionMismatch("0644, wanted 0600"),
            ["0644, wanted 0600"],
            "ModelProfileKeychainError.permissionMismatch"
        )
    }

    @Test("UUID payloads reach the rendered description")
    func uuidPayloadsRender() {
        assertRenders(
            WorktreeLifecycleError.worktreeNotFound(Self.worktreeID),
            [Self.worktreeID.uuidString],
            "WorktreeLifecycleError.worktreeNotFound"
        )
        assertRenders(
            WorktreeLifecycleError.repoNotFound(Self.repoID),
            [Self.repoID.uuidString],
            "WorktreeLifecycleError.repoNotFound"
        )
        assertRenders(
            WorktreeLifecycleError.worktreeHasNoRepo(Self.worktreeID),
            [Self.worktreeID.uuidString],
            "WorktreeLifecycleError.worktreeHasNoRepo"
        )
        assertRenders(
            OrphanGCError.recordNotFound(Self.recordID),
            [Self.recordID.uuidString],
            "OrphanGCError.recordNotFound"
        )
        assertRenders(
            OrphanGCError.alreadyRestored(Self.recordID),
            [Self.recordID.uuidString],
            "OrphanGCError.alreadyRestored"
        )
        assertRenders(
            PanelSurfaceStoreError.panelHistoryOwnedByOtherTab(
                panelID: Self.panelID,
                existingTabID: Self.owningTabID,
                incomingTabID: Self.incomingTabID
            ),
            [Self.panelID.uuidString, Self.owningTabID.uuidString, Self.incomingTabID.uuidString],
            "PanelSurfaceStoreError.panelHistoryOwnedByOtherTab"
        )
    }

    @Test("lease generation and holder payloads reach the rendered description")
    func leasePayloadsRender() {
        assertRenders(
            WatchDeskLeaseError.contended(
                holder: Self.holderID,
                generation: 4207,
                expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            [Self.holderID.uuidString, "4207"],
            "WatchDeskLeaseError.contended"
        )
    }

    @Test("branch and kind payloads reach the rendered description")
    func branchAndKindPayloadsRender() {
        assertRenders(
            WorktreeLifecycleError.branchMissingNoFallback(branch: "feature/acme-7"),
            ["feature/acme-7"],
            "WorktreeLifecycleError.branchMissingNoFallback"
        )
        assertRenders(
            OrphanGCError.unsupportedKind(.scratchpad),
            [ReapKind.scratchpad.rawValue],
            "OrphanGCError.unsupportedKind"
        )
        assertRenders(
            WorktreeLifecycleError.createFailed("branch already checked out"),
            ["branch already checked out"],
            "WorktreeLifecycleError.createFailed"
        )
    }

    /// Guards the guard: the bridge-shape regex must actually reject a real
    /// bridge string, or `noBridgeStringAnywhere` would pass against
    /// unconverted code and prove nothing.
    @Test("the bridge-shape matcher rejects a genuine bridge string")
    func bridgeShapeMatcherIsNotVacuous() {
        // Spelled with the typographic apostrophe Foundation actually emits.
        let genuine = "The operation couldn\u{2019}t be completed. (TBDDaemonLib.GitError error 1.)"
        #expect(Self.bridgePrefixes.contains { genuine.contains($0) })
        #expect(genuine.range(of: Self.bridgeShape, options: .regularExpression) != nil)

        // …and must not fire on a legitimate rendered payload that happens to
        // carry parentheses and digits.
        let legitimate = WorktreeDeletionQueueError
            .renameFailed(from: "/a", to: "/b", errno: 18)
            .localizedDescription
        #expect(legitimate.range(of: Self.bridgeShape, options: .regularExpression) == nil)
    }
}
