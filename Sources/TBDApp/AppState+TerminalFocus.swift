import AppKit
import Foundation

@MainActor
final class TerminalFocusTarget {
    weak var view: TBDTerminalView?

    init(_ view: TBDTerminalView) {
        self.view = view
    }
}

extension AppState {
    func registerTerminalView(_ view: TBDTerminalView, for terminalID: UUID) {
        terminalFocusTargets[terminalID] = TerminalFocusTarget(view)
    }

    func registerTerminalCloseContext(_ context: TabCloseContext?, for terminalID: UUID) {
        if let context {
            terminalTabCloseContexts[terminalID] = context
        } else {
            terminalTabCloseContexts.removeValue(forKey: terminalID)
        }
    }

    func unregisterTerminalView(_ view: TBDTerminalView, for terminalID: UUID) {
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
    /// writes `focusedTabCloseContext` on mouse-driven focus changes, in and
    /// out, which makes it the best observable proxy available for a
    /// first-responder change.
    ///
    /// It is a proxy, not a mirror. Focus can also move programmatically —
    /// `makeFirstResponder` from the webview find bar, an inline rename field,
    /// a submitting text editor — and those paths do not write the property, so
    /// Close Tab can stay *enabled* after focus leaves a terminal that way.
    /// Pressing ⌘W then re-resolves and no-ops, so the consequence is a stale
    /// menu state rather than a wrong close. Closing that gap properly means
    /// writing nil on resign-first-responder, which is a change to the focus
    /// bookkeeping rather than to this read.
    func resolvedFocusedTabCloseContext() -> TabCloseContext? {
        let lastFocused = focusedTabCloseContext
        if terminalFocusTargets.isEmpty {
            return lastFocused
        }
        guard let terminalView = NSApp.keyWindow?.firstResponder as? TBDTerminalView else {
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
}
