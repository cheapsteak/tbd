import Foundation

/// Which terminals hold an unsent draft in the app's own composer, as the app
/// last reported them (`app.setComposerDrafts`).
///
/// The drafts live only in the app's memory (`AppState+Composer`), so without
/// this report nothing outside the app can tell that closing a terminal would
/// throw one away. `terminal.delete`'s rails refuse such a close, and
/// `terminal.list` shows the flag so a caller can check before it tries.
///
/// The app sends the whole set on every change and whenever its state
/// subscription starts. The router forgets the set when the last subscription
/// closes: a draft does not outlive the app that held it, and a set kept past
/// the app's exit would refuse closes on drafts that no longer exist.
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

    /// Forget every draft — the app that held them is gone.
    public func clear() {
        replace(with: [])
    }
}
