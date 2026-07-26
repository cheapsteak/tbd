import SwiftUI
import TBDShared

/// Content displayed in the nightwatch desk status chip.
struct NightwatchBannerContent: Equatable {
    let glyph: String
    let text: String
}

/// Computes the chip content (glyph and text) for a given nightwatch mode.
/// - .off: returns nil (chip hidden)
/// - .daywatch: returns content with "◐" glyph and "Daywatch desk" text
/// - .nightwatch: returns content with "🌙" glyph and "Nightwatch desk" text
func nightwatchBannerContent(for mode: NightwatchMode) -> NightwatchBannerContent? {
    switch mode {
    case .off:
        return nil
    case .daywatch:
        return NightwatchBannerContent(glyph: "◐", text: "Daywatch desk")
    case .nightwatch:
        return NightwatchBannerContent(glyph: "🌙", text: "Nightwatch desk")
    }
}

/// Compact status-bar chip showing the active nightwatch desk session when mode != .off.
/// Clicking it focuses the Watch Desk scratch worktree.
///
/// Mode indication is deliberately confined to the status bar. An earlier
/// iteration washed the whole window with `tintColor(for:)` at 5% opacity, which
/// bled through every pane that paints no background of its own (the transcript
/// most visibly). This chip is the only in-window surface that carries the mode
/// tint.
struct NightwatchDeskStatusChip: View {
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
           let content = nightwatchBannerContent(for: appState.nightwatchMode) {
            let tint = tintColor(for: appState.nightwatchMode) ?? .gray
            Button(action: focusDeskSession) {
                HStack(spacing: 4) {
                    Text(content.glyph)
                    Text(content.text)
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 8))
                }
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(tint.opacity(0.15))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(tint.opacity(0.3), lineWidth: 1)
                )
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
