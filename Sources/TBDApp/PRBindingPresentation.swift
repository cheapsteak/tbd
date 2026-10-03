import Foundation
import TBDShared

/// A single row in the multi-PR dropdown menu — the app-facing summary of one
/// `PRBinding`, laid out so the menu can render without touching `PRBinding`
/// fields directly.
struct MenuRow: Identifiable, Equatable {
    let id: UUID
    let number: Int
    let title: String
    let url: URL?
    let state: PRMergeableState?
}

/// Pure presentation helpers for rendering a worktree's set of `PRBinding`s —
/// the toolbar split-button label, its icon, the status-bar chip row, and the
/// dropdown menu rows. Every function here is a plain value transform: no
/// `AppState`, no SwiftUI `@Environment`, no daemon calls. That is deliberate —
/// it lets the toolbar dropdown (Task 11) and status-bar chips (Task 12) be
/// tested without a running app.
///
/// Two different orderings are used on purpose:
/// - `iconBinding` picks the WORST state (via `PRBinding.worst(of:)`), because
///   one icon has to summarize every bound PR.
/// - `statusBarChips`, `statusBarGroups` and `menuRows` preserve BIND ORDER.
///   A row must not move under the user's cursor as CI states change
///   underneath it.
enum PRBindingPresentation {

    /// The bindings every PR surface should render for one worktree.
    ///
    /// Bindings win whenever the worktree has any. With NONE, a persisted
    /// single `PRStatus` is lifted into one synthetic binding so the control
    /// keeps rendering exactly as it did before multi-PR. That fallback is not
    /// hypothetical: with `gh` unavailable or unauthenticated the daemon still
    /// hydrates `Worktree.prStatus`, but every bind attempt fails to resolve a
    /// repo, so the bindings table stays permanently empty — and on first
    /// launch after upgrade the same holds transiently until the first
    /// successful poll. Without this, a user's last-known PR state simply
    /// disappears from the toolbar and the sidebar.
    ///
    /// `detachedCount` is what keeps that fallback from overriding the user.
    /// `tbd pr detach` tombstones a binding rather than deleting it, and
    /// tombstones are excluded from `bindings` — so detaching a worktree's last
    /// PR lands in the same empty list as never having bound one, while nothing
    /// ever clears `Worktree.prStatus`. Without this the toolbar, sidebar dot
    /// and status-bar chip would keep showing the detached PR forever. A
    /// non-zero count means the user has expressed an opinion about this
    /// worktree's PRs, and it outranks a stale cached status.
    ///
    /// Neither bindings nor a status → empty, and no control renders.
    ///
    /// The synthetic binding is built to be VALUE-STABLE across body
    /// evaluations, because it feeds `ForEach` identity in the menu/chip rows,
    /// the split button's `.id` key, and SwiftUI's own view-value diffing. So
    /// `id` is the worktree's own UUID and `boundAt` a fixed sentinel, rather
    /// than the initializer's `UUID()` / `Date()` defaults, which would mint a
    /// different value on every render. The sentinel is also the honest answer:
    /// a lifted legacy status was never bound, so there is no bind time.
    /// `owner`/`repo` are empty because the legacy status carries no repo
    /// coordinates and no app-side surface reads them — only `number`, `url`
    /// and `status` are rendered.
    static func effectiveBindings(
        _ bindings: [PRBinding],
        legacyStatus: PRStatus?,
        worktreeID: UUID,
        detachedCount: Int = 0
    ) -> [PRBinding] {
        guard bindings.isEmpty else { return bindings }
        guard detachedCount == 0 else { return [] }
        guard let status = legacyStatus else { return [] }
        // The status URL is the only forge coordinate a legacy status carries,
        // so the host comes from it rather than from `PRBinding`'s github.com
        // default — a GitLab status lifted with that default would describe
        // itself as a GitHub PR.
        let syntheticHost = URL(string: status.url)?.host ?? "github.com"
        return [PRBinding(
            id: worktreeID,
            worktreeID: worktreeID,
            host: syntheticHost,
            owner: "",
            repo: "",
            number: status.number,
            url: status.url,
            status: status,
            source: .manual,
            boundAt: Date(timeIntervalSince1970: 0)
        )]
    }

