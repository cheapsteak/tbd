import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.app", category: "composer")

extension AppState {

    /// This target's draft, created on first ask and kept for the app's
    /// lifetime — or until `discardComposerDraft` forgets it.
    ///
    /// Kept in an `@ObservationIgnored` dictionary because the DICTIONARY is not
    /// what anything observes: each `ComposerDraft` is itself `@Observable`, and
    /// a view that holds one re-renders on its changes. Making the registry
    /// observable would republish every composer in the app whenever any of them
    /// gained a draft.
    func composerDraft(for key: ComposerKey) -> ComposerDraft {
        if let existing = composerDrafts[key] { return existing }
        let draft = ComposerDraft()
        composerDrafts[key] = draft
        return draft
    }

    /// A local terminal's draft — `composerDraft(for: .terminal(id))`.
    func composerDraft(for terminalID: UUID) -> ComposerDraft {
        composerDraft(for: .terminal(terminalID))
    }

    /// Forget a target's draft — on a successful send, and when its tab closes.
    func discardComposerDraft(for key: ComposerKey) {
        composerDrafts[key] = nil
    }

    /// A local terminal's `discardComposerDraft(for: .terminal(id))`.
    func discardComposerDraft(for terminalID: UUID) {
        discardComposerDraft(for: .terminal(terminalID))
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
        composerFocusTargets.removeValue(forKey: .terminal(terminalID))
        transcriptFocusTargets.removeValue(forKey: .terminal(terminalID))
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
            return try await composerCompletionsFetcher(terminalID)
        } catch {
            logger.debug("""
            completions unavailable for terminal \
            \(terminalID.uuidString, privacy: .public): \(error, privacy: .public)
            """)
            return nil
        }
    }
}
