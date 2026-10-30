import Foundation
import Testing
@testable import TBDDaemonLib

/// Writes a session's files as a spawn made with the composer-draft feature
/// left them: the daemon's spawn record naming `incarnation`, then, when
/// given, the mod's heartbeat at `heartbeatAt` and its saved draft. A spawn
/// record alone reads unknown (`no-alive-file`); with a fresh heartbeat it
/// reads confirmed. A draft carries `restorable`, as the mod writes it; a
/// draft written with `restorable: false` reads unknown
/// (`draft-not-restorable`). Shared by the coordinator and holder park tests.
func writeComposerDraftSession(
    sessionsDir: URL, sessionID: String, incarnation: UUID,
    heartbeatAt: Date? = nil, hasDraft: Bool? = nil, restorable: Bool = true
) throws {
    try SessionModFiles.writeSpawnRecord(
        .init(sessionId: sessionID, incarnationId: incarnation.uuidString,
              spawnedAtMs: 1, features: ["composer-draft"]),
        sessionsDir: sessionsDir)
    let directory = sessionsDir.appendingPathComponent(sessionID, isDirectory: true)
    if let heartbeatAt {
        let alive = SessionModFiles.AliveRecord(
            sessionId: sessionID, incarnationId: incarnation.uuidString,
            features: ["composer-draft"],
            heartbeatAtMs: Int64((heartbeatAt.timeIntervalSince1970 * 1000).rounded()))
        try JSONEncoder().encode(alive)
            .write(to: directory.appendingPathComponent(SessionModFiles.aliveFileName))
    }
    if let hasDraft {
        let draft = SessionModFiles.ComposerDraftRecord(
            sessionId: sessionID, hasDraft: hasDraft,
            text: hasDraft ? "unsent" : nil, cursor: hasDraft ? 6 : nil,
            restorable: hasDraft ? restorable : nil, savedAtMs: 1)
        try JSONEncoder().encode(draft)
            .write(to: directory.appendingPathComponent(SessionModFiles.composerDraftFileName))
    }
}

/// The park gate's decision table, as a pure function: each row of
/// `docs/specs/2026-10-24-mod-only-park-guard-design.md`, "Which parks go
/// ahead", against each policy. The coordinator tests in
/// `HibernationCoordinatorTests` pin how each decision reaches a real park,
/// and that every park it lets through ends by signal.
@Suite struct ComposerDraftParkGateTests {
    private static let automatic: HibernateEligibilityPolicy =
        .automatic(enabled: true, idleTimeout: 60, idleSince: nil)

    /// One of every policy, so a branch that must hold for all of them is
    /// asserted against all of them.
    private static let everyPolicy: [HibernateEligibilityPolicy] = [
        .manual, .merge, automatic, .profileSwap,
    ]

    /// Every unknown reason a session spawned with the feature can read.
    private static let unknownStatuses: [ComposerDraftStatus] = [
        .unknown(.noAliveFile),
        .unknown(.otherIncarnation),
        .unknown(.staleHeartbeat),
        .unknown(.featureNotRunning),
        .unknown(.unreadableFile),
        .unknown(.draftNotRestorable),
    ]

    /// Row: spawned without the feature. Every park proceeds, by hand,
    /// automatic or a profile swap: nothing saved the draft and nothing can see
    /// it, so nothing is left to wait for.
    @Test func aSessionSpawnedWithoutTheFeatureProceedsUnderEveryPolicy() {
        #expect(Self.everyPolicy.count == 4, "a policy is missing from the table")
        for policy in Self.everyPolicy {
            #expect(ComposerDraftParkGate.decide(status: .legacy, policy: policy) == .proceed,
                    "\(policy) did not park a session spawned without the feature")
        }
    }

    /// Row: spawned with the feature, mod confirmed. Every park proceeds,
    /// with an empty box or a saved draft.
    @Test func aConfirmedSessionProceedsUnderEveryPolicy() {
        for policy in Self.everyPolicy {
            #expect(ComposerDraftParkGate.decide(status: .confirmed, policy: policy) == .proceed)
        }
    }

    /// Row: spawned with the feature, mod not confirmed — the manual park.
    /// It proceeds without asking, for every reason.
    @Test func anUnconfirmedSessionProceedsAtAManualPark() {
        for status in Self.unknownStatuses {
            #expect(ComposerDraftParkGate.decide(status: status, policy: .manual) == .proceed,
                    "a manual park of \(status) did not go ahead")
        }
    }

    /// Row: spawned with the feature, mod not confirmed — the profile swap,
    /// which proceeds like a manual park.
    @Test func anUnconfirmedSessionProceedsAtAProfileSwap() {
        for status in Self.unknownStatuses {
            #expect(ComposerDraftParkGate.decide(status: status, policy: .profileSwap) == .proceed,
                    "a profile swap of \(status) did not go ahead")
        }
    }

    /// Row: spawned with the feature, mod not confirmed — the merge-park and
    /// the idle sweep skip it, carrying the reason the skip logs.
    @Test func anUnconfirmedSessionIsSkippedByMergeParkAndTheIdleSweep() {
        let reasons: [(ComposerDraftStatus, String)] = [
            (.unknown(.noAliveFile), "no-alive-file"),
            (.unknown(.otherIncarnation), "other-incarnation"),
            (.unknown(.staleHeartbeat), "stale-heartbeat"),
            (.unknown(.featureNotRunning), "feature-not-running"),
            (.unknown(.unreadableFile), "unreadable-file"),
            (.unknown(.draftNotRestorable), "draft-not-restorable"),
        ]
        #expect(reasons.count == Self.unknownStatuses.count, "an unknown reason is missing")
        for (status, reason) in reasons {
            for policy in [HibernateEligibilityPolicy.merge, Self.automatic] {
                #expect(ComposerDraftParkGate.decide(status: status, policy: policy)
                    == .skip(reason: reason))
            }
        }
    }

    @Test func theSkipReasonNamesTheUnknownReason() {
        #expect(ComposerDraftParkGate.skipReason("no-alive-file")
            == "TBD can't confirm this session's draft is saved (no-alive-file).")
    }
}
