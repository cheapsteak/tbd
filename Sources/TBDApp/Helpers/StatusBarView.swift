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
        /// Which worktree this chip is bound to — what the untrack gesture
        /// detaches it from. Carried on the chip rather than threaded through
        /// the view so the whole gesture can be reasoned about as a value.
        let worktreeID: UUID
        /// The PR number, kept alongside the rendered `label` because opening
        /// the PR names its tab `PR #N` and must not have to re-parse "#412".
        let number: Int
        let label: String
        /// The binding named in its own forge's vocabulary (`PR #412` /
        /// `MR !412`), for the tooltip. Carried on the chip rather than
        /// recomposed in the view because the binding — the only thing that
        /// knows the host — does not reach the view.
        let refLabel: String
        /// The PR's own URL, both the open target and how the detach names the
        /// PR to the daemon — a synthetic chip has no row to name by id.
        let url: URL?
        let state: PRMergeableState?
        /// The status's own words for that state, when it has any — the same
        /// `reason ?? state.displayReason` the overflow menu and the toolbar
        /// dropdown render. Carried rather than derived so the three surfaces
        /// cannot describe one observation differently.
        let reason: String?
        /// The PR's title, or nil when it was never observed (a chip lifted
        /// from a cached `Worktree.prStatus` has none). The hover overlay
        /// omits the line rather than fabricating a placeholder.
        let title: String?
        /// When `state` was read. nil = never, which the overlay says out loud
        /// rather than passing the cached state off as current.
        let observedAt: Date?
        /// The clause naming a last poll attempt that did not resolve, or nil
        /// when the last attempt settled the question either way. The toolbar
        /// and sidebar both append it; a chip that omitted it would render the
        /// more confident of two readings of one fact.
        let undetermined: String?
    }

    /// How many chips the bar shows before the rest collapse into `+N`.
    ///
    /// Seven is a judgement about how many numbers are worth scanning at a
    /// glance; past that the dropdown is the better surface. It is not a width
    /// calculation — nothing here consults the available width, and the
    /// overflow count is a pure function of how many bindings there are.
    ///
    /// It buys no width safety either, and the `layoutPriority(-1)` it carries
    /// does not provide any: the path/branch cluster beside it is at the same
    /// priority, so the two are peers in one bucket and share the deficit
    /// rather than one yielding to the other. A narrow window therefore
    /// squeezes both, truncating chip labels and path segments alike rather
    /// than folding chips into the overflow menu — and seven chips reach that
    /// point at a wider window than four did. Width-aware collapsing would be
    /// the real answer and is deliberately not built here.
    nonisolated static let prChipLimit = 7

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

    /// `observation` is the worktree's last poll attempt, carried so the
    /// overlay can say when that attempt did not resolve — the same clause the
    /// toolbar and sidebar append. Without it a chip would render the more
    /// confident of two readings of one fact.
    nonisolated static func prChips(
        _ bindings: [PRBinding],
        limit: Int = prChipLimit,
        observation: PRObservation? = nil
    ) -> (chips: [PRChip], overflow: Int) {
        let selected = PRBindingPresentation.statusBarChips(bindings, limit: limit)
        let undetermined = PRFreshness.undeterminedClause(observation)
        let chips = selected.chips.map { binding in
            PRChip(
                id: binding.id,
                worktreeID: binding.worktreeID,
                number: binding.number,
                label: "#\(binding.number)",
                refLabel: binding.refLabel,
                url: URL(string: binding.url),
                state: binding.status?.state,
                reason: binding.status.map { $0.reason ?? $0.state.displayReason },
                title: binding.title,
                observedAt: binding.status?.observedAt,
                undetermined: undetermined
            )
        }
        return (chips, selected.overflow)
    }

    /// What a chip's hover overlay says: the PR's title, its number, the state
    /// and **when that state was read**.
    ///
    /// The age is not decoration. `PRStatus` is a display-tier cache and was
    /// measured reading "Ready to merge" for pull requests merged days earlier,
    /// so no surface may render it as current truth — the wording comes from
    /// `PRFreshness`, shared with the toolbar and sidebar so the three cannot
    /// describe one observation differently.
    ///
    /// A chip with no observed title renders no title line, and one with no
    /// observed status still gets its number and an honest "unknown time".
    /// Pure, so the whole overlay can be asserted without a panel.
    nonisolated static func chipHoverCard(_ chip: PRChip, now: Date = Date()) -> HoverCardModel {
        var model = HoverCardModel()
        if let title = chip.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            model.title = title
        }
        model.rows = [
            HoverCardRow(label: "PR", value: chip.label),
            HoverCardRow(
                label: "State",
                // The status's own words when it has any, exactly as the
                // overflow menu and the toolbar dropdown render them.
                value: chip.reason ?? unobservedStateValue,
                // Age first, then whether the last attempt to reconfirm it
                // failed — the same two clauses in the same order the toolbar
                // and sidebar compose from `PRFreshness`.
                caption: ([PRFreshness.checkedLabel(observedAt: chip.observedAt, now: now)]
                    + [chip.undetermined].compactMap { $0})
                    .joined(separator: " · ")
            )
        ]
        return model
    }

    /// What the overlay's state row says for a binding nothing has polled yet.
    /// Named so a test can pin it without restating the copy.
    nonisolated static let unobservedStateValue = "No status observed yet"

    /// Tooltip and accessibility label for a chip's untrack target — the xmark
    /// the status dot becomes on hover. It names the worktree scope explicitly
    /// because the gesture removes an association, not the pull request.
    nonisolated static func untrackLabel(_ chip: PRChip) -> String {
        "Stop tracking \(chip.refLabel) in this worktree"
    }

    /// Tooltip and accessibility hint for the chip's own click target, e.g.
    /// `Open PR #412 — Checks failing`.
    nonisolated static func openLabel(_ chip: PRChip) -> String {
        guard let state = chip.state else { return "Open \(chip.refLabel)" }
        return "Open \(chip.refLabel) — \(state.displayReason)"
    }

    /// What the leading icon slot's tooltip says, and therefore what clicking it
    /// does — the two are one function of `isHovering` on purpose.
    ///
    /// The slot draws a status dot at rest and an xmark while hovered, and
    /// `onHover` is not guaranteed to have arrived: chips are inserted and
    /// reflowed under a stationary cursor whenever the selection changes or a
    /// poll adds one. Deriving the meaning from the same flag as the glyph is
    /// what stops a click on a drawn dot from untracking a PR the user meant to
    /// open.
    nonisolated static func iconSlotLabel(_ chip: PRChip, isHovering: Bool) -> String {
        isHovering ? untrackLabel(chip) : openLabel(chip)
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
                    PRChipCluster(bindings: bindings,
                                  observation: appState.prObservations[selected.id])
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
    /// The worktree's last poll attempt, so a chip's overlay can say when that
    /// attempt did not resolve — the clause the toolbar and sidebar append.
    let observation: PRObservation?

    var body: some View {
        let model = StatusBarView.prChips(bindings, observation: observation)
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
///
/// Two click targets, deliberately laid out as **siblings** rather than as a
/// control nested inside a tappable row: the leading icon slot untracks the PR
/// while the chip is hovered, and everything else opens it. An `.onTapGesture`
/// on a common ancestor is exactly the shape that swallows a child's gesture in
/// this codebase, so there is no ancestor gesture to swallow anything — each
/// target owns its own tap, its own tooltip and its own accessibility element.
///
/// The slot's *action* is gated on the same `isHovering` that chooses its
/// *glyph*, so a click always does what the slot is drawing: an xmark untracks,
/// a status dot opens the PR exactly as it did before this control existed.
private struct PRChipView: View {
    @EnvironmentObject var appState: AppState
    let chip: StatusBarView.PRChip

    @State private var isHovering = false

    /// The fixed square the status dot and the untrack xmark share.
    ///
    /// Sized for the LARGER of the two glyphs, with both centred in it, so the
    /// chip is exactly as wide hovered as at rest. A slot that grew on hover
    /// would shove every chip to its right and slide the xmark out from under
    /// the cursor that summoned it.
    private static let iconSlotSide: CGFloat = 9
    /// The drawn xmark's point size — under `iconSlotSide` in both axes.
    private static let xmarkPointSize: CGFloat = 8
    /// The untrack click region, contributed as a transparent **overlay** on
    /// the slot rather than as padding: an overlay is proposed its parent's
    /// size but may choose its own and never pushes a sibling, so a hit area
    /// wider than the glyph costs no layout width. 12pt centred on the 6pt dot
    /// reaches 3pt past the dot on each side, well inside the 6pt gap
    /// `PRChipCluster` puts between chips, so no chip can take a neighbour's
    /// click.
    private static let untrackHitSide: CGFloat = 12
    /// Gap between the icon slot and the number. Applied as leading padding on
    /// the text rather than as `HStack` spacing so the gap belongs to the
    /// open-the-PR target instead of being dead space.
    private static let iconTextGap: CGFloat = 3

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
        HStack(spacing: 0) {
            // Above the number in z-order, so the 1.5pt by which the untrack
            // region overhangs the slot on the trailing side wins the hit test
            // against the text's own leading padding. Later `HStack` children
            // are otherwise drawn — and hit-tested — on top.
            iconSlot.zIndex(1)
            Text(chip.label)
                .lineLimit(1)
                .underline(isHovering)
                .padding(.leading, Self.iconTextGap)
                // The gap beside the number is part of the open target.
                .contentShape(Rectangle())
                // No `.help` here, deliberately: the hover overlay already
                // names this PR, its state and the age of that reading, and a
                // tooltip would surface a second, smaller box saying less on
                // top of it. The icon slot keeps its tooltip because the
                // overlay says nothing about what clicking the slot does.
                // Accessibility is unaffected — the hint below carries the same
                // sentence.
                // Opens the DEFAULT BROWSER, not an in-app tab. Intentional,
                // and the one place the status bar and the toolbar deliberately
                // differ: the toolbar control and its dropdown open a webview
                // tab, while the status bar agrees with the sidebar row
                // indicator and shells out. Not drift — the status bar is an
                // at-a-glance strip, and a click there is a "take me to GitHub"
                // gesture rather than a request to park a tab in the worktree.
                .onTapGesture { open() }
                .accessibilityElement()
                .accessibilityLabel("PR \(chip.label)")
                .accessibilityHint(StatusBarView.openLabel(chip))
                .accessibilityAddTraits(.isButton)
        }
        .foregroundStyle(.secondary)
        // Hover is read on the WHOLE chip, so travelling from the number onto
        // the xmark cannot flip the icon back under the cursor.
        .modifier(StatusBarHoverAffordance(isHovering: $isHovering))
        // Anchored to the whole chip, so the overlay survives the pointer
        // moving from the number onto the xmark.
        .hoverCard(StatusBarView.chipHoverCard(chip))
    }

    /// The fixed-size leading slot: the status dot at rest, the untrack xmark
    /// while the chip is hovered. Both centred in the same square.
    private var iconSlot: some View {
        ZStack {
            if isHovering {
                Image(systemName: "xmark")
                    .font(.system(size: Self.xmarkPointSize, weight: .bold))
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: Self.iconSlotSide, height: Self.iconSlotSide)
        .overlay {
            // Transparent, larger than the slot, and laid over it — sized by
            // this overlay and not by the layout, so it widens the hit area
            // without widening the chip.
            Color.clear
                .frame(width: Self.untrackHitSide, height: Self.untrackHitSide)
                .contentShape(Rectangle())
                // Pointer behaviour follows the SAME `isHovering` that chooses
                // the glyph, so the click can never mean something other than
                // what the slot is drawing — see `iconSlotLabel`.
                .help(StatusBarView.iconSlotLabel(chip, isHovering: isHovering))
                .onTapGesture {
                    if isHovering { detach() } else { open() }
                }
                // Accessibility never hovers, so `isHovering` is false for it
                // and the slot's default action is "open" — which is what the
                // label therefore says. Untracking is offered as a NAMED
                // action instead of the default: a named action cannot be
                // confused with the tap gesture's synthesized one, so the
                // element can never announce one thing and do the other, and a
                // destructive action is better reached deliberately than by
                // activating whatever has focus.
                .accessibilityElement()
                .accessibilityLabel(StatusBarView.iconSlotLabel(chip, isHovering: isHovering))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: Text(StatusBarView.untrackLabel(chip))) { detach() }
        }
    }

    private func open() {
        guard let url = chip.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Untrack by url when the chip has one and by number when it does not — a
    /// legacy cached status can carry a url that will not parse, and the daemon
    /// resolves a bare number against the worktree's own repo. Silently
    /// declining there is the failure this control was added to remove.
    private func detach() {
        Task {
            await appState.detachPR(worktreeID: chip.worktreeID,
                                    url: chip.url?.absoluteString,
                                    number: chip.number)
        }
    }
}

/// The `+N` chip. Clicking it drops down the same list the toolbar's multi-PR
/// dropdown shows — `PRBindingPresentation.menuRows`, in bind order — so the
/// two surfaces cannot describe the same worktree differently.
///
/// It renders **no PR title**, and that is a decision rather than an omission.
/// Titles reach the chips through the hover overlay, which is an ordinary
/// SwiftUI view re-evaluated on every change. A title in these rows would have
/// to survive AppKit's once-only `NSMenu` materialization — the constraint
/// `PRButtonLabel.prSplitButtonID` exists for and `PRSplitButtonIDTests`
/// tripwires — and this `Menu` has no `.id` key to fold it into, so a retitled
/// PR would read stale here for as long as the menu lived. Sharing `menuRows`
/// with the toolbar is also what keeps the two surfaces from disagreeing;
/// forking it for one field would give that up to duplicate what the overlay
/// already says better.
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
