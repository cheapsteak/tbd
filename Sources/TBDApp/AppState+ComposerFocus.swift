import AppKit
import Foundation

/// A weak handle on one composer's text view, so focus can be moved to it from
/// a menu command without the registry keeping a torn-down pane alive.
///
/// The `TerminalFocusTarget` shape (`AppState+TerminalFocus.swift`), for the
/// same reason: focus is a fact about a view that exists right now.
@MainActor
final class ComposerFocusTarget {
    weak var view: NSView?

    init(_ view: NSView) { self.view = view }
}

/// What a composer's wake answered.
///
/// Three cases rather than a `Bool` and an error string, because the middle one
/// is the interesting one: a wake the daemon answered `woken: false` delivered
/// the prompt nowhere, which is neither a success nor a failure and must not be
/// reported as either.
///
/// Named at file scope rather than nested in `ComposerSendCoordinator` so this
/// plumbing compiles before the coordinator exists; the coordinator adopts it
/// as its `WakeReply`.
enum ComposerWakeReply: Equatable, Sendable {
    /// A spawn happened. The incarnation is the id that spawn will echo on its
    /// `SessionStart`, or nil from a daemon that predates the field — in which
    /// case there is nothing to scope a wait to.
    case woken(incarnationID: UUID?)
    /// Idempotent no-op: already awake, or another wake was in flight. The
    /// prompt reached nobody.
    case noOp
    case failed(message: String)
}

extension AppState {
    func registerComposerView(_ view: NSView, for terminalID: UUID) {
        composerFocusTargets[terminalID] = ComposerFocusTarget(view)
    }

    /// Only the CURRENT view may unregister. A pane rebuilt while the old view is
    /// still deallocating would otherwise evict its own replacement.
    func unregisterComposerView(_ view: NSView, for terminalID: UUID) {
        guard composerFocusTargets[terminalID]?.view === view else { return }
        composerFocusTargets.removeValue(forKey: terminalID)
    }

    /// Cmd+/ — put the caret in this terminal's composer. A no-op when no
    /// composer is mounted, which is the honest answer for a pane that is closed.
    func focusComposer(terminalID: UUID) {
        guard let view = composerFocusTargets[terminalID]?.view else { return }
        view.window?.makeFirstResponder(view)
    }

    /// The transcript table this terminal is reading, so Escape in the composer
    /// has somewhere to send focus back to.
    ///
    /// Written from `TableTranscriptView.makeNSView` rather than from a deferred
    /// task: both registries are `@ObservationIgnored`, so the write publishes
    /// nothing and cannot re-enter the view update that is making the view.
    func registerTranscriptView(_ view: NSView, for terminalID: UUID) {
        transcriptFocusTargets[terminalID] = ComposerFocusTarget(view)
    }

    /// Newer-wins, exactly as `unregisterComposerView` is: a session rollover
    /// rebuilds the table under its `.id`, and the outgoing view must not evict
    /// the replacement that has already registered.
    func unregisterTranscriptView(_ view: NSView, for terminalID: UUID) {
        guard transcriptFocusTargets[terminalID]?.view === view else { return }
        transcriptFocusTargets.removeValue(forKey: terminalID)
    }

    /// Escape from the composer — hand focus back to the transcript, which is
    /// where the person was reading.
    func focusTranscript(terminalID: UUID) {
        guard let view = transcriptFocusTargets[terminalID]?.view else {
            // No transcript table registered: give up first responder rather
            // than holding it, so the pane's own key handling resumes.
            composerFocusTargets[terminalID]?.view?.window?.makeFirstResponder(nil)
            return
        }
        view.window?.makeFirstResponder(view)
    }

    /// The Reveal Terminal action on the blocked banner. Answering a dialog in
    /// the terminal is the correct resolution, so the composer's job is to get
    /// the person there rather than to offer a second way to answer.
    func revealTerminal(terminalID: UUID) {
        guard let view = terminalFocusTargets[terminalID]?.view else { return }
        view.window?.makeFirstResponder(view)
        view.window?.makeKeyAndOrderFront(nil)
    }

    /// The Reveal Terminal action's sibling for the wake path: wake this
    /// terminal and report what the daemon answered, incarnation included.
    ///
    /// A sibling of `wakeTerminal` rather than a change to it. That one returns
    /// an error string, which is all its five call sites want, and threading a
    /// result through PR A's shared `terminalWakeSender` seam would change every
    /// one of them to serve one screen. The app's own `wakeInFlight` dedupe is
    /// deliberately not consulted here either: the daemon has its own
    /// `wakesInFlight`, and it answers a racing wake with `woken: false`, which
    /// is exactly the honest reply for a composer — the prompt went nowhere.
    ///
    /// **Returns before the terminal refresh, on purpose.** The refresh is a
    /// second daemon round trip that buys this method nothing the reply
    /// itself needs — the caller's next move is `awaitSessionStart`, scoped to
    /// the incarnation this method already has in hand. Awaiting the refresh
    /// first would open a window between minting that incarnation and the
    /// caller registering its waiter: a `SessionStart` landing in that window
    /// would reach `noteSessionStart` before any waiter existed to release,
    /// stalling the send to its timeout. (`noteSessionStart`'s latch closes
    /// that gap too, independently — this is the other half of the fix.)
    /// Firing the refresh as its own unstructured task keeps it happening
    /// without making the caller wait for it.
    func wakeTerminalForComposer(
        terminalID: UUID, worktreeID: UUID, prompt: String
    ) async -> ComposerWakeReply {
        do {
            let size = mainAreaTerminalSize()
            let result = try await composerWakeSender(
                terminalID, size.cols, size.rows, prompt)
            Task { @MainActor [weak self] in
                await self?.refreshTerminals(worktreeID: worktreeID)
            }
            return result.woken
                ? .woken(incarnationID: result.sessionIncarnationID)
                : .noOp
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }
}

extension AppState {
    /// The terminal the composer menu commands act on.
    ///
    /// `resolvedFocusedTabCloseContext()` is the accessor the Terminal menu's
    /// other items already use to name what has focus. It answers nil while
    /// focus sits in something that is not a terminal view — the transcript
    /// table and the composer itself both qualify, and both are exactly where
    /// somebody pressing these shortcuts is — so the last-focused tab is the
    /// fallback, which is the same value that method falls back to when nothing
    /// has registered at all.
    ///
    /// `terminalIDs(in:)` rather than the layout's own enumeration, because a
    /// `.liveTranscript` tab — the composer's own home — is precisely the shape
    /// `allTerminalIDs()` does not report. A tab rendering several terminals
    /// prefers whichever one has a composer registered, and names the tab's
    /// first otherwise, so the command still points somewhere during the one
    /// main-actor turn before the composer's deferred registration lands.
    var composerCommandTerminalID: UUID? {
        guard let context = resolvedFocusedTabCloseContext() ?? focusedTabCloseContext,
              let tab = tabs[context.worktreeID]?.first(where: { $0.id == context.tabID })
        else { return nil }
        let ids = terminalIDs(in: tab)
        return ids.first(where: { composerFocusTargets[$0]?.view != nil }) ?? ids.first
    }
}
