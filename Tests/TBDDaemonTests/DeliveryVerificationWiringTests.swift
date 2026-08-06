import Clocks
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// A source that answers nothing and counts every question. Anything that
/// touches it while the flag is off is a leak.
private final class CountingObservationSource: DeliveryObservationSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _factsCalls = 0
    private var _tailReads = 0
    private let facts: TerminalDeliveryFacts?
    private let tail: Data?

    init(facts: TerminalDeliveryFacts? = nil, tail: Data? = nil) {
        self.facts = facts
        self.tail = tail
    }

    var factsCalls: Int { lock.withLock { _factsCalls } }
    var tailReads: Int { lock.withLock { _tailReads } }

    func facts(forTerminal terminalID: UUID) async -> TerminalDeliveryFacts? {
        lock.withLock { _factsCalls += 1 }
        return facts
    }

    func transcriptTail(atPath path: String, maxBytes: Int) async -> Data? {
        lock.withLock { _tailReads += 1 }
        return tail
    }
}

/// Tier 2 — an in-memory database, a dry-run tmux, a real (temp-directory)
/// actuation log and a `TestClock`. Proves the two branches of
/// `delivery_verification_enabled` at the wiring seam, and — with the verifier
/// really wired to a router — that an ordinary send costs no transcript read
/// and that a verified one joins its observation to its own request row.
@Suite("delivery verification wiring and the flag's two branches", .clockDriven)
struct DeliveryVerificationWiringTests {

    private struct Fixture {
        let db: TBDDatabase
        let router: RPCRouter
        let terminal: Terminal
        let logPath: String
        let log: ActuationLog
        let pastes: PasteRecorder
    }

