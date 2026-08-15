import Foundation
import Testing
import TBDShared

@testable import TBDCLI

private enum SuperviseFixtureError: Error {
    case encodedStatusWasNotUTF8
}

/// Fixtures and the two shapes every assertion here is made against: the text a
/// human reads, and the JSON a program branches on.
private enum SuperviseFixture {
    static let zone = TimeZone(identifier: "UTC")!
    /// 2026-08-14T22:10:00Z — the rows below sit a few minutes on either side.
    static let now = Date(timeIntervalSince1970: 1_786_745_400)

    static func project(
        name: String,
        on: Bool,
        mode: String = "attended",
        declaredModes: [String] = ["attended", "autonomous"],
        supervisor: SupervisionSupervisorArrangement = .hostedDesk,
        spanStartedAt: Date? = nil,
        lastSweepContactAt: Date? = nil,
        coverageWindow: String? = nil
    ) -> SupervisionStatusProject {
        SupervisionStatusProject(
            name: name, on: on, mode: mode, declaredModes: declaredModes,
            supervisor: supervisor,
            spanStartedAt: spanStartedAt.map { SupervisionInstant($0) },
            lastSweepContactAt: lastSweepContactAt.map { SupervisionInstant($0) },
            coverageWindow: coverageWindow)
    }

    static func status(
        brake: SupervisionBrakeState,
        effectivelySupervising: Bool,
        projects: [SupervisionStatusProject],
        warnings: [SupervisionWarning] = []
    ) -> SupervisionStatus {
        SupervisionStatus(
            brake: brake, effectivelySupervising: effectivelySupervising,
            projects: projects, warnings: warnings)
    }

    static func render(_ status: SupervisionStatus) -> String {
        renderSupervisionStatus(status, now: now, timeZone: zone)
    }

    /// The `--json` form as a program sees it, encoded exactly the way
    /// `printJSON` encodes it.
    static func json(_ status: SupervisionStatus) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(status)
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw SuperviseFixtureError.encodedStatusWasNotUTF8
        }
        return text
    }
}

@Suite("tbd supervise status — the loud case")
struct SupervisionStatusLoudCaseTests {
    /// The property this whole design fears losing: a fleet switched on with
    /// nothing marked on must not render a calm night.
    @Test func fleetOnWithNoProjectOnSaysSoInWords() {
        let text = SuperviseFixture.render(
            SuperviseFixture.status(
                brake: .released, effectivelySupervising: false,
                projects: [
                    SuperviseFixture.project(name: "acme-checkout", on: false),
                    SuperviseFixture.project(name: "tbd", on: false),
                ]))
        #expect(text.contains("brake: released"))
        #expect(text.contains("warning:"))
        #expect(text.contains("no project is on"))
        #expect(text.contains("nothing is being supervised"))
    }

    @Test func fleetOnWithNoProjectsAtAllSaysSoToo() {
        let text = SuperviseFixture.render(
            SuperviseFixture.status(
                brake: .released, effectivelySupervising: false, projects: []))
        #expect(text.contains("nothing is being supervised"))
    }

    /// The same fact as a field a program branches on.
    @Test func jsonCarriesTheSameFactAsFields() throws {
        let status = SuperviseFixture.status(
            brake: .released, effectivelySupervising: false,
            projects: [SuperviseFixture.project(name: "acme-checkout", on: false)],
            warnings: [
                SupervisionWarning(
                    code: .noProjectsOn,
                    message: "the brake is released but no project is on."),
            ])
        let json = try SuperviseFixture.json(status)
        #expect(json.contains("\"schemaVersion\" : 1"))
        #expect(json.contains("\"effectivelySupervising\" : false"))
        #expect(json.contains("\"noProjectsOn\""))
    }

    @Test func daemonSuppliedWarningTextIsWhatGetsPrinted() {
        let text = SuperviseFixture.render(
            SuperviseFixture.status(
                brake: .released, effectivelySupervising: false, projects: [],
                warnings: [
                    SupervisionWarning(code: .noProjectsOn, message: "nobody is watching acme."),
                ]))
        #expect(text.contains("warning: nobody is watching acme."))
        // The daemon's sentence replaces the built-in one rather than doubling it.
        #expect(!text.contains("nothing is being supervised"))
    }

