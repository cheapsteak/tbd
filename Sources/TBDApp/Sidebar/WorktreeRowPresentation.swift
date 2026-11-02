import AppKit
import TBDShared

/// The pure decisions behind a worktree row: what its leading slot shows,
/// whether a terminal counts as working, the subtitle while it is created,
/// the dev-server dot, and the cached PR status icons. View-free, so
/// `SidebarRowModelFactory` and the row cells share one rule and a test can
/// call it without an `AppState` or a view hierarchy.
enum WorktreeRowPresentation {
    /// Whether one terminal has foreground work to animate in the sidebar: its
    /// activity column reads `.working`. The column is the agent's own report,
    /// written from the OSC 7501 state Claude Code or Codex emits, so the row
    /// animates exactly while the agent says it is working.
    static func isForegroundWorking(_ terminal: TBDShared.Terminal) -> Bool {
        terminal.activityState == .working
    }

    /// The leading-slot indicator for one row. Pure, so the rule — in
    /// particular that a remote row still yields its PR badge when it has
    /// one — is unit-testable without an `AppState` or a view hierarchy.
    ///
    /// A `.remote` row is one whose `location` is not `.local`; that is the
    /// only thing read here, and nothing about this makes a remote row look
    /// local — `localPath` is never consulted.
    static func leadingIndicator(
        worktree: Worktree,
        isPending: Bool,
        hasPRStatus: Bool,
        hasUndeterminedPR: Bool = false
    ) -> LeadingRowIndicator? {
        RowStatusIndicator.leading(
            isPending: isPending,
            hasPRStatus: hasPRStatus,
            isRemote: !worktree.location.isLocal,
            hasUndeterminedPR: hasUndeterminedPR
        )
    }

    /// Subtitle under the name while the worktree is `.creating`. A visible
    /// pre-session hook terminal means the git checkout is done and the
    /// blocking pre-session hook is what the user is waiting on.
    static func creatingSubtitle(hasPreSessionTerminal: Bool) -> String {
        hasPreSessionTerminal ? "Running setup…" : "Creating worktree…"
    }

    /// A green dot when any of this worktree's dev servers runs by a live
    /// running file or a live TBD server tab. Never runs `status` commands;
    /// stopped and exited servers show nothing.
    static func showsServerDot(worktreeID: UUID, running: Set<UUID>) -> Bool {
        running.contains(worktreeID)
    }

    /// Cache for sidebar PR status icons, keyed by icon name. The returned
    /// `NSImage` is identity-stable across calls, so a cell that sets the same
    /// icon again hands its image view the instance it already holds, and the
    /// disk I/O (`Bundle.module.url` + `NSImage(contentsOf:)`) runs once per
    /// icon. Main-actor confinement makes this safe without locks.
    @MainActor
    private static var iconCache: [String: NSImage] = [:]

    @MainActor
    static func loadIcon(_ name: String) -> NSImage? {
        if let cached = iconCache[name] { return cached }
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        iconCache[name] = image
        return image
    }
}
