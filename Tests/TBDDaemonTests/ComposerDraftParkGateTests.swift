import Foundation
import Testing
@testable import TBDDaemonLib

/// Writes a session's files as a spawn made with the composer-draft feature
/// left them: the daemon's spawn record naming `incarnation`, then, when
/// given, the mod's heartbeat at `heartbeatAt` and its saved draft. A spawn
/// record alone reads unknown (`no-alive-file`); with a fresh heartbeat it
/// reads confirmed. Shared by the coordinator and holder park tests.
func writeComposerDraftSession(
    sessionsDir: URL, sessionID: String, incarnation: UUID,
    heartbeatAt: Date? = nil, hasDraft: Bool? = nil
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
            text: hasDraft ? "unsent" : nil, cursor: hasDraft ? 6 : nil, savedAtMs: 1)
        try JSONEncoder().encode(draft)
            .write(to: directory.appendingPathComponent(SessionModFiles.composerDraftFileName))
    }
}

/// The park gate's decision table and its shadow-comparison line, as pure
/// functions. The coordinator tests in `HibernationCoordinatorTests` pin how
/// each decision reaches a real park.
@Suite struct ComposerDraftParkGateTests {
    /// One of every policy, so a branch that must hold for all of them is
    /// asserted against all of them.
    private static let everyPolicy: [HibernateEligibilityPolicy] = [
        .manual,
        .merge(inputVetoEnabled: true),
        .automatic(enabled: true, inputVetoEnabled: true, idleTimeout: 60, idleSince: nil),
        .profileSwap,
    ]