    /// A daemon that sends the code with no sentence must still be loud.
    @Test func emptyWarningMessageFallsBackToTheBuiltInSentence() {
        let text = SuperviseFixture.render(
            SuperviseFixture.status(
                brake: .released, effectivelySupervising: false, projects: [],
                warnings: [SupervisionWarning(code: .noProjectsOn, message: "   ")]))
        #expect(text.contains("warning: the brake is released but no project is on"))
    }

    /// A project whose name cannot be a directory is still supervised — the
    /// warning must say what is missing and how to fix it without reading as a
    /// stopped fleet.
    @Test func anUnusableProjectNameWarnsWithoutClaimingSupervisionStopped() {
        let text = SuperviseFixture.render(
            SuperviseFixture.status(
                brake: .released, effectivelySupervising: true,
                projects: [SuperviseFixture.project(name: "acme/web", on: true)],
                warnings: [SupervisionWarning(code: .unusableProjectName, message: "")]))
        #expect(text.contains("warning:"))
        #expect(text.contains("cannot be used as a directory name"))
        #expect(text.contains("rename the repo"))
        #expect(text.contains("supervised like any other project"))
        #expect(!text.contains("nothing is being supervised"))
        // The project keeps its row, its mark and its mode.
        #expect(text.contains("acme/web"))
        #expect(text.contains("mode attended"))
    }

    /// Releasing the brake is the moment an operator forms the belief that
    /// supervision is running, and the only gesture that can create the state
    /// the warning describes — so bare `on` says it too.
    @Test func releasingTheBrakeOverNothingWarnsAtTheRelease() {
        let lines = supervisionGestureWarningLines(
            SuperviseFixture.status(
                brake: .released, effectivelySupervising: false,
                projects: [SuperviseFixture.project(name: "acme-checkout", on: false)]))
        #expect(lines.count == 1)
        #expect(lines.first?.contains("no project is on") == true)
        #expect(lines.first?.contains("nothing is being supervised") == true)
    }

    /// The mirror, and the worse of the two: the operator ran `on acme`, was
    /// told `on: acme`, and nothing is watching it.
    @Test func markingAProjectOnUnderAnEngagedBrakeSaysNothingIsWatching() {
        let lines = supervisionGestureWarningLines(
            SuperviseFixture.status(
                brake: .engaged, effectivelySupervising: false,
                projects: [SuperviseFixture.project(name: "acme-checkout", on: true)]))
        #expect(lines.count == 1)
        #expect(lines.first?.contains("brake is engaged") == true)
        #expect(lines.first?.contains("nothing is watching") == true)
        #expect(lines.first?.contains("tbd supervise on") == true)
        // Not the other half of the pair: these two states are both
        // `effectivelySupervising == false` and call for opposite actions.
        #expect(lines.first?.contains("no project is on") == false)
    }

    /// An engaged brake over a fleet with no marks is a deliberately quiet
    /// system. Warning there would train an operator to ignore the line.
    @Test func anEngagedBrakeWithNoMarksStandingIsQuiet() {
        let lines = supervisionGestureWarningLines(
            SuperviseFixture.status(
                brake: .engaged, effectivelySupervising: false,
                projects: [
                    SuperviseFixture.project(name: "acme-checkout", on: false),
                    SuperviseFixture.project(name: "tbd", on: false),
                ]))
        #expect(lines.isEmpty)
    }

