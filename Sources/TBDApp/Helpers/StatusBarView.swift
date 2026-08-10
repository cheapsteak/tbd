import AppKit
import SwiftUI
import TBDShared

struct StatusBarView: View {
    @EnvironmentObject var appState: AppState

    /// Path + repo of the resolved single-selected worktree. Taking a
    /// `LocalWorktree?` is what makes "nil when it has no path yet" true —
    /// the wrapper refuses an empty path, so no hand-written guard is needed.
    /// The caller resolves the selection once per body evaluation and passes
    /// it in, so this never re-runs `findWorktree`.
    private static func selectedWorktreeInfo(_ worktree: LocalWorktree?) -> (path: String, repoID: UUID?)? {
        guard let worktree else { return nil }
        return (worktree.path, worktree.repoID)
    }

    /// The bottom-left cluster: where the selected worktree lives on disk and
    /// which branch it is on. `displayPath` is tilde-abbreviated for display
    /// only — `path` is the full value that lands on the pasteboard.
    struct LocationLabel: Equatable {
        let path: String
        let displayPath: String
        /// nil when the worktree has no branch (scratch spaces).
        let branch: String?
    }

    /// Pure helper so tests can exercise the formatting without a view.
    /// `home` is injected for the same reason.
    static func locationLabel(
        _ worktree: LocalWorktree?,
        home: String = NSHomeDirectory()
    ) -> LocationLabel? {
        guard let worktree else { return nil }
        let branch = worktree.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return LocationLabel(
            path: worktree.path,
            displayPath: abbreviateWithTilde(worktree.path, home: home),
            branch: branch.isEmpty ? nil : branch
        )
    }

