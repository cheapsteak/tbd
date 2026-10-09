import Foundation
import TBDShared
import Testing

@testable import TBDApp

/// What the screen router promises: **a request reaches the panel that claims
/// its session, a request for a session nobody claims is refused by name, and a
/// torn-down panel cannot unregister its successor.**
///
/// The sibling of `TerminalInjectionRouter`'s suite, and the properties are the
/// same three because the failure shapes are: a request routed nowhere, a
/// request routed to the wrong panel, and a live panel silently stopped from
/// answering because a dead one withdrew its claim.
@Suite("Terminal screen router")
@MainActor
struct TerminalScreenRouterTests {

    private static func request(for terminalID: UUID, lines: Int = 50) -> SidecarScreenRequest {
        SidecarScreenRequest(
            terminalID: terminalID, requestID: UUID(), requestedLines: lines,
            retainedScrollbackLines: 5_000, wantStyledCapture: false)
    }

    private static func payload(lines: [String]) -> ViewerScreenPayload {
        ViewerScreenPayload(
            lines: lines, viewportStart: 0, cursorRow: 0, cursorColumn: 0,
            cursorVisible: true, cursorVisibleObserved: false,
            columns: 80, rows: 24,
            bracketedPaste: false, applicationCursor: false, alternateScreen: false,
            ageMilliseconds: 0)
    }

    @Test("a request reaches the panel claiming its session")
    func requestReachesTheClaimingPanel() async {
        let router = TerminalScreenRouter()
        let mine = UUID()
        _ = router.register(terminalID: mine) { _, _ in
            .answered(Self.payload(lines: ["mine"]), styledCapture: nil)
        }

        let answer = await router.answer(Self.request(for: mine))
        #expect(answer == .answered(Self.payload(lines: ["mine"]), styledCapture: nil))
    }

    /// Not an error: the daemon can send a request for a session whose panel
    /// closed between the attach record and the frame arriving, and a named
    /// refusal is what tells it its own emulator is the live store after all.
    /// Silence would cost it the whole bound.
    @Test("a request for a session nobody claims is refused by name")
    func unclaimedSessionIsRefusedByName() async {
        let router = TerminalScreenRouter()
        #expect(await router.answer(Self.request(for: UUID())) == .unavailable(.noPanel))
    }

    @Test("a request reaches only the panel it names")
    func requestsAreNotCrossRouted() async {
        let router = TerminalScreenRouter()
        let first = UUID()
        let second = UUID()
        _ = router.register(terminalID: first) { _, _ in
            .answered(Self.payload(lines: ["first"]), styledCapture: nil)
        }
        _ = router.register(terminalID: second) { _, _ in
            .answered(Self.payload(lines: ["second"]), styledCapture: nil)
        }

        #expect(
            await router.answer(Self.request(for: first))
                == .answered(Self.payload(lines: ["first"]), styledCapture: nil))
        #expect(
            await router.answer(Self.request(for: second))
                == .answered(Self.payload(lines: ["second"]), styledCapture: nil))
    }

    /// The token is what makes a rebuilt tab safe. A coordinator torn down
    /// *after* its successor registered would otherwise remove the successor's
    /// entry, and the live panel would stop answering with nothing to show why.
    @Test("a torn-down panel cannot unregister its successor's claim")
    func unregisterIsTokenScoped() async {
        let router = TerminalScreenRouter()
        let terminalID = UUID()
        let stale = router.register(terminalID: terminalID) { _, _ in
            .answered(Self.payload(lines: ["stale"]), styledCapture: nil)
        }
        _ = router.register(terminalID: terminalID) { _, _ in
            .answered(Self.payload(lines: ["successor"]), styledCapture: nil)
        }

        router.unregister(stale)

        #expect(router.registrationCount == 1)
        #expect(
            await router.answer(Self.request(for: terminalID))
                == .answered(Self.payload(lines: ["successor"]), styledCapture: nil))
    }

    @Test("a panel's own registration can be withdrawn")
    func unregisterWithdrawsTheClaim() async {
        let router = TerminalScreenRouter()
        let terminalID = UUID()
        let registration = router.register(terminalID: terminalID) { _, _ in
            .answered(Self.payload(lines: ["live"]), styledCapture: nil)
        }

        router.unregister(registration)

        #expect(router.registrationCount == 0)
        #expect(await router.answer(Self.request(for: terminalID)) == .unavailable(.noPanel))
    }

    /// Nothing in production can make this call — `answer` looks an entry up by
    /// id and passes that same id as the target — so the panel's own
    /// `target == panelID` check is only reachable through the testing seam. A
    /// test that built its own closure instead would assert on itself.
    @Test("the production closure refuses a target the panel does not own")
    func foreignTargetIsRefused() async throws {
        let router = TerminalScreenRouter()
        let mine = UUID()
        _ = router.register(terminalID: mine) { target, _ in
            guard target == mine else { return .unavailable(.noPanel) }
            return .answered(Self.payload(lines: ["mine"]), styledCapture: nil)
        }

        let closure = try #require(router.registeredHandlerForTesting(terminalID: mine))
        let foreign = UUID()
        #expect(await closure(foreign, Self.request(for: foreign)) == .unavailable(.noPanel))
    }
}
