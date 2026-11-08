import AppKit
import Foundation
import class TBDGhosttyTerminal.GhosttyTerminalView
import TBDShared

/// A weak reference to a mounted terminal's view, for focus. An `NSView`
/// rather than a concrete terminal view type, because a panel's view is
/// whatever its terminal engine draws with.
@MainActor
final class TerminalFocusTarget {
    weak var view: NSView?
    /// Puts back the view's own window hook, which a remote attach
    /// registration chains in front of. Nil for a panel's terminal, whose
    /// registration takes no hook.
    var restoreWindowHook: (() -> Void)?

    init(_ view: NSView) {
        self.view = view
    }
}

/// A terminal engine's view as the remote attach focus registry needs it: one
/// whose window hook a registration can chain a focus claim onto, after the
/// engine's own forwarder, and later take back off.
///
/// Both engines' views conform, so a local PTY built on libghostty is
/// registered, claimed and given up exactly as a SwiftTerm one is. Without
/// that, a libghostty attach pane hidden behind the log fallback would keep
/// focus and send typing to the remote session unseen.
@MainActor
protocol RemoteFocusTerminalView: NSView {
    /// Chains `claim` after the view's own window hook, and returns what puts
    /// the own hook back.
    func chainWindowHook(_ claim: @escaping @MainActor () -> Void) -> () -> Void
}

extension TBDTerminalView: RemoteFocusTerminalView {
    func chainWindowHook(_ claim: @escaping @MainActor () -> Void) -> () -> Void {
        let ownHook = onMovedToWindow
        onMovedToWindow = {
            ownHook?()
            claim()
        }
        return { [weak self] in
            self?.onMovedToWindow = ownHook
        }
    }
}

extension GhosttyTerminalView: RemoteFocusTerminalView {
    func chainWindowHook(_ claim: @escaping @MainActor () -> Void) -> () -> Void {
        let ownHook = onMovedToWindow
        onMovedToWindow = {
            ownHook?()
            claim()
        }
        return { [weak self] in
            self?.onMovedToWindow = ownHook
        }
    }
}

extension AppState {
    func registerTerminalView(_ view: NSView, for terminalID: UUID) {
        terminalFocusTargets[terminalID] = TerminalFocusTarget(view)
    }

    func registerTerminalCloseContext(_ context: TabCloseContext?, for terminalID: UUID) {
        if let context {
            terminalTabCloseContexts[terminalID] = context
        } else {
            terminalTabCloseContexts.removeValue(forKey: terminalID)
        }
    }

    func unregisterTerminalView(_ view: NSView, for terminalID: UUID) {
        guard terminalFocusTargets[terminalID]?.view === view else { return }
        terminalFocusTargets.removeValue(forKey: terminalID)
        terminalTabCloseContexts.removeValue(forKey: terminalID)
    }

    /// The tab ⌘W would close: the one owning the focused terminal view, or the
    /// last-focused context when no terminal view has registered yet.
    ///
    /// The unconditional read of `focusedTabCloseContext` is load-bearing even
    /// though the non-empty branch below ignores its value. Everything that
    /// branch consults is invisible to Observation — `terminalFocusTargets` and
    /// `terminalTabCloseContexts` are `@ObservationIgnored`, and
    /// `NSApp.keyWindow?.firstResponder` is not observable at all — so without
    /// this touch, `canCloseFocusedTab` would register no dependency on the one
    /// property that actually moves when focus does, and the File ▸ Close Tab
    /// item would stay stuck at whatever it computed last. `TerminalPanelView`
    /// writes `focusedTabCloseContext` when a terminal becomes first
    /// responder and clears it when that terminal resigns, however focus
    /// moves, which makes it the best observable proxy available for a
    /// first-responder change.
    ///
    /// It is a proxy, not a mirror: the property only moves for terminals
    /// whose panel transport is live, and focus moving between two
    /// non-terminal views writes nothing. Pressing ⌘W re-resolves from the
    /// first responder regardless, so a stale proxy costs a stale menu state
    /// rather than a wrong close.
    func resolvedFocusedTabCloseContext() -> TabCloseContext? {
        let lastFocused = focusedTabCloseContext
        if terminalFocusTargets.isEmpty {
            return lastFocused
        }
        guard let terminalView = NSApp.keyWindow?.firstResponder as? NSView else {
            return nil
        }
        guard let terminalID = terminalFocusTargets.first(where: { $0.value.view === terminalView })?.key else {
            return nil
        }
        return terminalTabCloseContexts[terminalID]
    }