    /// One fact, one sentence: the gesture surfaces and `status` must not drift
    /// into separate wordings for the same condition.
    @Test func theGestureWarningIsTheSameCompositionStatusRenders() {
        for status in [
            SuperviseFixture.status(
                brake: .released, effectivelySupervising: false, projects: []),
            SuperviseFixture.status(
                brake: .released, effectivelySupervising: false, projects: [],
                warnings: [SupervisionWarning(code: .unusableProjectName, message: "")]),
            SuperviseFixture.status(
                brake: .engaged, effectivelySupervising: false,
                projects: [SuperviseFixture.project(name: "acme", on: true)]),
            SuperviseFixture.status(
                brake: .released, effectivelySupervising: true,
                projects: [SuperviseFixture.project(name: "acme", on: true)]),
        ] {
            #expect(supervisionGestureWarningLines(status)
                == supervisionStatusWarningLines(status))
        }
    }

    /// A gesture that covers something is quiet — the warning is a finding, not
    /// a ceremony printed on every gesture.
    @Test func releasingTheBrakeOverASupervisedFleetIsQuiet() {
        let lines = supervisionGestureWarningLines(
            SuperviseFixture.status(
                brake: .released, effectivelySupervising: true,
                projects: [SuperviseFixture.project(name: "acme-checkout", on: true)]))
        #expect(lines.isEmpty)
    }

    /// The daemon's own line wins over the recomputed one — never both.
    @Test func theDaemonsEngagedBrakeWarningIsNotDuplicatedByTheRecomputation() {
        let lines = supervisionGestureWarningLines(
            SuperviseFixture.status(
                brake: .engaged, effectivelySupervising: false,
                projects: [SuperviseFixture.project(name: "acme", on: true)],
                warnings: [
                    SupervisionWarning(
                        code: .brakeEngagedWithProjectsOn,
                        message: "the brake is engaged; acme is marked on."),
                ]))
        #expect(lines == ["warning: the brake is engaged; acme is marked on."])
    }

    /// Two repos answering to one name resolve to nothing, so neither is
    /// covered — a coverage loss, stated as one.
    @Test func anAmbiguousRepoNameWarnsThatNeitherRepoIsSupervised() {
        let text = SuperviseFixture.render(
            SuperviseFixture.status(
                brake: .released, effectivelySupervising: true,
                projects: [SuperviseFixture.project(name: "acme", on: true)],
                warnings: [SupervisionWarning(code: .ambiguousRepoName, message: "")]))
        #expect(text.contains("share a display name"))
        #expect(text.contains("none is supervised"))
        #expect(text.contains("Rename one"))
    }

    @Test func aSupervisedFleetGetsNoWarning() {
        let text = SuperviseFixture.render(
            SuperviseFixture.status(
                brake: .released, effectivelySupervising: true,
                projects: [SuperviseFixture.project(name: "acme-checkout", on: true)]))
        #expect(!text.contains("warning"))
        #expect(!text.contains("nothing is being supervised"))
    }

    /// An engaged brake is a deliberately quiet fleet: the brake line already
    /// says so, and warning on top of it would cry wolf on every paused fleet.
    @Test func anEngagedBrakeWithNothingOnDoesNotWarn() {
        let text = SuperviseFixture.render(
            SuperviseFixture.status(
                brake: .engaged, effectivelySupervising: false,
                projects: [SuperviseFixture.project(name: "acme-checkout", on: false)]))
        #expect(text.contains("brake: engaged"))
        #expect(!text.contains("warning"))
    }
}

@Suite("tbd supervise status — rendered rows")
struct SupervisionStatusRowRenderingTests {
    @Test func bothBrakeBranchesRenderTheirOwnWord() {
        let released = SuperviseFixture.render(
            SuperviseFixture.status(
                brake: .released, effectivelySupervising: true,
                projects: [SuperviseFixture.project(name: "acme-checkout", on: true)]))
        let engaged = SuperviseFixture.render(
            SuperviseFixture.status(
                brake: .engaged, effectivelySupervising: false,
                projects: [SuperviseFixture.project(name: "acme-checkout", on: true)]))
        #expect(released.hasPrefix("brake: released\n"))
        #expect(engaged.hasPrefix("brake: engaged\n"))
        #expect(released != engaged)
    }

    @Test func anOnProjectRendersItsSpanAndAnOffProjectDoesNot() throws {
        let text = SuperviseFixture.render(
            SuperviseFixture.status(
                brake: .released, effectivelySupervising: true,
                projects: [
                    SuperviseFixture.project(
                        name: "acme-checkout", on: true, mode: "autonomous",
                        spanStartedAt: SuperviseFixture.now.addingTimeInterval(-6 * 60)),
                    SuperviseFixture.project(name: "tbd", on: false),
                ]))
        #expect(text.contains("on since 22:04"))
        #expect(text.contains("mode autonomous"))
        let rows = text.split(separator: "\n").map(String.init)
        let offRow = try #require(rows.first(where: { $0.hasPrefix("tbd") }))
        #expect(offRow.contains("off"))
        #expect(!offRow.contains("since"))
    }

