import Foundation
import Testing
@testable import TBDDaemonLib

/// **A claim sweep takes back only what its app has said it no longer holds.**
///
/// The app tells the daemon which sessions it holds a descriptor for or has an
/// attach in flight for, and the highest `attachSeq` it had sent when it built
/// that set. The daemon may then take back what that app owns on every other
/// session, and nothing else: every other claim is on a pty a live process may
/// be reading, and the daemon's drain beside it would be the double reader. So
/// each condition in `HolderRegistry.reconcileClaims` refuses a take-back on
/// its own, and each test here departs from one baseline in exactly one of
/// them. The baseline is a claim owned by app A under `attachSeq` 5, on a
/// session A did not list, swept through `throughSeq` 5; `actFalseOnlyReports`
/// shows it selected, and `aCandidateIsNotKept` shows it acted on.
///
/// The flag decides whether a sweep acts, never what it selects, so every
/// refusal is checked both ways: a report first, which changes nothing, then a
/// sweep that acts.
///
/// **No holder answers for any session here.** The fixture is
/// `HolderClaimOwnershipTests`': a take-back attempted on it fails at the
/// hand-over and drops its claim, so a claim still recorded afterwards is what
/// "kept" looks like, and nothing here asserts that anything was taken back.
/// The take-back itself, with a real reader on a real pty, is
/// `HolderClaimReconcileLiveTests`'.
///
/// Tier 1: no holder, no pty, no real process.
@Suite struct HolderClaimReconcileTests {

    /// The app every sweep here speaks for.
    private static let appA = HolderClaimOwnershipTests.oldApp
    /// Another live app, with claims of its own.
    private static let appB = HolderClaimOwnershipTests.newApp
    /// A process that held app A's pid before A did: the same number, an
    /// earlier start, so a different identity.
    private static let earlierHolderOfAppAsPID = ProcessIdentity(
        pid: HolderClaimOwnershipTests.oldApp.pid,
        startedAt: HolderClaimOwnershipTests.oldApp.startedAt.addingTimeInterval(-3_600),
        commandLine: HolderClaimOwnershipTests.oldApp.commandLine)

    /// A sweep that found nothing, in either mode.
    private static let nothing = HolderClaimSweep(takenBack: [], wouldTakeBack: [])

    /// What a sweep from app A reports, and then what it does, under one
    /// statement of what A holds. The report changes nothing, so the second
    /// sweep finds what the first did.
    private static func sweepBothWays(
        _ registry: HolderRegistry, held: Set<UUID>, throughSeq: UInt64 = 5
    ) async -> (report: HolderClaimSweep, acted: HolderClaimSweep) {
        let report = await registry.reconcileClaims(
            heldBy: appA, held: held, throughSeq: throughSeq, act: false)
        let acted = await registry.reconcileClaims(
            heldBy: appA, held: held, throughSeq: throughSeq, act: true)
        return (report, acted)
    }

    // MARK: - Each condition refuses on its own