    /// The toolbar split-button's label text. `nil` when there is nothing to
    /// show, `"#412"` for exactly one binding (matching the pre-multi-PR
    /// single-PR label), `"3 PRs"` for more.
    static func buttonLabel(_ bindings: [PRBinding]) -> String? {
        switch bindings.count {
        case 0: return nil
        case 1: return "#\(bindings[0].number)"
        default: return "\(bindings.count) PRs"
        }
    }

    /// The binding whose state the toolbar icon should reflect — the one
    /// needing the most attention. Delegates entirely to
    /// `PRBinding.worst(of:)` in TBDShared; this file must not reimplement
    /// worst-state selection.
    static func iconBinding(_ bindings: [PRBinding]) -> PRBinding? {
        PRBinding.worst(of: bindings)
    }

    /// The leading `limit` bindings, in bind order, plus a count of whatever
    /// didn't fit. Bind order (not severity) so a chip doesn't jump around the
    /// status bar as its PR's CI state changes.
    static func statusBarChips(_ bindings: [PRBinding], limit: Int) -> (chips: [PRBinding], overflow: Int) {
        guard limit > 0 else { return ([], bindings.count) }
        let chips = Array(bindings.prefix(limit))
        let overflow = max(0, bindings.count - chips.count)
        return (chips, overflow)
    }

    /// Whether a binding counts as finished for the status bar's done chip: its
    /// last observed state is terminal (`.merged` or `.closed`), the same rule
    /// `PRBinding.allResolved` judges by. A binding with no observed status is
    /// open — nothing says it is done.
    static func isFinished(_ binding: PRBinding) -> Bool {
        binding.status?.state.isTerminal == true
    }

    /// How many finished PRs it takes before the status bar folds them into
    /// one done chip. A single merged PR stays a normal chip: on its own it is
    /// news — the worktree's work shipped — rather than clutter.
    static let doneGroupThreshold = 2

    /// The status bar's PR cluster, split into what renders as chips, what the
    /// `+N` menu lists, and what folds into the done chip.
    ///
    /// With fewer than `doneGroupThreshold` finished bindings this is exactly
    /// `statusBarChips` over every binding, the `+N` menu lists every binding,
    /// and `done` is empty. Past it, the finished bindings leave the chip row
    /// and land in `done`, and the cap, the overflow count and the `+N` menu
    /// all cover the open bindings only. Both groups keep bind order — they are
    /// order-preserving filters of one list — so nothing moves under the
    /// cursor except a PR crossing from open to finished, which is the point.
    static func statusBarGroups(
        _ bindings: [PRBinding], limit: Int
    ) -> (chips: [PRBinding], overflow: Int, overflowMenu: [PRBinding], done: [PRBinding]) {
        var open: [PRBinding] = []
        var done: [PRBinding] = []
        for binding in bindings {
            if isFinished(binding) {
                done.append(binding)
            } else {
                open.append(binding)
            }
        }
        guard done.count >= doneGroupThreshold else {
            let selected = statusBarChips(bindings, limit: limit)
            return (selected.chips, selected.overflow, bindings, [])
        }
        let selected = statusBarChips(open, limit: limit)
        return (selected.chips, selected.overflow, open, done)
    }

    /// Dropdown menu rows, in bind order — the same "don't move under the
    /// cursor" reasoning as `statusBarChips`. Each row's title carries the
    /// request named in its own forge's vocabulary, the one shared sentence
    /// describing its state, and the head branch, e.g.
    /// `"PR #412  Checks failing  fix-login-timeout"` or
    /// `"MR !412  Checks failing  fix-login-timeout"`.
    ///
    /// That sentence comes from `PRStatusPresentation.stateDescription` rather
    /// than being composed here, because these rows share a screen with the
    /// surfaces that use it: the status bar's `+N` menu is opened from beside
    /// the chips themselves, and a multi-PR worktree can show a chip reading
    /// "In merge queue" next to a row that used to say only "Checks pending"
    /// for the very same PR.
    ///
    /// A row describes ONE binding, so it takes the per-binding wording rule
    /// rather than the neutral aggregate one: `refLabel` reads the forge from
    /// that binding's own URL, exactly as the split button's help text does for
    /// a lone binding. A bare `#412` would name a merge request in GitHub's
    /// syntax — `#412` is an issue reference on GitLab, whose own syntax for
    /// this row's subject is `!412`.
    static func menuRows(_ bindings: [PRBinding]) -> [MenuRow] {
        bindings.map { binding in
            var parts = [binding.refLabel]
            if let status = binding.status {
                parts.append(PRStatusPresentation.stateDescription(for: status))
            }
            if let branch = binding.headBranch {
                parts.append(branch)
            }
            return MenuRow(
                id: binding.id,
                number: binding.number,
                title: parts.joined(separator: "  "),
                url: URL(string: binding.url),
                state: binding.status?.state
            )
        }
    }