    func terminalIDForAutofocus(worktreeID: UUID) -> UUID? {
        guard !historyActiveWorktrees.contains(worktreeID),
              let activeTab = resolvedActiveTab(worktreeID: worktreeID)
        else {
            return nil
        }

        let activeLayout = layouts[activeTab.id] ?? .pane(activeTab.content)

        return activeLayout.allTerminalIDs().first
    }

    func focusTerminalAfterSelectionChange(worktreeID: UUID) {
        // Auto-wake: focusing a worktree with hibernated Claude sessions
        // respawns them (`claude --resume`) in their kept-alive windows.
        // Idempotent + singleflighted, so a double-focus won't double-spawn.
        wakeHibernatedTerminalsOnFocus(worktreeID: worktreeID)

        guard let terminalID = terminalIDForAutofocus(worktreeID: worktreeID) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let terminalView = self.terminalFocusTargets[terminalID]?.view,
                  terminalView.window != nil
            else {
                return
            }

            terminalView.window?.makeFirstResponder(terminalView)
            self.focusedTabCloseContext = self.terminalTabCloseContexts[terminalID]
        }
    }
}

extension AppState {
    /// Register the mounted `attach` terminal for `selection`, and have it
    /// claim focus whenever it lands in a window while it is the selected
    /// session: first mount, and a kept-alive pane that a pager tab switch
    /// puts back on screen. Panes of other sessions are out of their window
    /// (the pagers are `NSTabViewController`s); the selected session's own
    /// pane can be in its window but transparent, which the claim's
    /// `remoteAttachSlotShownSelection` check covers.
    ///
    /// The view's `onMovedToWindow` already belongs to the terminal engine
    /// that owns the view, which forwards it to its delegate. The claim is
    /// chained after that hook, never in place of it, and unregistering puts
    /// the hook back. A registration that supersedes another for the same
    /// selection puts the superseded view's hook back first, so hooks never
    /// stack and a superseded view never claims for its replacement.
    func registerRemoteTerminalView(_ view: any RemoteFocusTerminalView, for selection: RemoteSessionSelection) {
        remoteTerminalFocusTargets[selection]?.restoreWindowHook?()
        let target = TerminalFocusTarget(view)
        target.restoreWindowHook = view.chainWindowHook { [weak self] in
            self?.focusRemoteTerminalAfterSelectionChange(selection)
        }
        remoteTerminalFocusTargets[selection] = target
    }

    /// Called by `RemoteSessionDetailView` whenever the selection whose
    /// attach slot it shows changes — including a change in what fills the
    /// pane (the session going gone and falling back to the log view, say),
    /// which moves nothing in or out of a window and so never reaches
    /// `onMovedToWindow`.
    ///
    /// Hiding the slot also takes focus back from a pane that holds it: the
    /// log fallback keeps the pane in its window at zero opacity, so focus
    /// left there would send typing to the remote session unseen. A pane that
    /// leaves its window (a switch to another session) resigns on its own.
    func setRemoteAttachSlotShown(_ selection: RemoteSessionSelection?) {
        if let previous = remoteAttachSlotShownSelection, previous != selection,
           let hidden = remoteTerminalFocusTargets[previous]?.view,
           let window = hidden.window, window.firstResponder === hidden {
            window.makeFirstResponder(nil)
        }
        remoteAttachSlotShownSelection = selection
        if let selection {
            focusRemoteTerminalAfterSelectionChange(selection)
        }
    }

    /// Identity-guarded: a superseded view's dismantle, which can land after
    /// its replacement registered, leaves the replacement alone. Its own hook
    /// was put back when it was superseded.
    func unregisterRemoteTerminalView(_ view: any RemoteFocusTerminalView, for selection: RemoteSessionSelection) {
        guard let target = remoteTerminalFocusTargets[selection], target.view === view else { return }
        target.restoreWindowHook?()
        remoteTerminalFocusTargets.removeValue(forKey: selection)
    }

