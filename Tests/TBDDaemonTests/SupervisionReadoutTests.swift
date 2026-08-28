import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// `supervise.readout` and the bounded record walk it stands on.
///
/// Tier 2: a real temp filesystem for the two records and the transcripts, an
/// in-memory database, and every path injected. Nothing here reads or writes
/// `~/tbd`, and no test sets `TBD_HOME`.
@Suite("Supervision readout")
struct SupervisionReadoutTests {

    // MARK: - Fixture

    private struct Fixture {
        let db: TBDDatabase
        let directory: URL
        let store: SupervisionStore
        let counters: SessionCountersTracker
        let branchTips: BranchTipTracker
        let actuationPath: String
        let now: Date

        var record: ActuationRecordReader { ActuationRecordReader(activePath: actuationPath) }

        func builder(
            transcriptFingerprinter: @escaping TranscriptFingerprinter
                = TranscriptFingerprinting.live,
            transcriptDeltaInspector: @escaping TranscriptDeltaInspector
                = { _, _ in .containsParentContent }
        ) -> SupervisionReadoutBuilder {
            let stamp = now
            return SupervisionReadoutBuilder(
                db: db,
                fleet: DatabaseSupervisionFleetReader(db: db),
                sessionCounters: counters,
                branchTips: branchTips,
                actuationRecord: record,
                transcriptFingerprinter: transcriptFingerprinter,
                transcriptDeltaInspector: transcriptDeltaInspector,
                now: { stamp })
        }

        func writeRecord(_ lines: [String]) throws {
            try (lines.joined(separator: "\n") + "\n")
                .write(toFile: actuationPath, atomically: true, encoding: .utf8)
        }
    }

    /// A fixed instant well clear of any real clock, so nothing here compares
    /// against wall time.
    private static let fixedNow = Date(timeIntervalSince1970: 1_786_000_000)

