import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The `supervise.brief` pipe: the seven contract outcomes, the order the
/// pipeline's steps happen in, and the two facts a quiet contact leaves behind.
///
/// Tier 2 — real filesystem, no clocks, no subprocesses. Every path is injected
/// into a temp directory and time is pinned through the store's date seam, so
/// nothing here touches `~/tbd` and nothing waits on wall time.
@Suite("Supervision brief pipe")
struct SupervisionBriefTests {

    // MARK: - Fixture

    private struct StubFleet: SupervisionFleetReading {
        var repoList: [SupervisionRepo] = []

        func repos() async throws -> [SupervisionRepo] { repoList }

        func agents(inRepos repoIDs: Set<UUID>) async throws -> [SupervisionFleetAgent] { [] }
    }

    /// A deliverer that answers whatever a test tells it to and counts how many
    /// times it was asked.
    ///
    /// The count is the assertion behind "one full attempt, never a retry": a
    /// pipe that retried a failed send would call this twice.
    private final class RecordingDeliverer: SupervisionBriefingDelivering, @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: SupervisionBriefOutcome
        private(set) var calls: [(project: String, text: String)] = []

        init(_ outcome: SupervisionBriefOutcome) { self.outcome = outcome }

        var callCount: Int { lock.withLock { calls.count } }
        var deliveredTexts: [String] { lock.withLock { calls.map(\.text) } }