    /// What a finished PR leads with on the done chip's surfaces: its title,
    /// trimmed and with every internal run of whitespace (a newline or tab
    /// included) collapsed to one space, or its head branch when it has no
    /// title. nil when it has
    /// neither — a synthetic binding lifted from a legacy status carries no
    /// title or branch — and both surfaces then show `doneReference` alone.
    ///
    /// The title leads there, where the `+N` menu leads with the reference,
    /// because a finished PR has no chip of its own: a folded PR's title is
    /// otherwise shown nowhere on the status bar, and a merged branch name is
    /// a poorer reminder of what shipped than the title it shipped under.
    static func doneLead(_ binding: PRBinding) -> String? {
        for candidate in [binding.title, binding.headBranch] {
            let words = (candidate ?? "")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            if !words.isEmpty { return words.joined(separator: " ") }
        }
        return nil
    }

    /// A finished PR's reference and state, e.g. `PR #930 · Merged` or
    /// `MR !931 · Closed` — the one wording both done-chip surfaces use for
    /// it, the menu row after its title and the hover card beneath it, so the
    /// card and the menu one click away cannot spell one PR two ways.
    ///
    /// The reference is the binding's own `refLabel`, in its forge's syntax:
    /// a finished PR has no chip drawing a bare `#930` for it to agree with.
    /// The state is `PRStatusPresentation.stateDescription`, the sentence the
    /// `+N` menu and the toolbar compose with, dropped when blank so the line
    /// never ends in a dangling separator.
    static func doneReference(_ binding: PRBinding) -> String {
        let reference = binding.refLabel
        guard let state = binding.status
                .map({ PRStatusPresentation.stateDescription(for: $0) })?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !state.isEmpty else { return reference }
        return "\(reference) · \(state)"
    }

    /// How many characters of a finished PR's title the done chip's menu row
    /// shows before an ellipsis. AppKit does not truncate a menu item's title,
    /// so one long title would otherwise widen the whole menu. The hover card
    /// wraps instead, under its own, longer `StatusBarView.doneCardLeadLimit`.
    static let doneMenuLeadLimit = 80

    /// `text` cut to at most `limit` characters, the last of them an ellipsis
    /// when anything was cut. Bounds a done-chip lead on surfaces that would
    /// otherwise grow with it.
    static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return text.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// The done chip's menu rows, in bind order: the PR's title (or head
    /// branch) first, then its `doneReference`, e.g.
    /// `"Fix the login timeout  PR #930 · Merged"` or
    /// `"Trim the relay  MR !931 · Closed"`. A binding with neither title nor
    /// branch reads as the reference alone. A lead longer than
    /// `doneMenuLeadLimit` is cut short with an ellipsis.
    ///
    /// A done-chip builder of its own rather than `menuRows`, so the `+N` menu
    /// and the toolbar dropdown keep sharing one row shape. Rows render through
    /// `menuRowsID` exactly as `menuRows`' do — the key reads only `id`,
    /// `title` and `url`.
    static func doneMenuRows(_ bindings: [PRBinding]) -> [MenuRow] {
        bindings.map { binding in
            let reference = doneReference(binding)
            let title = doneLead(binding).map { (lead: String) -> String in
                "\(clipped(lead, to: doneMenuLeadLimit))  \(reference)"
            } ?? reference
            return MenuRow(
                id: binding.id,
                number: binding.number,
                title: title,
                url: URL(string: binding.url),
                state: binding.status?.state
            )
        }
    }

