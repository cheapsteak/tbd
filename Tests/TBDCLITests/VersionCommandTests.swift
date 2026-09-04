import Foundation
import Testing

@testable import TBDCLI
@testable import TBDShared

/// Tier 1. What `tbd version` prints, and where `tbd update` looks.
///
/// Both are pure functions on purpose: the interesting behavior is which of
/// four sentences appears and which two paths were searched, and a test that
/// had to stand up a daemon to read either is a test nobody writes.
@Suite("tbd version")
struct VersionReportTests {

    private static let daemonBuild = BuildIdentity(
        commit: "1111111111111111111111111111111111111111",
        shortCommit: "1111111", branch: "main",
        sourceWorktree: "/Users/me/tbd/updates/src")
    private static let latest = "2222222222222222222222222222222222222222"

    // MARK: - The verdict line: exactly one of four

    @Test func behindWithACountNamesTheCount() {
        let verdict = VersionReport.verdict(
            daemon: Self.daemonBuild,
            update: UpdateStatus(
                latestCommit: Self.latest, relation: .behind, behindBy: 13))
        #expect(verdict == "Update available: 1111111 → 2222222 (13 commits behind). Run: tbd update")
    }

    /// One commit is not "1 commits". The count is the only number in this
    /// output and it is read by a person.
    @Test func oneCommitBehindIsSingular() {
        let verdict = VersionReport.verdict(
            daemon: Self.daemonBuild,
            update: UpdateStatus(
                latestCommit: Self.latest, relation: .behind, behindBy: 1))
        #expect(verdict.contains("(1 commit behind)"))
    }

    /// The ordinary case on a machine that has never fetched the newer objects
    /// — `ls-remote` moves none — so the sentence says less rather than
    /// inventing a number.
    @Test func behindWithoutACountOmitsTheCountEntirely() {
        let verdict = VersionReport.verdict(
            daemon: Self.daemonBuild,
            update: UpdateStatus(latestCommit: Self.latest, relation: .behind))
        #expect(verdict == "Update available: 1111111 → 2222222. Run: tbd update")
    }

    /// A zero count is the same situation as no count: nothing to report about
    /// distance, and "(0 commits behind)" beside "update available" is a
    /// contradiction.
    @Test func aZeroCountIsRenderedAsNoCount() {
        let verdict = VersionReport.verdict(
            daemon: Self.daemonBuild,
            update: UpdateStatus(
                latestCommit: Self.latest, relation: .behind, behindBy: 0))
        #expect(verdict == "Update available: 1111111 → 2222222. Run: tbd update")
    }

