import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "terminalInjection")

/// Where a daemon injection goes once it reaches the app: the panel that owns
/// the named session's pty, or nowhere.
///
/// A holder-backed panel holds its session's pty master while it is attached,
/// which is precisely why the daemon hands it the write instead of racing it
/// (`docs/specs/2026-08-30-pty-holder-session-transport-design.md`, "Input is
/// not arbitrated, but it is serialized"). This is the lookup that makes that
/// possible, and it is deliberately its own small thing rather than a reach
/// into panel state: the injection frame names its target, and the target is
/// resolved by *that name*.
///
/// **Registration is token-scoped.** A panel unregisters with the token it was
/// given, so a torn-down coordinator cannot remove the entry a successor
/// coordinator for the same session has already installed — the ordinary
/// shape when a tab is rebuilt, and one that would otherwise silently stop
/// routing to a live panel.
///
/// Ordering is not this type's problem and is not guaranteed by it: injections
/// arrive one per sidecar frame and each is delivered from its own main-actor
/// hop. Nothing here would keep two injections for one session in order — the
/// daemon is what does, by running every `terminal.send` for a terminal in a
/// serializer lane and waiting for the ack before returning, so a second
/// injection for that session cannot be on the wire while the first is
/// unresolved.
@MainActor
final class TerminalInjectionRouter {
    /// A panel's claim on one session's injections. Opaque, and the only thing
    /// that can withdraw the claim.
    struct Registration: Equatable, Sendable {
        let terminalID: UUID
        fileprivate let token: UUID
    }

    private struct Entry {
        let token: UUID
        /// Takes the frame's own target and its bytes, and answers whether
        /// anything wrote them. The target is passed rather than assumed so
        /// the panel can verify the frame is addressed to it.
        let deliver: @MainActor (UUID, Data) async -> Bool
    }

    private var entries: [UUID: Entry] = [:]

    /// Test-facing: how many sessions currently have a panel claiming them.
    var registrationCount: Int { entries.count }

    /// Test-facing: the closure a panel actually registered for `terminalID`.
    ///
    /// Exists so a test can call the **production** delivery closure with a
    /// target the panel does not own. Nothing in production can produce that
    /// call — `deliver` looks an entry up by id and passes that same id as the
    /// target — so without this seam the panel's own `target == panelID` check
    /// is unreachable from a test, and a test that builds its own closure
    /// instead only ever asserts on itself.
    func registeredHandlerForTesting(
        terminalID: UUID
    ) -> (@MainActor (UUID, Data) async -> Bool)? {
        entries[terminalID]?.deliver
    }

    /// Whether some panel currently owns this session's pty.
    ///
    /// A claim is taken the instant `attach.ready` is accepted and withdrawn by
    /// `stopHolderReader`, so it is true over exactly the span in which the
    /// daemon is NOT this session's reader. That makes it the app's answer to
    /// the question the daemon fail-closes on: a manual park asked for now
    /// would be refused, because the pending-input rail cannot read a screen
    /// the daemon no longer has. The menu reads it so the refusal is never
    /// offered as an action.
    ///
    /// It is a fact about *this app's* panels, not about the daemon's viewer
    /// table, and the two can disagree for the width of an attach or detach
    /// RPC. That is why the daemon keeps its own refusal: this one is the UX.
    func holdsPTY(terminalID: UUID) -> Bool {
        entries[terminalID] != nil
    }

    func register(
        terminalID: UUID, deliver: @escaping @MainActor (UUID, Data) async -> Bool
    ) -> Registration {
        let token = UUID()
        entries[terminalID] = Entry(token: token, deliver: deliver)
        return Registration(terminalID: terminalID, token: token)
    }

    /// Withdraw a claim. A no-op when a newer registration for the same
    /// session has replaced this one.
    func unregister(_ registration: Registration) {
        guard entries[registration.terminalID]?.token == registration.token else { return }
        entries.removeValue(forKey: registration.terminalID)
    }

    /// Hand `bytes` to the panel that claims `terminalID`.
    ///
    /// `nil` means nobody claims it — which is not an error: the daemon can
    /// send an injection for a session whose panel closed between the attach
    /// record and the frame arriving. The caller answers the daemon `written:
    /// false` for it, which is what makes the daemon write the bytes itself
    /// immediately rather than waiting out its deadline.
    func deliver(terminalID: UUID, bytes: Data) async -> Bool? {
        guard let entry = entries[terminalID] else {
            logger.info(
                "injection for terminal \(terminalID.uuidString, privacy: .public) has no attached panel; reporting it unwritten")
            return nil
        }
        return await entry.deliver(terminalID, bytes)
    }
}
