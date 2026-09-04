import Foundation
import Testing

@testable import TBDApp
@testable import TBDShared

/// Tier 1. The app's one-line rendering of the daemon's update observation.
///
/// Pure by construction, for the same reason `DaemonBuildSkewTests` is: the
/// behavior is which sentence appears — and, for the banner, whether one
/// appears at all — and none of that needs a window.
@Suite("UpdateNotice")
struct UpdateNoticeTests {

    private static let build = BuildIdentity(
        commit: "1111111111111111111111111111111111111111",
        shortCommit: "1111111", branch: "main")
    private static let latest = "2222222222222222222222222222222222222222"

    // MARK: - The banner speaks only when there is something to do

    @Test func behindProducesABannerNamingBothCommits() {
        let message = UpdateNotice.message(
            daemon: Self.build,
            update: UpdateStatus(latestCommit: Self.latest, relation: .behind, behindBy: 4))
        #expect(message == "A newer TBD is available: 1111111 → 2222222 (4 commits behind). Run tbd update in a terminal.")
    }

    @Test func oneCommitBehindIsSingular() {
        let message = UpdateNotice.message(
            daemon: Self.build,
            update: UpdateStatus(latestCommit: Self.latest, relation: .behind, behindBy: 1))
        #expect(message?.contains("(1 commit behind)") == true)
    }

    @Test func behindWithoutACountOmitsIt() {
        let message = UpdateNotice.message(
            daemon: Self.build,
            update: UpdateStatus(latestCommit: Self.latest, relation: .behind))
        #expect(message == "A newer TBD is available: 1111111 → 2222222. Run tbd update in a terminal.")
    }

    /// The states a healthy installation sits in for weeks. A banner that says
    /// "up to date" is a banner people learn to ignore.
    @Test func nothingToDoProducesNoBanner() {
        #expect(UpdateNotice.message(
            daemon: Self.build,
            update: UpdateStatus(latestCommit: Self.latest, relation: .upToDate)) == nil)
        #expect(UpdateNotice.message(
            daemon: Self.build, update: UpdateStatus(relation: .unknown)) == nil)
        #expect(UpdateNotice.message(daemon: Self.build, update: nil) == nil)
    }

    /// `behind` with no commit to name is not a banner either — an arrow
    /// pointing at nothing tells the user nothing.
    @Test func behindWithNoLatestCommitProducesNoBanner() {
        #expect(UpdateNotice.message(
            daemon: Self.build, update: UpdateStatus(relation: .behind)) == nil)
    }

    /// A daemon whose own identity could not be learned still gets a readable
    /// sentence rather than an empty left-hand side.
    @Test func anUnknownDaemonBuildStillReads() {
        let message = UpdateNotice.message(
            daemon: nil,
            update: UpdateStatus(latestCommit: Self.latest, relation: .behind))
        #expect(message == "A newer TBD is available: this build → 2222222. Run tbd update in a terminal.")
    }

    // MARK: - The requested check answers in every case

    /// The distinction that matters: an unprompted banner earns its silence, a
    /// check somebody asked for does not.
    @Test func theCheckToastSaysSomethingForEveryRelation() {
        #expect(UpdateNotice.checkResultToast(
            daemon: Self.build,
            update: UpdateStatus(latestCommit: Self.latest, relation: .upToDate))
            == "TBD is up to date.")
        #expect(UpdateNotice.checkResultToast(
            daemon: Self.build, update: UpdateStatus(relation: .unknown))
            == "Could not tell whether a newer TBD is available.")
        #expect(UpdateNotice.checkResultToast(daemon: Self.build, update: nil)
            == "Could not check for updates.")
        #expect(UpdateNotice.checkResultToast(
            daemon: Self.build,
            update: UpdateStatus(latestCommit: Self.latest, relation: .behind, behindBy: 2))
            == "A newer TBD is available: 1111111 → 2222222 (2 commits behind). Run tbd update in a terminal.")
    }

    /// `behind` with nothing to name would leave the banner silent; the toast
    /// still owes an answer, so it falls back rather than returning nothing.
    @Test func theCheckToastFallsBackWhenTheBannerWouldBeSilent() {
        #expect(UpdateNotice.checkResultToast(
            daemon: Self.build, update: UpdateStatus(relation: .behind))
            == "A newer TBD is available. Run tbd update in a terminal.")
    }

    // MARK: - The status-bar label

    /// A build with no identity still shows something; one with an identity
    /// shows the commit, which is the only part of "v0.1.0" that ever changes.
    @Test func theStatusBarLabelCarriesTheCommitWhenThereIsOne() {
        #expect(UpdateNotice.appVersionLabel(nil) == "v0.1.0")
        #expect(UpdateNotice.appVersionLabel(Self.build) == "v0.1.0 (1111111)")
        #expect(UpdateNotice.appVersionLabel(BuildIdentity(
            commit: "d", shortCommit: "ddddddd", branch: "main", dirty: true))
            == "v0.1.0 (ddddddd-dirty)")
    }

    // MARK: - The Settings caption

    /// Three modes, three captions, each naming what the daemon will do. A
    /// caption shared between two modes is a caption that is wrong in one.
    @Test func everyModeHasItsOwnCaption() {
        let captions = UpdateMode.allCases.map(UpdateNotice.modeCaption)
        #expect(Set(captions).count == UpdateMode.allCases.count)
        #expect(UpdateNotice.modeCaption(.off).contains("never checks"))
        #expect(UpdateNotice.modeCaption(.check).contains("installs nothing"))
        #expect(UpdateNotice.modeCaption(.auto).contains("installs a newer version"))
    }
}

