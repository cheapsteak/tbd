import Testing
import Foundation
@testable import TBDShared

// Path helpers are exercised through the `environment:` injection seam, and
// every file test uses an explicit temporary directory. This target does not
// link TestSupport and may not call `setenv("TBD_HOME", …)` — that is permitted
// only in suites nested under `TBDHomeSerialized` in `Tests/TBDDaemonTests`.

@Suite struct SupervisionPathTests {
    private let env = ["TBD_HOME": "/tmp/tbd-supervision-paths"]

    @Test func supervisionDirHangsOffConfigDir() {
        #expect(TBDConstants.supervisionDir(environment: env).path
            == "/tmp/tbd-supervision-paths/supervision")
    }

    @Test func fileLedgerAndStatusSitInTheSupervisionDir() {
        #expect(TBDConstants.supervisionFilePath(environment: env)
            == "/tmp/tbd-supervision-paths/supervision/supervision.json")
        #expect(TBDConstants.supervisionLedgerPath(environment: env)
            == "/tmp/tbd-supervision-paths/supervision/ledger.jsonl")
        #expect(TBDConstants.supervisionStatusPath(environment: env)
            == "/tmp/tbd-supervision-paths/supervision/status.json")
    }

    @Test func projectDirIsNamedByTheProject() {
        #expect(TBDConstants.supervisionProjectDir(project: "acme-checkout", environment: env).path
            == "/tmp/tbd-supervision-paths/supervision/projects/acme-checkout")
    }

    @Test func pathsFallBackToHomeTbdWithoutTBDHome() {
        let path = TBDConstants.supervisionFilePath(environment: [:])
        #expect(path.hasSuffix("/tbd/supervision/supervision.json"))
        #expect(path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    }
}

// MARK: - The on-disk shape

@Suite struct SupervisionFileCodingTests {
    /// The design spec §8 file, verbatim.
    static let specFixture = """
        {
          "version": 1,
          "projects": {
            "acme-checkout": {
              "repos": ["11111111-1111-1111-1111-111111111111",
                        "22222222-2222-2222-2222-222222222222"],
              "policy": { "repo": "11111111-1111-1111-1111-111111111111" },
              "sweep": { "script": "~/tbd/supervision/projects/acme-checkout/sweep.py" }
            }
          },
          "supervised": ["acme-checkout"],
          "modes": {
            "acme-checkout": "autonomous",
            "acme-hooks": { "selected": "friday-freeze",
                            "declared": ["attended", "autonomous", "friday-freeze"] }
          },
          "supervisors": { "acme-checkout": { "terminal": "t42" } }
        }
        """

    private func decodeFixture() throws -> SupervisionFile {
        try JSONDecoder().decode(SupervisionFile.self, from: Data(Self.specFixture.utf8))
    }

    @Test func decodesTheSpecShape() throws {
        let file = try decodeFixture()
        try file.validate()
        #expect(file.version == 1)
        #expect(file.projects["acme-checkout"]?.repos.count == 2)
        #expect(file.projects["acme-checkout"]?.policy
            == .repo(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!))
        #expect(file.projects["acme-checkout"]?.sweep?.script
            == "~/tbd/supervision/projects/acme-checkout/sweep.py")
        #expect(file.supervised == ["acme-checkout"])
        #expect(file.supervisors["acme-checkout"]?.terminal == "t42")
    }

    @Test func roundTripKeepsSweepSupervisorsAndModeShapes() throws {
        let file = try decodeFixture()
        let encoded = try JSONEncoder().encode(file)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let projects = object?["projects"] as? [String: Any]
        let checkout = projects?["acme-checkout"] as? [String: Any]
        #expect((checkout?["sweep"] as? [String: Any])?["script"] as? String
            == "~/tbd/supervision/projects/acme-checkout/sweep.py")
        #expect((object?["supervisors"] as? [String: Any])?["acme-checkout"] != nil)

        let modes = object?["modes"] as? [String: Any]
        // A bare selection stays bare; an object entry stays an object.
        #expect(modes?["acme-checkout"] as? String == "autonomous")
        #expect((modes?["acme-hooks"] as? [String: Any])?["selected"] as? String == "friday-freeze")

        let reloaded = try JSONDecoder().decode(SupervisionFile.self, from: encoded)
        #expect(reloaded == file)
    }

    @Test func unknownSweepKeysSurviveARewrite() throws {
        let json = """
            {"version": 1,
             "projects": {"acme-checkout": {"repos": ["11111111-1111-1111-1111-111111111111"],
                                            "policy": {"operator": true},
                                            "sweep": {"schedule": "external",
                                                      "contactWindowMinutes": 15,
                                                      "somethingLaterVersionsAdd": [1, 2]}}}}
            """
        let file = try JSONDecoder().decode(SupervisionFile.self, from: Data(json.utf8))
        let encoded = try JSONEncoder().encode(file)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let sweep = ((object?["projects"] as? [String: Any])?["acme-checkout"]
            as? [String: Any])?["sweep"] as? [String: Any]
        #expect(sweep?["schedule"] as? String == "external")
        #expect(sweep?["contactWindowMinutes"] as? Int == 15)
        #expect((sweep?["somethingLaterVersionsAdd"] as? [Int]) == [1, 2])
    }

    @Test func emptyFileEncodesWithoutEmptyScaffolding() throws {
        let encoded = try JSONEncoder().encode(SupervisionFile())
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(object?.keys.sorted() == ["version"])
    }

    @Test func operatorPolicyRoundTrips() throws {
        let source = SupervisionPolicySource.operator
        let encoded = try JSONEncoder().encode(source)
        #expect(String(bytes: encoded, encoding: .utf8) == "{\"operator\":true}")
        #expect(try JSONDecoder().decode(SupervisionPolicySource.self, from: encoded) == source)
    }

    @Test func operatorFalseIsNotAPolicySource() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                SupervisionPolicySource.self, from: Data("{\"operator\":false}".utf8))
        }
    }
}