    @Test func upToDateSaysSoAndNothingElse() {
        #expect(VersionReport.verdict(
            daemon: Self.daemonBuild,
            update: UpdateStatus(latestCommit: Self.latest, relation: .upToDate)) == "Up to date")
    }

    @Test func unknownPointsAtTheCommandThatWouldAnswerIt() {
        #expect(VersionReport.verdict(
            daemon: Self.daemonBuild,
            update: UpdateStatus(relation: .unknown))
            == "Unknown — run tbd version --check")
    }

    /// No observation at all — an `off`-mode daemon, or one that has not
    /// finished its first check — is the same answer as an undecided one.
    @Test func noObservationIsAlsoUnknown() {
        #expect(VersionReport.verdict(daemon: Self.daemonBuild, update: nil)
            == "Unknown — run tbd version --check")
    }

    /// A daemon whose own identity could not be learned still gets a
    /// destination in the sentence rather than an empty arrow.
    @Test func anUnknownDaemonCommitStillRendersTheDestination() {
        let verdict = VersionReport.verdict(
            daemon: nil,
            update: UpdateStatus(latestCommit: Self.latest, relation: .behind))
        #expect(verdict == "Update available: unknown → 2222222. Run: tbd update")
    }

    // MARK: - The identity lines

    @Test func aStampedIdentityShowsCommitAndBranch() {
        #expect(VersionReport.describe(Self.daemonBuild) == "1111111 (main)")
    }

    /// A detached build has no branch worth printing, and `HEAD` is noise.
    @Test func aDetachedBuildOmitsTheBranch() {
        #expect(VersionReport.describe(BuildIdentity(
            commit: "a", shortCommit: "aaaaaaa", branch: "HEAD")) == "aaaaaaa")
    }

    /// The fallback resolution says so, because "the tree's HEAD now" is a
    /// different claim from "the commit this binary was built from".
    @Test func aWorktreeHeadFallbackIsLabelled() {
        let described = VersionReport.describe(BuildIdentity(
            commit: "b", shortCommit: "bbbbbbb", branch: "feature", origin: .worktreeHead))
        #expect(described == "bbbbbbb (feature) [worktree HEAD, may be newer than this binary]")
    }

    @Test func aDirtyBuildSaysSo() {
        #expect(VersionReport.describe(BuildIdentity(
            commit: "c", shortCommit: "ccccccc", branch: "main", dirty: true))
            == "ccccccc-dirty (main)")
    }

    @Test func unknownIdentityRendersAsUnknown() {
        #expect(VersionReport.describe(nil) == "unknown")
    }

    @Test func aMissingDaemonSaysNotRunningRatherThanUnknown() {
        #expect(VersionReport.describeDaemon(nil) == "not running")
    }

    @Test func theDaemonLineCarriesItsExecutablePath() {
        let described = VersionReport.describeDaemon(DaemonStatusResult(
            version: "0.1.0", uptime: 1, connectedClients: 0,
            executablePath: "/Users/me/tbd/updates/src/.build/release/TBDDaemon",
            buildIdentity: Self.daemonBuild))
        #expect(described == "1111111 (main) — /Users/me/tbd/updates/src/.build/release/TBDDaemon")
    }

    @Test func neverCheckedIsSaidPlainly() {
        #expect(VersionReport.describeLatest(nil) == "never checked")
        #expect(VersionReport.describeLatest(UpdateStatus(relation: .unknown)) == "never checked")
    }

    @Test func anObservationCarriesItsTimestamp() {
        let described = VersionReport.describeLatest(UpdateStatus(
            latestCommit: Self.latest,
            observedAt: Date(timeIntervalSince1970: 1_780_000_000),
            relation: .behind))
        #expect(described.hasPrefix("2222222 (observed "))
    }

    // MARK: - The whole report

    @Test func theReportNamesEveryPartOnItsOwnLine() {
        let report = VersionReport.render(
            cli: BuildIdentity(commit: "d", shortCommit: "ddddddd", branch: "main"),
            daemon: DaemonStatusResult(
                version: "0.1.0", uptime: 1, connectedClients: 0,
                executablePath: "/w/.build/release/TBDDaemon",
                buildIdentity: Self.daemonBuild),
            update: UpdateStatus(latestCommit: Self.latest, relation: .behind, behindBy: 2))
        let lines = report.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "TBD 0.1.0")
        #expect(lines.contains { $0.hasPrefix("  CLI:") && $0.contains("ddddddd") })
        #expect(lines.contains { $0.hasPrefix("  Daemon:") && $0.contains("1111111") })
        #expect(lines.contains { $0.hasPrefix("  Latest:") && $0.contains("2222222") })
        #expect(lines.last == "Update available: 1111111 → 2222222 (2 commits behind). Run: tbd update")
    }

    // MARK: - tbd daemon status text form

    /// Both new lines are conditional: a daemon that predates the fields, or
    /// one in `off` mode, must not grow an empty `Build:` or `Update:` row.
    @Test func daemonStatusOmitsBuildAndUpdateWhenAbsent() {
        let rendered = DaemonStatusReport.render(DaemonStatusResult(
            version: "0.1.0", uptime: 90, connectedClients: 2))
        #expect(rendered.contains("Version:"))
        #expect(!rendered.contains("Build:"))
        #expect(!rendered.contains("Update:"))
    }

    @Test func daemonStatusShowsBuildAndUpdateWhenPresent() {
        let rendered = DaemonStatusReport.render(DaemonStatusResult(
            version: "0.1.0", uptime: 90, connectedClients: 2,
            executablePath: "/w/.build/release/TBDDaemon",
            buildIdentity: Self.daemonBuild,
            update: UpdateStatus(latestCommit: Self.latest, relation: .upToDate)))
        #expect(rendered.contains("Build:             1111111 (main)"))
        #expect(rendered.contains("Update:            Up to date"))
    }
}

