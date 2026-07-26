import AppKit
import SwiftUI
import TBDShared

struct StatusBarView: View {
    @EnvironmentObject var appState: AppState

    /// Same experimental opt-in that gates every other nightwatch surface.
    /// Fail-closed: no tint unless the user explicitly turned it on.
    @AppStorage(AppState.nightwatchExperimentalKey) private var nightwatchExperimental: Bool = false

    /// Opacity the mode tint is layered over the bar's `.bar` material at.
    ///
    /// One value serves both modes and both appearances — measured, not guessed:
    ///
    /// - Light appearance, `.bar` composites to ~white. At 18% the bar becomes
    ///   (221, 225, 236) for nightwatch and (247, 239, 230) for daywatch, keeping
    ///   `.primary` ink at 12.2:1 and 13.6:1 respectively (untinted baseline is
    ///   15.1:1). `.secondary` ink tracks its backdrop, so it barely moves at all:
    ///   3.95:1 untinted → 3.85/3.78:1 tinted.
    /// - Dark appearance needs no special case. 18% of a mid-luminance tint over
    ///   a ~(40, 40, 40) bar lands at (43, 49, 60) / (71, 62, 54), i.e. still
    ///   dark, and white text stays at 13.1:1 / 10.5:1.
    ///
    /// The two tints differ in luminance (amber is far lighter), so nightwatch
    /// reads as the stronger wash. Their *hue* shift — the part that actually
    /// distinguishes the modes — is near-identical at this opacity, and the
    /// luminance asymmetry matches the semantics, so a per-mode opacity is not
    /// worth the branch.
    static let tintOpacity: Double = 0.18

    /// The mode tint the status bar paints over its `.bar` material, or nil for
    /// no tint. Pure so it is testable without instantiating the view.
    static func statusBarTint(mode: NightwatchMode, experimentalEnabled: Bool) -> Color? {
        guard experimentalEnabled else { return nil }
        return tintColor(for: mode)
    }

    /// Path + repo of the resolved single-selected worktree (nil when it has
    /// no path yet). The caller resolves the selection once per body
    /// evaluation and passes it in, so this never re-runs `findWorktree`.
    private static func selectedWorktreeInfo(_ worktree: Worktree?) -> (path: String, repoID: UUID?)? {
        guard let worktree, !worktree.path.isEmpty else { return nil }
        return (worktree.path, worktree.repoID)
    }

    /// Resolved once per process: the absolute path of the worktree that built
    /// this running TBDApp. Primary source is a sidecar file written into the
    /// bundle by `scripts/restart.sh`; falls back to parsing the exec path for
    /// the legacy in-place `.build/debug/TBD.app` launch shape.
    private static let sourceWorktreePath: String? = resolveSourceWorktreePath(
        bundleURL: Bundle.main.bundleURL,
        executablePath: Bundle.main.executablePath
    )

    /// Pure helper extracted so tests can exercise it without a real bundle.
    /// Tries the sidecar file first, then the exec-path heuristic.
    /// Delegates to SourceWorktreePathResolver for the actual resolution logic.
    static func resolveSourceWorktreePath(
        bundleURL: URL,
        executablePath: String?,
        sidecarReader: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }
    ) -> String? {
        SourceWorktreePathResolver.resolve(
            bundleURL: bundleURL,
            executablePath: executablePath,
            sidecarReader: sidecarReader
        )
    }

    private var footerLabel: (text: String, tooltip: String?) {
        let version = "v\(TBDConstants.version)"
        guard let sourcePath = Self.sourceWorktreePath,
              let worktree = appState.worktrees.values.flatMap({ $0 }).first(where: { $0.path == sourcePath }) else {
            return (version, nil)
        }
        return (worktree.displayName, version)
    }

    var body: some View {
        // Resolve the single-selected worktree ONCE per body evaluation —
        // selectedWorktreeInfo (the editor button) uses it, instead of
        // re-running findWorktree per render.
        let selected = appState.selectedWorktreeIDs.count == 1
            ? appState.selectedWorktreeIDs.first.flatMap { appState.findWorktree(id: $0) }
            : nil
        let selectedInfo = Self.selectedWorktreeInfo(selected)
        HStack {
            // The nightwatch/daywatch mode *tint* is confined to this bar; the
            // sidebar's NightwatchModeToggle stays the in-window control for
            // changing mode. The label self-hides when mode is .off or the
            // experimental flag is unset, matching the bar tint below.
            NightwatchDeskStatusLabel()
            Spacer()
            if let info = selectedInfo {
                OpenInEditorButton(path: info.path, repoID: info.repoID)
            }
            let footer = footerLabel
            if let tooltip = footer.tooltip {
                Text(footer.text)
                    .foregroundStyle(.secondary)
                    .help(tooltip)
            } else {
                Text(footer.text)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal)
        .padding(.vertical, 4)
        // The bar keeps its native `.bar` material; the mode tint is layered on
        // top of it but still BEHIND the bar's text. Both layers live in one
        // background because chaining `.background(.bar).background(tint)` would
        // put the tint *behind* the material (later backgrounds sit further
        // back), and `.overlay` would put it in front of the text and wash it.
        .background {
            ZStack {
                Rectangle().fill(.bar)
                if let tint = Self.statusBarTint(
                    mode: appState.nightwatchMode,
                    experimentalEnabled: nightwatchExperimental
                ) {
                    tint.opacity(Self.tintOpacity)
                }
            }
        }
    }
}
