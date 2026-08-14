import Testing
import Foundation
@testable import TBDShared

@Suite struct SupervisionInstantTests {
    @Test func encodesISO8601WithFractionalSecondsInUTC() throws {
        let instant = SupervisionInstant(Date(timeIntervalSince1970: 1_786_000_392.482))
        #expect(instant.wireValue.hasSuffix("Z"))
        #expect(instant.wireValue.contains("."))
        let encoded = try JSONEncoder().encode(instant)
        #expect(String(bytes: encoded, encoding: .utf8) == "\"\(instant.wireValue)\"")
    }

    @Test func roundTripsToTheMillisecond() throws {
        let instant = SupervisionInstant(Date(timeIntervalSince1970: 1_786_000_392.482))
        let decoded = try JSONDecoder().decode(
            SupervisionInstant.self, from: try JSONEncoder().encode(instant))
        #expect(abs(decoded.date.timeIntervalSince(instant.date)) < 0.001)
        // The stronger claim, and the one the ledger needs: a line that made a
        // round trip is the same value, not a near neighbour.
        #expect(decoded.wireValue == instant.wireValue)
        #expect(decoded == instant)
    }

    @Test func subMillisecondPrecisionIsDroppedAtConstruction() {
        // An instant holds the precision it can persist. Two `Date`s inside one
        // millisecond of each other are one instant.
        let base = Date(timeIntervalSince1970: 1_786_000_392.4821)
        #expect(SupervisionInstant(base) == SupervisionInstant(base.addingTimeInterval(0.0002)))
        #expect(SupervisionInstant(base) != SupervisionInstant(base.addingTimeInterval(0.01)))
    }

    @Test func refusesAValueThatIsNotATimestamp() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SupervisionInstant.self, from: Data("\"soon\"".utf8))
        }
    }
}

@Suite struct SupervisionLedgerLineTests {
    private let writtenAt = Date(timeIntervalSince1970: 1_786_000_392.482)

