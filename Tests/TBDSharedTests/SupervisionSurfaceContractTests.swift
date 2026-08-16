import Foundation
import Testing

@testable import TBDShared

/// Tier 1. The wire contract of the three public supervision surfaces —
/// `supervise readout`, `supervise ledger`, `supervise brief`.
///
/// Everything asserted here is something a sweep program outside this process
/// depends on and cannot negotiate: the pinned briefing-outcome vocabulary, the
/// top-level `schemaVersion` on each result, the explicit-null rule for every
/// optional, and the ledger's verbatim pass-through of fields this build does
/// not model. Assertions are whitelist-shaped — they name the key that must be
/// present and the value it must carry — so a field going missing reddens
/// rather than passing quietly.
@Suite("Supervision public surface contract")
struct SupervisionSurfaceContractTests {

    // MARK: Fixtures

    private static let instant = SupervisionInstant(Date(timeIntervalSince1970: 1_760_000_000))
    private static let terminal = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let worktree = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let repo = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    /// The compact JSON text a value encodes to, keys sorted so an assertion on
    /// a substring is stable.
    private func jsonText(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return try #require(String(bytes: data, encoding: .utf8))
    }

    /// A readout whose every optional is nil — the shape the explicit-null rule
    /// has to survive.
    private func emptyReadout() -> SupervisionReadout {
        SupervisionReadout(
            project: "acme-platform",
            generatedAt: Self.instant,
            supervision: SupervisionReadoutMachinery(
                brake: .released, on: true, mode: "attended",
                declaredModes: ["attended", "autonomous"],
                spanStartedAt: nil, lastSweepContactAt: nil),
            supervisor: SupervisionReadoutSupervisor(
                arrangement: .hostedDesk, state: nil, lastAttestedAct: nil,
                contextLoad: nil, unansweredBriefingSince: nil, live: false),
            agents: [
                SupervisionReadoutAgent(
                    terminal: Self.terminal, worktree: Self.worktree, repo: Self.repo,
                    spawnSource: "claude", transcriptPath: nil,
                    state: SessionState(
                        value: .idle, source: .hookEvent("Stop"),
                        observedAt: Date(timeIntervalSince1970: 1_760_000_000)),
                    work: SupervisionReadoutWork(
                        branch: "feature/x", hasConflicts: false,
                        commitsUnchangedSince: nil, pr: nil, prStatus: nil),
                    counters: nil, pinned: false,
                    notToAct: SupervisionReadoutNotToAct(
                        interventionInFlight: false, recheckPending: false,
                        rateLimitedUntil: nil))
            ])
    }

    // MARK: Briefing outcome vocabulary

    /// The seven values design §3 pins, each against its exact raw string.
    ///
    /// Spelled out one by one rather than derived from `allCases`, because the
    /// contract is the *string*: a case renamed in Swift with its raw value
    /// intact must stay green, and a raw value edited must go red.
    @Test("Every briefing outcome round-trips through its pinned raw string")
    func briefOutcomeRawValuesArePinned() throws {
        let pinned: [(SupervisionBriefOutcome, String)] = [
            (.delivered, "delivered"),
            (.refusedPaused, "refused-paused"),
            (.refusedOff, "refused-off"),
            (.refusedRateLimit, "refused-rate-limit"),
            (.refusedSize, "refused-size"),
            (.transportFailed, "transport-failed"),
            (.noLiveSupervisor, "no-live-supervisor"),
        ]
        for (value, raw) in pinned {
            #expect(value.rawValue == raw)
            #expect(SupervisionBriefOutcome(rawValue: raw) == value)
            let encoded = try jsonText([value])
            #expect(encoded == "[\"\(raw)\"]")
        }
    }