        func deliver(project: String, text: String) async -> SupervisionBriefOutcome {
            lock.withLock {
                calls.append((project: project, text: text))
                return outcome
            }
        }
    }

    private struct Fixture {
        let directory: URL
        let ledgerPath: String
        let dates: TestDateSource
        let store: SupervisionStore
    }

    private static func makeFixture(repos names: [String]) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-supervision-brief-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledgerPath = directory.appendingPathComponent("ledger.jsonl").path
        let dates = TestDateSource()
        let fleet = StubFleet(repoList: names.map { SupervisionRepo(id: UUID(), name: $0) })
        return Fixture(
            directory: directory,
            ledgerPath: ledgerPath,
            dates: dates,
            store: SupervisionStore(
                files: SupervisionFileStore(
                    fileURL: directory.appendingPathComponent("supervision.json")),
                ledger: SupervisionLedgerWriter(path: ledgerPath),
                fleet: fleet,
                now: dates.provider))
    }

    /// A project marked on, which is the state every non-refusal case needs.
    private static func turnOn(_ fixture: Fixture, _ project: String) async throws {
        let result = try await fixture.store.setProjectMark(project: project, on: true)
        #expect(result.changed)
    }

    private func lines(at path: String) throws -> [SupervisionLedgerLine] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return try data.split(separator: 0x0A, omittingEmptySubsequences: true).map { raw in
            try JSONDecoder().decode(SupervisionLedgerLine.self, from: Data(raw))
        }
    }

    /// A briefing whose byte count is over the bound, built from single-byte
    /// characters so the two counts agree — the *disagreement* is its own test.
    private static var oversizeText: String {
        String(repeating: "a", count: SupervisionBriefing.maxBriefingBytes + 1)
    }

    // MARK: - Every outcome, produced by the condition that names it

    /// Each of the seven contract values, reached by the one condition it
    /// names — and asserted against `allCases`, so an eighth outcome added
    /// later fails here rather than going untested.
    @Test("All seven brief outcomes are reachable, each by its own condition")
    func everyOutcomeIsReachable() async throws {
        var reached: [SupervisionBriefOutcome] = []

        // delivered — an empty submission, the attested "looked, found nothing".
        let quiet = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(quiet, "acme-alpha")
        let quietResult = try await quiet.store.submitBriefing(
            project: "acme-alpha", text: "", brake: .released,
            deliverer: RecordingDeliverer(.transportFailed))
        #expect(quietResult.result == .delivered)
        #expect(quietResult.retryAfter == nil)
        reached.append(quietResult.result)

        // refused-off — the project's mark is off.
        let off = try Self.makeFixture(repos: ["acme-alpha"])
        let offResult = try await off.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released,
            deliverer: RecordingDeliverer(.delivered))
        #expect(offResult.result == .refusedOff)
        reached.append(offResult.result)

        // refused-paused — the fleet brake is engaged.
        let paused = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(paused, "acme-alpha")
        let pausedResult = try await paused.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .engaged,
            deliverer: RecordingDeliverer(.delivered))
        #expect(pausedResult.result == .refusedPaused)
        reached.append(pausedResult.result)

        // refused-size — over the byte bound.
        let big = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(big, "acme-alpha")
        let bigResult = try await big.store.submitBriefing(
            project: "acme-alpha", text: Self.oversizeText, brake: .released,
            deliverer: RecordingDeliverer(.delivered))
        #expect(bigResult.result == .refusedSize)
        reached.append(bigResult.result)

        // refused-rate-limit — a second submission inside the window.
        let paced = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(paced, "acme-alpha")
        // Delivered, because only a delivered briefing spends the slot the
        // second submission is refused for.
        let pacedDeliverer = RecordingDeliverer(.delivered)
        _ = try await paced.store.submitBriefing(
            project: "acme-alpha", text: "first", brake: .released, deliverer: pacedDeliverer)
        paced.dates.advance(by: SupervisionBriefing.rateLimitInterval - 1)
        let pacedResult = try await paced.store.submitBriefing(
            project: "acme-alpha", text: "second", brake: .released, deliverer: pacedDeliverer)
        #expect(pacedResult.result == .refusedRateLimit)
        #expect(pacedResult.retryAfter != nil, "the one outcome whose remedy is to wait")
        reached.append(pacedResult.result)

        // no-live-supervisor — nothing stands in the role, which is what the
        // shipped deliverer answers.
        let bare = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(bare, "acme-alpha")
        let bareResult = try await bare.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released,
            deliverer: SupervisorBriefingDeliverer())
        #expect(bareResult.result == .noLiveSupervisor)
        reached.append(bareResult.result)

        // transport-failed — only an injected deliverer can produce it, which
        // is why the seam exists.
        let broken = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(broken, "acme-alpha")
        let brokenResult = try await broken.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released,
            deliverer: RecordingDeliverer(.transportFailed))
        #expect(brokenResult.result == .transportFailed)
        reached.append(brokenResult.result)

        #expect(Set(reached) == Set(SupervisionBriefOutcome.allCases),
                "every contract outcome must be produced by the condition that names it")
        #expect(reached.count == SupervisionBriefOutcome.allCases.count)
    }

    @Test("An unknown project is refused, never answered with an empty success")
    func unknownProjectIsRefused() async throws {
        let fixture = try Self.makeFixture(repos: ["acme-alpha"])
        await #expect(throws: SupervisionStoreError.unknownProject("acme-ghost")) {
            try await fixture.store.submitBriefing(
                project: "acme-ghost", text: "findings", brake: .released,
                deliverer: RecordingDeliverer(.delivered))
        }
    }

    // MARK: - The headline: a quiet contact is counted but writes no line

    /// The slice's whole point. Empty submissions leave no line in the ledger —
    /// the noise rule — and are still counted, so the closing lifecycle line can
    /// say "checked 14 times, nothing found" rather than nothing at all.
    @Test("A quiet contact writes no ledger line and is counted in the coverage summary")
    func quietContactIsCountedButSilent() async throws {
        let fixture = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(fixture, "acme-alpha")
        let afterOn = try lines(at: fixture.ledgerPath).count
        #expect(afterOn == 1, "the projectOn line, and nothing else yet")

        let contacts = 14
        for index in 0..<contacts {
            fixture.dates.advance(by: 30)
            let result = try await fixture.store.submitBriefing(
                project: "acme-alpha", text: "", brake: .released,
                deliverer: RecordingDeliverer(.transportFailed))
            #expect(result.result == .delivered, "quiet contact \(index) must be accepted")
        }
        #expect(try lines(at: fixture.ledgerPath).count == afterOn,
                "a quiet contact writes no ledger line")

        _ = try await fixture.store.setProjectMark(project: "acme-alpha", on: false)
        let closing = try #require(try lines(at: fixture.ledgerPath).last)
        guard case .projectOff(let coverage) = closing.payload else {
            Issue.record("the closing line must be projectOff, got \(closing.payload)")
            return
        }
        #expect(coverage.sweepContacts == contacts)
        #expect(coverage.briefingsDelivered == 0, "nothing was delivered to anyone")
    }

    @Test("The status readout's last contact moves with a quiet submission")
    func quietContactMovesLastContact() async throws {
        let fixture = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(fixture, "acme-alpha")
        fixture.dates.advance(by: 90)
        let at = fixture.dates.now

        _ = try await fixture.store.submitBriefing(
            project: "acme-alpha", text: "", brake: .released,
            deliverer: RecordingDeliverer(.noLiveSupervisor))

        let facts = try await fixture.store.projectFacts(project: "acme-alpha", brake: .released)
        #expect(facts.lastSweepContactAt == SupervisionInstant(at))
    }

    // MARK: - Refusals that record no contact

    /// Paused and off leave the liveness record exactly where it was: the
    /// contact window is disarmed while coverage is closed, so no contact is
    /// owed and none is counted.
    @Test("A paused or off refusal records no contact")
    func standingRefusalsRecordNoContact() async throws {
        // Off: the project is never on, so its facts carry no contact at all.
        let off = try Self.makeFixture(repos: ["acme-alpha"])
        _ = try await off.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released,
            deliverer: RecordingDeliverer(.delivered))
        let offFacts = try await off.store.projectFacts(project: "acme-alpha", brake: .released)
        #expect(offFacts.lastSweepContactAt == nil, "an off refusal records no contact")

        // Paused: on, with one real contact, then a brake refusal that must not
        // move the stamp or the counter.
        let paused = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(paused, "acme-alpha")
        paused.dates.advance(by: 10)
        let contactAt = paused.dates.now
        _ = try await paused.store.submitBriefing(
            project: "acme-alpha", text: "", brake: .released,
            deliverer: RecordingDeliverer(.noLiveSupervisor))

        paused.dates.advance(by: 600)
        let refused = try await paused.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .engaged,
            deliverer: RecordingDeliverer(.delivered))
        #expect(refused.result == .refusedPaused)

        let facts = try await paused.store.projectFacts(project: "acme-alpha", brake: .engaged)
        #expect(facts.lastSweepContactAt == SupervisionInstant(contactAt),
                "the brake refusal must not move the liveness stamp")

        _ = try await paused.store.setProjectMark(project: "acme-alpha", on: false)
        let closing = try #require(try lines(at: paused.ledgerPath).last)
        guard case .projectOff(let coverage) = closing.payload else {
            Issue.record("the closing line must be projectOff, got \(closing.payload)")
            return
        }
        #expect(coverage.sweepContacts == 1, "only the submission that got past the brake counts")
    }

    /// Off beats paused when both stand. Off is a standing state: releasing the
    /// brake would change nothing, so "retry when supervision resumes" would
    /// send the program back forever.
    @Test("refused-off wins when the project is off and the brake is engaged")
    func offBeatsPaused() async throws {
        let fixture = try Self.makeFixture(repos: ["acme-alpha"])
        let result = try await fixture.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .engaged,
            deliverer: RecordingDeliverer(.delivered))
        #expect(result.result == .refusedOff)
        #expect(result.retryAfter == nil)
    }

    // MARK: - Contact precedes the remaining refusals

    /// A runaway composer must read as *broken*, not as silent. Silence is the
    /// one signal reserved for "nobody looked", so an oversize submission still
    /// records its contact before it is refused.
    @Test("An oversize submission is refused but still records contact")
    func oversizeStillRecordsContact() async throws {
        let fixture = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(fixture, "acme-alpha")
        fixture.dates.advance(by: 45)
        let at = fixture.dates.now

        let result = try await fixture.store.submitBriefing(
            project: "acme-alpha", text: Self.oversizeText, brake: .released,
            deliverer: RecordingDeliverer(.delivered))
        #expect(result.result == .refusedSize)

        let facts = try await fixture.store.projectFacts(project: "acme-alpha", brake: .released)
        #expect(facts.lastSweepContactAt == SupervisionInstant(at),
                "a broken composer must read as broken, not as silent")
    }

    /// A rate-limited submission is contact too — the refusal proves a program
    /// looked.
    @Test("A rate-limited submission still records contact")
    func rateLimitedStillRecordsContact() async throws {
        let fixture = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(fixture, "acme-alpha")
        let deliverer = RecordingDeliverer(.delivered)
        _ = try await fixture.store.submitBriefing(
            project: "acme-alpha", text: "first", brake: .released, deliverer: deliverer)

        fixture.dates.advance(by: 5)
        let at = fixture.dates.now
        let refused = try await fixture.store.submitBriefing(
            project: "acme-alpha", text: "second", brake: .released, deliverer: deliverer)
        #expect(refused.result == .refusedRateLimit)

        let facts = try await fixture.store.projectFacts(project: "acme-alpha", brake: .released)
        #expect(facts.lastSweepContactAt == SupervisionInstant(at))

        _ = try await fixture.store.setProjectMark(project: "acme-alpha", on: false)
        let closing = try #require(try lines(at: fixture.ledgerPath).last)
        guard case .projectOff(let coverage) = closing.payload else {
            Issue.record("the closing line must be projectOff, got \(closing.payload)")
            return
        }
        #expect(coverage.sweepContacts == 2, "both submissions looked")
    }

    // MARK: - The size bound is on bytes

    /// A character count would pass this briefing; a byte count refuses it. The
    /// bound is on what gets stored and sent.
    @Test("The size bound counts bytes, not characters")
    func sizeBoundCountsBytes() async throws {
        let fixture = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(fixture, "acme-alpha")

        // "é" is two UTF-8 bytes, so this is under the bound by characters and
        // over it by bytes.
        let text = String(repeating: "é", count: SupervisionBriefing.maxBriefingBytes / 2 + 1)
        #expect(text.count < SupervisionBriefing.maxBriefingBytes, "a character count would pass")
        #expect(text.utf8.count > SupervisionBriefing.maxBriefingBytes, "a byte count refuses")

        let result = try await fixture.store.submitBriefing(
            project: "acme-alpha", text: text, brake: .released,
            deliverer: RecordingDeliverer(.delivered))
        #expect(result.result == .refusedSize)
    }

    @Test("A briefing exactly at the byte bound is accepted")
    func exactlyAtTheBoundIsAccepted() async throws {
        let fixture = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(fixture, "acme-alpha")
        let text = String(repeating: "a", count: SupervisionBriefing.maxBriefingBytes)
        let deliverer = RecordingDeliverer(.noLiveSupervisor)
        let result = try await fixture.store.submitBriefing(
            project: "acme-alpha", text: text, brake: .released, deliverer: deliverer)
        #expect(result.result == .noLiveSupervisor, "the bound is inclusive")
        #expect(deliverer.callCount == 1)
    }

    // MARK: - Empty means zero bytes, and nothing else

    /// Whitespace is not empty. TBD does not read the text, and deciding that a
    /// briefing of three newlines "says nothing" would be reading it.
    @Test("A whitespace-only submission takes the non-empty path")
    func whitespaceIsNotEmpty() async throws {
        let fixture = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(fixture, "acme-alpha")
        let deliverer = RecordingDeliverer(.noLiveSupervisor)

        let result = try await fixture.store.submitBriefing(
            project: "acme-alpha", text: "\n\n\n", brake: .released, deliverer: deliverer)
        #expect(result.result == .noLiveSupervisor, "it went to the deliverer")
        #expect(deliverer.deliveredTexts == ["\n\n\n"], "verbatim, unparsed and untrimmed")
    }

    /// …and once delivered it burns the pacing slot like any other non-empty
    /// briefing. Whitespace gets no special treatment in either direction: TBD
    /// does not read the text, so it cannot be the reason a slot is or is not
    /// spent — delivery is.
    @Test("A whitespace-only submission paces the next one once it is delivered")
    func whitespaceBurnsTheSlot() async throws {
        let fixture = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(fixture, "acme-alpha")
        let deliverer = RecordingDeliverer(.delivered)
        _ = try await fixture.store.submitBriefing(
            project: "acme-alpha", text: " ", brake: .released, deliverer: deliverer)

        fixture.dates.advance(by: 1)
        let second = try await fixture.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released, deliverer: deliverer)
        #expect(second.result == .refusedRateLimit)
    }

    // MARK: - Pacing

    /// Pacing is per project: one project's window says nothing about another's.
    @Test("Pacing is per project")
    func pacingIsPerProject() async throws {
        let fixture = try Self.makeFixture(repos: ["acme-alpha", "acme-beta"])
        try await Self.turnOn(fixture, "acme-alpha")
        try await Self.turnOn(fixture, "acme-beta")
        let deliverer = RecordingDeliverer(.delivered)

        let first = try await fixture.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released, deliverer: deliverer)
        #expect(first.result == .delivered)

        fixture.dates.advance(by: 1)
        let other = try await fixture.store.submitBriefing(
            project: "acme-beta", text: "findings", brake: .released, deliverer: deliverer)
        #expect(other.result == .delivered, "pacing acme-alpha must not pace acme-beta")

        let again = try await fixture.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released, deliverer: deliverer)
        #expect(again.result == .refusedRateLimit, "…and acme-alpha is still inside its window")
    }

    @Test("The window lifts exactly one interval after the slot was spent")
    func windowLiftsAfterTheInterval() async throws {
        let fixture = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(fixture, "acme-alpha")
        let deliverer = RecordingDeliverer(.delivered)
        let spentAt = fixture.dates.now
        _ = try await fixture.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released, deliverer: deliverer)

        fixture.dates.advance(by: SupervisionBriefing.rateLimitInterval - 0.5)
        let inside = try await fixture.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released, deliverer: deliverer)
        #expect(inside.result == .refusedRateLimit)
        #expect(inside.retryAfter == SupervisionInstant(
            spentAt.addingTimeInterval(SupervisionBriefing.rateLimitInterval)),
                "retryAfter names when the window opens")

        fixture.dates.advance(by: 0.5)
        let atTheBoundary = try await fixture.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released, deliverer: deliverer)
        #expect(atTheBoundary.result == .delivered, "the interval is exclusive at its end")
    }

    /// Pacing is identity-blind, structurally: the submission carries no
    /// identity for the pipe to read, and two submissions that differ in
    /// everything a caller controls pace identically.
    @Test("Pacing is identity-blind: the pipe is given nothing but a project and text")
    func pacingIsIdentityBlind() async throws {
        // Structural: the params type carries exactly two fields, so there is
        // no declared caller for pacing to consult even if it wanted one.
        let encoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(
                SuperviseBriefParams(project: "acme-alpha", text: "findings")))
        let keys = Set((encoded as? [String: Any] ?? [:]).keys)
        #expect(keys == ["project", "text"],
                "an identity on this type would be an identity pacing could read")

        // Behavioural: two submissions differing in everything the submitter
        // controls — length, content, encoding — pace exactly alike.
        let first = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(first, "acme-alpha")
        let second = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(second, "acme-alpha")
        let deliverer = RecordingDeliverer(.delivered)

        _ = try await first.store.submitBriefing(
            project: "acme-alpha", text: "desk-a: one line", brake: .released,
            deliverer: deliverer)
        _ = try await second.store.submitBriefing(
            project: "acme-alpha", text: String(repeating: "desk-b ☃ ", count: 500),
            brake: .released, deliverer: deliverer)

        first.dates.advance(by: 30)
        second.dates.advance(by: 30)
        let firstAgain = try await first.store.submitBriefing(
            project: "acme-alpha", text: "desk-a: one line", brake: .released,
            deliverer: deliverer)
        let secondAgain = try await second.store.submitBriefing(
            project: "acme-alpha", text: String(repeating: "desk-b ☃ ", count: 500),
            brake: .released, deliverer: deliverer)
        #expect(firstAgain.result == secondAgain.result)
        #expect(firstAgain.result == .refusedRateLimit)
        #expect(firstAgain.retryAfter == secondAgain.retryAfter,
                "same timestamps in, same window out")
    }

    /// Pacing never applies to an empty submission, and an empty submission
    /// never spends the slot a later briefing needs — throttling the heartbeat
    /// would make a healthy sweep look like a dead one.
    ///
    /// **Both halves need a slot that is really spent, which is why every
    /// submission here goes to a deliverer that delivers.** The slot is spent
    /// only on delivery, so against a deliverer that never delivers no window
    /// is ever open, an empty submission could not be refused even if pacing
    /// did apply to it, and the follow-up could not be refused even if empties
    /// did burn the slot — both assertions would hold for the wrong reason.
    @Test("Pacing never applies to an empty submission, and empties do not burn the slot")
    func emptySubmissionsAreNeverPaced() async throws {
        let fixture = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(fixture, "acme-alpha")
        let deliverer = RecordingDeliverer(.delivered)

        // A real briefing, delivered: from here the project's window is shut,
        // which is the state the first half needs to say anything.
        #expect(try await fixture.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released,
            deliverer: deliverer).result == .delivered)

        // Half one: the heartbeat goes on beating inside a shut window.
        // Throttling it would make a healthy sweep look like a dead one.
        for index in 0..<10 {
            fixture.dates.advance(by: 1)
            let result = try await fixture.store.submitBriefing(
                project: "acme-alpha", text: "", brake: .released, deliverer: deliverer)
            #expect(result.result == .delivered, "empty submission \(index) inside a shut window")
            #expect(result.retryAfter == nil)
        }
        #expect(deliverer.callCount == 1, "an empty submission never reaches the deliverer")

        // Half two: with that window lapsed, ten more empties must leave the
        // slot alone, so the briefing that follows them a second later gets
        // through. If an empty spent the slot, this is where it shows.
        fixture.dates.advance(by: SupervisionBriefing.rateLimitInterval)
        for _ in 0..<10 {
            #expect(try await fixture.store.submitBriefing(
                project: "acme-alpha", text: "", brake: .released,
                deliverer: deliverer).result == .delivered)
        }
        fixture.dates.advance(by: 1)
        let real = try await fixture.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released, deliverer: deliverer)
        #expect(real.result == .delivered, "twenty empties must not have burned the slot")
        #expect(deliverer.callCount == 2)
    }

    /// A refusal the program did not cause must not cost it the window.
    ///
    /// Each arm's deliverer answers `delivered` for the same reason as the test
    /// above: only a delivered briefing spends the slot, so a follow-up sent to
    /// a deliverer that never delivers could never be rate-limited and the
    /// assertion would hold no matter what the refusals did.
    @Test("A refusal for paused, off or size does not burn the pacing slot")
    func refusalsDoNotBurnTheSlot() async throws {
        // Paused, then released: the very next submission must get through.
        let paused = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(paused, "acme-alpha")
        let pausedDeliverer = RecordingDeliverer(.delivered)
        #expect(try await paused.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .engaged,
            deliverer: pausedDeliverer).result == .refusedPaused)
        #expect(try await paused.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released,
            deliverer: pausedDeliverer).result == .delivered,
                "a brake refusal must not have spent the slot")

        // Off, then on.
        let off = try Self.makeFixture(repos: ["acme-alpha"])
        let offDeliverer = RecordingDeliverer(.delivered)
        #expect(try await off.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released,
            deliverer: offDeliverer).result == .refusedOff)
        try await Self.turnOn(off, "acme-alpha")
        #expect(try await off.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released,
            deliverer: offDeliverer).result == .delivered,
                "an off refusal must not have spent the slot")

        // Oversize, then a briefing that fits.
        let big = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(big, "acme-alpha")
        let bigDeliverer = RecordingDeliverer(.delivered)
        #expect(try await big.store.submitBriefing(
            project: "acme-alpha", text: Self.oversizeText, brake: .released,
            deliverer: bigDeliverer).result == .refusedSize)
        #expect(try await big.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released,
            deliverer: bigDeliverer).result == .delivered,
                "an oversize refusal must not have spent the slot")
    }

    /// A briefing that reached nobody must leave the window open, because the
    /// documented continuation for `no-live-supervisor` is to run `on` (ensure)
    /// and resubmit **in the same run**. A slot spent on a briefing no
    /// supervisor received would refuse that resubmission for two minutes and
    /// break the whole workflow — and since the shipped deliverer answers
    /// `no-live-supervisor` for every non-empty briefing today, it would break
    /// every one of them.
    @Test("A briefing that reached no supervisor does not burn the pacing slot")
    func aBriefingDeliveredToNobodyDoesNotBurnTheSlot() async throws {
        let fixture = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(fixture, "acme-alpha")

        let first = try await fixture.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released,
            deliverer: SupervisorBriefingDeliverer())
        #expect(first.result == .noLiveSupervisor)

        // Immediately — same instant, well inside the window — the program
        // establishes a supervisor and resubmits.
        let resubmitted = try await fixture.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released,
            deliverer: RecordingDeliverer(.delivered))
        #expect(resubmitted.result == .delivered,
                "the resubmission the contract prescribes must not meet refused-rate-limit")
        #expect(resubmitted.retryAfter == nil)
    }

    /// The same exemption for the other failed-delivery outcome: a send that
    /// was attempted and failed leaves the window open too.
    @Test("A transport failure does not burn the pacing slot")
    func aTransportFailureDoesNotBurnTheSlot() async throws {
        let fixture = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(fixture, "acme-alpha")
        #expect(try await fixture.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released,
            deliverer: RecordingDeliverer(.transportFailed)).result == .transportFailed)
        #expect(try await fixture.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released,
            deliverer: RecordingDeliverer(.delivered)).result == .delivered,
                "a failed send must not have spent the slot")
    }

    // MARK: - One attempt, never a retry

    @Test("A failed delivery is attempted exactly once")
    func failedDeliveryIsNotRetried() async throws {
        let fixture = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(fixture, "acme-alpha")
        let deliverer = RecordingDeliverer(.transportFailed)

        let result = try await fixture.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released, deliverer: deliverer)
        #expect(result.result == .transportFailed)
        #expect(deliverer.callCount == 1, "TBD makes one full attempt and never retries")
        #expect(deliverer.deliveredTexts == ["findings"], "delivered verbatim, unparsed")
    }

    @Test("A delivered briefing is counted in the coverage summary")
    func deliveredBriefingsAreCounted() async throws {
        let fixture = try Self.makeFixture(repos: ["acme-alpha"])
        try await Self.turnOn(fixture, "acme-alpha")
        let deliverer = RecordingDeliverer(.delivered)

        #expect(try await fixture.store.submitBriefing(
            project: "acme-alpha", text: "findings", brake: .released,
            deliverer: deliverer).result == .delivered)
        fixture.dates.advance(by: SupervisionBriefing.rateLimitInterval)
        #expect(try await fixture.store.submitBriefing(
            project: "acme-alpha", text: "more findings", brake: .released,
            deliverer: deliverer).result == .delivered)

        _ = try await fixture.store.setProjectMark(project: "acme-alpha", on: false)
        let closing = try #require(try lines(at: fixture.ledgerPath).last)
        guard case .projectOff(let coverage) = closing.payload else {
            Issue.record("the closing line must be projectOff, got \(closing.payload)")
            return
        }
        #expect(coverage.briefingsDelivered == 2)
        #expect(coverage.sweepContacts == 2)
    }

    // MARK: - Through the RPC surface

    private func makeRouter(directory: URL, db: TBDDatabase) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: ActuationLog(
                path: directory.appendingPathComponent("actuations.jsonl").path))
    }

    @Test("supervise.brief answers no-live-supervisor with the shipped deliverer")
    func briefThroughRPC() async throws {
        let fixture = try Self.makeFixture(repos: ["acme-alpha"])
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(directory: fixture.directory, db: db)
        router.supervision = fixture.store
        try await Self.turnOn(fixture, "acme-alpha")

        // The brake is read from config by the handler, so it has to be
        // released there rather than passed in.
        let released = await router.handle(try RPCRequest(
            method: RPCMethod.configSetSupervisionEnabled,
            params: ConfigSetSupervisionEnabledParams(enabled: true)))
        #expect(released.success)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.superviseBrief,
            params: SuperviseBriefParams(project: "acme-alpha", text: "findings")))
        #expect(response.success, "\(response.error ?? "")")
        let result = try response.decodeResult(SupervisionBriefResult.self)
        #expect(result.result == .noLiveSupervisor)
        #expect(result.project == "acme-alpha")
        #expect(result.schemaVersion == SupervisionBriefResult.currentSchemaVersion)
    }

    @Test("supervise.brief reads the brake from config")
    func briefThroughRPCHonoursTheBrake() async throws {
        let fixture = try Self.makeFixture(repos: ["acme-alpha"])
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(directory: fixture.directory, db: db)
        router.supervision = fixture.store
        try await Self.turnOn(fixture, "acme-alpha")

        // The shipped default is braked, and nothing released it here.
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.superviseBrief,
            params: SuperviseBriefParams(project: "acme-alpha", text: "findings")))
        #expect(response.success, "\(response.error ?? "")")
        let result = try response.decodeResult(SupervisionBriefResult.self)
        #expect(result.result == .refusedPaused)
    }

    @Test("supervise.brief hands the router's deliverer to the pipe")
    func briefThroughRPCUsesTheInjectedDeliverer() async throws {
        let fixture = try Self.makeFixture(repos: ["acme-alpha"])
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(directory: fixture.directory, db: db)
        router.supervision = fixture.store
        let deliverer = RecordingDeliverer(.transportFailed)
        router.supervisionBriefingDeliverer = deliverer
        try await Self.turnOn(fixture, "acme-alpha")
        #expect(await router.handle(try RPCRequest(
            method: RPCMethod.configSetSupervisionEnabled,
            params: ConfigSetSupervisionEnabledParams(enabled: true))).success)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.superviseBrief,
            params: SuperviseBriefParams(project: "acme-alpha", text: "findings")))
        let result = try response.decodeResult(SupervisionBriefResult.self)
        #expect(result.result == .transportFailed)
        #expect(deliverer.callCount == 1)
    }

    @Test("supervise.brief refuses when no supervision store is wired")
    func briefRefusesWithoutAStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-supervision-brief-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(directory: directory, db: db)

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.superviseBrief,
            params: SuperviseBriefParams(project: "acme-alpha", text: "findings")))
        #expect(response.success == false)
        #expect(response.error?.contains("no supervision store") == true)
    }
}
