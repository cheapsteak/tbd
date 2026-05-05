import SwiftUI
import AppKit
import TBDShared

/// Menu bar item for installing / updating the TBD skill in the user's harness.
/// Three states (mirrors PR #90's CLI installer pattern):
///  - not installed: "Install TBD Skill…"
///  - installed and up to date: "TBD Skill: Installed ✓" (clickable; shows path)
///  - installed but outdated: "Update TBD Skill…"
/// If the harness root (~/.claude/) is missing, the item is disabled with a tooltip.
struct SkillMenu: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandMenu("TBD") {
            SkillMenuContent()
                .environmentObject(appState)
        }
    }
}

private struct SkillMenuContent: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        switch appState.skillStatus?.status {
        case .none, .some(.notInstalled):
            Button("Install TBD Skill…") {
                Task { @MainActor in
                    await appState.installSkill()
                    let alert = NSAlert()
                    if let err = appState.skillInstallError {
                        alert.alertStyle = .warning
                        alert.messageText = "Couldn't install TBD skill"
                        alert.informativeText = "\(err)\n\nIf the TBD daemon isn't running, restart it with scripts/restart.sh, then try again."
                    } else if let s = appState.skillStatus, s.status == .upToDate {
                        alert.messageText = "TBD skill installed"
                        alert.informativeText = "Installed at \(s.harnessPath)"
                    } else if let s = appState.skillStatus, s.status == .harnessNotDetected {
                        alert.alertStyle = .warning
                        alert.messageText = "Claude Code not detected"
                        alert.informativeText = "TBD couldn't find ~/.claude/. Install Claude Code, then try again."
                    } else {
                        alert.alertStyle = .warning
                        alert.messageText = "Couldn't install TBD skill"
                        alert.informativeText = "Check Console.app (subsystem com.tbd.app, category skill) for details."
                    }
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        case .some(.upToDate):
            Button("TBD Skill: Installed ✓") {
                if let path = appState.skillStatus?.harnessPath {
                    let alert = NSAlert()
                    alert.messageText = "TBD skill is installed"
                    alert.informativeText = path
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        case .some(.outdated):
            Button("Update TBD Skill…") {
                Task { @MainActor in
                    let alert = NSAlert()
                    alert.messageText = "Update TBD skill?"
                    alert.informativeText = "This will overwrite \(appState.skillStatus?.harnessPath ?? "")."
                    alert.addButton(withTitle: "Update")
                    alert.addButton(withTitle: "Cancel")
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        await appState.installSkill()
                    }
                }
            }
        case .some(.harnessNotDetected):
            Button("Install TBD Skill…") {}
                .disabled(true)
                .help("Claude Code not detected (~/.claude/ is missing).")
        }
    }
}