    private func makeFixture(now: Date = SupervisionReadoutTests.fixedNow) throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-supervision-readout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SupervisionStore(
            files: SupervisionFileStore(
                fileURL: directory.appendingPathComponent("supervision.json")),
            ledger: SupervisionLedgerWriter(
                path: directory.appendingPathComponent("ledger.jsonl").path),
            fleet: DatabaseSupervisionFleetReader(db: db))
        return Fixture(
            db: db,
            directory: directory,
            store: store,
            counters: SessionCountersTracker(),
            branchTips: BranchTipTracker(),
            actuationPath: directory.appendingPathComponent("actuations.jsonl").path,
            now: now)
    }

    private struct Seeded {
        let repo: Repo
        let worktree: Worktree
        let terminal: Terminal
    }

    /// One repo, one worktree, one Claude terminal. The repo's display name is
    /// the singleton project's name, so `name` is also the project.
    @discardableResult
    private func seed(
        _ fixture: Fixture, project name: String, branch: String = "feature/x",
        transcript: String? = nil
    ) async throws -> Seeded {
        let repo = try await fixture.db.repos.create(
            path: "/private/tmp/\(name)", displayName: name, defaultBranch: "main")
        let worktree = try await fixture.db.worktrees.create(
            repoID: repo.id, name: "\(name)-wt", branch: branch,
            path: "/private/tmp/\(name)/wt", tmuxServer: "tbd-\(name)")
        let terminal = try await fixture.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude)
        if let transcript {
            try await fixture.db.terminals.updateSession(
                id: terminal.id, sessionID: UUID().uuidString, transcriptPath: transcript)
        }
        let reloaded = try #require(try await fixture.db.terminals.get(id: terminal.id))
        return Seeded(repo: repo, worktree: worktree, terminal: reloaded)
    }

    // MARK: - Record lines

    /// Fractionless ISO-8601 UTC — the form §6's own example actuation rows use.
    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func actuationLine(_ fields: [String: Any]) -> String {
        var object = fields
        object["actor"] = ["kind": "daemon"]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func verifiedSend(id: String, at date: Date, terminal: UUID) -> String {
        actuationLine([
            "id": id, "ts": stamp(date), "kind": "send", "verify": true,
            "target": ["terminal": terminal.uuidString],
        ])
    }

    // MARK: - Composition

    @Test("The readout carries the machinery, the supervisor and one entry per agent")
    func readoutComposesTheProjectsPicture() async throws {
        let fixture = try makeFixture()
        let seeded = try await seed(fixture, project: "acme-alpha", branch: "feature/login")
        try fixture.writeRecord([])

        let facts = try await fixture.store.projectFacts(project: "acme-alpha", brake: .released)
        let readout = try await fixture.builder().build(facts: facts)

        #expect(readout.schemaVersion == SupervisionReadout.currentSchemaVersion)
        #expect(readout.project == "acme-alpha")
        #expect(readout.generatedAt == SupervisionInstant(fixture.now))
        #expect(readout.supervision.brake == .released)
        #expect(readout.supervision.on == false)
        #expect(readout.supervision.mode == facts.project.activeMode)
        #expect(readout.supervision.spanStartedAt == nil)
        #expect(readout.supervision.lastSweepContactAt == nil)

        // The four supervisor facts are null and `live` is false until briefing
        // delivery lands; `arrangement` says only what WOULD supervise.
        #expect(readout.supervisor.live == false)
        #expect(readout.supervisor.arrangement.kind == .hostedDesk)
        #expect(readout.supervisor.state == nil)
        #expect(readout.supervisor.lastAttestedAct == nil)
        #expect(readout.supervisor.contextLoad == nil)
        #expect(readout.supervisor.unansweredBriefingSince == nil)

        let agent = try #require(readout.agents.first)
        #expect(readout.agents.count == 1)
        #expect(agent.terminal == seeded.terminal.id)
        #expect(agent.worktree == seeded.worktree.id)
        #expect(agent.repo == seeded.repo.id)
        #expect(agent.spawnSource == "claude")
        #expect(agent.work.branch == "feature/login")
        #expect(agent.work.hasConflicts == false)
        #expect(agent.work.commitsUnchangedSince == nil)
        #expect(agent.work.pr == nil)
        #expect(agent.work.prStatus == nil)
        #expect(agent.pinned == false)
        // No transcript path, so the counters have no honest value — null,
        // never a zeroed block that would read as "nothing happened".
        #expect(agent.counters == nil)
        #expect(agent.notToAct.interventionInFlight == false)
        #expect(agent.notToAct.recheckPending == false)
        #expect(agent.notToAct.rateLimitedUntil == nil)
    }

    @Test("Every optional in the encoded readout is present and null, never absent")
    func readoutEncodesExplicitNulls() async throws {
        let fixture = try makeFixture()
        try await seed(fixture, project: "acme-alpha")
        try fixture.writeRecord([])

        let facts = try await fixture.store.projectFacts(project: "acme-alpha", brake: .engaged)
        let readout = try await fixture.builder().build(facts: facts)
        let encoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(readout)) as? [String: Any]
        let object = try #require(encoded)

        let supervision = try #require(object["supervision"] as? [String: Any])
        #expect(supervision["spanStartedAt"] is NSNull)
        #expect(supervision["lastSweepContactAt"] is NSNull)

        let supervisor = try #require(object["supervisor"] as? [String: Any])
        #expect(supervisor["state"] is NSNull)
        #expect(supervisor["contextLoad"] is NSNull)
        #expect(supervisor["unansweredBriefingSince"] is NSNull)
        #expect(supervisor["live"] as? Bool == false)

        let agents = try #require(object["agents"] as? [[String: Any]])
        let agent = try #require(agents.first)
        #expect(agent["counters"] is NSNull)
        #expect(agent["transcriptPath"] is NSNull)
        let work = try #require(agent["work"] as? [String: Any])
        #expect(work["commitsUnchangedSince"] is NSNull)
        #expect(work["pr"] is NSNull)
        #expect(work["prStatus"] is NSNull)
        let notToAct = try #require(agent["notToAct"] as? [String: Any])
        #expect(notToAct["rateLimitedUntil"] is NSNull)
    }

    @Test("The readout of an unknown project refuses rather than answering with no agents")
    func unknownProjectIsRefused() async throws {
        let fixture = try makeFixture()
        try await seed(fixture, project: "acme-alpha")

        await #expect(throws: SupervisionStoreError.unknownProject("acme-ghost")) {
            _ = try await fixture.store.projectFacts(project: "acme-ghost", brake: .released)
        }
    }

    // MARK: - The not-to-act facts

    @Test("A verified send inside its deadline is in flight, and owes no re-check")
    func dispatchedSendInsideDeadlineIsInFlight() async throws {
        let fixture = try makeFixture()
        let seeded = try await seed(fixture, project: "acme-alpha")
        try fixture.writeRecord([
            Self.verifiedSend(
                id: "act-1", at: fixture.now.addingTimeInterval(-10),
                terminal: seeded.terminal.id),
        ])

        let facts = try await fixture.store.projectFacts(project: "acme-alpha", brake: .released)
        let agent = try #require(try await fixture.builder().build(facts: facts).agents.first)
        #expect(agent.notToAct.interventionInFlight == true)
        #expect(agent.notToAct.recheckPending == false)
    }

    @Test("The same act past its deadline owes a re-check, and is no longer in flight")
    func dispatchedSendPastDeadlineOwesARecheck() async throws {
        let fixture = try makeFixture()
        let seeded = try await seed(fixture, project: "acme-alpha")
        try fixture.writeRecord([
            Self.verifiedSend(
                id: "act-1",
                at: fixture.now.addingTimeInterval(-DeliveryRecord.acknowledgementDeadline - 30),
                terminal: seeded.terminal.id),
        ])

        let facts = try await fixture.store.projectFacts(project: "acme-alpha", brake: .released)
        let agent = try #require(try await fixture.builder().build(facts: facts).agents.first)
        #expect(agent.notToAct.recheckPending == true)
        #expect(agent.notToAct.interventionInFlight == false)
    }

    @Test("An act an observation settled is neither in flight nor owed a re-check")
    func observedSendStandsOff() async throws {
        let fixture = try makeFixture()
        let seeded = try await seed(fixture, project: "acme-alpha")
        try fixture.writeRecord([
            Self.verifiedSend(
                id: "act-1", at: fixture.now.addingTimeInterval(-600),
                terminal: seeded.terminal.id),
            Self.actuationLine([
                "id": "act-2", "ts": Self.stamp(fixture.now.addingTimeInterval(-500)),
                "kind": "outcome", "confirms": "act-1", "result": "landed-and-acting",
            ]),
        ])

        let facts = try await fixture.store.projectFacts(project: "acme-alpha", brake: .released)
        let agent = try #require(try await fixture.builder().build(facts: facts).agents.first)
        #expect(agent.notToAct.interventionInFlight == false)
        #expect(agent.notToAct.recheckPending == false)
    }

    @Test("An intervention whose request predates the lookback window is not reported")
    func actsOlderThanTheLookbackAreNotReported() async throws {
        let fixture = try makeFixture()
        let seeded = try await seed(fixture, project: "acme-alpha")
        let ancient = fixture.now
            .addingTimeInterval(-SupervisionReadoutBuilder.interventionLookback - 86_400)
        try fixture.writeRecord([
            // Verified, never observed — `unconfirmed` for as long as it is in
            // view. The window is what takes it out of view.
            Self.verifiedSend(id: "ancient", at: ancient, terminal: seeded.terminal.id),
            Self.actuationLine([
                "id": "recent", "ts": Self.stamp(fixture.now.addingTimeInterval(-5)),
                "kind": "wake", "target": ["terminal": seeded.terminal.id.uuidString],
            ]),
        ])

        let facts = try await fixture.store.projectFacts(project: "acme-alpha", brake: .released)
        let agent = try #require(try await fixture.builder().build(facts: facts).agents.first)
        #expect(agent.notToAct.recheckPending == false)
        #expect(agent.notToAct.interventionInFlight == false)
    }

    // MARK: - The retain trap

    @Test("A readout of one project leaves another project's counter baselines standing")
    func readoutDoesNotResetAnotherProjectsCounters() async throws {
        let fixture = try makeFixture()
        try await seed(fixture, project: "acme-alpha")
        let transcript = fixture.directory.appendingPathComponent("beta.jsonl").path
        let beta = try await seed(fixture, project: "acme-beta", transcript: transcript)
        try fixture.writeRecord([])
        try "".write(toFile: transcript, atomically: true, encoding: .utf8)

        // Establish beta's baseline at the empty file's end, then grow it.
        _ = await fixture.counters.sample(
            terminalID: beta.terminal.id, worktreeID: beta.worktree.id,
            transcriptPath: transcript, commitsUnchangedSince: nil, at: fixture.now)
        try "{}\n{}\n{}\n".write(toFile: transcript, atomically: true, encoding: .utf8)

        // A readout of the OTHER project. It enumerates alpha's worktree only,
        // and may prune nothing outside it.
        let facts = try await fixture.store.projectFacts(project: "acme-alpha", brake: .released)
        _ = try await fixture.builder().build(facts: facts)

        let sampled = try #require(await fixture.counters.sample(
            terminalID: beta.terminal.id, worktreeID: beta.worktree.id,
            transcriptPath: transcript, commitsUnchangedSince: nil, at: fixture.now))
        #expect(sampled.turnsInWindow == 3, "beta's baseline survived alpha's readout")
    }

    // MARK: - Transcript supersession

    /// The readout can be the only reader on a daemon with no app attached, so
    /// it supersedes a stale prompt on its own pass rather than reporting one.

    private static let transcriptModifiedAt = Date(timeIntervalSince1970: 1_785_900_000)

    private static func fingerprint(path: String, size: Int64) -> TranscriptFingerprint {
        TranscriptFingerprint(path: path, modifiedAt: transcriptModifiedAt, size: size)
    }

    private func recordPrompt(
        _ fixture: Fixture, terminal: UUID, fingerprint: TranscriptFingerprint
    ) async throws {
        _ = try await fixture.db.terminals.recordAwaitingInputReason(
            id: terminal,
            reason: AwaitingInputReason(
                message: "Claude needs your permission to use Bash",
                hookEventName: "Notification",
                raw: "{}",
                notificationType: "permission_prompt",
                transcriptFingerprint: fingerprint),
            observedAt: fixture.now)
    }

    private func isAwaitingInput(_ state: SessionState) -> Bool {
        if case .awaitingInput = state.value { return true }
        return false
    }

    @Test("The readout supersedes a prompt whose transcript moved")
    func theReadoutSupersedesAPromptWhoseTranscriptMoved() async throws {
        let fixture = try makeFixture()
        let transcript = fixture.directory.appendingPathComponent("moved.jsonl").path
        let seeded = try await seed(fixture, project: "acme-super", transcript: transcript)
        try fixture.writeRecord([])
        try await recordPrompt(
            fixture, terminal: seeded.terminal.id,
            fingerprint: Self.fingerprint(path: transcript, size: 10))

        let facts = try await fixture.store.projectFacts(project: "acme-super", brake: .released)
        let readout = try await fixture.builder(
            transcriptFingerprinter: { _ in Self.fingerprint(path: transcript, size: 20) }
        ).build(facts: facts)

        let agent = try #require(readout.agents.first)
        #expect(isAwaitingInput(agent.state) == false,
                "the readout reported a prompt its own pass retracted")
        let row = try #require(try await fixture.db.terminals.get(id: seeded.terminal.id))
        #expect(row.awaitingInputReason == nil)
        #expect(row.awaitingInputObservedAt == nil)
    }

    @Test("The readout leaves the hand up when only a subagent wrote")
    func theReadoutLeavesTheHandUpWhenOnlyASubagentWrote() async throws {
        let fixture = try makeFixture()
        let transcript = fixture.directory.appendingPathComponent("sidechain.jsonl").path
        let seeded = try await seed(fixture, project: "acme-sidechain", transcript: transcript)
        try fixture.writeRecord([])
        try await recordPrompt(
            fixture, terminal: seeded.terminal.id,
            fingerprint: Self.fingerprint(path: transcript, size: 10))

        let facts = try await fixture.store.projectFacts(project: "acme-sidechain", brake: .released)
        let readout = try await fixture.builder(
            transcriptFingerprinter: { _ in Self.fingerprint(path: transcript, size: 20) },
            transcriptDeltaInspector: { _, _ in .sidechainOnly }
        ).build(facts: facts)

        let agent = try #require(readout.agents.first)
        #expect(isAwaitingInput(agent.state),
                "a nested agent's writes are not the parent answering a prompt")
        let standing = try #require(
            try await fixture.db.terminals.get(id: seeded.terminal.id)?.awaitingInputReason)
        #expect(standing.transcriptFingerprint == Self.fingerprint(path: transcript, size: 20))
    }

    @Test("The readout leaves a pending prompt raised")
    func theReadoutLeavesAPendingPromptRaised() async throws {
        let fixture = try makeFixture()
        let transcript = fixture.directory.appendingPathComponent("pending.jsonl").path
        let seeded = try await seed(fixture, project: "acme-pending", transcript: transcript)
        try fixture.writeRecord([])
        try await recordPrompt(
            fixture, terminal: seeded.terminal.id,
            fingerprint: Self.fingerprint(path: transcript, size: 10))

        let facts = try await fixture.store.projectFacts(project: "acme-pending", brake: .released)
        let readout = try await fixture.builder(
            transcriptFingerprinter: { _ in Self.fingerprint(path: transcript, size: 10) }
        ).build(facts: facts)

        let agent = try #require(readout.agents.first)
        #expect(isAwaitingInput(agent.state))
        let standing = try #require(
            try await fixture.db.terminals.get(id: seeded.terminal.id)?.awaitingInputReason)
        #expect(standing.classification == .promptOnScreen)
        #expect(standing.transcriptFingerprint == Self.fingerprint(path: transcript, size: 10))
    }

    // MARK: - The bounded record walk

    /// A record laid out across rotated segments, so the walk's stopping rule
    /// is observable in what it returns.
    private func makeRecordDirectory(_ segments: [(name: String, body: String)]) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-actuation-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for segment in segments {
            try segment.body.write(
                toFile: directory.appendingPathComponent(segment.name).path,
                atomically: true, encoding: .utf8)
        }
        return directory.appendingPathComponent("actuations.jsonl").path
    }

    private static func row(id: String, at date: Date) -> String {
        actuationLine(["id": id, "ts": stamp(date), "kind": "wake"]) + "\n"
    }

    @Test("readRows stops once the window is covered, leaving older segments unread")
    func readRowsStopsOnceTheWindowIsCovered() throws {
        let now = Self.fixedNow
        let path = try makeRecordDirectory([
            ("actuations-2020-01-01.jsonl", Self.row(id: "ancient", at: Date(timeIntervalSince1970: 1_577_836_800))),
            ("actuations-2026-08-14.jsonl", Self.row(id: "yesterday", at: now.addingTimeInterval(-86_400))),
            ("actuations.jsonl", Self.row(id: "today", at: now.addingTimeInterval(-60))),
        ])
        let reader = ActuationRecordReader(activePath: path)

        let since = now.addingTimeInterval(-3_600)
        #expect(reader.readRows(since: since).map(\.id) == ["yesterday", "today"])
        #expect(reader.segmentPaths(since: since).map { ($0 as NSString).lastPathComponent }
            == ["actuations-2026-08-14.jsonl", "actuations.jsonl"])
        // The whole record is still reachable — the window is what narrowed it.
        #expect(reader.readRows().map(\.id) == ["ancient", "yesterday", "today"])
    }

    @Test("A segment of pure junk does not terminate the walk early")
    func junkSegmentDoesNotTruncateTheWalk() throws {
        let now = Self.fixedNow
        let path = try makeRecordDirectory([
            ("actuations-2026-08-12.jsonl", Self.row(id: "old", at: now.addingTimeInterval(-3 * 86_400))),
            ("actuations-2026-08-13.jsonl", "{not json at all\n\u{FFFD}garbage\n"),
            ("actuations.jsonl", Self.row(id: "today", at: now.addingTimeInterval(-60))),
        ])
        let reader = ActuationRecordReader(activePath: path)

        // The junk segment carries no parseable timestamp, so it says nothing
        // about coverage; the walk must carry on past it to the segment that
        // actually spans the cutoff.
        #expect(reader.readRows(since: now.addingTimeInterval(-3_600)).map(\.id) == ["old", "today"])
    }

    @Test("The segment holding the cutoff is included, not stopped before")
    func theSegmentSpanningTheCutoffIsIncluded() throws {
        let now = Self.fixedNow
        let path = try makeRecordDirectory([
            ("actuations-2026-08-14.jsonl",
             Self.row(id: "before", at: now.addingTimeInterval(-7_200))
                + Self.row(id: "after", at: now.addingTimeInterval(-1_800))),
            ("actuations.jsonl", Self.row(id: "today", at: now.addingTimeInterval(-60))),
        ])
        let reader = ActuationRecordReader(activePath: path)

        // A request row can precede the cutoff while the outcome that settles
        // it lands after, so the segment straddling `since` is read whole.
        #expect(reader.readRows(since: now.addingTimeInterval(-3_600)).map(\.id)
            == ["before", "after", "today"])
    }
}
