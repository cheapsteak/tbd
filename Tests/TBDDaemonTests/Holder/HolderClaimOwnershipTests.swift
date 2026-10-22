import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
import TBDShared

/// **An app's death takes back that app's sessions, and nobody else's.**
///
/// A confirmed death is evidence about one process: its descriptors closed
/// with it. It says nothing about any other process holding a pty — and the
/// moment that matters most is exactly when another one does. An old app that
/// was still exiting at its disconnect is confirmed gone only on a re-check,
/// and by then a new app may have connected and attached its own tabs. Taking
/// those back too would put the daemon's drain on ptys the new app is reading:
/// the double-reader byte theft the holder transport exists to prevent, and
/// the one failure it cannot recover from.
///
/// So every viewer claim records the app its descriptor was vended to, and a
/// death selects by that owner. A claim whose owner is unknown is selected by
/// no death at all — the fail-closed posture `.undetermined` takes.
///
/// **No holder answers for any session here.** Every claim is bookkeeping
/// alone, recorded through `recordViewerClaimForTesting`, so a take-back of
/// one fails at the hand-over — nothing listens at the rendezvous path under a
/// `TBD_HOME` that does not exist — and drops the claim on its way out, which
/// is `takeBackFromViewer`'s failure arm. A claim's absence afterwards is what
/// "taken back" looks like in this suite. The resume itself, with a real
/// reader on a real pty, is `HolderAppDeathSeizureTests`' to prove.
///
/// Tier 1: no holder, no pty, no real process, and virtual time.
@Suite(.clockDriven) struct HolderClaimOwnershipTests {

    private static let appExecutable = "/opt/tbd/.build/debug/TBDApp"
    /// The app that was running before the update.
    private static let oldApp = ProcessIdentity(
        pid: 4242, startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        commandLine: appExecutable)
    /// The app the update launched in its place.
    private static let newApp = ProcessIdentity(
        pid: 5353, startedAt: Date(timeIntervalSince1970: 1_700_000_120),
        commandLine: appExecutable)