    /// Seven members, no more. An eighth is a deliberate widening of a
    /// documented contract, and it should cost the author a look at this test
    /// and at the spec section it names.
    @Test("The briefing outcome vocabulary has exactly its seven documented members")
    func briefOutcomeVocabularyIsClosedAtSeven() {
        #expect(SupervisionBriefOutcome.allCases.count == 7)
        #expect(Set(SupervisionBriefOutcome.allCases.map(\.rawValue)) == [
            "delivered", "refused-paused", "refused-off", "refused-rate-limit",
            "refused-size", "transport-failed", "no-live-supervisor",
        ])
    }

    // MARK: Schema version

    @Test("The readout carries schemaVersion 1 at the top level")
    func readoutCarriesSchemaVersion() throws {
        #expect(SupervisionReadout.currentSchemaVersion == 1)
        #expect(try jsonText(emptyReadout()).contains("\"schemaVersion\":1"))
    }

    @Test("The ledger view carries schemaVersion 1 at the top level")
    func ledgerViewCarriesSchemaVersion() throws {
        #expect(SupervisionLedgerView.currentSchemaVersion == 1)
        let view = SupervisionLedgerView(
            project: "acme-platform", since: Self.instant, generatedAt: Self.instant,
            lines: [], skipped: SupervisionLedgerViewSkipped(
                actuationLines: 0, supervisionLines: 0))
        #expect(try jsonText(view).contains("\"schemaVersion\":1"))
    }

    @Test("The brief result carries schemaVersion 1 at the top level")
    func briefResultCarriesSchemaVersion() throws {
        #expect(SupervisionBriefResult.currentSchemaVersion == 1)
        let result = SupervisionBriefResult(
            project: "acme-platform", result: .delivered, submittedAt: Self.instant,
            detail: "Delivered to the hosted desk.", retryAfter: nil)
        #expect(try jsonText(result).contains("\"schemaVersion\":1"))
    }

    // MARK: Explicit nulls

    /// Every optional on the readout, named and asserted present-and-null.
    ///
    /// A missing key would leave a reader unable to tell "TBD does not know
    /// this" from "an older build did not write this field", which is the
    /// distinction the hand-written encoders exist to preserve.
    @Test("Every readout optional encodes as an explicit null")
    func readoutOptionalsEncodeAsExplicitNulls() throws {
        let text = try jsonText(emptyReadout())
        let nullKeys = [
            "spanStartedAt", "lastSweepContactAt",          // machinery
            "state", "lastAttestedAct", "contextLoad",      // supervisor
            "unansweredBriefingSince",
            "transcriptPath", "counters",                   // agent
            "commitsUnchangedSince", "pr", "prStatus",      // work
            "rateLimitedUntil",                             // notToAct
        ]
        for key in nullKeys {
            #expect(text.contains("\"\(key)\":null"), "readout must carry \(key) as an explicit null")
        }
    }

    /// The supervisor section's nulls are the finding, not a gap: `live` is
    /// false and the four facts are absent-as-null until briefing delivery
    /// lands. A consumer reads `live`, never a non-null `arrangement`.
    @Test("An offline supervisor reports live=false beside a present arrangement")
    func offlineSupervisorReportsLiveFalse() throws {
        let text = try jsonText(emptyReadout())
        #expect(text.contains("\"live\":false"))
        #expect(text.contains("\"arrangement\":{"))
        #expect(text.contains("\"kind\":\"hostedDesk\""))
    }

    @Test("A ledger line owed no observation encodes delivery as an explicit null")
    func ledgerLineDeliveryEncodesAsExplicitNull() throws {
        let line = SupervisionLedgerViewLine(
            source: .supervision, kind: "lifecycle", ts: Self.instant,
            delivery: nil, line: .object(["kind": .string("lifecycle")]))
        #expect(try jsonText(line).contains("\"delivery\":null"))
    }

    @Test("A brief result with no retry window encodes retryAfter as an explicit null")
    func briefResultRetryAfterEncodesAsExplicitNull() throws {
        let result = SupervisionBriefResult(
            project: "acme-platform", result: .refusedOff, submittedAt: Self.instant,
            detail: "Project acme-platform is not marked on.", retryAfter: nil)
        #expect(try jsonText(result).contains("\"retryAfter\":null"))
    }

    /// The one outcome that does carry a retry window carries it as a value, so
    /// the null above is a statement rather than the encoder's only behavior.
    @Test("A rate-limit refusal carries retryAfter as a value")
    func rateLimitRefusalCarriesRetryAfter() throws {
        let result = SupervisionBriefResult(
            project: "acme-platform", result: .refusedRateLimit, submittedAt: Self.instant,
            detail: "One briefing per project per 2 minutes.", retryAfter: Self.instant)
        #expect(try jsonText(result).contains("\"retryAfter\":\"\(Self.instant.wireValue)\""))
    }

    // MARK: Verbatim pass-through

    /// The reason lines are carried as JSON rather than re-modelled: a field a
    /// later build adds must survive a query whose whole job is showing a
    /// program everything that touched the fleet.
    @Test("A ledger line preserves keys this build does not model")
    func ledgerLinePreservesUnmodelledKeys() throws {
        let original: SupervisionJSONValue = .object([
            "id": .string("a3f1b2c3d4e5"),
            "kind": .string("send"),
            "someFutureField": .object([
                "nested": .array([.integer(1), .string("two"), .null])
            ]),
        ])
        let line = SupervisionLedgerViewLine(
            source: .actuation, kind: "send", ts: Self.instant,
            delivery: "awaiting-observation", line: original)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoded = try JSONDecoder().decode(
            SupervisionLedgerViewLine.self, from: try encoder.encode(line))

        #expect(decoded.line == original)
        #expect(decoded.delivery == "awaiting-observation")
        #expect(decoded.source == .actuation)
        #expect(try jsonText(line).contains("\"someFutureField\""))
        #expect(try jsonText(line).contains("\"nested\""))
    }

    // MARK: Compiled defaults

    /// The §10 numbers this slice compiles. Spelled here so a change to any of
    /// them is a change to a documented default and not a silent edit.
    @Test("The briefing pipe's compiled defaults match design section 10")
    func briefingCompiledDefaultsMatchSpec() {
        #expect(SupervisionBriefing.maxBriefingBytes == 262_144)
        #expect(SupervisionBriefing.rateLimitInterval == 120)
        #expect(SupervisionBriefing.pausedExitCode == 75)
    }

    // MARK: Method names

    @Test("The three surfaces' RPC method names are the documented ones")
    func rpcMethodNamesAreDocumented() {
        #expect(RPCMethod.superviseReadout == "supervise.readout")
        #expect(RPCMethod.superviseLedger == "supervise.ledger")
        #expect(RPCMethod.superviseBrief == "supervise.brief")
    }

    // MARK: Round trips

    @Test("Each surface's params and results survive a round trip")
    func surfacesRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let readoutParams = SuperviseReadoutParams(project: "acme-platform")
        #expect(try decoder.decode(
            SuperviseReadoutParams.self, from: encoder.encode(readoutParams)) == readoutParams)

        let ledgerParams = SuperviseLedgerParams(project: "acme-platform", since: Self.instant)
        #expect(try decoder.decode(
            SuperviseLedgerParams.self, from: encoder.encode(ledgerParams)) == ledgerParams)

        let briefParams = SuperviseBriefParams(project: "acme-platform", text: "")
        #expect(try decoder.decode(
            SuperviseBriefParams.self, from: encoder.encode(briefParams)) == briefParams)

        let readout = emptyReadout()
        #expect(try decoder.decode(
            SupervisionReadout.self, from: encoder.encode(readout)) == readout)
    }
}
