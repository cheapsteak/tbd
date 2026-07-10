import SwiftUI
import TBDShared

/// Content displayed in the nightwatch desk status banner.
struct NightwatchBannerContent: Equatable {
    let glyph: String
    let text: String
}

/// Computes the banner content (glyph and text) for a given nightwatch mode.
/// - .off: returns nil (banner hidden)
/// - .daywatch: returns content with "◐" glyph and "Daywatch — desk session active" text
/// - .nightwatch: returns content with "🌙" glyph and "Nightwatch — desk session active" text
func nightwatchBannerContent(for mode: NightwatchMode) -> NightwatchBannerContent? {
    switch mode {
    case .off:
        return nil
    case .daywatch:
        return NightwatchBannerContent(glyph: "◐", text: "Daywatch — desk session active")
    case .nightwatch:
        return NightwatchBannerContent(glyph: "🌙", text: "Nightwatch — desk session active")
    }
}

/// Banner showing the active nightwatch desk session status when mode != .off.
/// Displays: "◐ Daywatch — desk session active" with click-through to focus the desk.
struct NightwatchDeskStatusBanner: View {
    @EnvironmentObject var appState: AppState
    @State private var deskWorktree: Worktree?

    /// Resolve the "Watch Desk" worktree by fixed display name.
    private func findDeskWorktree() -> Worktree? {
        // Scratch spaces live only in scratchWorktrees, never in the repo-keyed
        // worktrees dict — allWorktrees resolves both (see AppState.swift).
        return appState.allWorktrees.first { $0.displayName == NightwatchDeskPrompts.deskDisplayName && $0.isScratch }
    }

    /// Returns the banner text and glyph based on current mode.
    private var bannerContent: NightwatchBannerContent? {
        nightwatchBannerContent(for: appState.nightwatchMode)
    }

    var body: some View {
        if let content = bannerContent {
            Button(action: focusDeskSession) {
                HStack(spacing: 8) {
                    Text(content.glyph)
                        .font(.system(size: 14, weight: .semibold))
                    Text(content.text)
                        .font(.caption)
                    Spacer()
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 10))
                }
                .padding(8)
                .background(
                    (tintColor(for: appState.nightwatchMode) ?? .gray)
                        .opacity(0.15)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            (tintColor(for: appState.nightwatchMode) ?? .gray)
                                .opacity(0.3),
                            lineWidth: 1
                        )
                )
            }
            .buttonStyle(.plain)
            .help("Focus Watch Desk session")
            .onAppear {
                // Only update desk worktree lookup when mode is active (not .off)
                if appState.nightwatchMode != .off {
                    deskWorktree = findDeskWorktree()
                }
            }
            .onReceive(appState.objectWillChange) { _ in
                // Gate desk lookup on mode != .off (MINOR: optimization)
                if appState.nightwatchMode != .off {
                    deskWorktree = findDeskWorktree()
                } else {
                    deskWorktree = nil
                }
            }
        }
    }

    private func focusDeskSession() {
        if let desk = deskWorktree ?? findDeskWorktree() {
            appState.selectedWorktreeIDs = [desk.id]
        }
    }
}

/// Helper for mode-themed colors. Consolidated: single tint color for both background and border.

// #Preview disabled — PreviewsMacros plugin unavailable in this build context
// #Preview {
//    VStack(spacing: 0) {
//        NightwatchDeskStatusBanner()
//            .environmentObject({
//                let state = AppState()
//                state.nightwatchMode = .daywatch
//                return state
//            }())
//
//        Text("Content area")
//            .padding()
//            .frame(maxWidth: .infinity, maxHeight: .infinity)
//    }
