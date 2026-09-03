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
/// - `statusBarChips` and `menuRows` preserve BIND ORDER. A row must not move
///   under the user's cursor as CI states change underneath it.
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
    /// EVERY binding — the same rows the toolbar dropdown shows, deliberately,
    /// so the two surfaces cannot describe one worktree differently. The wording
    /// therefore has to lead with the whole list and mention the overflow count
    /// second; "\(overflow) more pull requests" described a menu this one has
    /// never shown.
    ///
    /// "pull request" here is the **aggregate** wording and stays put: this
    /// sentence counts a set, one worktree can hold bindings on both forges at
    /// once, and no forge's own noun would be true of that set. Only text
    /// naming ONE binding takes `refLabel` / `refNoun` — the rows this chip
    /// opens do, and each of them speaks its own forge.
    static func overflowChipTooltip(total: Int, overflow: Int) -> String {
        "Show all \(total) pull request\(total == 1 ? "" : "s") (\(overflow) not shown here)"
    }

    /// Accessibility label for the `+N` overflow chip. Same correction as
    /// `overflowChipTooltip`: the control opens the full list, not the remainder.
    static func overflowChipAccessibilityLabel(total: Int, overflow: Int) -> String {
        "Show all \(total) pull request\(total == 1 ? "" : "s"), \(overflow) not shown here"
    }
}
