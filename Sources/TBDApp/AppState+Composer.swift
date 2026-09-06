import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.app", category: "composer")

extension AppState {

    /// This terminal's draft, created on first ask and kept for the app's
    /// lifetime — or until `discardComposerDraft` forgets it.
    ///
    /// Kept in an `@ObservationIgnored` dictionary because the DICTIONARY is not
    /// what anything observes: each `ComposerDraft` is itself `@Observable`, and
    /// a view that holds one re-renders on its changes. Making the registry
    /// observable would republish every composer in the app whenever any of them
    /// gained a draft.
    func composerDraft(for terminalID: UUID) -> ComposerDraft {
        if let existing = composerDrafts[terminalID] { return existing }
        let draft = ComposerDraft()
        composerDrafts[terminalID] = draft
        return draft
    }

    /// Forget a terminal's draft — on a successful send, and when its tab closes.
    func discardComposerDraft(for terminalID: UUID) {
        composerDrafts[terminalID] = nil
    }

    /// Forget everything the composer keys on this terminal, because the
    /// terminal itself is gone.
    ///
    /// Called from both deaths a terminal has: the tab close that deletes it,
    /// and `removeDeletedTerminalFromState`, which every other route — a pane
    /// close, an archive, a daemon-reported removal — funnels through. The tab
    /// close alone was not enough: it is the rarer of the two, and a draft left
    /// behind by the common path sits in the map for the app's lifetime, joined
    /// by a fresh empty one whenever a send finishing after the row is gone asks
    /// `composerDraft(for:)` again.
    ///
    /// Memory only, and safe by construction: the terminal row no longer exists,
    /// so nothing can send this draft, mount this composer, or spawn into this
    /// incarnation. The two focus registries hold their views weakly and leak
    /// nothing, but they do accumulate empty boxes, so they are pruned here too.
    ///
    /// Waiters are RESUMED rather than dropped — see
    /// `releaseSessionStartWaiters`.
    func forgetComposerState(for terminalID: UUID) {
        discardComposerDraft(for: terminalID)
        composerFocusTargets.removeValue(forKey: terminalID)
        transcriptFocusTargets.removeValue(forKey: terminalID)
        lastStartedIncarnation.removeValue(forKey: terminalID)
        releaseSessionStartWaiters(terminalID: terminalID)
    }

    /// Whether the daemon reports the composer as enabled. False until
    /// capabilities have been fetched, which is the conservative reading: a
    /// composer that flashed in and then disappeared would be worse than one that
    /// appeared a moment late.
    var transcriptComposerEnabled: Bool {
        daemonCapabilities?.transcriptComposerEnabled ?? false
    }

    /// Fetch this terminal's completion inventory. nil on any failure — the menu
    /// shows its loading row and then simply has nothing to offer, which is a
    /// smaller loss than an error banner over a text field.
    func fetchCompletions(terminalID: UUID) async -> TerminalCompletionsResult? {
        do {
            return try await daemonClient.terminalCompletions(terminalID: terminalID)
        } catch {
            logger.debug("""
            completions unavailable for terminal \
            \(terminalID.uuidString, privacy: .public): \(error, privacy: .public)
            """)
            return nil
        }
    }
}
