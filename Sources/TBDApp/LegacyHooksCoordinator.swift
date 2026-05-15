import Foundation
import AppKit
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "legacy-hooks")

/// Coordinates the one-time migration prompt that asks the user whether
/// TBD should remove its legacy global hook entries from
/// `~/.claude/settings.json` (the entries now superseded by the spawn-time
/// `--settings <overlay>` injection introduced in this PR).
///
/// Mirrors the shape of `CLIInstallerCoordinator`:
///   - `checkOnLaunch()` runs once per app session, gated by a UserDefaults
///     dismissal key. Repo-level entries are surfaced informationally; only
///     the global file is auto-modifiable.
///   - `runFromMenu()` is the explicit entry point — bypasses the dismissal
///     latch.
///   - On observing a clean state (no global entries), the dismissal latch
///     is cleared, so a future legacy reinstall (e.g., the user runs an old
///     `tbd setup-hooks --global` script) re-arms the prompt.
@MainActor
final class LegacyHooksCoordinator {
    private let daemonClient: DaemonClient
    private let userDefaults: UserDefaults

    private var hasCheckedThisSession = false

    private static let dismissedKey = "com.tbd.app.legacyHooks.dismissed"
    private var dismissed: Bool {
        get { userDefaults.bool(forKey: Self.dismissedKey) }
        set { userDefaults.set(newValue, forKey: Self.dismissedKey) }
    }

    init(daemonClient: DaemonClient, userDefaults: UserDefaults = .standard) {
        self.daemonClient = daemonClient
        self.userDefaults = userDefaults
    }

    /// One-time launch check. Skips on subsequent invocations within the
    /// same app session, even if a daemon reconnect happens.
    func checkOnLaunch() async {
        guard !hasCheckedThisSession else { return }
        // Latch immediately so a second concurrent caller can't slip past
        // the guard during the daemonClient await below. Mirrors CLI
        // installer's pattern: only the first invocation per session runs.
        hasCheckedThisSession = true
        let status: LegacyHooksStatusResult
        do {
            status = try await daemonClient.legacyHooksStatus()
        } catch {
            logger.warning("daemon.legacyHooksStatus failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        if status.globalEntries.isEmpty {
            // Re-arm dismissal so a later reinstall surfaces the prompt
            // again — matches CLIInstallerCoordinator's behavior on
            // `.installed`.
            if dismissed {
                logger.info("legacy hooks clean — clearing prior dismissal")
                dismissed = false
            }
            return
        }

        guard !dismissed else {
            logger.debug("legacy hooks present but user previously dismissed prompt")
            return
        }

        await presentDialog(status: status, recordDismissalOnDecline: true)
    }

    /// Menu entry point — always presents the dialog regardless of
    /// dismissal state. Declining here does NOT record a dismissal.
    func runFromMenu() async {
        let status: LegacyHooksStatusResult
        do {
            status = try await daemonClient.legacyHooksStatus()
        } catch {
            presentAlert(
                style: .warning,
                title: "Couldn't read legacy hook status",
                body: error.localizedDescription
            )
            return
        }
        if status.globalEntries.isEmpty && status.repoEntries.isEmpty {
            presentAlert(
                style: .informational,
                title: "No legacy TBD hooks detected",
                body: "Your Claude Code settings are already up to date — TBD provisions hooks automatically when it spawns Claude."
            )
            return
        }
        // Repo-only case: presentDialog renders Remove/Not Now/Show File…
        // but Remove only acts on global entries. Show an info alert that
        // names the affected repo files instead, so the menu path doesn't
        // dangle a button that does nothing.
        if status.globalEntries.isEmpty {
            let body = "TBD doesn't auto-modify repo settings (often git-tracked). "
                + "Edit these manually:\n\n"
                + status.repoEntries.keys.sorted().map { "• \($0)" }.joined(separator: "\n")
            presentAlert(
                style: .informational,
                title: "Repo-level legacy hooks need manual cleanup",
                body: body
            )
            return
        }
        await presentDialog(status: status, recordDismissalOnDecline: false)
    }

    // MARK: - Private

    private func presentDialog(status: LegacyHooksStatusResult, recordDismissalOnDecline: Bool) async {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Migrate TBD's Claude hooks?"
        alert.informativeText = buildBody(status: status)
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Show File…")
        // HIG: destructive action shouldn't be the Return-key default.
        // Move the keyEquivalent off "Remove" and onto "Not Now" so muscle-
        // memory Return-presses don't trigger the destructive path. The
        // pristine-backup mechanism makes accidental removal recoverable,
        // but the friction is still worth adding.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            await performRemove()
        case .alertSecondButtonReturn:
            if recordDismissalOnDecline {
                logger.info("user dismissed legacy-hooks prompt — not auto-prompting next launch")
                dismissed = true
            }
        case .alertThirdButtonReturn:
            // Reveal global settings.json in Finder. We always reveal the
            // global file since that's the one TBD can modify; repo files
            // are user-managed.
            let url = URL(fileURLWithPath: LegacyHookSettingsPath.global)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        default:
            break
        }
    }

    private func performRemove() async {
        do {
            let result = try await daemonClient.removeLegacyGlobalHooks()
            // Clear dismissal so the prompt re-arms if the entries reappear.
            dismissed = false
            let body: String
            if result.removedCount == 0 {
                body = "No matching entries were found in ~/.claude/settings.json. Nothing was changed."
            } else if let backup = result.backupPath {
                body = "Removed \(result.removedCount) entr\(result.removedCount == 1 ? "y" : "ies") from ~/.claude/settings.json. A backup of your original file is saved at \(backup)."
            } else {
                body = "Removed \(result.removedCount) entr\(result.removedCount == 1 ? "y" : "ies") from ~/.claude/settings.json."
            }
            presentAlert(style: .informational, title: "Legacy hooks removed", body: body)
        } catch {
            presentAlert(
                style: .warning,
                title: "Couldn't update Claude settings",
                body: """
                TBD didn't modify the file — please check ~/.claude/settings.json manually and report this to TBD.

                Error: \(error.localizedDescription)
                """
            )
        }
    }

    private func buildBody(status: LegacyHooksStatusResult) -> String {
        var lines: [String] = []
        if !status.globalEntries.isEmpty {
            let n = status.globalEntries.count
            lines.append("TBD found \(n) legacy hook entr\(n == 1 ? "y" : "ies") in your global Claude settings (\(LegacyHookSettingsPath.global)).")
            lines.append("")
            lines.append("These are no longer needed — TBD now installs hooks per-spawn via the --settings overlay file at \(LegacyHookSettingsPath.overlayHint), so the global entries can fire twice or stick around if you stop using TBD.")
            lines.append("")
            lines.append("• Remove: TBD will atomically rewrite the global file (a backup is saved next to it).")
            lines.append("• Not Now: keep the entries; we'll ask again next launch.")
            lines.append("• Show File…: reveal the global file in Finder so you can inspect it.")
        }
        if !status.repoEntries.isEmpty {
            lines.append("")
            lines.append("Repo-level settings files also contain legacy entries. TBD will NOT modify these for you — please review them yourself:")
            for path in status.repoEntries.keys.sorted() {
                lines.append("  • \(path)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func presentAlert(style: NSAlert.Style, title: String, body: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Constants the coordinator surfaces in the dialog body. Kept separate so
/// the overlay hint stays in sync if we ever move the file.
enum LegacyHookSettingsPath {
    static let global: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude")
        .appendingPathComponent("settings.json")
        .path
    static let overlayHint = "~/tbd/runtime/claude-overlay.json"
}
