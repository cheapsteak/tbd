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
    static func message(daemon: BuildIdentity?, update: UpdateStatus?) -> String? {
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
    static func modeCaption(_ mode: UpdateMode) -> String {
        switch mode {
        case .off:
            return "TBD never checks whether a newer version exists. You can still check by hand with tbd version --check."
        case .check:
            return "TBD checks hourly and shows a notice when a newer version exists. It installs nothing."
        case .auto:
            return "TBD checks hourly and installs a newer version on its own, rebuilding out of place and restarting the daemon and this app. Sessions are handed over rather than killed; any that end up parked are woken again, a few at a time."
        }
    }
}
