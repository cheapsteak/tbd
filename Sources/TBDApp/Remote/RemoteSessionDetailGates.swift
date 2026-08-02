import Foundation
import TBDShared

/// Pure capability gates behind `RemoteSessionDetailView` — which tabs a
/// provider's capabilities make available, which tab to land/re-land on,
/// whether the tab picker renders, and whether the Send footer renders.
/// Mirrors `RemoteSessionActionMenu`'s split: no SwiftUI here, so every gate
/// is directly unit-testable without a view hierarchy or `AppState`.
///
/// These three gates used to be inline conditionals in the view, with
/// `selectedTab` defaulting to `.attach` regardless of what the provider
/// actually declared. For a `log`-only provider that left `availableTabs ==
/// [.log]`: the picker was suppressed (only shown for >1 tab) AND the
/// content area rendered nothing (the attach branch was gated false, the log
/// branch required `selectedTab == .log`, which nothing ever corrected in
/// the steady state — the `.onChange(of:)` two-parameter overload doesn't
/// fire for the INITIAL value). Extracting the decisions here, and having
/// the view derive what to render from `initialTab` rather than trust
/// `selectedTab` alone, makes that permanently-blank-pane state
/// unrepresentable instead of merely rare.
enum RemoteSessionDetailGates {
    /// The `describe.capabilities` string each optional gate checks — named
    /// constants (not re-typed at each call site) so a typo can't silently
    /// make a gate always false.
    private static let attachCapability = "attach"
    private static let logCapability = "log"
    private static let sendCapability = "send"

    /// Ordered tabs available for a provider's declared capabilities. Attach
    /// first, then Log — matches `RemoteSessionDetailTab`'s declaration
    /// order. Empty when the provider declares neither (the view renders its
    /// "doesn't support attach or a log view" empty state instead).
    ///
    /// `gone` drops Attach even when the provider declares the capability —
    /// consistent with `RemoteSessionActionMenu.items(gone:)`, which
    /// collapses a tombstone row's context menu to exactly Copy Session ID +
    /// Dismiss: starting a new interactive attach against a session the
    /// provider no longer reports isn't meaningful. Log stays available when
    /// `gone` — reading a dead session's last scrollback is still useful.
    static func available(capabilities: [String], gone: Bool) -> [RemoteSessionDetailTab] {
        var tabs: [RemoteSessionDetailTab] = []
        if !gone, capabilities.contains(attachCapability) { tabs.append(.attach) }
        if capabilities.contains(logCapability) { tabs.append(.log) }
        return tabs
    }

    /// The tab to show: `requested` when it's one of `available`, otherwise
    /// `available`'s first tab, otherwise nil (nothing to show — `available`
    /// is empty, the empty state renders instead). Never returns a tab
    /// absent from `available`, so a caller that always renders based on
    /// this result — rather than trusting a separately-tracked `selectedTab`
    /// to already be valid — can't land on a blank pane, regardless of
    /// timing: this is safe to call from the very first `body` evaluation,
    /// not just from `onAppear`/`onChange`.
    static func initialTab(
        available: [RemoteSessionDetailTab], requested: RemoteSessionDetailTab?
    ) -> RemoteSessionDetailTab? {
        if let requested, available.contains(requested) { return requested }
        return available.first
    }

    /// Whether the segmented tab picker renders — only when there's an
    /// actual choice between tabs. A single available tab (or zero) must
    /// still render its content; it just does so unconditionally rather than
    /// via a picker selection.
    static func showsPicker(available: [RemoteSessionDetailTab]) -> Bool {
        available.count > 1
    }

    /// Whether the Send footer renders. `gone` suppresses it for the same
    /// reason `available` drops Attach: sending input to a session the
    /// provider no longer reports isn't meaningful, and mutating a session
    /// from a stale snapshot is unsafe. This keeps the detail view consistent
    /// with the context menu, which drops Send Text… in both cases.
    static func showsSendField(
        capabilities: [String], gone: Bool, snapshotFresh: Bool = true
    ) -> Bool {
        snapshotFresh && !gone && capabilities.contains(sendCapability)
    }
}
