import Foundation
import Testing

@testable import TBDShared

/// `BuildIdentityLoader` decides which of three sources describes a running
/// binary, and `UpdateRelation` decides what to do about the answer. Both are
/// pure given injected readers, which is the whole reason they are separate
/// from the daemon that consumes them.
@Suite("BuildIdentity")
struct BuildIdentityTests {

    private static let stampJSON = """
        {"commit":"0123456789abcdef0123456789abcdef01234567",
         "shortCommit":"0123456",
         "branch":"main",
         "builtAt":"2026-09-04T17:00:00Z",
         "sourceWorktree":"/Users/me/tbd/worktrees/tbd/feature",
         "dirty":false}
        """

    /// A reader over a fixed path→bytes map. Fake paths only; nothing here
    /// touches a filesystem.
    private static func reader(_ files: [String: String]) -> (String) -> Data? {
        { path in files[path].map { Data($0.utf8) } }
    }

    // MARK: - Source 1: the sidecar beside the binary

    @Test func sidecarBesideTheBinaryWins() {
        var gitWasAsked = false
        let identity = BuildIdentityLoader.load(
            executablePath: "/Users/me/tbd/worktrees/tbd/feature/.build/debug/TBDDaemon",
            fileReader: Self.reader([
                "/Users/me/tbd/worktrees/tbd/feature/.build/debug/TBDBuildIdentity.json":
                    Self.stampJSON
            ]),
            gitHead: { _ in
                gitWasAsked = true
                return nil
            })
        #expect(gitWasAsked == false, "git must not run when a stamp exists")
        #expect(identity?.commit == "0123456789abcdef0123456789abcdef01234567")
        #expect(identity?.shortCommit == "0123456")
        #expect(identity?.branch == "main")
        #expect(identity?.sourceWorktree == "/Users/me/tbd/worktrees/tbd/feature")
        #expect(identity?.origin == .stamp)
        #expect(identity?.dirty == false)
    }

    // MARK: - Source 2: the sidecar inside the bundle

    /// The app executable lives at `Contents/MacOS/TBDApp`, whose sibling
    /// directory is not the build directory — so the bundle copy is the only
    /// stamp an installed app can find.
    @Test func bundleSidecarIsFoundWhenNoSiblingExists() {
        let identity = BuildIdentityLoader.load(
            executablePath: "/Applications/TBD.app/Contents/MacOS/TBDApp",
            bundleContentsPath: "/Applications/TBD.app/Contents",
            fileReader: Self.reader([
                "/Applications/TBD.app/Contents/TBDBuildIdentity.json": Self.stampJSON
            ]),
            gitHead: { _ in nil })
        #expect(identity?.shortCommit == "0123456")
        #expect(identity?.origin == .stamp)
    }

    /// When both exist, the one written for this exact binary wins. An in-place
    /// `.build/debug/TBD.app` has both, and they can disagree after a rebuild.
    @Test func siblingStampOutranksTheBundleStamp() {
        let bundleJSON = Self.stampJSON.replacingOccurrences(
            of: "0123456", with: "9999999")
        let identity = BuildIdentityLoader.load(
            executablePath: "/w/.build/debug/TBD.app/Contents/MacOS/TBDApp",
            bundleContentsPath: "/w/.build/debug/TBD.app/Contents",
            fileReader: Self.reader([
                "/w/.build/debug/TBD.app/Contents/MacOS/TBDBuildIdentity.json": Self.stampJSON,
                "/w/.build/debug/TBD.app/Contents/TBDBuildIdentity.json": bundleJSON,
            ]),
            gitHead: { _ in nil })
        #expect(identity?.shortCommit == "0123456")
    }

    // MARK: - Source 3: the worktree's HEAD