    /// An untouched project and a turned-off one are the same state — there is
    /// no third tier, so the record's leftover span must not leak one into the
    /// rendering.
    @Test func untouchedAndTurnedOffRenderIdentically() {
        let untouched = SuperviseFixture.project(name: "acme", on: false)
        let turnedOff = SuperviseFixture.project(
            name: "acme", on: false,
            spanStartedAt: SuperviseFixture.now.addingTimeInterval(-3600))
        let a = SuperviseFixture.render(
            SuperviseFixture.status(
                brake: .engaged, effectivelySupervising: false, projects: [untouched]))
        let b = SuperviseFixture.render(
            SuperviseFixture.status(
                brake: .engaged, effectivelySupervising: false, projects: [turnedOff]))
        #expect(a == b)
    }

    @Test func markedOnAndMarkedOffRenderDifferently() {
        let on = SuperviseFixture.render(
            SuperviseFixture.status(
                brake: .released, effectivelySupervising: true,
                projects: [SuperviseFixture.project(name: "acme", on: true)]))
        let off = SuperviseFixture.render(
            SuperviseFixture.status(
                brake: .released, effectivelySupervising: false,
                projects: [SuperviseFixture.project(name: "acme", on: false)]))
        #expect(on.contains("acme  on"))
        #expect(off.contains("acme  off"))
        #expect(on != off)
    }

    /// This slice fills none of these honestly, and says so rather than
    /// printing a plausible-looking measurement.
    @Test func unfilledFactsRenderAsTheirHonestNotYetValues() {
        let text = SuperviseFixture.render(
            SuperviseFixture.status(
                brake: .released, effectivelySupervising: true,
                projects: [SuperviseFixture.project(name: "acme", on: true)]))
        #expect(text.contains("supervisor: hosted desk"))
        #expect(text.contains("last sweep contact: never"))
        #expect(text.contains("coverage unknown"))
    }

    @Test func declaredFactsReplaceTheNotYetValuesWhenPresent() {
        let text = SuperviseFixture.render(
            SuperviseFixture.status(
                brake: .released, effectivelySupervising: true,
                projects: [
                    SuperviseFixture.project(
                        name: "acme", on: true,
                        supervisor: .appointed(terminal: "t42"),
                        lastSweepContactAt: SuperviseFixture.now.addingTimeInterval(-120),
                        coverageWindow: "22:00-08:00"),
                ]))
        #expect(text.contains("supervisor: appointed (t42)"))
        #expect(text.contains("last sweep contact: 2m ago"))
        #expect(text.contains("coverage 22:00-08:00"))
        #expect(!text.contains("coverage unknown"))
    }

    @Test func rowsAlignOnTheWidestNameAndState() {
        let text = SuperviseFixture.render(
            SuperviseFixture.status(
                brake: .engaged, effectivelySupervising: false,
                projects: [
                    SuperviseFixture.project(name: "acme-checkout", on: false),
                    SuperviseFixture.project(name: "tbd", on: false),
                ]))
        let rows = text.split(separator: "\n").map(String.init).filter { $0.contains("mode ") }
        #expect(rows.count == 2)
        let offsets = rows.compactMap { row in
            row.range(of: "mode ").map { row.distance(from: row.startIndex, to: $0.lowerBound) }
        }
        #expect(offsets.count == 2)
        #expect(offsets[0] == offsets[1])
    }

    @Test func anEmptyFleetSaysItHasNoProjects() {
        let text = SuperviseFixture.render(
            SuperviseFixture.status(
                brake: .engaged, effectivelySupervising: false, projects: []))
        #expect(text.contains("(no projects)"))
    }

    @Test func agesRenderInTheLargestWholeUnit() {
        let now = SuperviseFixture.now
        #expect(supervisionAge(from: now.addingTimeInterval(-30), to: now) == "30s ago")
        #expect(supervisionAge(from: now.addingTimeInterval(-90), to: now) == "1m ago")
        #expect(supervisionAge(from: now.addingTimeInterval(-7200), to: now) == "2h ago")
        #expect(supervisionAge(from: now.addingTimeInterval(-3 * 86400), to: now) == "3d ago")
        // A clock that ran backwards reads as "now", never as a negative age.
        #expect(supervisionAge(from: now.addingTimeInterval(60), to: now) == "0s ago")
    }
}