// MARK: - Modes

@Suite struct SupervisionModeEntryTests {
    @Test func bareStringDecodesAsASelectionAgainstTheBuiltInList() throws {
        let entry = try JSONDecoder().decode(
            SupervisionModeEntry.self, from: Data("\"autonomous\"".utf8))
        #expect(entry.activeMode == "autonomous")
        #expect(entry.declaredModes == ["attended", "autonomous"])
        #expect(entry.wireShape == .bareSelection)
    }

    @Test func bareEntryReEncodesBare() throws {
        let entry = try JSONDecoder().decode(
            SupervisionModeEntry.self, from: Data("\"autonomous\"".utf8))
        let encoded = try JSONEncoder().encode(entry)
        #expect(String(bytes: encoded, encoding: .utf8) == "\"autonomous\"")
    }

    @Test func objectEntryReEncodesAsAnObject() throws {
        let json = "{\"selected\":\"friday-freeze\",\"declared\":[\"attended\",\"friday-freeze\"]}"
        let entry = try JSONDecoder().decode(SupervisionModeEntry.self, from: Data(json.utf8))
        #expect(entry.wireShape == .object)
        #expect(entry.activeMode == "friday-freeze")
        #expect(entry.declaredModes == ["attended", "friday-freeze"])
        let reencoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(entry)) as? [String: Any]
        #expect(reencoded?["selected"] as? String == "friday-freeze")
        #expect(reencoded?["declared"] as? [String] == ["attended", "friday-freeze"])
    }

    @Test func absentDeclaredListFallsBackToTheBuiltInPair() throws {
        let entry = try JSONDecoder().decode(
            SupervisionModeEntry.self, from: Data("{\"selected\":\"autonomous\"}".utf8))
        #expect(entry.declaredModes == ["attended", "autonomous"])
        #expect(entry.activeMode == "autonomous")
    }

    @Test func absentSelectionFallsBackToAttended() throws {
        let entry = try JSONDecoder().decode(
            SupervisionModeEntry.self,
            from: Data("{\"declared\":[\"attended\",\"autonomous\",\"friday-freeze\"]}".utf8))
        #expect(entry.activeMode == "attended")
    }

    @Test func absentEntryEntirelyIsAttendedAgainstTheBuiltInPair() {
        let file = SupervisionFile()
        #expect(file.activeMode(for: "acme-checkout") == "attended")
        #expect(file.declaredModes(for: "acme-checkout") == ["attended", "autonomous"])
    }

    @Test func selectingKeepsTheWireShape() throws {
        let bare = SupervisionModeEntry.bare("attended").selecting("autonomous")
        #expect(try String(bytes: JSONEncoder().encode(bare), encoding: .utf8) == "\"autonomous\"")

        let object = SupervisionModeEntry
            .declaring(declared: ["attended", "autonomous"], selected: "attended")
            .selecting("autonomous")
        let encoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(object)) as? [String: Any]
        #expect(encoded?["selected"] as? String == "autonomous")
        #expect(encoded?["declared"] as? [String] == ["attended", "autonomous"])
    }

    @Test func settingAModeOnAProjectWithNoEntryWritesABareOne() throws {
        let file = SupervisionFile().settingMode("acme-checkout", to: "autonomous")
        #expect(file.modes["acme-checkout"]?.wireShape == .bareSelection)
        #expect(file.activeMode(for: "acme-checkout") == "autonomous")
    }
}

// MARK: - What the loader refuses

@Suite struct SupervisionFileValidationTests {
    private let repoA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
    private let repoB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!

