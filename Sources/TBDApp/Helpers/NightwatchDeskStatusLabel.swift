import SwiftUI
import TBDShared

/// Content displayed in the nightwatch desk status label.
struct NightwatchDeskStatusContent: Equatable {
    let glyph: String
    let text: String
}

/// Computes the desk status content (glyph and text) for a given nightwatch mode.
/// - .off: returns nil (label hidden)
/// - .daywatch: returns content with "◐" glyph and "Daywatch desk" text
/// - .nightwatch: returns content with "🌙" glyph and "Nightwatch desk" text
func nightwatchDeskStatusContent(for mode: NightwatchMode) -> NightwatchDeskStatusContent? {
    switch mode {
    case .off:
        return nil
    case .daywatch:
        return NightwatchDeskStatusContent(glyph: "◐", text: "Daywatch desk")
    case .nightwatch:
        return NightwatchDeskStatusContent(glyph: "🌙", text: "Nightwatch desk")
    }
}

/// Plain status-bar text naming the active nightwatch desk session when mode != .off.
/// Clicking it focuses the Watch Desk scratch worktree.
///
/// The mode *tint* is deliberately confined to the status bar — the sidebar's
/// `NightwatchModeToggle` still shows and changes the active mode. An earlier
/// iteration washed the whole window with `tintColor(for:)` at 5% opacity, which
/// bled through every pane that paints no background of its own (the transcript
/// most visibly). The bar itself now carries the mode tint —
/// `StatusBarView.statusBarTint(mode:experimentalEnabled:)` owns it — which is
/// why this label paints no background or border of its own.
struct NightwatchDeskStatusLabel: View {
    @EnvironmentObject var appState: AppState

    /// Same experimental opt-in that gates every other nightwatch surface.
    /// Fail-closed: hidden unless the user explicitly turned it on.
    @AppStorage(AppState.nightwatchExperimentalKey) private var nightwatchExperimental: Bool = false

    /// Resolve the "Watch Desk" worktree by fixed display name.
    /// Called only from the tap action — no per-AppState-change rescan.
    private func findDeskWorktree() -> Worktree? {
        // Scratch spaces live only in scratchWorktrees, never in the repo-keyed
        // worktrees dict — allWorktrees resolves both (see AppState.swift).
        return appState.allWorktrees.first {
            $0.displayName == NightwatchDeskPrompts.deskDisplayName && $0.isScratch
        }
    }

    var body: some View {
        if nightwatchExperimental,
           let content = nightwatchDeskStatusContent(for: appState.nightwatchMode) {
            Button(action: focusDeskSession) {
                HStack(spacing: 4) {
                    Text(content.glyph)
                    Text(content.text)
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 8))
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Focus Watch Desk session")
        }
    }

    private func focusDeskSession() {
        if let desk = findDeskWorktree() {
            appState.selectedWorktreeIDs = [desk.id]
        }
    }
}
