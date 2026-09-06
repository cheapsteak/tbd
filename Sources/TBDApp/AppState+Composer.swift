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
