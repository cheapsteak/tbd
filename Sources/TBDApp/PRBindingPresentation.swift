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
        worktreeID: UUID
    ) -> [PRBinding] {
        guard bindings.isEmpty else { return bindings }
        guard let status = legacyStatus else { return [] }
        return [PRBinding(
            id: worktreeID,
            worktreeID: worktreeID,
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
    /// cursor" reasoning as `statusBarChips`. Each row's title carries the PR
    /// number, its human-readable reason (falling back to the state's default
    /// when `PRStatus.reason` is nil), and the head branch, e.g.
    /// `"#412  Checks failing  fix-login-timeout"`.
    static func menuRows(_ bindings: [PRBinding]) -> [MenuRow] {
        bindings.map { binding in
            var parts = ["#\(binding.number)"]
            if let status = binding.status {
                parts.append(status.reason ?? status.state.displayReason)
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
}
