import Testing
import Foundation
@testable import TBDShared

/// A deterministic generator, so a failing case is reproducible from the seed
/// rather than being a coin flip in CI.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func generatedRepos(count: Int, using generator: inout SplitMix64) -> [SupervisionRepo] {
    let words = ["acme", "checkout", "hooks", "platform", "ledger", "atlas", "harbor", "meadow"]
    return (0..<count).map { index in
        let name = "\(words[Int(generator.next() % UInt64(words.count))])-\(index)"
        return SupervisionRepo(id: UUID(), name: name)
    }
}

@Suite struct SupervisionCollapseTests {
    /// The singleton collapse is a property, not a branch: for any repo set, an
    /// absent `supervision.json` and a file declaring one single-repo project
    /// per repo resolve to *equal* values — same names, same repos, same policy
    /// source, same marks, same modes, same supervisor arrangement.
    ///
    /// Any field that could tell the two apart would let a consumer behave
    /// differently between them, which design §5 calls a bug.
    @Test(arguments: [1, 2, 3, 5, 8, 13])
    func nothingDeclaredResolvesLikeOneProjectPerRepo(count: Int) throws {
        var generator = SplitMix64(state: UInt64(count) &* 0x1234_5678)
        for _ in 0..<8 {
            let repos = generatedRepos(count: count, using: &generator)
            guard Set(repos.map(\.name)).count == repos.count else { continue }

            let declaredPerRepo = SupervisionFile(
                projects: Dictionary(uniqueKeysWithValues: repos.map { repo in
                    (repo.name, SupervisionProjectDeclaration(
                        repos: [repo.id], policy: .repo(repo.id)))
                }))

            let implicit = try SupervisionTopology.resolve(file: SupervisionFile(), repos: repos)
            let declared = try SupervisionTopology.resolve(file: declaredPerRepo, repos: repos)
            #expect(implicit == declared)
            #expect(implicit.count == repos.count)
        }
    }

    /// The same property with marks and modes in play — the state an operator
    /// actually accumulates.
    @Test(arguments: [1, 4, 7])
    func collapseHoldsWithMarksAndModes(count: Int) throws {
        var generator = SplitMix64(state: UInt64(count) &* 0x9999)
        let repos = generatedRepos(count: count, using: &generator)
        guard Set(repos.map(\.name)).count == repos.count else { return }
        let marked = repos.first!.name

        let implicitFile = SupervisionFile(
            supervised: [marked], modes: [marked: .bare("autonomous")])
        var declaredFile = implicitFile
        declaredFile.projects = Dictionary(uniqueKeysWithValues: repos.map { repo in
            (repo.name, SupervisionProjectDeclaration(repos: [repo.id], policy: .repo(repo.id)))
        })

        let implicit = try SupervisionTopology.resolve(file: implicitFile, repos: repos)
        let declared = try SupervisionTopology.resolve(file: declaredFile, repos: repos)
        #expect(implicit == declared)
        #expect(implicit.first { $0.name == marked }?.mark == true)
        #expect(implicit.first { $0.name == marked }?.activeMode == "autonomous")
    }
}

@Suite struct SupervisionResolutionTests {
    private let repoA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
    private let repoB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!
    private let repoC = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000000")!

    private var repos: [SupervisionRepo] {
        [SupervisionRepo(id: repoA, name: "acme-web"),
         SupervisionRepo(id: repoB, name: "acme-api"),
         SupervisionRepo(id: repoC, name: "tbd")]
    }

    @Test func declaredMembersJoinTheirProjectAndTheRestAreTheirOwn() throws {
        let file = SupervisionFile(projects: [
            "acme-checkout": .init(repos: [repoA, repoB], policy: .repo(repoA)),
        ])
        let projects = try SupervisionTopology.resolve(file: file, repos: repos)
        #expect(projects.map(\.name) == ["acme-checkout", "tbd"])
        #expect(projects[0].repos == [repoA, repoB])
        #expect(projects[1].repos == [repoC])
        #expect(projects[1].policy == .repo(repoC))
        #expect(projects[1].supervisor == .hostedDesk)
    }

