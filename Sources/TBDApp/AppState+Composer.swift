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
        if case .terminal = key {
            draft.onContentChange = { [weak self] _ in self?.pushComposerDrafts() }
        }
        composerDrafts[key] = draft
        return draft
    }

    /// Local terminals whose composer holds something a close would discard.
    var terminalIDsWithComposerDrafts: Set<UUID> {
        Set(composerDrafts.compactMap { key, draft in
            guard case .terminal(let id) = key, draft.hasContent else { return nil }
            return id
        })
    }

    /// Tell the daemon which terminals hold a composer draft, so a CLI
    /// `terminal close` refuses to discard one and `terminal list` shows it.
    /// Called when a draft gains or loses content, when one is forgotten, and
    /// each time the daemon acknowledges the state subscription. The daemon
    /// keeps the last set it was given even after a subscription drops, so the
    /// report on a resubscribe is what replaces a set gone stale while the
    /// connection was down. An empty set is sent like any other: it is how a
    /// stale entry gets cleared.
    ///
    /// Pushes are chained, and each reads the set when its turn comes rather
    /// than when it was queued: the RPCs travel on separate connections, so
    /// unchained pushes could land out of order and leave the daemon holding
    /// an older set than the app.
    func pushComposerDrafts() {
        let previous = composerDraftsPush
        composerDraftsPush = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await self.composerDraftsSetter(Array(self.terminalIDsWithComposerDrafts))
            } catch {
                logger.debug("composer drafts report failed: \(error, privacy: .public)")
            }
        }
    }

    /// A local terminal's draft — `composerDraft(for: .terminal(id))`.
    func composerDraft(for terminalID: UUID) -> ComposerDraft {
        composerDraft(for: .terminal(terminalID))
    }

    /// Forget a target's draft — on a successful send, and when its tab closes.
    func discardComposerDraft(for key: ComposerKey) {
        let hadContent = composerDrafts[key]?.hasContent ?? false
        composerDrafts[key] = nil
        if hadContent { pushComposerDrafts() }
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