    /// Tilde-abbreviates `path` against `home`, matching only whole path
    /// components so a sibling directory like `/Users/meadow` under a home of
    /// `/Users/me` is left alone.
    static func abbreviateWithTilde(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
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

    /// One status-bar PR chip: a status dot plus `#N` that opens that PR.
    /// A plain value so the row can be asserted without a view — `state` is
    /// what the dot's color is derived from, and `id` is the binding's own id
    /// so a chip keeps its identity across status refreshes.
    ///
    /// `nonisolated` throughout — `StatusBarView`'s `View` conformance infers
    /// whole-type `@MainActor` isolation onto even a nested value type, and a
    /// main-actor `init` called from a nonisolated `map` closure traps at
    /// runtime rather than failing to compile (same reason
    /// `WorktreeRowView.rowHeight` is `nonisolated`).
    nonisolated struct PRChip: Identifiable, Equatable {
        let id: UUID
        /// The PR number, kept alongside the rendered `label` because opening
        /// the PR names its tab `PR #N` and must not have to re-parse "#412".
        let number: Int
        let label: String
        let url: URL?
        let state: PRMergeableState?
    }

    /// How many chips the bar shows before the rest collapse into `+N`. Four
    /// keeps the cluster narrower than the path it sits beside on a typical
    /// window; past that the dropdown is the better surface.
    nonisolated static let prChipLimit = 4

    /// The chip row for `bindings`, plus how many did not fit. Pure: delegates
    /// the cap and the bind-order guarantee to `PRBindingPresentation` so the
    /// status bar cannot disagree with the toolbar about which PRs are shown
    /// or in what order.
    nonisolated static func prChips(
        _ bindings: [PRBinding],
        limit: Int = prChipLimit
    ) -> (chips: [PRChip], overflow: Int) {
        let selected = PRBindingPresentation.statusBarChips(bindings, limit: limit)
        let chips = selected.chips.map { binding in
            PRChip(
                id: binding.id,
                number: binding.number,
                label: "#\(binding.number)",
                url: URL(string: binding.url),
                state: binding.status?.state
            )
        }
        return (chips, selected.overflow)
    }

    private var footerLabel: (text: String, tooltip: String?) {
        let version = "v\(TBDConstants.version)"
        guard let sourcePath = Self.sourceWorktreePath,
              let worktree = appState.worktrees.values.flatMap({ $0 }).first(where: { $0.localPath == sourcePath }) else {
            return (version, nil)
        }
        return (worktree.displayName, version)
    }

    var body: some View {
        // Resolve the single-selected worktree ONCE per body evaluation —
        // selectedWorktreeInfo (the editor button) uses it, instead of
        // re-running findWorktree per render.
        let selected = appState.selectedWorktreeIDs.count == 1
            ? appState.selectedWorktreeIDs.first
                .flatMap { appState.findWorktree(id: $0) }
                .flatMap(LocalWorktree.init)
            : nil
        let selectedInfo = Self.selectedWorktreeInfo(selected)
        HStack {
            if let location = Self.locationLabel(selected) {
                HStack(spacing: 8) {
                    CopyableStatusText(
                        text: location.displayPath,
                        copyValue: location.path,
                        truncation: .head,
                        tooltip: "Click to copy \(location.path)",
                        confirmation: "Copied path"
                    )
                    if let branch = location.branch {
                        // The branch glyph doubles as the separator from the
                        // path, so no interpunct is needed between them.
                        CopyableStatusText(
                            icon: GitBranchIcon(),
                            text: branch,
                            copyValue: branch,
                            truncation: .tail,
                            tooltip: "Click to copy branch \(branch)",
                            confirmation: "Copied branch"
                        )
                    }
                }
                // Yields to the version/display-name label on the right, which
                // is short and must never truncate.
                .layoutPriority(-1)
            }
            // Chips render for a SINGLE selection only — `selected` is already
            // nil for a multi-selection, matching the path/branch cluster and
            // the toolbar's PR control.
            if let selected {
                let bindings = appState.prBindings[selected.id] ?? []
                if !bindings.isEmpty {
                    PRChipCluster(bindings: bindings, worktreeID: selected.id)
                        // Same reason as the path cluster: yield width to the
                        // version/display-name label rather than squeezing it.
                        .layoutPriority(-1)
                }
            }
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
        .background(.bar)
    }
}

/// The status bar's shared hover affordance: a pointing-hand cursor pushed on
/// enter and popped on exit.
///
/// The `onDisappear` arm is the load-bearing half. Selecting a different
/// worktree tears these labels down while the pointer is still over them, and
/// an `NSCursor.push()` with no matching `pop()` leaves the pointing hand stuck
/// for the whole application — there is no later event that would balance it.
/// Every hoverable status-bar label must use this modifier rather than wiring
/// `onHover` by hand, so the two halves can never drift apart.
private struct StatusBarHoverAffordance: ViewModifier {
    @Binding var isHovering: Bool

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                guard hovering != isHovering else { return }
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    isHovering = false
                    NSCursor.pop()
                }
            }
    }
}

/// The status bar's PR cluster: one chip per bound PR up to
/// `StatusBarView.prChipLimit`, then a `+N` chip listing the rest.
private struct PRChipCluster: View {
    let bindings: [PRBinding]
    /// The worktree the chips belong to — the one whose tab strip a click
    /// opens the PR in. Passed down rather than read off a binding so the
    /// cluster targets the same worktree the status bar is describing.
    let worktreeID: UUID

    var body: some View {
        let model = StatusBarView.prChips(bindings)
        HStack(spacing: 6) {
            ForEach(model.chips) { chip in
                PRChipView(chip: chip, worktreeID: worktreeID)
            }
            if model.overflow > 0 {
                PRChipOverflowMenu(bindings: bindings, overflow: model.overflow, worktreeID: worktreeID)
            }
        }
    }
}

/// One `● #412` chip. Chrome-less like `CopyableStatusText` — the hover
/// underline plus pointing-hand cursor are the whole affordance.
private struct PRChipView: View {
    @EnvironmentObject var appState: AppState

    let chip: StatusBarView.PRChip
    let worktreeID: UUID

    @State private var isHovering = false

