import Foundation
import TBDShared

/// The app's one-line rendering of the daemon's update observation.
///
/// Pure and free of the view, for the same reason `DaemonBuildSkew` is: the
/// interesting behavior is which of several sentences appears, and every branch
/// should be assertable without standing up a daemon or a window.
enum UpdateNotice {
    /// The banner text, or nil when there is nothing worth a banner.
    ///
    /// Only `behind` produces one. `upToDate` and `unknown` are the states a
    /// healthy installation sits in for weeks; a banner that says "up to date"
    /// is a banner people learn to ignore, and by the time it says something
    /// that matters they have stopped reading it.
    ///
    /// Also silent while auto-update is on: an update that installs by itself
    /// needs no prompt to run `tbd update`. `idleLine` covers the one case
    /// where that promise is not being kept.
    static func message(daemon: BuildIdentity?, update: UpdateStatus?) -> String? {
        guard update?.autoUpdateActive != true else { return nil }
        return availableText(daemon: daemon, update: update)
    }

    /// How long a newer build may wait while auto-update is on before the app
    /// says so.
    static let idleWaitThreshold: TimeInterval = 24 * 60 * 60

    /// The small line shown in place of the banner while auto-update is on and
    /// a newer build has been waiting longer than `idleWaitThreshold`. Nil in
    /// every other case, including when the daemon did not say when it first
    /// saw the commit.
    static func idleLine(update: UpdateStatus?, now: Date) -> String? {
        guard let update, update.autoUpdateActive == true,
              update.relation == .behind, update.latestCommit != nil,
              let seen = update.latestFirstSeenAt,
              now.timeIntervalSince(seen) > idleWaitThreshold
        else { return nil }
        return "Update installs when idle."
    }

    /// The "a newer TBD exists" sentence, with no regard for whether anything
    /// should be shown unprompted.
    private static func availableText(daemon: BuildIdentity?, update: UpdateStatus?) -> String? {
        guard let update, update.relation == .behind,
              let latest = update.latestCommit
        else { return nil }
        let ours = daemon?.displayCommit ?? "this build"
        let short = String(latest.prefix(7))
        if let count = update.behindBy, count > 0 {
            let plural = count == 1 ? "commit" : "commits"
            return "A newer TBD is available: \(ours) → \(short) (\(count) \(plural) behind). Run tbd update in a terminal."
        }
        return "A newer TBD is available: \(ours) → \(short). Run tbd update in a terminal."
    }

    /// What the "Check for Updates…" menu item reports as a toast.
    ///
    /// Says something in every case, including the two the banner stays silent
    /// about: somebody who just asked is owed an answer, which is exactly the
    /// distinction between an unprompted banner and a requested check.
    static func checkResultToast(daemon: BuildIdentity?, update: UpdateStatus?) -> String {
        guard let update else { return "Could not check for updates." }
        switch update.relation {
        case .upToDate:
            return "TBD is up to date."
        case .behind:
            if update.autoUpdateActive == true {
                // Asked for by hand, so it answers even though the banner is
                // hidden; the answer says nothing needs doing.
                let short = update.latestCommit.map { String($0.prefix(7)) }
                return "A newer TBD is available" + (short.map { " (\($0))" } ?? "")
                    + ". Auto-update installs it when idle."
            }
            return message(daemon: daemon, update: update)
                ?? "A newer TBD is available. Run tbd update in a terminal."
        case .unknown:
            return "Could not tell whether a newer TBD is available."
        }
    }

    /// What the status bar shows for the running app: `v0.1.0`, or
    /// `v0.1.0 (abc1234)` once the build carries an identity.
    ///
    /// The commit is the version here — `TBDConstants.version` has been the
    /// literal `0.1.0` since the first commit and says nothing on its own.
    static func appVersionLabel(_ identity: BuildIdentity?) -> String {
        guard let identity else { return "v\(TBDConstants.version)" }
        return "v\(TBDConstants.version) (\(identity.displayCommit))"
    }

    /// Caption under the Settings picker: what the chosen mode will actually do.
    ///
    /// A pure static presenter rather than three `.help(…)` strings inline, so
    /// each branch is a value a test can read.
    static func modeCaption(_ mode: UpdateMode, update: UpdateStatus? = nil) -> String {
        let base = baseModeCaption(mode)
        if mode != .auto, update?.autoUpdateActive == true {
            return base + " An external auto-updater is on, so the newer-version notice is hidden."
        }
        return base
    }

    private static func baseModeCaption(_ mode: UpdateMode) -> String {
        switch mode {
        case .off:
            return "TBD never checks whether a newer version exists. You can still check by hand with tbd version --check."
        case .check:
            return "TBD checks hourly and shows a notice when a newer version exists. It installs nothing."
        case .auto:
            return "TBD checks hourly and installs a newer version on its own, rebuilding out of place and restarting the daemon and this app. Sessions are handed over rather than killed; any that end up parked are woken again, a few at a time. The newer-version notice stays hidden; \"Check for Updates…\" still answers."
        }
    }
}
