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
        /// The binding named in its own forge's vocabulary (`PR #412` /
        /// `MR !412`), for the tooltip. Carried on the chip rather than
        /// recomposed in the view because the binding — the only thing that
        /// knows the host — does not reach the view.
        let refLabel: String
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
    /// Whether the bar carries the selected worktree's first-message entry.
    ///
    /// Failures only. A `.pending` message is the pane banner's to announce —
    /// it sits right above the terminal the operator is watching and says the
    /// reassuring thing — and this bar is for the case where TBD can see that
    /// nothing will ever receive the text. The two conditions are complements
    /// of one enum, so they cannot both be on, and neither is a guess: the app
    /// says "cannot be delivered" only where it can name why.
    ///
    /// The status bar is the right home for that because it is *scoped to the
    /// selection* and has room for words. The first cut put a glyph on every
    /// sidebar row: always visible, unlabelled, and lighting up for messages
    /// that were merely waiting. Alarming and unreadable at once.
    static func showsParkedPromptEntry(_ readback: ParkedPromptReadback?) -> Bool {
        readback?.phase.undeliverableReason != nil
    }

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
                refLabel: binding.refLabel,
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
            // Failures only; a message merely waiting is the pane banner's.
            // `selected` is nil for a remote worktree, which has no local pane
            // to have parked a prompt against in the first place.
            if let selected,
               Self.showsParkedPromptEntry(
                   appState.parkedPrompt(for: selected.worktree)) {
                ParkedPromptStatusItem(worktree: selected.worktree)
            }
            // the toolbar's PR control.
            if let selected {
                // Same accessor as the toolbar control and the sidebar
                // indicator — bindings when there are any, else the legacy
                // single status lifted into one synthetic binding — so the
                // three surfaces cannot show different PRs for one worktree.
                let bindings = appState.effectivePRBindings(worktreeID: selected.id)
                if !bindings.isEmpty {
                    PRChipCluster(bindings: bindings)
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

    var body: some View {
        let model = StatusBarView.prChips(bindings)
        HStack(spacing: 6) {
            ForEach(model.chips) { chip in
                PRChipView(chip: chip)
            }
            if model.overflow > 0 {
                PRChipOverflowMenu(bindings: bindings, overflow: model.overflow)
            }
        }
    }
}

/// One `● #412` chip. Chrome-less like `CopyableStatusText` — the hover
/// underline plus pointing-hand cursor are the whole affordance.
private struct PRChipView: View {
    let chip: StatusBarView.PRChip

    @State private var isHovering = false

    /// Tooltip and accessibility hint, e.g. `Open PR #412 — Checks failing`,
    /// or `Open MR !412 — Checks failing` for a GitLab binding.
    private var tooltip: String {
        guard let state = chip.state else { return "Open \(chip.refLabel)" }
        return "Open \(chip.refLabel) — \(state.displayReason)"
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
        // Opens the DEFAULT BROWSER, not an in-app tab. Intentional, and the
        // one place the status bar and the toolbar deliberately differ: the
        // toolbar control and its dropdown open a webview tab, while the status
        // bar agrees with the sidebar row indicator and shells out. Not drift —
        // the status bar is an at-a-glance strip, and a click there is a "take
        // me to GitHub" gesture rather than a request to park a tab in the
        // worktree.
        .onTapGesture {
            guard let url = chip.url else { return }
            NSWorkspace.shared.open(url)
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
    let bindings: [PRBinding]
    let overflow: Int

    @State private var isHovering = false

    var body: some View {
        Menu {
            ForEach(PRBindingPresentation.menuRows(bindings)) { row in
                // The default browser, matching the chips beside it — see
                // `PRChipView`'s tap handler for why the status bar differs
                // from the toolbar here.
                Button(row.title) {
                    guard let url = row.url else { return }
                    NSWorkspace.shared.open(url)
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
        // The label counts what didn't fit; the menu lists everything. The
        // wording says so — see `PRBindingPresentation.overflowChipTooltip`.
        .help(PRBindingPresentation.overflowChipTooltip(
            total: bindings.count, overflow: overflow))
        .modifier(StatusBarHoverAffordance(isHovering: $isHovering))
        .accessibilityLabel(PRBindingPresentation.overflowChipAccessibilityLabel(
            total: bindings.count, overflow: overflow))
    }
}

/// The selected worktree's undeliverable first message, as a status-bar entry
/// that opens the composer.
///
/// Labelled, not a bare glyph: an icon cannot say why nothing will receive the
/// text, and the reason is the whole content of the notice. It uses
/// `StatusBarHoverAffordance` rather than wiring `onHover` by hand, so its
/// cursor push can never lose its matching pop.
private struct ParkedPromptStatusItem: View {
    @EnvironmentObject var appState: AppState
    let worktree: Worktree

    @State private var isHovering = false

    private var tooltip: String {
        "This worktree's first message cannot be delivered — nothing here will receive it. Click to read, copy or discard it."
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 11, weight: .semibold))
            Text("First message undelivered")
                .lineLimit(1)
                .underline(isHovering)
        }
        .foregroundStyle(SuffixRowIndicator.attention.color)
        .contentShape(Rectangle())
        .help(tooltip)
        .modifier(StatusBarHoverAffordance(isHovering: $isHovering))
        .onTapGesture { appState.revealParkedPrompt(worktree) }
        .accessibilityElement()
        .accessibilityLabel("First message cannot be delivered for \(worktree.displayName)")
        .accessibilityHint(tooltip)
        .accessibilityAddTraits(.isButton)
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
