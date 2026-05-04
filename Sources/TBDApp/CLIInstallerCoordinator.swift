import Foundation
import AppKit
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "cli-installer")

@MainActor
final class CLIInstallerCoordinator {
    private let daemonClient: DaemonClient
    private let installer = CLIInstaller()

    /// Persists across launches. Set when the user clicks "Not Now" on the
    /// `.notInstalled` prompt; cleared on successful install or whenever we
    /// observe a healthy install at launch (so a manual install or a later
    /// re-install via the menu re-arms the prompt for future deletions).
    private static let dismissedKey = "com.tbd.app.cliInstaller.notInstalledDismissed"
    private var notInstalledDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: Self.dismissedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.dismissedKey) }
    }

    init(daemonClient: DaemonClient) {
        self.daemonClient = daemonClient
    }

    /// Called once at end of `connectAndLoadInitialState`. Surfaces a one-click
    /// prompt if the symlink is missing or stale. Silent if everything's healthy
    /// or if the user previously dismissed the missing-CLI prompt.
    func checkOnLaunch() async {
        guard let target = await fetchExpectedTarget() else { return }
        let state = installer.currentState(expectedTarget: target)

        if case .installed = state {
            logger.debug("CLI symlink installed and current at \(self.installer.symlinkPath, privacy: .public)")
            if notInstalledDismissed {
                logger.info("CLI symlink healthy — clearing prior dismissal")
                notInstalledDismissed = false
            }
            return
        }

        guard let kind = state.launchPromptKind(userPreviouslyDismissed: notInstalledDismissed) else {
            logger.debug("Skipping CLI install prompt — user previously dismissed Not Now")
            return
        }

        switch kind {
        case .missing:
            logger.info("CLI symlink missing — prompting to install")
        case .stale(let current):
            logger.info("CLI symlink stale: current=\(current, privacy: .public) expected=\(target, privacy: .public) — prompting to refresh")
        case .nonSymlink:
            logger.info("Non-symlink at \(self.installer.symlinkPath, privacy: .public) — prompting to replace")
        }
        await presentLaunchPrompt(target: target, kind: kind, recordDismissalOnDecline: true)
    }

    /// Called from the menu item. Routes through the same prompt as the
    /// launch-time check (so verb/wording stays accurate per state) but
    /// doesn't record a Not-Now dismissal — the user explicitly invoked us.
    func runFromMenu() async {
        guard let target = await fetchExpectedTarget() else {
            presentTargetUnavailableAlert()
            return
        }
        let state = installer.currentState(expectedTarget: target)
        let kind: CLILaunchPromptKind
        switch state {
        case .installed:
            presentAlreadyInstalledAlert(target: target)
            return
        case .notInstalled:
            kind = .missing
        case .stale(let current):
            kind = .stale(current: current)
        case .nonSymlink:
            kind = .nonSymlink
        }
        await presentLaunchPrompt(target: target, kind: kind, recordDismissalOnDecline: false)
    }

    // MARK: - Private

    private func fetchExpectedTarget() async -> String? {
        let status: DaemonStatusResult
        do {
            status = try await daemonClient.daemonStatus()
        } catch {
            logger.warning("daemon.status failed during CLI install check: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let exec = status.executablePath, !exec.isEmpty else {
            logger.info("Daemon did not report executablePath (likely older daemon); skipping CLI install check")
            return nil
        }
        let cli = CLIInstaller.cliPath(forDaemonExecutable: exec)
        guard FileManager.default.fileExists(atPath: cli) else {
            logger.warning("Expected TBDCLI binary not found at \(cli, privacy: .public)")
            return nil
        }
        return cli
    }

    private func presentLaunchPrompt(target: String, kind: CLILaunchPromptKind, recordDismissalOnDecline: Bool) async {
        let alert = NSAlert()
        alert.alertStyle = .informational
        let symlinkPath = installer.symlinkPath
        let primaryButton: String
        switch kind {
        case .missing:
            alert.messageText = "Install the tbd command-line tool?"
            alert.informativeText = "TBD can add a `tbd` command at \(symlinkPath) so you can launch and control TBD from the terminal. No sudo required."
            primaryButton = "Install"
        case .stale(let current):
            alert.messageText = "Refresh the tbd command-line tool?"
            alert.informativeText = "Your `tbd` symlink at \(symlinkPath) points at \(current), which doesn't match this TBD's CLI. Update it?"
            primaryButton = "Refresh"
        case .nonSymlink:
            alert.messageText = "Replace the file at \(symlinkPath)?"
            alert.informativeText = "A regular file already exists at \(symlinkPath). TBD can replace it with a symlink to this TBD's CLI."
            primaryButton = "Replace"
        }
        alert.addButton(withTitle: primaryButton)
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            await performInstall(target: target)
        } else if recordDismissalOnDecline, case .missing = kind {
            // User declined the auto-launch missing-CLI prompt. Suppress on
            // future launches until they install — manually, via menu, or
            // after we observe a healthy `.installed` state. Stale/nonSymlink
            // dismissals are NOT remembered: those are broken-install states
            // they opted into. Menu-invoked declines also aren't remembered
            // (the user explicitly opened the dialog themselves).
            logger.info("User dismissed install prompt — not auto-prompting next launch")
            notInstalledDismissed = true
        }
    }

    private func performInstall(target: String) async {
        let symlinkDir = (installer.symlinkPath as NSString).deletingLastPathComponent
        let result: CLIInstallResult
        do {
            // install() is async — its PATH probe bridges Process termination
            // into a continuation, so the awaiting task yields its thread
            // instead of blocking AppKit during the 2s wait.
            result = try await installer.install(target: target)
        } catch {
            logger.error("CLI install failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't install tbd"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        logger.info("CLI symlink installed: \(result.symlinkPath, privacy: .public) -> \(result.target, privacy: .public) onPath=\(result.onPath, privacy: .public)")
        // Re-arm the launch prompt for any future unintended deletion.
        notInstalledDismissed = false

        let alert = NSAlert()
        alert.alertStyle = .informational
        if result.onPath {
            alert.messageText = "tbd installed"
            alert.informativeText = "Symlink created at \(result.symlinkPath). You can now run `tbd` from any terminal."
            alert.addButton(withTitle: "OK")
        } else {
            alert.messageText = "tbd installed — one more step"
            let rc = result.suggestedShellRC ?? "your shell rc file"
            let line = result.exportLine ?? ""
            alert.informativeText = """
            Symlink created at \(result.symlinkPath).

            \(symlinkDir) is not on your shell's PATH. Add this line to \(rc) and restart your shell:

            \(line)
            """
            alert.addButton(withTitle: "Copy export line")
            alert.addButton(withTitle: "OK")
        }
        let response = alert.runModal()
        if !result.onPath, response == .alertFirstButtonReturn, let line = result.exportLine {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(line, forType: .string)
        }
    }

    private func presentAlreadyInstalledAlert(target: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "tbd is already installed"
        alert.informativeText = "\(installer.symlinkPath) → \(target)"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Reinstall")
        if alert.runModal() == .alertSecondButtonReturn {
            Task { @MainActor in
                await self.performInstall(target: target)
            }
        }
    }

    private func presentTargetUnavailableAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't locate the TBD CLI binary"
        alert.informativeText = "TBD couldn't determine where its TBDCLI binary lives. Make sure the daemon is running (try restarting TBD) and try again."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