    /// Tooltip and accessibility hint, e.g. `Open PR #412 — Checks failing`.
    private var tooltip: String {
        guard let state = chip.state else { return "Open PR \(chip.label)" }
        return "Open PR \(chip.label) — \(state.displayReason)"
    }

    /// The dot color, taken from the shared PR palette so a chip cannot drift
    /// from the sidebar glyph or the toolbar icon for the same state. The
    /// synthetic `PRStatus` exists only to reach that palette — `make(for:)`
    /// reads nothing but `state` once `mergeQueuePosition` is nil.
    private var dotColor: Color {
        guard let state = chip.state,
              let presentation = PRStatusPresentation.make(
                for: PRStatus(number: 0, url: "", state: state)
              ) else { return .secondary }
        return presentation.color
    }

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(chip.label)
                .lineLimit(1)
                .underline(isHovering)
        }
        .foregroundStyle(.secondary)
        // The dot and the gap beside it are part of the click target.
        .contentShape(Rectangle())
        .help(tooltip)
        .modifier(StatusBarHoverAffordance(isHovering: $isHovering))
        // Same helper the toolbar's split button and dropdown rows use, so a
        // chip and a toolbar row for the same PR land in the same tab —
        // in-app webview, reused by URL, ⌘-click for the default browser.
        .onTapGesture {
            guard let url = chip.url else { return }
            appState.openPR(url: url, number: chip.number, worktreeID: worktreeID)
        }
        .accessibilityElement()
        .accessibilityLabel("PR \(chip.label)")
        .accessibilityHint(tooltip)
        .accessibilityAddTraits(.isButton)
    }
}

/// The `+N` chip. Clicking it drops down the same list the toolbar's multi-PR
/// dropdown shows — `PRBindingPresentation.menuRows`, in bind order — so the
/// two surfaces cannot describe the same worktree differently.
private struct PRChipOverflowMenu: View {
    @EnvironmentObject var appState: AppState

    let bindings: [PRBinding]
    let overflow: Int
    let worktreeID: UUID

    @State private var isHovering = false

    var body: some View {
        Menu {
            ForEach(PRBindingPresentation.menuRows(bindings)) { row in
                Button(row.title) {
                    guard let url = row.url else { return }
                    appState.openPR(url: url, number: row.number, worktreeID: worktreeID)
                }
                .disabled(row.url == nil)
            }
        } label: {
            Text("+\(overflow)")
                .lineLimit(1)
                .underline(isHovering)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(overflow) more pull request\(overflow == 1 ? "" : "s")")
        .modifier(StatusBarHoverAffordance(isHovering: $isHovering))
        .accessibilityLabel("\(overflow) more pull requests")
    }
}

/// A deliberately chrome-less status-bar label that copies `copyValue` on
/// click. It carries no button styling — the hover underline plus pointing-hand
/// cursor are the whole affordance, and the toast is what confirms the copy
/// landed (the label itself is too small to flash a "Copied" state legibly).
private struct CopyableStatusText: View {
    @EnvironmentObject var appState: AppState

    /// Optional leading glyph naming what the value is. Part of the same click
    /// target and hover affordance as the text.
    var icon: GitBranchIcon?
    let text: String
    let copyValue: String
    let truncation: Text.TruncationMode
    let tooltip: String
    let confirmation: String

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                // Sized to the caption text this bar is set in; the glyph's
                // own grid has generous padding, so it optically matches.
                icon.frame(width: 11, height: 11)
            }
            Text(text)
                .lineLimit(1)
                .truncationMode(truncation)
                .underline(isHovering)
        }
            .foregroundStyle(.secondary)
            // Makes the icon and the gap beside it part of the click target,
            // not just the glyphs.
            .contentShape(Rectangle())
            .help(tooltip)
            .modifier(StatusBarHoverAffordance(isHovering: $isHovering))
            .onTapGesture {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyValue, forType: .string)
                appState.showTransientToast(confirmation, style: .success)
            }
            .accessibilityElement()
            .accessibilityLabel(text)
            .accessibilityHint(tooltip)
            .accessibilityAddTraits(.isButton)
    }
}