    @Test func legacyKeepsTheOldPath() {
        for policy in Self.everyPolicy {
            for override in [false, true] {
                #expect(ComposerDraftParkGate.decide(
                    status: .legacy, policy: policy, overrideUnconfirmed: override) == .legacy)
            }
        }
    }

    @Test func confirmedProceeds() {
        for policy in Self.everyPolicy {
            for hasDraft in [false, true] {
                #expect(ComposerDraftParkGate.decide(
                    status: .confirmed(hasDraft: hasDraft), policy: policy,
                    overrideUnconfirmed: false) == .proceed)
            }
        }
    }

    @Test func unknownManualRefuses() {
        #expect(ComposerDraftParkGate.decide(
            status: .unknown(.staleHeartbeat), policy: .manual,
            overrideUnconfirmed: false) == .refuse(reason: "stale-heartbeat"))
    }

    @Test func unknownManualWithOverrideProceeds() {
        #expect(ComposerDraftParkGate.decide(
            status: .unknown(.staleHeartbeat), policy: .manual,
            overrideUnconfirmed: true) == .proceed)
    }

    /// The override belongs to the person's manual park; a merge-park skips
    /// whatever it carries.
    @Test func unknownMergeSkips() {
        for override in [false, true] {
            #expect(ComposerDraftParkGate.decide(
                status: .unknown(.noAliveFile), policy: .merge(inputVetoEnabled: false),
                overrideUnconfirmed: override) == .skip(reason: "no-alive-file"))
        }
    }

    @Test func unknownSweepSkips() {
        for override in [false, true] {
            #expect(ComposerDraftParkGate.decide(
                status: .unknown(.otherIncarnation),
                policy: .automatic(
                    enabled: true, inputVetoEnabled: false, idleTimeout: 60, idleSince: nil),
                overrideUnconfirmed: override) == .skip(reason: "other-incarnation"))
        }
    }

    @Test func unknownProfileSwapProceeds() {
        #expect(ComposerDraftParkGate.decide(
            status: .unknown(.unreadableFile), policy: .profileSwap,
            overrideUnconfirmed: false) == .proceed)
    }

    @Test func agreementLogsNothing() {
        let id = UUID()
        #expect(ComposerDraftParkGate.shadowDisagreement(
            terminalID: id, featureHasDraft: true, scrapeHasDraft: true) == nil)
        #expect(ComposerDraftParkGate.shadowDisagreement(
            terminalID: id, featureHasDraft: false, scrapeHasDraft: false) == nil)
    }

    @Test func disagreementComposesTheLine() throws {
        let id = try #require(UUID(uuidString: "6F1C2A4E-0B7D-4C1A-9E3F-2D5B8A7C6E10"))
        #expect(ComposerDraftParkGate.shadowDisagreement(
            terminalID: id, featureHasDraft: true, scrapeHasDraft: false)
            == "composer-draft shadow disagreement terminal=6F1C2A4E-0B7D-4C1A-9E3F-2D5B8A7C6E10 feature=draft scrape=empty")
        #expect(ComposerDraftParkGate.shadowDisagreement(
            terminalID: id, featureHasDraft: false, scrapeHasDraft: true)
            == "composer-draft shadow disagreement terminal=6F1C2A4E-0B7D-4C1A-9E3F-2D5B8A7C6E10 feature=empty scrape=draft")
    }

    /// The scrape refuses only a legacy session's park, whatever it reads; a
    /// confirmed or unconfirmed-but-proceeding session is never refused on it.
    /// The fast rail and the authoritative read answer alike.
    @Test func onlyALegacyParkIsRefusedOnTheScrape() {
        let id = UUID()
        let legacy = ComposerDraftParkContext(status: .legacy, decision: .legacy)
        #expect(legacy.scrapeRefuses(hasPendingInput: true))
        #expect(!legacy.scrapeRefuses(hasPendingInput: false))
        #expect(legacy.judgeAuthoritativeScrape(hasPendingInput: true, terminalID: id))
        #expect(!legacy.judgeAuthoritativeScrape(hasPendingInput: false, terminalID: id))
        let proceeding = [
            ComposerDraftParkContext(status: .confirmed(hasDraft: false), decision: .proceed),
            ComposerDraftParkContext(status: .confirmed(hasDraft: true), decision: .proceed),
            ComposerDraftParkContext(status: .unknown(.noAliveFile), decision: .proceed),
        ]
        for context in proceeding {
            #expect(!context.scrapeRefuses(hasPendingInput: true))
            #expect(!context.scrapeRefuses(hasPendingInput: false))
            #expect(!context.judgeAuthoritativeScrape(hasPendingInput: true, terminalID: id))
            #expect(!context.judgeAuthoritativeScrape(hasPendingInput: false, terminalID: id))
        }
    }

    /// Only the authoritative read compares, and only a confirmed session has
    /// an answer to compare with: the fast rail logs nothing whatever it reads,
    /// an agreement logs nothing, and a disagreement logs its one line.
    @Test func onlyTheAuthoritativeReadLogsADisagreement() throws {
        let id = UUID()
        let lines = ShadowLines()
        let confirmedEmpty = ComposerDraftParkContext(
            status: .confirmed(hasDraft: false), decision: .proceed, shadowLog: lines.append)

        _ = confirmedEmpty.scrapeRefuses(hasPendingInput: true)
        #expect(lines.snapshot().isEmpty, "the fast rail compared")
        _ = confirmedEmpty.judgeAuthoritativeScrape(hasPendingInput: false, terminalID: id)
        #expect(lines.snapshot().isEmpty, "an agreement was logged")
        let expected = try #require(ComposerDraftParkGate.shadowDisagreement(
            terminalID: id, featureHasDraft: false, scrapeHasDraft: true))
        _ = confirmedEmpty.judgeAuthoritativeScrape(hasPendingInput: true, terminalID: id)
        #expect(lines.snapshot() == [expected])

        let unanswered = [
            ComposerDraftParkContext(status: .legacy, decision: .legacy, shadowLog: lines.append),
            ComposerDraftParkContext(
                status: .unknown(.noAliveFile), decision: .proceed, shadowLog: lines.append),
        ]
        for context in unanswered {
            _ = context.judgeAuthoritativeScrape(hasPendingInput: true, terminalID: id)
        }
        #expect(lines.snapshot().count == 1, "a session with no feature answer was compared")
    }

    /// Only a session spawned without the feature is ended by typing `/exit`.
    /// Every other status — confirmed with or without a draft, and every
    /// unknown reason — ends by signal: the ending reads `spawnedWithFeature`
    /// and nothing else.
    @Test func endingStyleIsTypedExitOnlyForLegacy() {
        #expect(ComposerDraftParkGate.endingStyle(for: .legacy) == .typedExit)
        let featureStatuses: [ComposerDraftStatus] = [
            .confirmed(hasDraft: false),
            .confirmed(hasDraft: true),
            .unknown(.noAliveFile),
            .unknown(.otherIncarnation),
            .unknown(.staleHeartbeat),
            .unknown(.featureNotRunning),
            .unknown(.unreadableFile),
        ]
        for status in featureStatuses {
            #expect(ComposerDraftParkGate.endingStyle(for: status) == .signal,
                    "\(status) was typed into")
            #expect(ComposerDraftParkContext(status: status, decision: .proceed).endingStyle
                == .signal)
        }
        #expect(ComposerDraftParkContext(status: .legacy, decision: .legacy).endingStyle
            == .typedExit)
    }

    /// The holder ladder skips the typed `/exit` rung for a signal ending and
    /// starts at SIGTERM; a typed ending still starts with `/exit`.
    @Test func holderLadderStartsAtTerminateForSignal() {
        #expect(HolderParkLadder.firstRung(for: .signal) == .terminate)
        #expect(HolderParkLadder.firstRung(for: .typedExit) == .typedExit)
    }

    @Test func unconfirmedRefusalNamesTheReason() {
        #expect(ComposerDraftParkGate.unconfirmedRefusal(reason: "no-alive-file")
            == "TBD can't confirm this session's draft is saved (no-alive-file).")
    }
}

/// Records shadow-disagreement lines from any thread.
final class ShadowLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var append: @Sendable (String) -> Void {
        { [self] line in lock.withLock { lines.append(line) } }
    }

    func snapshot() -> [String] {
        lock.withLock { lines }
    }
}
