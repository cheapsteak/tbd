import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "cli-installer")

/// The launch-time check of the `tbd` CLI install, without the UI.
///
/// It decides what to do with `CLIInstallState.launchAction`, does the parts
/// that need no user (recording the installed file's identity, refreshing a
/// stale install TBD recognizes as its own) and returns an `Outcome` for
/// `CLIInstallerCoordinator` to turn into an alert, or into none.
///
/// It owns the record: the `CLIFileIdentity` of the `tbd` TBD last installed
/// or saw healthy at the install path, kept in the injected `UserDefaults`.
/// While the file at the install path keeps that identity, TBD put it there,
/// so a rebuild that made it stale is repaired without asking — on the
/// default TBD home only. An app on a sandboxed `TBD_HOME` shares the install
/// path and the record with the developer's own installation, so it asks.
@MainActor
struct CLILaunchCheck {
    /// Where the record lives, as `CLIFileIdentity.storageString`.
    static let recordedIdentityKey = "com.tbd.app.cliInstaller.installedIdentity"

    enum Outcome {
        /// The install matches the daemon's TBDCLI. Its identity is recorded.
        case upToDate
        /// Nothing to do: the CLI is missing and the user declined to install
        /// it before.
        case nothing
        /// Ask the user.
        case prompt(CLILaunchPromptKind)
        /// The stale install was TBD's own and is now re-linked to the
        /// daemon's TBDCLI, with the new identity recorded.
        case refreshedSilently
        /// The silent refresh failed. Whatever was at the install path is
        /// still there, and the record is unchanged.
        case silentRefreshFailed(any Error)
    }

    let installer: CLIInstaller
    let userDefaults: UserDefaults
    /// Whether a stale install TBD recognizes may be re-linked without asking.
    /// The coordinator sets it from `TBDConstants.isDefaultConfigDir`: true on
    /// the default TBD home, false on a sandboxed `TBD_HOME`. Recording a
    /// current install never depends on it, since that changes no file.
    let allowsSilentRefresh: Bool

    /// The recorded identity, or nil when nothing (or nothing parseable) is
    /// recorded.
    var recordedIdentity: CLIFileIdentity? {
        guard let stored = userDefaults.string(forKey: Self.recordedIdentityKey) else {
            return nil
        }
        return CLIFileIdentity(storageString: stored)
    }

    /// Check the install against `target`, the TBDCLI beside the running
    /// daemon. `userPreviouslyDismissed` is the coordinator's Not-Now flag for
    /// the missing-CLI prompt.
    func run(target: String, userPreviouslyDismissed: Bool) -> Outcome {
        let state = installer.currentState(expectedTarget: target)
        if case .installed = state {
            recordInstalledIdentity()
            return .upToDate
        }
        let action = state.launchAction(
            installedFile: installer.installedFileIdentity(),
            recorded: recordedIdentity,
            userPreviouslyDismissed: userPreviouslyDismissed,
            allowsSilentRefresh: allowsSilentRefresh
        )
        switch action {
        case .none:
            return .nothing
        case .prompt(let kind):
            return .prompt(kind)
        case .refreshSilently:
            return refreshSilently(target: target)
        }
    }

    /// Record the identity of the file at the install path when it is a
    /// current link to `target`; touch nothing otherwise. The coordinator
    /// calls it each time a new daemon first answers
    /// (`CLIInstallerCoordinator.recordCurrentInstall`), so a re-link made
    /// while the app keeps running is recorded, not left to read later as
    /// someone else's file. `scripts/restart.sh` re-links before it hands
    /// over to the new daemon, so that daemon's first answer finds the
    /// install current. `scripts/update.sh` re-links after its handover, so
    /// with the app left open (`tbd update --no-app`) this can run first and
    /// miss the new file. The next launch then records it if it is still
    /// current, or prompts if a rebuild has made it stale.
    func recordIfInstalled(target: String) {
        guard case .installed = installer.currentState(expectedTarget: target) else {
            return
        }
        recordInstalledIdentity()
    }

    /// Record the identity of the file now at the install path. Called after
    /// every successful install, prompted or from the menu, and whenever the
    /// install is seen healthy. Leaves the record alone when no regular file
    /// is there.
    func recordInstalledIdentity() {
        guard let identity = installer.installedFileIdentity() else { return }
        userDefaults.set(identity.storageString, forKey: Self.recordedIdentityKey)
    }

    /// Re-link without asking. Only the link: `install(target:)` would also
    /// run the PATH probe, which starts the user's login shell, and nothing
    /// here would show its answer.
    private func refreshSilently(target: String) -> Outcome {
        let installPath = installer.installPath
        do {
            try installer.replaceLink(target: target)
        } catch {
            logger.error("Silent CLI refresh at \(installPath, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return .silentRefreshFailed(error)
        }
        recordInstalledIdentity()
        logger.info("Refreshed the CLI TBD installed at \(installPath, privacy: .public) -> \(target, privacy: .public) without prompting")
        return .refreshedSilently
    }
}