    @Test func fallsBackToWorktreeHeadAndSaysSo() {
        var asked: [String] = []
        let identity = BuildIdentityLoader.load(
            executablePath: "/Users/me/tbd/worktrees/tbd/feature/.build/debug/TBDDaemon",
            fileReader: Self.reader([:]),
            gitHead: { path in
                asked.append(path)
                return .init(commit: "abcdef0123456789abcdef0123456789abcdef01", branch: "feature")
            })
        #expect(asked == ["/Users/me/tbd/worktrees/tbd/feature"])
        #expect(identity?.origin == .worktreeHead)
        #expect(identity?.shortCommit == "abcdef0")
        #expect(identity?.branch == "feature")
        #expect(identity?.sourceWorktree == "/Users/me/tbd/worktrees/tbd/feature")
    }

    // MARK: - Neither

    /// The installed CLI: a hard link in `~/.local/bin` with no sidecar beside
    /// it and no `.build` in its path. Nothing can say, and nothing is guessed.
    @Test func nilWhenNothingCanSay() {
        var gitWasAsked = false
        let identity = BuildIdentityLoader.load(
            executablePath: "/Users/me/.local/bin/tbd",
            fileReader: Self.reader([:]),
            gitHead: { _ in
                gitWasAsked = true
                return nil
            })
        #expect(identity == nil)
        #expect(gitWasAsked == false, "no .build in the path, so there is no worktree to ask about")
    }

    @Test func nilWhenTheExecutablePathIsUnknown() {
        let identity = BuildIdentityLoader.load(
            executablePath: nil, fileReader: Self.reader([:]), gitHead: { _ in nil })
        #expect(identity == nil)
    }

    /// A sidecar that is present but not JSON must not be treated as an
    /// identity — the fallback is what should answer.
    @Test func unparseableSidecarFallsThroughRatherThanReturningGarbage() {
        let identity = BuildIdentityLoader.load(
            executablePath: "/w/.build/debug/TBDDaemon",
            fileReader: Self.reader(["/w/.build/debug/TBDBuildIdentity.json": "not json"]),
            gitHead: { _ in .init(commit: "1111111222222233333334444444555555566666", branch: "main") })
        #expect(identity?.origin == .worktreeHead)
    }

    // MARK: - Sidecar decoding

    /// Unknown keys are ignored, so a newer build wrapper's stamp still reads.
    @Test func unknownKeysAreIgnored() throws {
        let json = """
            {"commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","shortCommit":"aaaaaaa",
             "branch":"main","somethingNewInTwoYears":{"nested":true}}
            """
        let identity = try JSONDecoder().decode(BuildIdentity.self, from: Data(json.utf8))
        #expect(identity.shortCommit == "aaaaaaa")
    }

    /// Only `commit` is required; a stamp naming just that abbreviates itself.
    @Test func minimalSidecarAbbreviatesTheFullSHA() throws {
        let json = #"{"commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}"#
        let identity = try JSONDecoder().decode(BuildIdentity.self, from: Data(json.utf8))
        #expect(identity.shortCommit == "bbbbbbb")
        #expect(identity.branch == "HEAD")
        #expect(identity.dirty == false)
        #expect(identity.origin == .stamp)
    }

    @Test func dirtyBuildsSaySoInTheDisplayForm() {
        let clean = BuildIdentity(commit: "c", shortCommit: "c123456", branch: "main")
        let dirty = BuildIdentity(
            commit: "c", shortCommit: "c123456", branch: "main", dirty: true)
        #expect(clean.displayCommit == "c123456")
        #expect(dirty.displayCommit == "c123456-dirty")
    }

    // MARK: - sourceWorktree derivation

    @Test func sourceWorktreeIsEverythingBeforeTheLastDotBuild() {
        #expect(BuildIdentityLoader.sourceWorktree(
            fromExecutablePath: "/a/b/.build/debug/TBDDaemon") == "/a/b")
        // A worktree whose own name contains `.build` must not truncate early.
        #expect(BuildIdentityLoader.sourceWorktree(
            fromExecutablePath: "/a/.build/x/.build/release/tbd") == "/a/.build/x")
        #expect(BuildIdentityLoader.sourceWorktree(
            fromExecutablePath: "/Applications/TBD.app/Contents/MacOS/TBDApp") == nil)
        #expect(BuildIdentityLoader.sourceWorktree(fromExecutablePath: nil) == nil)
    }
}