/// Where `tbd update` looks for the procedure it hands over to.
@Suite("tbd update")
struct UpdateScriptLocatorTests {

    @Test func theDaemonsSourceWorktreeWins() {
        let outcome = UpdateScriptLocator.locate(
            sourceWorktree: "/Users/me/tbd/updates/src",
            executablePath: "/Users/me/tbd/worktrees/tbd/feature/.build/debug/tbd",
            fileExists: { $0 == "/Users/me/tbd/updates/src/scripts/update.sh" })
        #expect(outcome == .found("/Users/me/tbd/updates/src/scripts/update.sh"))
    }

    /// The daemon said nothing — an older daemon, or one that is not running —
    /// so the CLI's own worktree is the fallback.
    @Test func theCLIsOwnWorktreeIsTheFallback() {
        let outcome = UpdateScriptLocator.locate(
            sourceWorktree: nil,
            executablePath: "/Users/me/tbd/worktrees/tbd/feature/.build/debug/tbd",
            fileExists: { _ in true })
        #expect(outcome == .found("/Users/me/tbd/worktrees/tbd/feature/scripts/update.sh"))
    }

    /// A daemon whose tree has no script — a build from before the feature —
    /// falls through to the CLI's tree rather than giving up at the first miss.
    @Test func aMissingScriptInTheFirstTreeFallsThroughToTheSecond() {
        let outcome = UpdateScriptLocator.locate(
            sourceWorktree: "/old",
            executablePath: "/new/.build/debug/tbd",
            fileExists: { $0 == "/new/scripts/update.sh" })
        #expect(outcome == .found("/new/scripts/update.sh"))
    }

    @Test func nothingFoundReportsEveryPathItTried() {
        let outcome = UpdateScriptLocator.locate(
            sourceWorktree: "/old",
            executablePath: "/new/.build/debug/tbd",
            fileExists: { _ in false })
        #expect(outcome == .missing(searched: [
            "/old/scripts/update.sh", "/new/scripts/update.sh",
        ]))
    }

    /// The same tree named twice is searched once — a user reading the failure
    /// should not see the same path listed twice.
    @Test func theSameTreeIsNotSearchedTwice() {
        let outcome = UpdateScriptLocator.locate(
            sourceWorktree: "/w",
            executablePath: "/w/.build/debug/tbd",
            fileExists: { _ in false })
        #expect(outcome == .missing(searched: ["/w/scripts/update.sh"]))
    }

    /// Nothing to go on at all: an installed CLI with no `.build` in its path
    /// talking to a daemon that reported no identity.
    @Test func noCandidatesAtAllIsItsOwnMessage() {
        let outcome = UpdateScriptLocator.locate(
            sourceWorktree: nil,
            executablePath: "/Users/me/.local/bin/tbd",
            fileExists: { _ in true })
        #expect(outcome == .missing(searched: []))
        let message = UpdateScriptLocator.missingMessage(searched: [])
        #expect(message.contains("could not tell which worktree"))
    }

    @Test func theMissingMessageListsTheSearchedPaths() {
        let message = UpdateScriptLocator.missingMessage(
            searched: ["/a/scripts/update.sh", "/b/scripts/update.sh"])
        #expect(message.contains("/a/scripts/update.sh"))
        #expect(message.contains("/b/scripts/update.sh"))
    }
}