    @Test func everyRepoLandsInExactlyOneProject() throws {
        let file = SupervisionFile(projects: [
            "acme-checkout": .init(repos: [repoA, repoB], policy: .repo(repoA)),
        ])
        let projects = try SupervisionTopology.resolve(file: file, repos: repos)
        let memberships = projects.flatMap(\.repos)
        #expect(memberships.sorted { $0.uuidString < $1.uuidString }
            == [repoA, repoB, repoC].sorted { $0.uuidString < $1.uuidString })
        #expect(Set(memberships).count == memberships.count)
    }

    @Test func anAppointedSupervisorShowsAsTheArrangement() throws {
        let file = SupervisionFile(supervisors: ["tbd": .init(terminal: "t42")])
        let projects = try SupervisionTopology.resolve(file: file, repos: repos)
        #expect(projects.first { $0.name == "tbd" }?.supervisor == .appointed(terminal: "t42"))
    }

    @Test func aProjectNameCollidingWithANonMemberRepoIsReported() {
        let file = SupervisionFile(projects: [
            "tbd": .init(repos: [repoA], policy: .repo(repoA)),
        ])
        let thrown = #expect(throws: SupervisionTopologyError.self) {
            try SupervisionTopology.resolve(file: file, repos: repos)
        }
        #expect(thrown == SupervisionTopologyError.projectNameCollidesWithRepo(
            project: "tbd", repo: repoC, repoName: "tbd"))
        #expect(thrown?.description.contains("tbd") == true)
    }

    @Test func aProjectMayShareItsNameWithOneOfItsOwnMembers() throws {
        let file = SupervisionFile(projects: [
            "tbd": .init(repos: [repoC, repoA], policy: .repo(repoC)),
        ])
        let projects = try SupervisionTopology.resolve(file: file, repos: repos)
        #expect(projects.map(\.name) == ["acme-api", "tbd"])
    }

    @Test func twoReposWithOneNameAreReportedRatherThanCollapsed() {
        let twins = [SupervisionRepo(id: repoA, name: "acme-web"),
                     SupervisionRepo(id: repoB, name: "acme-web")]
        let thrown = #expect(throws: SupervisionTopologyError.self) {
            try SupervisionTopology.resolve(file: SupervisionFile(), repos: twins)
        }
        #expect(thrown?.description.contains("acme-web") == true)
    }

    @Test func aRejectedFileServesNoPartialResolution() {
        let file = SupervisionFile(projects: [
            "acme-checkout": .init(repos: [repoA], policy: .repo(repoA)),
            "acme-hooks": .init(repos: [repoA], policy: .repo(repoA)),
        ])
        #expect(throws: SupervisionFileError.self) {
            try SupervisionTopology.resolve(file: file, repos: repos)
        }
    }
}

@Suite struct SupervisionMoveTests {
    private let repoA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
    private let repoB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!
    private let repoC = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000000")!
    private let unknownRepo = UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000000")!

    private var repos: [SupervisionRepo] {
        [SupervisionRepo(id: repoA, name: "acme-web"),
         SupervisionRepo(id: repoB, name: "acme-api"),
         SupervisionRepo(id: repoC, name: "tbd")]
    }

    private var grouped: SupervisionFile {
        SupervisionFile(projects: [
            "acme-checkout": .init(repos: [repoA, repoB], policy: .repo(repoA)),
        ])
    }

    /// The invariant every move must preserve, checked through resolution
    /// rather than through the file's internals.
    private func expectExactlyOneProjectPerRepo(
        _ file: SupervisionFile, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let projects = try SupervisionTopology.resolve(file: file, repos: repos)
        let memberships = projects.flatMap(\.repos)
        #expect(memberships.count == repos.count, sourceLocation: sourceLocation)
        #expect(Set(memberships) == Set(repos.map(\.id)), sourceLocation: sourceLocation)
    }

    @Test func movingIntoAProjectAddsExactlyOneMembership() throws {
        let moved = try SupervisionTopology.move(
            repo: repoC, to: .project("acme-checkout"), in: grouped, repos: repos)
        #expect(moved.projects["acme-checkout"]?.repos == [repoA, repoB, repoC])
        try expectExactlyOneProjectPerRepo(moved)
    }