// MARK: - AppState wiring

/// The banner's dismissal is per commit, and the picker's write goes through
/// the same refresh-capabilities path every other Settings control uses.
///
/// `AppState()` here is the same shape the sibling toggle tests use: the
/// injected setters mean nothing reaches a socket.
@MainActor
@Test func appState_updateNoticeAppearsOnlyWhenBehindAndNotDismissed() {
    let state = AppState()
    state.daemonBuildIdentity = BuildIdentity(
        commit: "1111111111111111111111111111111111111111",
        shortCommit: "1111111", branch: "main")
    #expect(state.updateNoticeMessage == nil, "no observation, no banner")

    state.daemonUpdateStatus = UpdateStatus(
        latestCommit: "2222222222222222222222222222222222222222",
        relation: .behind, behindBy: 2)
    #expect(state.updateNoticeMessage?.contains("2222222") == true)

    state.dismissUpdateNotice()
    #expect(state.updateNoticeMessage == nil, "a dismissed commit stays dismissed")

    // `main` moved. The dismissal named the old commit, so the new one is
    // announced without the user having to reset anything.
    state.daemonUpdateStatus = UpdateStatus(
        latestCommit: "3333333333333333333333333333333333333333",
        relation: .behind)
    #expect(state.updateNoticeMessage?.contains("3333333") == true)
}

@MainActor
@Test func appState_setUpdateModeRefreshesCapabilitiesOnSuccess() async {
    let state = AppState()
    var written: UpdateMode?
    state.updateModeSetter = { mode in written = mode }
    state.daemonCapabilitiesFetcher = {
        DaemonCapabilitiesResult(controlModeEnabled: false, updateMode: .check)
    }

    await state.setUpdateMode(.check)

    #expect(written == .check)
    #expect(state.daemonCapabilities?.updateMode == .check,
            "a successful choice must re-fetch the daemon's stored mode")
}

@MainActor
@Test func appState_setUpdateModeKeepsLastKnownCapabilitiesOnRefreshFailure() async {
    let state = AppState()
    state.updateModeSetter = { _ in }        // the set succeeds...
    state.daemonCapabilitiesFetcher = { nil }  // ...but the re-fetch fails
    state.daemonCapabilities = DaemonCapabilitiesResult(
        controlModeEnabled: false, updateMode: .auto)

    await state.setUpdateMode(.auto)

    #expect(state.daemonCapabilities?.updateMode == .auto,
            "a transient refresh failure after a successful set must not snap the picker back")
}

/// The requested check publishes what it learned, so the banner and the toast
/// agree — and a failed check says so rather than silently doing nothing.
@MainActor
@Test func appState_checkForUpdatesNowPublishesTheObservation() async {
    let state = AppState()
    state.updateCheckRunner = {
        UpdateStatus(
            latestCommit: "2222222222222222222222222222222222222222",
            relation: .behind, behindBy: 5)
    }

    await state.checkForUpdatesNow()

    #expect(state.daemonUpdateStatus?.behindBy == 5)
    #expect(state.activeToast?.message.contains("5 commits behind") == true)
}

@MainActor
@Test func appState_checkForUpdatesNowReportsAFailure() async {
    struct Boom: Error {}
    let state = AppState()
    state.updateCheckRunner = { throw Boom() }

    await state.checkForUpdatesNow()

    #expect(state.daemonUpdateStatus == nil)
    #expect(state.activeToast?.style == .error)
}
