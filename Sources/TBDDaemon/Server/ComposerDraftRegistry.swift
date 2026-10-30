import Foundation

/// Which terminals hold an unsent draft in the app's own composer, as the app
/// last reported them (`app.setComposerDrafts`).
///
/// The drafts live only in the app's memory (`AppState+Composer`), so without
/// this report nothing outside the app can tell that closing a terminal would
/// throw one away. `terminal.delete`'s rails refuse such a close, and
/// `terminal.list` shows the flag so a caller can check before it tries.
///
/// The app sends the whole set on every change and each time the daemon
/// acknowledges its state subscription, so every report replaces whatever the
/// last one left. The set outlives the subscription on purpose: a subscription
/// can drop while the app and its drafts live on, and forgetting the set then
/// would leave those drafts unprotected until the app resubscribed. Keeping it
/// fails safe. If the app quits for good, a rails close of a terminal still
/// listed is refused until the caller passes `--force` or the app relaunches
/// and reports again.
public final class ComposerDraftRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var terminalIDs: Set<UUID> = []

    public init() {}

    /// Replace the whole set with the app's latest report.
    public func replace(with terminalIDs: Set<UUID>) {
        lock.withLock { self.terminalIDs = terminalIDs }
    }

    public func hasDraft(terminalID: UUID) -> Bool {
        lock.withLock { terminalIDs.contains(terminalID) }
    }
}