    final class PasteRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _pastes: [String] = []
        var pastes: [String] { lock.withLock { _pastes } }
        func record(_ bytes: Data) {
            lock.withLock { _pastes.append(String(decoding: bytes, as: UTF8.self)) }
        }
    }

    private func makeFixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-delivery-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logPath = directory.appendingPathComponent("actuations.jsonl").path
        let pastes = PasteRecorder()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunPaneSendTarget: { _, _ in .live(terminalID: nil) },
            dryRunPasteBytes: { _, _, bytes in pastes.record(bytes) })
        let db = try TBDDatabase(inMemory: true)
        let log = ActuationLog(path: logPath)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date(),
            actuationLog: log)
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme-wt", branch: "main",
            path: FileManager.default.temporaryDirectory.path, tmuxServer: "tbd-acme")
        // An agent terminal: the envelope rides sends to agents, not to shells.
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@3", tmuxPaneID: "%7", kind: .claude)
        return Fixture(
            db: db, router: router, terminal: terminal, logPath: logPath, log: log,
            pastes: pastes)
    }

    /// Every row of the record, through the reader any later consumer uses —
    /// active segment plus rotated ones, so an append that happens to cross a
    /// UTC day boundary mid-test cannot change what these assertions see.
    private func rows(at path: String) -> [ActuationRow] {
        ActuationRecordReader(activePath: path).readRows()
    }

    /// Only the rows a *later observation* wrote. A synchronous `dispatched`
    /// says nothing about delivery, so it must not answer here.
    private func observations(at path: String) -> [ActuationRow] {
        rows(at: path).filter { $0.result?.observed != nil }
    }

    /// Seed the record with a verified send whose observation never ran — the
    /// replay's whole work list.
    private func seedUnconfirmedAct(
        at path: String, terminalID: UUID, dispatchedAt: Date
    ) async throws -> String {
        let log = ActuationLog(path: path, now: { dispatchedAt })
        var request = ActuationRow(actor: .anonymous, kind: .send)
        request.method = RPCMethod.terminalSend
        request.target = .local(worktree: UUID(), terminal: terminalID)
        request.verify = true
        let id = try await log.appendRequest(request)
        await log.appendOutcome(confirms: id, result: .dispatched)
        return id
    }

    // MARK: - The flag's two branches

    /// Off is the shipped default, and off means *inert*: no verifier on the
    /// router, no replay, and nothing observed. The armed send that would have
    /// reached it is refused upstream by `terminal.send` itself, which reads
    /// the same column per call — so the two halves fail closed together.
    @Test("with the flag off nothing is wired, nothing replays, and nothing is observed")
    func flagOffWiresNothing() async throws {
        let fixture = try await makeFixture()
        #expect(try await fixture.db.config.get().deliveryVerificationEnabled == false)
        _ = try await seedUnconfirmedAct(
            at: fixture.logPath, terminalID: fixture.terminal.id,
            dispatchedAt: Date().addingTimeInterval(-600))
        let source = CountingObservationSource()

        let verifier = await Daemon.wireDeliveryVerification(
            mockMode: nil, database: fixture.db, rpcRouter: fixture.router,
            actuationLog: fixture.log, source: source)

        #expect(verifier == nil)
        #expect(fixture.router.deliveryVerifier == nil)
        #expect(source.factsCalls == 0)
        #expect(source.tailReads == 0)
        // The seeded act's two rows and nothing else: no observation was written.
        #expect(rows(at: fixture.logPath).count == 2)
        #expect(observations(at: fixture.logPath).isEmpty)
    }

    @Test("with the flag on the verifier is wired and the replay observes the backlog")
    func flagOnWiresAndReplays() async throws {
        let fixture = try await makeFixture()
        try await fixture.db.config.setDeliveryVerification(enabled: true)
        let actID = try await seedUnconfirmedAct(
            at: fixture.logPath, terminalID: fixture.terminal.id,
            dispatchedAt: Date().addingTimeInterval(-600))
        let source = CountingObservationSource(
            facts: TerminalDeliveryFacts(
                transcriptPath: "/tmp/transcript.jsonl", activityState: .idle),
            tail: Data("{\"type\":\"summary\"}".utf8))

        let verifier = await Daemon.wireDeliveryVerification(
            mockMode: nil, database: fixture.db, rpcRouter: fixture.router,
            actuationLog: fixture.log, source: source)

        #expect(verifier != nil)
        #expect(fixture.router.deliveryVerifier != nil)
        #expect(source.factsCalls == 1)
        #expect(source.tailReads == 1)
        let written = observations(at: fixture.logPath)
        #expect(written.count == 1)
        // `undetermined`, not `not-landed`: a replayed act can be arbitrarily
        // old, so a bounded tail finding nothing is not evidence of anything.
        #expect(written.first?.result == .observed(.undetermined))
        #expect(written.first?.confirms == actID)
    }

    /// Mock mode renders hand-seeded fixtures exactly as authored; a replay
    /// writing observation rows into them would not.
    @Test("mock mode wires no verifier even with the flag on")
    func mockModeWiresNothing() async throws {
        let fixture = try await makeFixture()
        try await fixture.db.config.setDeliveryVerification(enabled: true)
        let source = CountingObservationSource()

        let verifier = await Daemon.wireDeliveryVerification(
            mockMode: .enabled(fixturePath: "/tmp/fixture.json"), database: fixture.db,
            rpcRouter: fixture.router, actuationLog: fixture.log, source: source)

        #expect(verifier == nil)
        #expect(fixture.router.deliveryVerifier == nil)
        #expect(source.factsCalls == 0)
    }

    // MARK: - An ordinary send costs the observation nothing

    /// The verifier is wired and live; the send simply did not ask for
    /// verification. Nothing must read a transcript on its behalf — proven by a
    /// source that counts, not by inspection.
    @Test("a verify-less send costs no transcript read")
    func verifylessSendReadsNoTranscript() async throws {
        let fixture = try await makeFixture()
        try await fixture.db.config.setDeliveryVerification(enabled: true)
        let source = CountingObservationSource()
        let clock = TestClock()
        fixture.router.deliveryVerifier = DeliveryVerifier(
            log: fixture.log, source: source,
            redeliver: { _, _, _ in .dispatched }, clock: clock)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: fixture.terminal.id, text: "status?", submit: true)))
        #expect(response.success)

        #expect(source.factsCalls == 0)
        #expect(source.tailReads == 0)
    }

    /// End to end through the real production source: the send pastes the
    /// envelope, the transcript the session writes carries it, and the
    /// observation joins back to the send's own request row.
    @Test("a verified send's observation joins the envelope to its own request row")
    func verifiedSendObservationJoinsOnTheRowID() async throws {
        let fixture = try await makeFixture()
        try await fixture.db.config.setDeliveryVerification(enabled: true)
        let transcriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-transcript-\(UUID().uuidString).jsonl").path
        try await fixture.db.terminals.updateSession(
            id: fixture.terminal.id, sessionID: UUID().uuidString,
            transcriptPath: transcriptPath)
        try await fixture.db.terminals.setActivityState(
            id: fixture.terminal.id, activityState: .working)
        let clock = TestClock()
        let verifier = DeliveryVerifier(
            log: fixture.log,
            source: DatabaseDeliveryObservationSource(db: fixture.db),
            redeliver: { _, _, _ in .dispatched },
            clock: clock)
        fixture.router.deliveryVerifier = verifier

        #expect(await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: fixture.terminal.id, text: "status?", submit: true,
                verify: true))).success)

        // The session's harness writes the submitted message into its
        // transcript JSONL — verbatim, envelope included, JSON-escaped.
        let actID = try #require(rows(at: fixture.logPath).first?.id)
        struct Line: Encodable { let type: String; let content: String }
        let payload = try #require(fixture.pastes.pastes.first)
        var jsonl = Data()
        jsonl.append(try JSONEncoder().encode(Line(type: "user", content: payload)))
        jsonl.append(0x0A)
        try jsonl.write(to: URL(fileURLWithPath: transcriptPath))

        await clock.advanceWhenSuspended(by: .seconds(60))
        await awaitDeliveryCycle(verifier, observed: {
            "\(observations(at: fixture.logPath).count) observation row(s)"
        })

        let observation = try #require(observations(at: fixture.logPath).last)
        #expect(observation.result == .observed(.landedAndActing))
        #expect(observation.confirms == actID)
        #expect(observation.observedAt != nil)
    }

    /// The flag and the machinery it enables are read at different times — the
    /// column per call, the verifier once at daemon start — so there is a window
    /// where the column says yes and there is still nothing to arm. A send that
    /// dispatched in that window would render `unconfirmed` forever, handing the
    /// caller a silence that reads like a delivery failure when nothing ever
    /// looked. It is refused instead, and nothing is typed.
    @Test("a verified send is refused when the flag is on but no verifier is wired")
    func verifiedSendRefusedWithoutAWiredVerifier() async throws {
        let fixture = try await makeFixture()
        try await fixture.db.config.setDeliveryVerification(enabled: true)
        #expect(fixture.router.deliveryVerifier == nil)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: fixture.terminal.id, text: "status?", submit: true,
                verify: true)))

        #expect(!response.success)
        #expect(response.error?.contains("Restart the daemon") == true)
        // Nothing reached the pane, and the record shows the near-miss.
        #expect(fixture.pastes.pastes.isEmpty)
        let outcome = try #require(rows(at: fixture.logPath).last)
        #expect(outcome.result == .synchronous(.refused))
        #expect(outcome.reason == .notEligible)
        // Refused, never observed: no row may claim a look that never happened.
        #expect(observations(at: fixture.logPath).isEmpty)
    }
}