    private func object(_ line: SupervisionLedgerLine) throws -> [String: Any] {
        let data = try JSONEncoder().encode(line)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    @Test func aBrakeLineCarriesAnExplicitNullProjectAndMode() throws {
        // The brake acts fleet-wide, so null is the accurate answer, not a gap:
        // the keys are present and null rather than omitted. And there is no
        // API by which a caller could name a project here — `brakeEngaged` and
        // `brakeReleased` take none, and the memberwise initializer is private.
        for line in [SupervisionLedgerLine.brakeEngaged(at: writtenAt),
                     SupervisionLedgerLine.brakeReleased(at: writtenAt)] {
            let encoded = try object(line)
            #expect(encoded.keys.contains("project"))
            #expect(encoded["project"] is NSNull)
            #expect(encoded.keys.contains("mode"))
            #expect(encoded["mode"] is NSNull)
            #expect(encoded["kind"] as? String == "lifecycle")
            #expect(line.project == nil)
            #expect(line.mode == nil)
        }
        #expect(try object(.brakeEngaged(at: writtenAt))["event"] as? String == "brakeEngaged")
        #expect(try object(.brakeReleased(at: writtenAt))["event"] as? String == "brakeReleased")
    }

    @Test func aProjectLineCarriesTheEnvelopeAndItsPayload() throws {
        let roster = [SupervisionRosterEntry(
            worktree: UUID(), terminal: UUID(), repo: UUID(), project: "acme-checkout",
            spawnSource: "tbd", transcriptPath: nil)]
        let line = SupervisionLedgerLine.projectOn(
            project: "acme-checkout", mode: "autonomous", roster: roster,
            at: writtenAt, id: "abc123")
        let encoded = try object(line)
        #expect(encoded["id"] as? String == "abc123")
        #expect(encoded["project"] as? String == "acme-checkout")
        #expect(encoded["mode"] as? String == "autonomous")
        #expect(encoded["kind"] as? String == "lifecycle")
        #expect(encoded["event"] as? String == "projectOn")
        #expect((encoded["roster"] as? [[String: Any]])?.count == 1)
        // An unknown transcript is null, never a missing key or a guess.
        let entry = (encoded["roster"] as? [[String: Any]])?.first
        #expect(entry?.keys.contains("transcriptPath") == true)
        #expect(entry?["transcriptPath"] is NSNull)
    }

    @Test func theSpanEndCarriesItsCoverageSummary() throws {
        let summary = SupervisionCoverageSummary(
            spanStartedAt: SupervisionInstant(writtenAt.addingTimeInterval(-3600)),
            spanEndedAt: SupervisionInstant(writtenAt),
            sweepContacts: 0, briefingsDelivered: 0)
        #expect(summary.durationSeconds == 3600)
        let line = SupervisionLedgerLine.projectOff(
            project: "acme-checkout", mode: "attended", coverage: summary, at: writtenAt)
        let coverage = try object(line)["coverage"] as? [String: Any]
        #expect(coverage?["sweepContacts"] as? Int == 0)
        #expect(coverage?["briefingsDelivered"] as? Int == 0)
        #expect(coverage?["durationSeconds"] as? Int == 3600)
    }

    @Test func anUnpairedSpanEndSaysSoRatherThanInventingAStart() throws {
        let summary = SupervisionCoverageSummary(
            spanStartedAt: nil, spanEndedAt: SupervisionInstant(writtenAt),
            sweepContacts: 0, briefingsDelivered: 0)
        #expect(summary.durationSeconds == nil)
        let line = SupervisionLedgerLine.projectOff(
            project: "acme-checkout", mode: "attended", coverage: summary, at: writtenAt)
        let coverage = try object(line)["coverage"] as? [String: Any]
        #expect(coverage?["spanStartedAt"] is NSNull)
        #expect(coverage?["durationSeconds"] is NSNull)
    }

    @Test func aModeChangeNamesBothEnds() throws {
        let line = SupervisionLedgerLine.modeChanged(
            project: "acme-checkout", from: "attended", to: "autonomous", at: writtenAt)
        let encoded = try object(line)
        #expect(encoded["from"] as? String == "attended")
        #expect(encoded["to"] as? String == "autonomous")
        // The envelope's mode is the mode in force after the change.
        #expect(encoded["mode"] as? String == "autonomous")
    }

    @Test func everyLineShapeSurvivesARoundTrip() throws {
        let lines: [SupervisionLedgerLine] = [
            .brakeEngaged(at: writtenAt),
            .brakeReleased(at: writtenAt),
            .projectOn(project: "acme-checkout", mode: "autonomous", roster: [], at: writtenAt),
            .projectOff(project: "acme-checkout", mode: "attended",
                        coverage: .init(spanStartedAt: nil,
                                        spanEndedAt: SupervisionInstant(writtenAt),
                                        sweepContacts: 0, briefingsDelivered: 0),
                        at: writtenAt),
            .modeChanged(project: "acme-checkout", from: "attended", to: "autonomous",
                         at: writtenAt),
        ]
        for line in lines {
            let decoded = try JSONDecoder().decode(
                SupervisionLedgerLine.self, from: try JSONEncoder().encode(line))
            #expect(decoded == line)
        }
    }

    @Test func lineIdsAreOpaqueAndUnique() {
        let first = SupervisionLedgerLine.newID()
        let second = SupervisionLedgerLine.newID()
        #expect(first != second)
        #expect(!first.contains("-"))
        #expect(first == first.lowercased())
    }

    @Test func aWholeLineIsOneJSONLRow() throws {
        let data = try JSONEncoder().encode(SupervisionLedgerLine.brakeEngaged(at: writtenAt))
        #expect(String(bytes: data, encoding: .utf8)?.contains("\n") == false)
    }
}

@Suite struct SupervisionStatusFileTests {
    @Test func theHeartbeatCarriesSchemaVersionBrakeAndProjects() throws {
        let file = SupervisionStatusFile(
            writtenAt: SupervisionInstant(Date(timeIntervalSince1970: 1_786_000_392.482)),
            brake: .released,
            projects: [.init(name: "acme-checkout", on: true, mode: "autonomous",
                             lastSweepContactAt: nil)])
        let encoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(file)) as? [String: Any]
        #expect(encoded?["schemaVersion"] as? Int == 1)
        #expect(encoded?["brake"] as? String == "released")
        #expect((encoded?["writtenAt"] as? String)?.hasSuffix("Z") == true)
        let project = (encoded?["projects"] as? [[String: Any]])?.first
        #expect(project?["on"] as? Bool == true)
        // Never contacted is null, not a fabricated time.
        #expect(project?.keys.contains("lastSweepContactAt") == true)
        #expect(project?["lastSweepContactAt"] is NSNull)
    }

    @Test func theHeartbeatRoundTrips() throws {
        let file = SupervisionStatusFile(
            writtenAt: SupervisionInstant(Date(timeIntervalSince1970: 1_786_000_392.482)),
            brake: .engaged, projects: [])
        let decoded = try JSONDecoder().decode(
            SupervisionStatusFile.self, from: try JSONEncoder().encode(file))
        #expect(decoded == file)
    }
}

