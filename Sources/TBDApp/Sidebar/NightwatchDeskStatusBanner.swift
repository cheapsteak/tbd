import SwiftUI
import TBDShared

/// Banner showing the active nightwatch desk session status when mode != .off.
/// Displays: "◐ Daywatch — desk session active" with click-through to focus the desk.
struct NightwatchDeskStatusBanner: View {
    @EnvironmentObject var appState: AppState
    @State private var deskWorktree: Worktree?

    /// Resolve the "Watch Desk" worktree by fixed display name.
    private func findDeskWorktree() -> Worktree? {
        let allWorktrees = appState.worktrees.values.flatMap { $0 }
        return allWorktrees.first { $0.displayName == NightwatchDeskPrompts.deskDisplayName && $0.isScratch }
    }

    /// Returns the banner text and glyph based on current mode.
    private var bannerContent: (glyph: String, text: String)? {
        switch appState.nightwatchMode {
        case .off:
            return nil
        case .daywatch:
            return ("◐", "Daywatch — desk session active")
        case .nightwatch:
            return ("🌙", "Nightwatch — desk session active")
        }
    }

    var body: some View {
        if let content = bannerContent {
            HStack(spacing: 8) {
                Text(content.glyph)
                    .font(.system(size: 14, weight: .semibold))
                Text(content.text)
                    .font(.caption)
                Spacer()
                Button(action: focusDeskSession) {
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Focus Watch Desk session")
            }
            .padding(8)
            .background(
                NightwatchModeTheme.backgroundColor(for: appState.nightwatchMode)
                    .opacity(0.15)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(
                        NightwatchModeTheme.accentColor(for: appState.nightwatchMode)
                            .opacity(0.3),
                        lineWidth: 1
                    )
            )
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

/// Helper for mode-themed colors.
enum NightwatchModeTheme {
    static func accentColor(for mode: NightwatchMode) -> Color {
        switch mode {
        case .off: return .gray
        case .daywatch: return .orange
        case .nightwatch: return .purple
        }
    }

    static func backgroundColor(for mode: NightwatchMode) -> Color {
        switch mode {
        case .off: return .gray
        case .daywatch: return .orange
        case .nightwatch: return .purple
        }
    }
}

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
// }