    /// The remote counterpart of `focusTerminalAfterSelectionChange`. A kept-
    /// alive pane never re-runs its spawn-time focus claim, so without this a
    /// revisited session draws a hollow cursor until the user presses Tab.
    /// Deferred one main turn, and re-checked then: the selection may have
    /// moved on, the detail view may not be showing its attach slot (the Log
    /// tab leaves the pane in its window at zero opacity, where typing would
    /// reach the session unseen), and a pane not yet in a window is left to
    /// `onMovedToWindow`. The selection path and the view's
    /// `setRemoteAttachSlotShown` both claim, so whichever lands after the
    /// view has rendered the new selection is the one that succeeds.
    func focusRemoteTerminalAfterSelectionChange(_ selection: RemoteSessionSelection) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.selectedRemoteSession == selection,
                  self.remoteAttachSlotShownSelection == selection,
                  let terminalView = self.remoteTerminalFocusTargets[selection]?.view,
                  let window = terminalView.window,
                  window.firstResponder !== terminalView
            else {
                return
            }
            window.makeFirstResponder(terminalView)
        }
    }
}

extension AppState {
    /// Install the app's answer to a daemon injection, once, for the app's
    /// life.
    ///
    /// The daemon sends an `.injection` frame for a holder-backed session a
    /// viewer has attached, rather than writing the pty itself, so the app is
    /// that session's only writer and a daemon write can never shear a
    /// keystroke or land inside a bracketed paste. This is where that frame
    /// becomes a write, and where the answer the daemon is waiting on is sent.
    ///
    /// **The main-actor hop is required, not incidental.** The handler runs on
    /// the sidecar's receive thread, and everything it needs — the injection
    /// router, the panel's outgoing queue — is main-actor-isolated, so the
    /// work is moved rather than reached for.
    ///
    /// **The ack is always sent, on every path.** No panel, a dead `AppState`,
    /// a panel whose write destination is gone: each answers `written: false`,
    /// which is what turns the daemon's five-second deadline into an immediate
    /// direct write. Silence would be the one answer that costs the session
    /// five seconds for no reason.
    ///
    /// Installed in `init` and never replaced, so it survives every sidecar
    /// reconnect — `FDSidecarClient` reads the handler per frame rather than
    /// capturing it per connection.
    func installInjectionHandler() {
        let sidecar = daemonClient.fdSidecar
        sidecar.setOnInjection { [weak self] header, bytes in
            Task { @MainActor in
                let written: Bool
                if let self {
                    written = await self.terminalInjections.deliver(
                        terminalID: header.terminalID, bytes: bytes) ?? false
                } else {
                    written = false
                }
                sidecar.sendInjectionAck(injectionID: header.injectionID, written: written)
            }
        }
    }

    /// Install the app's answer to a daemon screen request, once, for the app's
    /// life.
    ///
    /// While a panel is attached to a holder-backed session its terminal is the
    /// live store and the daemon's retained emulator is frozen at the attach,
    /// so a machine read or the input path's mode oracle has to ask the app
    /// rather than guess. This is where that frame becomes a projection, and
    /// where the answer the daemon is waiting on is sent.
    ///
    /// **The main-actor hop is required, not incidental.** The handler runs on
    /// the sidecar's receive thread, and everything it needs — the screen
    /// router, the panel's terminal view — is main-actor-isolated, so the work
    /// is moved rather than reached for. It is also where the single
    /// `withTerminal` hold happens, which is what makes the answer one
    /// observation.
    ///
    /// **A reply is sent on every path.** No panel, a dead `AppState`, a panel
    /// whose terminal is gone: each answers with a named `unavailable` reason,
    /// which is what turns the daemon's bound into an immediate fallback.
    /// Silence is the one answer that costs the session the whole bound for no
    /// reason.
    ///
    /// Installed in `init` and never replaced, so it survives every sidecar
    /// reconnect — `FDSidecarClient` reads the handler per frame rather than
    /// capturing it per connection.
    func installScreenRequestHandler() {
        let sidecar = daemonClient.fdSidecar
        sidecar.setOnScreenRequest { [weak self] request in
            Task { @MainActor in
                let answer: TerminalScreenRouter.Answer
                if let self {
                    answer = await self.terminalScreens.answer(request)
                } else {
                    answer = .unavailable(.noPanel)
                }
                switch answer {
                case .answered(let payload, let styledCapture):
                    sidecar.sendScreenReply(
                        SidecarScreenReply(
                            requestID: request.requestID,
                            terminalID: request.terminalID,
                            screen: payload,
                            styledCapture: styledCapture))
                case .unavailable(let reason):
                    sidecar.sendScreenReply(
                        SidecarScreenReply(
                            requestID: request.requestID,
                            terminalID: request.terminalID,
                            unavailable: reason))
                }
            }
        }
    }
}