    @Test func aRepoInTwoProjectsIsRejectedAndTheErrorNamesIt() {
        let file = SupervisionFile(projects: [
            "acme-checkout": .init(repos: [repoA, repoB], policy: .operator),
            "acme-hooks": .init(repos: [repoA], policy: .operator),
        ])
        let thrown = #expect(throws: SupervisionFileError.self) { try file.validate() }
        #expect(thrown == SupervisionFileError.repoInTwoProjects(
            repo: repoA, first: "acme-checkout", second: "acme-hooks"))
        let message = thrown?.description ?? ""
        #expect(message.contains(repoA.uuidString))
        #expect(message.contains("acme-checkout"))
        #expect(message.contains("acme-hooks"))
    }

    @Test func aRepoListedTwiceInOneProjectIsRejected() {
        let file = SupervisionFile(projects: [
            "acme-checkout": .init(repos: [repoA, repoA], policy: .operator),
        ])
        #expect(throws: SupervisionFileError.repoListedTwice(repo: repoA, project: "acme-checkout")) {
            try file.validate()
        }
    }

    @Test func aPolicyRepoOutsideTheProjectIsRejected() {
        let file = SupervisionFile(projects: [
            "acme-checkout": .init(repos: [repoA], policy: .repo(repoB)),
        ])
        #expect(throws: SupervisionFileError.policyRepoNotAMember(
            project: "acme-checkout", repo: repoB)) {
            try file.validate()
        }
    }

    @Test func anUnsupportedVersionIsRejected() {
        let file = SupervisionFile(version: 2)
        #expect(throws: SupervisionFileError.unsupportedVersion(found: 2, supported: 1)) {
            try file.validate()
        }
    }

    @Test func aProjectWithNoReposIsRejected() {
        let file = SupervisionFile(projects: ["acme-checkout": .init(repos: [], policy: .operator)])
        #expect(throws: SupervisionFileError.projectHasNoRepos(project: "acme-checkout")) {
            try file.validate()
        }
    }

    @Test(arguments: ["", ".", "..", "acme/checkout", " acme"])
    func anUnusableProjectNameIsRejected(_ name: String) {
        let file = SupervisionFile(projects: [name: .init(repos: [repoA], policy: .operator)])
        #expect(throws: SupervisionFileError.invalidProjectName(project: name)) {
            try file.validate()
        }
    }

    @Test func aSelectionOutsideTheDeclaredListIsRejected() {
        let file = SupervisionFile(modes: [
            "acme-hooks": .declaring(declared: ["attended", "autonomous"], selected: "friday-freeze"),
        ])
        #expect(throws: SupervisionFileError.selectedModeNotDeclared(
            project: "acme-hooks", selected: "friday-freeze",
            declared: ["attended", "autonomous"])) {
            try file.validate()
        }
    }

    @Test func aDeclaredListWithoutTheDefaultSelectionIsRejected() {
        // No selection means "attended", so a list that omits it leaves the
        // project with a selection it cannot make.
        let file = SupervisionFile(modes: ["acme-hooks": .declaring(declared: ["friday-freeze"])])
        #expect(throws: SupervisionFileError.selectedModeNotDeclared(
            project: "acme-hooks", selected: "attended", declared: ["friday-freeze"])) {
            try file.validate()
        }
    }

    @Test func markingIsMembershipWithNoThirdState() {
        let untouched = SupervisionFile()
        let turnedOff = SupervisionFile().settingMark("acme-checkout", on: true)
            .settingMark("acme-checkout", on: false)
        #expect(untouched == turnedOff)
        #expect(!untouched.isMarked("acme-checkout"))
        #expect(!turnedOff.isMarked("acme-checkout"))
    }

    @Test func aMarkThatAlreadyStandsChangesNothing() {
        let on = SupervisionFile().settingMark("acme-checkout", on: true)
        #expect(on.settingMark("acme-checkout", on: true) == on)
        #expect(on.supervised == ["acme-checkout"])
    }
}

// MARK: - The fleet brake's shared model field

@Suite struct SupervisionConfigFlagTests {
    @Test func shippedDefaultIsOff() {
        #expect(Config.supervisionEnabledDefault == false)
        #expect(Config().supervisionEnabled == Config.supervisionEnabledDefault)
    }

    @Test func absentKeyFollowsTheShippedDefault() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        // Asserted against the constant, not against `false`: an absent key is
        // the NULL column's situation and must follow the default wherever it
        // goes.
        #expect(config.supervisionEnabled == Config.supervisionEnabledDefault)
    }

    @Test func anExplicitChoiceIsHonored() throws {
        let released = try JSONDecoder().decode(
            Config.self, from: Data("{\"supervisionEnabled\":true}".utf8))
        #expect(released.supervisionEnabled)
        let engaged = try JSONDecoder().decode(
            Config.self, from: Data("{\"supervisionEnabled\":false}".utf8))
        #expect(!engaged.supervisionEnabled)
    }
}