    private static func registry() -> HolderRegistry {
        HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": "/nonexistent/acme-tbd-home"],
            listTerminals: { [] })
    }

    // MARK: - Scoped to the owner

    /// The selection itself, without an arbiter in front of it: the dead app's
    /// claim goes, and the new app's claims stay with the new app.
    @Test func aConfirmedDeathTakesBackOnlyTheClaimsThatAppOwns() async {
        let registry = Self.registry()
        let oldSession = UUID()
        let newSessions = [UUID(), UUID()]
        await registry.recordViewerClaimForTesting(
            terminalID: oldSession, generation: 1, owner: Self.oldApp)
        await registry.recordViewerClaimForTesting(
            terminalID: newSessions[0], generation: 2, owner: Self.newApp)
        await registry.recordViewerClaimForTesting(
            terminalID: newSessions[1], generation: 3, owner: Self.newApp)
        #expect(await registry.sessionsHeld(by: Self.oldApp) == 1)
        #expect(await registry.sessionsHeld(by: Self.newApp) == 2)

        await registry.reclaimSessions(heldBy: Self.oldApp)

        #expect(await registry.viewerAttachment(for: oldSession) == nil, """
            the dead app's claim outlived it, so its session stays undrained and refused to \
            every attach
            """)
        #expect(await registry.sessionsHeld(by: Self.oldApp) == 0)
        for session in newSessions {
            #expect(await registry.viewerAttachmentOwner(for: session) == Self.newApp, """
                a death took back a session another app holds, so the daemon would drain a pty \
                a live process is reading
                """)
        }
        #expect(await registry.sessionsHeld(by: Self.newApp) == 2)
    }

    /// A claim nobody could put a name to — the sidecar never identified the
    /// peer its descriptor went to — is never taken back by a death, whoever
    /// dies. A nil recipient records nothing, so it stays that way.
    @Test func aClaimWithNoRecordedOwnerIsNeverTakenBackByADeath() async {
        let registry = Self.registry()
        let unowned = UUID()
        await registry.recordViewerClaimForTesting(terminalID: unowned, generation: 9, owner: nil)
        await registry.recordAttachRecipient(nil, terminalID: unowned, generation: 9)

        await registry.reclaimSessions(heldBy: Self.oldApp)
        await registry.reclaimSessions(heldBy: Self.newApp)

        #expect(await registry.viewerAttachment(for: unowned) == 9, """
            a claim with no recorded owner was taken back on another app's death — it may be on a \
            pty a live process is reading
            """)
        #expect(await registry.viewerAttachmentOwner(for: unowned) == nil)
    }

    // MARK: - Recording the recipient

    /// The death is remembered. A delivery recorded only after its recipient
    /// was confirmed gone — the attach handler's record is one actor hop behind
    /// the send, and the arbitration runs concurrently with it — is taken back
    /// the moment it names the dead app, rather than holding its session for
    /// the daemon's whole life. A delivery to a live app is only recorded.
    @Test func aDeliveryRecordedAfterItsRecipientWasConfirmedGoneIsTakenBack() async {
        let registry = Self.registry()
        let late = UUID()
        let live = UUID()
        await registry.recordViewerClaimForTesting(terminalID: late, generation: 7, owner: nil)
        await registry.recordViewerClaimForTesting(terminalID: live, generation: 8, owner: nil)

        await registry.reclaimSessions(heldBy: Self.oldApp)
        #expect(await registry.viewerAttachment(for: late) == 7,
                "a claim that did not name the dead app yet was taken back on its death")

        await registry.recordAttachRecipient(Self.oldApp, terminalID: late, generation: 7)
        await registry.recordAttachRecipient(Self.newApp, terminalID: live, generation: 8)

        #expect(await registry.viewerAttachment(for: late) == nil, """
            a delivery to an app already confirmed gone was recorded and left standing, so its \
            session is held by a process that no longer exists
            """)
        #expect(await registry.viewerAttachmentOwner(for: live) == Self.newApp)
    }

    /// A recipient names one attach by its generation, and an attach that has
    /// moved on is not renamed by it.
    @Test func aRecipientForAnAttachThatMovedOnIsNotRecorded() async {
        let registry = Self.registry()
        let session = UUID()
        await registry.recordViewerClaimForTesting(terminalID: session, generation: 3, owner: nil)

        await registry.recordAttachRecipient(Self.oldApp, terminalID: session, generation: 2)

        #expect(await registry.viewerAttachmentOwner(for: session) == nil)
        #expect(await registry.sessionsHeld(by: Self.oldApp) == 0)
    }

    // MARK: - The late verdict, end to end

    /// **The update that bricked a session for two hours**, replayed. The old
    /// app's sidecar drops while it is still exiting, so the first verdict is
    /// alive and the arbiter watches. While it watches, the new app connects
    /// and attaches its own tabs. Then the old app finishes exiting, and the
    /// re-check confirms it: the old app's session comes back to the daemon,
    /// and the new app's sessions — on ptys it is reading — stay exactly where
    /// they are.
    @Test func anOldAppConfirmedDeadLateLeavesTheNewAppsSessionsAlone() async throws {
        let registry = Self.registry()
        let oldSession = UUID()
        let newSessions = [UUID(), UUID()]
        await registry.recordViewerClaimForTesting(
            terminalID: oldSession, generation: 1, owner: Self.oldApp)

        let signaller = FakeProcessSignaller()
        signaller.startTimes[Self.oldApp.pid] = Self.oldApp.startedAt
        signaller.cmdlines[Self.oldApp.pid] = Self.oldApp.commandLine
        let sidecar = SidecarScript()
        let clock = EventDrivenTestClock()
        let arbiter = SidecarDisconnectArbiter(
            liveness: AppLivenessArbiter(signaller: signaller),
            reclaim: { await registry.reclaimSessions(heldBy: $0) },
            sessionsHeld: { await registry.sessionsHeld(by: $0) },
            connectedApp: { sidecar.connected },
            recheckDelays: [.milliseconds(250), .milliseconds(500)],
            clock: clock)

        let arbitration = Task { await arbiter.handleDisconnect(identity: Self.oldApp) }
        // Watching: the drop found the old app still running.
        try await clock.requireSleeperArmed()

        // The new app connects and attaches its tabs while the old one is
        // watched.
        sidecar.connected = Self.newApp
        await registry.recordViewerClaimForTesting(
            terminalID: newSessions[0], generation: 2, owner: Self.newApp)
        await registry.recordViewerClaimForTesting(
            terminalID: newSessions[1], generation: 3, owner: Self.newApp)
        // Then the old app finishes exiting. Written while the arbiter is
        // parked, so nothing reads the table concurrently.
        signaller.behaviors[Self.oldApp.pid] = .init(aliveInitially: false)
        await clock.advance(by: .milliseconds(250))
        let ruling = await arbitration.value

        #expect(ruling.ending == .seized)
        #expect(ruling.checks == 2)
        #expect(await registry.viewerAttachment(for: oldSession) == nil, """
            the old app's claim survived its confirmed death, so every attach to that session is \
            refused for the daemon's whole life
            """)
        for session in newSessions {
            #expect(await registry.viewerAttachmentOwner(for: session) == Self.newApp, """
                the old app's late death took back a session the new app is reading — two readers \
                on one pty
                """)
        }
    }
}