    /// A session the app lists is one it still holds a descriptor for, or is
    /// still attaching. Its claim stands.
    @Test func aHeldClaimIsKept() async {
        let registry = HolderClaimOwnershipTests.registry()
        let session = UUID()
        await registry.recordViewerClaimForTesting(
            terminalID: session, generation: 11, owner: Self.appA, attachSeq: 5)

        let sweep = await Self.sweepBothWays(registry, held: [session])

        #expect(sweep.report == Self.nothing)
        #expect(sweep.acted == Self.nothing)
        #expect(await registry.viewerAttachment(for: session) == 11, """
            a sweep took back a claim on a session its app says it holds, so the daemon would \
            drain a pty a live panel is reading
            """)
    }

    /// A sweep speaks for one app. A claim another app owns is on a pty that
    /// app may be reading, whatever this one says — and so is the claim of an
    /// earlier process that held the same pid.
    @Test func anotherAppsClaimIsKept() async {
        let registry = HolderClaimOwnershipTests.registry()
        let othersSession = UUID()
        let reusedPIDSession = UUID()
        await registry.recordViewerClaimForTesting(
            terminalID: othersSession, generation: 11, owner: Self.appB, attachSeq: 5)
        await registry.recordViewerClaimForTesting(
            terminalID: reusedPIDSession, generation: 12, owner: Self.earlierHolderOfAppAsPID,
            attachSeq: 5)

        let sweep = await Self.sweepBothWays(registry, held: [])

        #expect(sweep.report == Self.nothing)
        #expect(sweep.acted == Self.nothing)
        #expect(await registry.viewerAttachmentOwner(for: othersSession) == Self.appB, """
            one app's sweep took back a claim another app owns
            """)
        #expect(
            await registry.viewerAttachmentOwner(for: reusedPIDSession)
                == Self.earlierHolderOfAppAsPID, """
            a sweep matched a claim by pid alone, so a reused pid took back a claim its app \
            never owned
            """)
    }

    /// An attach numbered after the app built its held set is one that set
    /// says nothing about: its request may still be on the wire, overtaken by
    /// the sweep on a separate connection.
    @Test func aClaimAboveThroughSeqIsKept() async {
        let registry = HolderClaimOwnershipTests.registry()
        let session = UUID()
        await registry.recordViewerClaimForTesting(
            terminalID: session, generation: 11, owner: Self.appA, attachSeq: 6)

        let sweep = await Self.sweepBothWays(registry, held: [])

        #expect(sweep.report == Self.nothing)
        #expect(sweep.acted == Self.nothing)
        #expect(await registry.viewerAttachment(for: session) == 11, """
            a sweep took back an attach numbered after it built its held set
            """)
    }

    /// An older app numbers nothing, and its claims behave as before: no sweep
    /// takes one back.
    @Test func aClaimWithoutASeqIsKept() async {
        let registry = HolderClaimOwnershipTests.registry()
        let session = UUID()
        await registry.recordViewerClaimForTesting(
            terminalID: session, generation: 11, owner: Self.appA, attachSeq: nil)

        let sweep = await Self.sweepBothWays(registry, held: [])

        #expect(sweep.report == Self.nothing)
        #expect(sweep.acted == Self.nothing)
        #expect(await registry.viewerAttachment(for: session) == 11, """
            a sweep took back a claim with no attachSeq, which no sweep can order against
            """)
    }

    /// A pending attach whose recipient is not recorded yet names no app, so
    /// no app's sweep can speak for it. It stays pending, for the attach
    /// handler's record or its ready-timeout to settle.
    @Test func anUnsentPendingAttachIsSkipped() async {
        let registry = HolderClaimOwnershipTests.registry()
        let session = UUID()
        await registry.recordPendingAttachForTesting(
            terminalID: session, generation: 11,
            reader: HolderClaimOwnershipTests.idleReader(for: session), recipient: nil,
            attachSeq: 5)

        let sweep = await Self.sweepBothWays(registry, held: [])

        #expect(sweep.report == Self.nothing)
        #expect(sweep.acted == Self.nothing)
        #expect(await registry.pendingAttachGeneration(for: session) == 11, """
            a sweep settled or dropped an attach whose recipient was not recorded yet
            """)
        #expect(await registry.viewerAttachment(for: session) == nil)
    }

    /// An attach the app is still waiting on is in its held set. Settling it
    /// into a claim, as a death's pass settles every attach of the dead app,
    /// would refuse its `attach.ready` while the panel is about to read.
    @Test func aHeldPendingAttachIsNotSettled() async {
        let registry = HolderClaimOwnershipTests.registry()
        let session = UUID()
        await registry.recordPendingAttachForTesting(
            terminalID: session, generation: 11,
            reader: HolderClaimOwnershipTests.idleReader(for: session), recipient: Self.appA,
            attachSeq: 5)

        let sweep = await Self.sweepBothWays(registry, held: [session])

        #expect(sweep.report == Self.nothing)
        #expect(sweep.acted == Self.nothing)
        #expect(await registry.pendingAttachGeneration(for: session) == 11, """
            a sweep settled an attach its app is still waiting on, so that attach's ready is \
            refused
            """)
        #expect(await registry.viewerAttachment(for: session) == nil, """
            a sweep turned a held attach into a claim
            """)
    }

    // MARK: - Reporting and acting

    /// With the flag off, the sweep names what it would take back — a claim
    /// and a pending attach alike — and changes nothing.
    @Test func actFalseOnlyReports() async {
        let registry = HolderClaimOwnershipTests.registry()
        let claimed = UUID()
        let vended = UUID()
        await registry.recordViewerClaimForTesting(
            terminalID: claimed, generation: 11, owner: Self.appA, attachSeq: 5)
        await registry.recordPendingAttachForTesting(
            terminalID: vended, generation: 12,
            reader: HolderClaimOwnershipTests.idleReader(for: vended), recipient: Self.appA,
            attachSeq: 4)

        let report = await registry.reconcileClaims(
            heldBy: Self.appA, held: [], throughSeq: 5, act: false)

        #expect(Set(report.wouldTakeBack) == [claimed, vended])
        #expect(report.wouldTakeBack.count == 2)
        #expect(report.takenBack == [])
        #expect(await registry.viewerAttachment(for: claimed) == 11, """
            a report took back a claim
            """)
        #expect(await registry.viewerAttachmentOwner(for: claimed) == Self.appA)
        #expect(await registry.pendingAttachGeneration(for: vended) == 12, """
            a report settled a pending attach
            """)
        #expect(await registry.viewerAttachment(for: vended) == nil)
    }

    /// The baseline, acted on: a claim and a sent pending attach that meet
    /// every condition are no longer recorded. Here each take-back fails at
    /// the hand-over — no holder answers — and drops its claim on the way out,
    /// so neither is counted: `takenBack` lists only take-backs that returned.
    @Test func aCandidateIsNotKept() async {
        let registry = HolderClaimOwnershipTests.registry()
        let claimed = UUID()
        let vended = UUID()
        await registry.recordViewerClaimForTesting(
            terminalID: claimed, generation: 11, owner: Self.appA, attachSeq: 5)
        await registry.recordPendingAttachForTesting(
            terminalID: vended, generation: 12,
            reader: HolderClaimOwnershipTests.idleReader(for: vended), recipient: Self.appA,
            attachSeq: 5)

        let acted = await registry.reconcileClaims(
            heldBy: Self.appA, held: [], throughSeq: 5, act: true)

        #expect(acted == Self.nothing, """
            a sweep counted take-backs that threw
            """)
        #expect(await registry.viewerAttachment(for: claimed) == nil, """
            a sweep left standing a claim its app says it no longer holds
            """)
        #expect(await registry.pendingAttachGeneration(for: vended) == nil, """
            a sweep left pending an attach its app says it no longer holds
            """)
        #expect(await registry.viewerAttachment(for: vended) == nil)
    }

    // MARK: - Logging what it would take back

    /// With the flag off a candidate stands, so every tick selects it again.
    /// Each sweep names it, and it is logged once per attach: a later attach
    /// of the same session, stuck the same way, is a new attach and is logged
    /// again.
    @Test func eachAttachIsLoggedOnce() async {
        let registry = HolderClaimOwnershipTests.registry()
        let session = UUID()
        await registry.recordViewerClaimForTesting(
            terminalID: session, generation: 11, owner: Self.appA, attachSeq: 5)

        let first = await registry.reconcileClaims(
            heldBy: Self.appA, held: [], throughSeq: 5, act: false)
        let second = await registry.reconcileClaims(
            heldBy: Self.appA, held: [], throughSeq: 5, act: false)

        #expect(first.wouldTakeBack == [session])
        #expect(second.wouldTakeBack == [session], """
            a report stopped naming a candidate that still stands
            """)
        #expect(await registry.wouldTakeBackNotices == 1, """
            two reports over one stuck attach logged it twice
            """)

        // The attach ends (here its take-back fails at the hand-over and drops
        // the claim), and the session's next attach gets stuck the same way.
        _ = await registry.reconcileClaims(heldBy: Self.appA, held: [], throughSeq: 5, act: true)
        #expect(await registry.viewerAttachment(for: session) == nil)
        await registry.recordViewerClaimForTesting(
            terminalID: session, generation: 12, owner: Self.appA, attachSeq: 6)

        let later = await registry.reconcileClaims(
            heldBy: Self.appA, held: [], throughSeq: 6, act: false)

        #expect(later.wouldTakeBack == [session])
        #expect(await registry.wouldTakeBackNotices == 2, """
            a later attach of the same session was taken for the one already logged
            """)
    }

    /// What the log remembers is bounded by what still stands: an attach that
    /// has ended is forgotten at the next sweep, even one that selects nothing.
    @Test func anEndedAttachIsForgotten() async {
        let registry = HolderClaimOwnershipTests.registry()
        let session = UUID()
        await registry.recordViewerClaimForTesting(
            terminalID: session, generation: 11, owner: Self.appA, attachSeq: 5)

        _ = await registry.reconcileClaims(heldBy: Self.appA, held: [], throughSeq: 5, act: false)
        #expect(await registry.wouldTakeBacksRemembered == 1)

        // A report for a session the app holds leaves the attach standing,
        // and so remembered.
        _ = await registry.reconcileClaims(
            heldBy: Self.appA, held: [session], throughSeq: 5, act: false)
        #expect(await registry.wouldTakeBacksRemembered == 1, """
            a sweep forgot an attach that still stands, so it would be logged again
            """)

        // The take-back fails at the hand-over here and drops the claim.
        _ = await registry.reconcileClaims(heldBy: Self.appA, held: [], throughSeq: 5, act: true)
        #expect(await registry.viewerAttachment(for: session) == nil)

        let after = await registry.reconcileClaims(
            heldBy: Self.appA, held: [], throughSeq: 5, act: false)

        #expect(after == Self.nothing)
        #expect(await registry.wouldTakeBacksRemembered == 0, """
            the sweep still remembers an attach that has ended, so the set grows for the \
            daemon's life
            """)
        #expect(await registry.wouldTakeBackNotices == 1)
    }

    // MARK: - The cheap gate

    /// The gate a caller asks before it resolves the app's identity applies
    /// every condition it can from the pid alone.
    @Test func hasCandidatesAppliesEveryCheapCondition() async {
        let pid = Self.appA.pid

        let covered = await Self.registryWithOneClaim(owner: Self.appA, attachSeq: 5)
        #expect(await covered.registry.hasCandidates(ownedByPID: pid, held: [], throughSeq: 5), """
            the gate missed an owned, unheld, covered claim
            """)
        #expect(await covered.registry.hasCandidates(
            ownedByPID: pid, held: [covered.session], throughSeq: 5) == false, """
            the gate passed a claim on a session its app holds
            """)

        let sent = HolderClaimOwnershipTests.registry()
        let sentSession = UUID()
        await sent.recordPendingAttachForTesting(
            terminalID: sentSession, generation: 11,
            reader: HolderClaimOwnershipTests.idleReader(for: sentSession), recipient: Self.appA,
            attachSeq: 5)
        #expect(await sent.hasCandidates(ownedByPID: pid, held: [], throughSeq: 5), """
            the gate missed a pending attach delivered to the app
            """)

        let unsent = HolderClaimOwnershipTests.registry()
        let unsentSession = UUID()
        await unsent.recordPendingAttachForTesting(
            terminalID: unsentSession, generation: 11,
            reader: HolderClaimOwnershipTests.idleReader(for: unsentSession), recipient: nil,
            attachSeq: 5)
        #expect(await unsent.hasCandidates(ownedByPID: pid, held: [], throughSeq: 5) == false, """
            the gate passed a pending attach whose recipient is not recorded
            """)

        let later = await Self.registryWithOneClaim(owner: Self.appA, attachSeq: 6)
        #expect(await later.registry.hasCandidates(
            ownedByPID: pid, held: [], throughSeq: 5) == false, """
            the gate passed a claim numbered after the held set was built
            """)

        let unnumbered = await Self.registryWithOneClaim(owner: Self.appA, attachSeq: nil)
        #expect(await unnumbered.registry.hasCandidates(
            ownedByPID: pid, held: [], throughSeq: 5) == false, """
            the gate passed a claim with no attachSeq
            """)

        let others = await Self.registryWithOneClaim(owner: Self.appB, attachSeq: 5)
        #expect(await others.registry.hasCandidates(
            ownedByPID: pid, held: [], throughSeq: 5) == false, """
            the gate passed a claim owned by another pid
            """)
    }

    /// A registry holding one claim, generation 11, and the session it is on.
    private static func registryWithOneClaim(
        owner: ProcessIdentity, attachSeq: UInt64?
    ) async -> (registry: HolderRegistry, session: UUID) {
        let registry = HolderClaimOwnershipTests.registry()
        let session = UUID()
        await registry.recordViewerClaimForTesting(
            terminalID: session, generation: 11, owner: owner, attachSeq: attachSeq)
        return (registry, session)
    }
}