/// The relation table and the status it is carried in.
@Suite("UpdateRelation")
struct UpdateRelationTests {

    private static let ours = "1111111111111111111111111111111111111111"
    private static let latest = "2222222222222222222222222222222222222222"

    @Test func equalCommitsAreUpToDate() {
        #expect(UpdateRelation.compute(
            ours: Self.ours, latest: Self.ours, ancestry: .contains) == .upToDate)
    }

    @Test func containedByLatestMeansBehind() {
        #expect(UpdateRelation.compute(
            ours: Self.ours, latest: Self.latest, ancestry: .contains) == .behind)
    }

    /// A build with commits `main` does not have — a feature branch, or one
    /// ahead of the remote. There is nothing to install.
    @Test func notContainedByLatestMeansNothingToInstall() {
        #expect(UpdateRelation.compute(
            ours: Self.ours, latest: Self.latest, ancestry: .doesNotContain) == .upToDate)
    }

    /// The commit is not in the local object store, so ancestry is undecidable.
    /// A commit never seen is a commit not held.
    @Test func aLatestCommitWeHaveNeverSeenMeansBehind() {
        #expect(UpdateRelation.compute(
            ours: Self.ours, latest: Self.latest, ancestry: .latestAbsentLocally) == .behind)
    }

    /// The other undecided answer, and the reason the two are not one case: a
    /// repository that could not answer is evidence in no direction, and
    /// `unknown` is the only relation `auto` never acts on.
    @Test func aRepositoryThatCouldNotAnswerMeansUnknown() {
        #expect(UpdateRelation.compute(
            ours: Self.ours, latest: Self.latest, ancestry: .undecided) == .unknown)
    }

    /// Every answer, in one place: the table is small enough to state whole, and
    /// a fifth case added without a mapping would fail to compile here.
    @Test func everyAncestryAnswerHasARelation() {
        let expected: [AncestryAnswer: UpdateRelation] = [
            .contains: .behind,
            .doesNotContain: .upToDate,
            .latestAbsentLocally: .behind,
            .undecided: .unknown,
        ]
        for answer in AncestryAnswer.allCases {
            #expect(
                UpdateRelation.compute(ours: Self.ours, latest: Self.latest, ancestry: answer)
                    == expected[answer],
                "\(answer.rawValue) must map to \(String(describing: expected[answer]))")
        }
    }

    @Test func missingEitherCommitIsUnknown() {
        #expect(UpdateRelation.compute(
            ours: nil, latest: Self.latest, ancestry: .contains) == .unknown)
        #expect(UpdateRelation.compute(
            ours: Self.ours, latest: nil, ancestry: .contains) == .unknown)
        #expect(UpdateRelation.compute(
            ours: "", latest: Self.latest, ancestry: .latestAbsentLocally) == .unknown)
    }

    @Test func statusRoundTrips() throws {
        let status = UpdateStatus(
            latestCommit: Self.latest,
            observedAt: Date(timeIntervalSince1970: 1_780_000_000),
            relation: .behind,
            behindBy: 13,
            remote: "git@github.com:acme/tbd.git")
        let decoded = try JSONDecoder().decode(
            UpdateStatus.self, from: JSONEncoder().encode(status))
        #expect(decoded == status)
    }

    /// A relation name a future daemon invented decodes as `unknown` rather
    /// than failing and losing the commit and timestamp beside it.
    @Test func unrecognisedRelationDecodesAsUnknown() throws {
        let json = #"{"latestCommit":"abc","relation":"diverged"}"#
        let decoded = try JSONDecoder().decode(UpdateStatus.self, from: Data(json.utf8))
        #expect(decoded.relation == .unknown)
        #expect(decoded.latestCommit == "abc")
    }

    @Test func modeCapabilities() {
        #expect(UpdateMode.off.runsChecks == false)
        #expect(UpdateMode.off.launchesUpdates == false)
        #expect(UpdateMode.check.runsChecks == true)
        #expect(UpdateMode.check.launchesUpdates == false)
        #expect(UpdateMode.auto.runsChecks == true)
        #expect(UpdateMode.auto.launchesUpdates == true)
    }
}