    @Test func movingToSingletonLeavesTheRepoItsOwnProject() throws {
        let moved = try SupervisionTopology.move(
            repo: repoB, to: .singleton, in: grouped, repos: repos)
        #expect(moved.projects["acme-checkout"]?.repos == [repoA])
        let projects = try SupervisionTopology.resolve(file: moved, repos: repos)
        #expect(projects.first { $0.name == "acme-api" }?.repos == [repoB])
        try expectExactlyOneProjectPerRepo(moved)
    }

    @Test func emptyingAProjectDeletesItAndItsSelections() throws {
        let file = SupervisionFile(
            projects: ["acme-checkout": .init(repos: [repoA], policy: .repo(repoA))],
            supervised: ["acme-checkout"],
            modes: ["acme-checkout": .bare("autonomous")],
            supervisors: ["acme-checkout": .init(terminal: "t42")])
        let moved = try SupervisionTopology.move(
            repo: repoA, to: .singleton, in: file, repos: repos)
        #expect(moved.projects.isEmpty)
        // A mark left behind would turn a later project of the same name on
        // without an operator gesture.
        #expect(moved.supervised.isEmpty)
        #expect(moved.modes.isEmpty)
        #expect(moved.supervisors.isEmpty)
        try expectExactlyOneProjectPerRepo(moved)
    }

    @Test func aMoveThatChangesNothingReturnsAnEqualValue() throws {
        let alreadyThere = try SupervisionTopology.move(
            repo: repoA, to: .project("acme-checkout"), in: grouped, repos: repos)
        #expect(alreadyThere == grouped)
        let alreadySingleton = try SupervisionTopology.move(
            repo: repoC, to: .singleton, in: grouped, repos: repos)
        #expect(alreadySingleton == grouped)
    }

    @Test func anUnknownRepoIsRefusedAndTheFileIsUntouched() throws {
        let before = grouped
        #expect(throws: SupervisionTopologyError.unknownRepo(repo: unknownRepo)) {
            try SupervisionTopology.move(
                repo: unknownRepo, to: .project("acme-checkout"), in: before, repos: repos)
        }
        #expect(before == grouped)
        try expectExactlyOneProjectPerRepo(before)
    }

    @Test func anUnknownTargetProjectIsRefusedAndTheFileIsUntouched() throws {
        let before = grouped
        #expect(throws: SupervisionTopologyError.unknownProject(project: "acme-platform")) {
            try SupervisionTopology.move(
                repo: repoC, to: .project("acme-platform"), in: before, repos: repos)
        }
        #expect(before == grouped)
        try expectExactlyOneProjectPerRepo(before)
    }

    @Test func movingOutTheSurvivingProjectsPolicySourceIsRefused() throws {
        let before = grouped
        #expect(throws: SupervisionTopologyError.policySourceWouldLeaveProject(
            project: "acme-checkout", repo: repoA)) {
            try SupervisionTopology.move(repo: repoA, to: .singleton, in: before, repos: repos)
        }
        #expect(before == grouped)
        try expectExactlyOneProjectPerRepo(before)
    }

    @Test func aRejectedFileIsRefusedBeforeAnyMove() throws {
        let broken = SupervisionFile(projects: [
            "acme-checkout": .init(repos: [repoA], policy: .repo(repoA)),
            "acme-hooks": .init(repos: [repoA], policy: .repo(repoA)),
        ])
        let before = broken
        #expect(throws: SupervisionFileError.self) {
            try SupervisionTopology.move(repo: repoA, to: .singleton, in: before, repos: repos)
        }
        #expect(before == broken)
    }

    @Test func theSingletonSentinelIsTheDocumentedWord() {
        #expect(SupervisionMoveTarget(argument: "singleton") == .singleton)
        #expect(SupervisionMoveTarget(argument: "acme-checkout") == .project("acme-checkout"))
        #expect(SupervisionMoveTarget.singleton.argument == "singleton")
        #expect(SuperviseProjectMoveParams.singletonTarget == "singleton")
    }
}