@Suite struct SupervisionRPCVocabularyTests {
    @Test func methodNamesAreTheDocumentedOnes() {
        #expect(RPCMethod.configSetSupervisionEnabled == "config.setSupervisionEnabled")
        #expect(RPCMethod.superviseStatus == "supervise.status")
        #expect(RPCMethod.superviseSetProjectMark == "supervise.setProjectMark")
        #expect(RPCMethod.superviseSetMode == "supervise.setMode")
        #expect(RPCMethod.superviseProjectList == "supervise.projectList")
        #expect(RPCMethod.superviseProjectCreate == "supervise.projectCreate")
        #expect(RPCMethod.superviseProjectDelete == "supervise.projectDelete")
        #expect(RPCMethod.superviseProjectMove == "supervise.projectMove")
    }

    @Test func statusCarriesASchemaVersionAndTheLoudWarning() throws {
        let status = SupervisionStatus(
            brake: .released, effectivelySupervising: false, projects: [],
            warnings: [.init(code: .noProjectsOn,
                             message: "supervision is on but no project is on — "
                                + "nothing is being supervised")])
        let encoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(status)) as? [String: Any]
        #expect(encoded?["schemaVersion"] as? Int == 1)
        #expect(encoded?["effectivelySupervising"] as? Bool == false)
        let warning = (encoded?["warnings"] as? [[String: Any]])?.first
        #expect(warning?["code"] as? String == "noProjectsOn")
    }

    @Test func everyResultDTOCarriesASchemaVersion() throws {
        let payloads: [any Encodable] = [
            SupervisionStatus(brake: .engaged, effectivelySupervising: false,
                              projects: [], warnings: []),
            SuperviseProjectListResult(projects: []),
            SuperviseSetProjectMarkResult(project: "acme-checkout", on: true, changed: true),
            SuperviseSetModeResult(project: "acme-checkout", mode: "autonomous",
                                   declaredModes: ["attended", "autonomous"], changed: true),
        ]
        for payload in payloads {
            let data = try JSONEncoder().encode(payload)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(object?["schemaVersion"] as? Int == 1)
        }
    }

    @Test func aStatusProjectRowLeavesUnknowableFieldsNull() throws {
        let row = SupervisionStatusProject(
            name: "tbd", on: false, mode: "attended",
            declaredModes: ["attended", "autonomous"], supervisor: .hostedDesk,
            spanStartedAt: nil, lastSweepContactAt: nil, coverageWindow: nil)
        let encoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(row)) as? [String: Any]
        #expect(encoded?["spanStartedAt"] is NSNull)
        #expect(encoded?["lastSweepContactAt"] is NSNull)
        #expect(encoded?["coverageWindow"] is NSNull)
        #expect((encoded?["supervisor"] as? [String: Any])?["kind"] as? String == "hostedDesk")
    }

    @Test func policyRequestsCarryTheRepoAsTypedText() throws {
        let byRepo = SupervisionPolicyRequest.repo("acme-web")
        let encoded = try JSONEncoder().encode(byRepo)
        #expect(String(bytes: encoded, encoding: .utf8) == "{\"repo\":\"acme-web\"}")
        #expect(try JSONDecoder().decode(SupervisionPolicyRequest.self, from: encoded) == byRepo)
        let byOperator = try JSONEncoder().encode(SupervisionPolicyRequest.operator)
        #expect(try JSONDecoder().decode(
            SupervisionPolicyRequest.self, from: byOperator) == .operator)
    }

    @Test func paramsRoundTrip() throws {
        let create = SuperviseProjectCreateParams(
            name: "acme-checkout", repos: ["acme-web", "acme-api"], policy: .repo("acme-web"))
        #expect(try JSONDecoder().decode(
            SuperviseProjectCreateParams.self,
            from: try JSONEncoder().encode(create)) == create)

        let move = SuperviseProjectMoveParams(repo: "acme-web", to: "singleton")
        #expect(try JSONDecoder().decode(
            SuperviseProjectMoveParams.self, from: try JSONEncoder().encode(move)) == move)

        let mark = SuperviseSetProjectMarkParams(project: "acme-checkout", on: true)
        #expect(try JSONDecoder().decode(
            SuperviseSetProjectMarkParams.self, from: try JSONEncoder().encode(mark)) == mark)

        let mode = SuperviseSetModeParams(project: "acme-checkout", mode: "autonomous")
        #expect(try JSONDecoder().decode(
            SuperviseSetModeParams.self, from: try JSONEncoder().encode(mode)) == mode)

        let brake = ConfigSetSupervisionEnabledParams(enabled: true)
        #expect(try JSONDecoder().decode(
            ConfigSetSupervisionEnabledParams.self,
            from: try JSONEncoder().encode(brake)) == brake)
    }
}
