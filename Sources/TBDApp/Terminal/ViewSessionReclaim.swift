import Foundation

/// The facts a terminal coordinator's `deinit` needs in order to reclaim the
/// tmux view session its own preparation created: the bridge that tracks the
/// session, and the generation that names *this* coordinator's preparation of
/// it.
///
/// They exist as a separate lock-guarded holder because of where they are
/// written and where they are read. The write happens on the main actor, when
/// a preparation succeeds; the read happens in a non-isolated `deinit`, which
/// runs on whatever thread drops the last strong reference to the coordinator.
/// As plain stored properties on a non-`@MainActor` class that is an
/// unsynchronized cross-thread read, and its failure is silent in the worst
/// way: `deinit` sees `nil`, skips `cleanupSession`, and the view session —
/// with the worktree window linked into it and that window's pane process —
/// leaks with no diagnostic anywhere.
///
/// In practice the ordering holds today: `SwiftTerm.LocalProcess.delegate` is
/// `weak`, so the last strong reference is SwiftUI's, and SwiftUI releases
/// coordinators on the main thread. That is an assumption about two other
/// components, not an invariant this file enforces — the lock is what turns it
/// into one, at the cost of two `NSLock` acquisitions per panel lifetime.
///
/// Deliberately narrow. The coordinator stays a plain class and its other
/// properties stay unguarded; only the facts a `deinit` reads cross a thread
/// boundary, so only they are published here.
final class ViewSessionReclaim: @unchecked Sendable {
    /// A preparation that succeeded, and everything needed to reclaim it.
    struct Preparation: Sendable {
        let bridge: TmuxBridge
        let generation: UInt64
    }

    private let lock = NSLock()
    private var preparation: Preparation?

    /// Publish the preparation this coordinator owns. Called from the main
    /// actor when `prepareSession` succeeds; a later preparation for the same
    /// coordinator replaces the earlier one.
    func publish(bridge: TmuxBridge, generation: UInt64) {
        lock.withLock { preparation = Preparation(bridge: bridge, generation: generation) }
    }

    /// The published preparation, or `nil` when none has succeeded. Safe to
    /// read from any thread, including a non-isolated `deinit`.
    var published: Preparation? {
        lock.withLock { preparation }
    }
}
