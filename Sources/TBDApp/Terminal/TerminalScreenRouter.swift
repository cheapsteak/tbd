import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "terminalScreenPull")

/// Where a daemon screen request goes once it reaches the app: the panel whose
/// terminal is the live store for the named session, or nowhere.
///
/// Copied in shape from `TerminalInjectionRouter`, and a **sibling** of it
/// rather than a second closure on it, because the two claims are not the same
/// capability. An injection needs the panel's write descriptor; a panel whose
/// `holderWriteFD` could not be taken runs read-only and reports every write
/// unwritten — and that panel can still answer a screen perfectly well, because
/// reading its own emulator needs no descriptor at all. One registration
/// covering both would make a read-only panel either refuse reads it can serve
/// or claim writes it cannot.
///
/// **Registration is token-scoped**, for `TerminalInjectionRouter`'s reason: a
/// panel unregisters with the token it was given, so a torn-down coordinator
/// cannot remove the entry a successor coordinator for the same session has
/// already installed — the ordinary shape when a tab is rebuilt, and one that
/// would otherwise silently stop answering for a live panel.
///
/// Ordering is not this type's problem and needs no guarantee here. Screen
/// requests are independent reads: each carries its own `requestID`, each is
/// answered from the live terminal at the moment it is handled, and two
/// overlapping requests for one session are *meant* to be two observations.
@MainActor
final class TerminalScreenRouter {
    /// A panel's claim on one session's screen requests. Opaque, and the only
    /// thing that can withdraw the claim.
    struct Registration: Equatable, Sendable {
        let terminalID: UUID
        fileprivate let token: UUID
    }

    /// What a panel answers with.
    ///
    /// A refusal is **named**, not silent, so the daemon stops waiting at once
    /// instead of spending its bound on an answer that was never coming — the
    /// same discipline as an injection ack's `written: false`, and the same
    /// reason: a knowable synchronous refusal reported truthfully is what makes
    /// the answers that are not refusals trustworthy.
    enum Answer: Equatable, Sendable {
        case answered(ViewerScreenPayload, styledCapture: String?)
        case unavailable(SidecarScreenReply.Unavailable)
    }

    private struct Entry {
        let token: UUID
        /// Takes the frame's own target and the request, and answers it. The
        /// target is passed rather than assumed so the panel can verify the
        /// frame is addressed to it.
        let answer: @MainActor (UUID, SidecarScreenRequest) async -> Answer
    }

    private var entries: [UUID: Entry] = [:]

    /// Test-facing: how many sessions currently have a panel claiming them.
    var registrationCount: Int { entries.count }

    /// Test-facing: the closure a panel actually registered for `terminalID`.
    ///
    /// Exists so a test can call the **production** answering closure with a
    /// target the panel does not own. Nothing in production can produce that
    /// call — `answer` looks an entry up by id and passes that same id as the
    /// target — so without this seam the panel's own `target == panelID` check
    /// is unreachable from a test, and a test that builds its own closure
    /// instead only ever asserts on itself.
    func registeredHandlerForTesting(
        terminalID: UUID
    ) -> (@MainActor (UUID, SidecarScreenRequest) async -> Answer)? {
        entries[terminalID]?.answer
    }

    func register(
        terminalID: UUID,
        answer: @escaping @MainActor (UUID, SidecarScreenRequest) async -> Answer
    ) -> Registration {
        let token = UUID()
        entries[terminalID] = Entry(token: token, answer: answer)
        return Registration(terminalID: terminalID, token: token)
    }

    /// Withdraw a claim. A no-op when a newer registration for the same session
    /// has replaced this one.
    func unregister(_ registration: Registration) {
        guard entries[registration.terminalID]?.token == registration.token else { return }
        entries.removeValue(forKey: registration.terminalID)
    }

    /// Answer one screen request from the panel that claims its session.
    ///
    /// `.unavailable(.noPanel)` when nobody claims it — which is not an error:
    /// the daemon can send a request for a session whose panel closed between
    /// the attach record and the frame arriving, and that answer tells it the
    /// truth, which is that its own emulator is the live store after all.
    func answer(_ request: SidecarScreenRequest) async -> Answer {
        guard let entry = entries[request.terminalID] else {
            logger.info("""
                screen request for terminal \
                \(request.terminalID.uuidString, privacy: .public) has no attached panel; \
                answering it unavailable
                """)
            return .unavailable(.noPanel)
        }
        return await entry.answer(request.terminalID, request)
    }
}