@Suite("tbd supervise mode and mark rendering")
struct SupervisionModeRenderingTests {
    @Test func aModeOutsideTheDeclaredListIsRefusedWithTheChoicesListed() throws {
        let refusal = try #require(
            supervisionModeRefusal(
                project: "acme-checkout", requested: "turbo",
                declared: ["attended", "autonomous"]))
        #expect(refusal.contains("turbo"))
        #expect(refusal.contains("not declared"))
        #expect(refusal.contains("acme-checkout"))
        #expect(refusal.contains("choices: attended, autonomous"))
    }

    @Test func aDeclaredModeIsNotRefused() {
        #expect(
            supervisionModeRefusal(
                project: "acme", requested: "autonomous",
                declared: ["attended", "autonomous"]) == nil)
        #expect(
            supervisionModeRefusal(
                project: "acme", requested: "attended",
                declared: ["attended", "autonomous"]) == nil)
    }

    @Test func aProjectDeclaringNoModesRefusesEveryNameAndSaysSo() throws {
        let refusal = try #require(
            supervisionModeRefusal(project: "acme", requested: "attended", declared: []))
        #expect(refusal.contains("(none declared)"))
    }

    @Test func showFormPrintsTheActiveModeAndTheChoices() {
        let text = renderSupervisionMode(
            project: "acme", active: "attended", declared: ["attended", "autonomous"])
        #expect(text.contains("acme"))
        #expect(text.contains("is attended"))
        #expect(text.contains("choices: attended, autonomous"))
    }

    @Test func selectionResultDistinguishesAChangeFromANoOp() {
        let changed = renderSupervisionModeResult(
            SuperviseSetModeResult(
                project: "acme", mode: "autonomous",
                declaredModes: ["attended", "autonomous"], changed: true))
        let unchanged = renderSupervisionModeResult(
            SuperviseSetModeResult(
                project: "acme", mode: "autonomous",
                declaredModes: ["attended", "autonomous"], changed: false))
        #expect(changed.contains("is now autonomous"))
        #expect(unchanged.contains("was already autonomous"))
        #expect(changed != unchanged)
    }

    @Test func markResultRendersBothBranchesAndTheNoOp() {
        let on = renderSupervisionMarkResult(
            SuperviseSetProjectMarkResult(project: "acme", on: true, changed: true))
        let off = renderSupervisionMarkResult(
            SuperviseSetProjectMarkResult(project: "acme", on: false, changed: true))
        let alreadyOn = renderSupervisionMarkResult(
            SuperviseSetProjectMarkResult(project: "acme", on: true, changed: false))
        #expect(on == "on: acme")
        #expect(off == "off: acme")
        #expect(alreadyOn == "on: acme (already on)")
    }

    @Test func brakeRendersBothBranches() {
        #expect(renderSupervisionBrake(.released) == "brake: released")
        #expect(renderSupervisionBrake(.engaged) == "brake: engaged")
    }
}

@Suite("tbd supervise project list rendering")
struct SupervisionProjectListRenderingTests {
    @Test func emptyTopologySaysSo() {
        #expect(renderSupervisionProjectList(SuperviseProjectListResult(projects: [])) == "(no projects)")
    }

    @Test func rowsCarryReposPolicyAndSweep() {
        let web = SupervisionProjectRepoRef(id: UUID(), name: "acme-web")
        let api = SupervisionProjectRepoRef(id: UUID(), name: "acme-api")
        let text = renderSupervisionProjectList(
            SuperviseProjectListResult(projects: [
                SupervisionProjectTopologyEntry(
                    name: "acme-platform", repos: [web, api],
                    policy: .repo(web.id), sweepScript: nil),
                SupervisionProjectTopologyEntry(
                    name: "tbd", repos: [SupervisionProjectRepoRef(id: UUID(), name: "tbd")],
                    policy: .operator, sweepScript: "/tmp/sweep.py"),
            ]))
        #expect(text.contains("acme-web, acme-api"))
        // The policy repo is shown by the name a human typed, not its UUID.
        #expect(text.contains("policy: repo:acme-web"))
        #expect(!text.contains(web.id.uuidString))
        #expect(text.contains("policy: operator"))
        #expect(text.contains("sweep: shipped"))
        #expect(text.contains("sweep: /tmp/sweep.py"))
    }
}