    /// The `.id` key for a `Menu` rendering `menuRows`, keyed on what those
    /// rows actually draw. AppKit materializes an `NSMenu` ONCE and later
    /// SwiftUI state changes do not reach it, so without a key that moves when
    /// the rows do, a row reads stale for as long as the menu lives — the
    /// constraint `PRButtonLabel.prSplitButtonID` exists for, in the smaller
    /// shape a plain menu needs.
    ///
    /// Keyed on the composed `title` rather than on any one field, because the
    /// title is the whole of what a row renders and it folds in every input
    /// that can move underneath it: the queue position (3 → 2 → 1 on every
    /// merge ahead of the PR, and the reason a stale row could contradict the
    /// chip two pixels away), the status `reason`, and the head branch. `url`
    /// joins it because the row's action captures it and `disabled` reads it, so
    /// a re-pointed PR must rebuild the item even with identical text. `id`
    /// pins which binding each row IS, so a reorder or a swap that happens to
    /// preserve the titles still counts as a change.
    ///
    /// Fields go through `PRButtonLabel.escapedIDField` for the same reason
    /// they do there: a title is free text that can contain the key's own
    /// separators, and an unescaped collision does not merely look wrong — it
    /// freezes the menu on the previous set.
    static func menuRowsID(_ rows: [MenuRow]) -> String {
        rows.map { row in
            "\(row.id)-\(PRButtonLabel.escapedIDField(row.title))"
                + "-\(PRButtonLabel.escapedIDField(row.url?.absoluteString))"
        }.joined(separator: "|")
    }

    /// Tooltip for the status bar's `+N` overflow chip.
    ///
    /// The chip is labelled by how many PRs did NOT fit, but its menu lists
    /// EVERY binding it covers — the same rows the toolbar dropdown shows,
    /// deliberately, so the two surfaces cannot describe one worktree
    /// differently. The wording therefore has to lead with the whole list and
    /// mention the overflow count second; "\(overflow) more pull requests"
    /// described a menu this one has never shown.
    ///
    /// "pull request" here is the **aggregate** wording and stays put: this
    /// sentence counts a set, one worktree can hold bindings on both forges at
    /// once, and no forge's own noun would be true of that set. Only text
    /// naming ONE binding takes `refLabel` / `refNoun` — the rows this chip
    /// opens do, and each of them speaks its own forge.
    ///
    /// `openOnly` is true when finished PRs fold into the done chip
    /// (`statusBarGroups`): the menu and `total` then cover the open bindings
    /// only, so the sentence says "open" rather than claiming the menu holds
    /// every PR the worktree has. The done chip lists the rest.
    static func overflowChipTooltip(total: Int, overflow: Int, openOnly: Bool = false) -> String {
        "Show all \(overflowChipCount(total, openOnly: openOnly)) (\(overflow) not shown here)"
    }

    /// Accessibility label for the `+N` overflow chip. Same correction as
    /// `overflowChipTooltip`: the control opens the full list, not the remainder.
    static func overflowChipAccessibilityLabel(
        total: Int, overflow: Int, openOnly: Bool = false
    ) -> String {
        "Show all \(overflowChipCount(total, openOnly: openOnly)), \(overflow) not shown here"
    }

    /// `"7 pull requests"`, or `"7 open pull requests"` when the done chip
    /// holds the finished ones.
    private static func overflowChipCount(_ total: Int, openOnly: Bool) -> String {
        "\(total) \(openOnly ? "open " : "")pull request\(total == 1 ? "" : "s")"
    }

    /// The status bar's done chip label, e.g. `"✓ 5 done"`.
    static func doneChipLabel(count: Int) -> String {
        "\u{2713} \(count) done"
    }

    /// The done chip's hover-card title. Counts a set that can span both
    /// forges, so it takes the aggregate "pull request" wording rather than
    /// any one forge's noun — see `overflowChipTooltip`.
    static func doneChipCardTitle(count: Int) -> String {
        "\(count) merged or closed pull request\(count == 1 ? "" : "s")"
    }

    /// Accessibility label for the done chip: the count, and that activating
    /// it opens their list.
    static func doneChipAccessibilityLabel(count: Int) -> String {
        "Show \(count) merged or closed pull request\(count == 1 ? "" : "s")"
    }
}
