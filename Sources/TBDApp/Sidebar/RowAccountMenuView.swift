import SwiftUI
import TBDShared

/// Hover-revealed "…" menu for a worktree row — the shared action list.
///
/// Structure, top to bottom:
///   [account section: per-session info + "Switch account" submenu]
///   Divider
///   [the shared `RowActionMenu` actions — identical to the right-click menu]
///
/// The account section lowers `RowAccountMenu.Model` (composition in the
/// testable helper); the action tail renders the shared `RowActionMenu` items
/// through `RowActionMenuActions`, so the "…" menu and the right-click
/// `SidebarContextMenu` can never drift.
struct RowAccountMenuView: View {
    let worktree: Worktree
    var onRename: () -> Void
    @EnvironmentObject var appState: AppState

    /// Subtle hover fill on the ellipsis label. A `Menu` with
    /// `.menuStyle(.borderlessButton)` does not apply the outer
    /// `HoverPressButtonStyle` fill to its label, so we drive the same look
    /// (cornerRadius 4, `Color.primary.opacity(0.08)` on hover) here directly to
    /// match the sibling "+" button.
    @State private var isHovering = false

    private var menuModel: RowAccountMenu.Model {
        RowAccountMenu.model(
            terminals: appState.terminals[worktree.id] ?? [],
            profiles: appState.modelProfiles
        )
    }

    private var actions: RowActionMenuActions {
        RowActionMenuActions(appState: appState, worktree: worktree, onRename: onRename)
    }

    var body: some View {
        Menu {
            menuContent(menuModel)
            Divider()
            RowActionMenuItemsView(actions: actions, includeSessionForks: false)
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .help("Session actions")
    }

    @ViewBuilder
    private func menuContent(_ model: RowAccountMenu.Model) -> some View {
        if model.isEmpty {
            Button("No Claude sessions") {}.disabled(true)
        } else {
            ForEach(model.sessions) { session in
                sessionSection(session)
            }
            Divider()
            Text(model.footer).font(.caption)
        }
    }

    @ViewBuilder
    private func sessionSection(_ session: RowAccountMenu.Session) -> some View {
        // Info header: session label + its current account.
        Button("\(session.label) — \(session.accountDescriptor)") {}
            .disabled(true)
        // Fork this conversation into a new tab on the same account.
        if let fork = forkAction(for: session.terminalID) {
            Button(fork.title) { actions.run(fork.kind) }
        }
        Menu(RowAccountMenu.switchAccountLabel) {
            ForEach(session.switchTargets) { target in
                switchTargetButton(session: session, target: target)
            }
        }
    }

    /// The fork-session action for a given terminal (matched from the shared
    /// per-session fork list), so the "…" menu renders fork alongside the
    /// session's switch submenu.
    private func forkAction(for terminalID: UUID) -> RowActionMenu.Action? {
        actions.sessionForkActions().first {
            if case let .forkSession(id, _) = $0.kind { return id == terminalID }
            return false
        }
    }

    @ViewBuilder
    private func switchTargetButton(session: RowAccountMenu.Session,
                                    target: RowAccountMenu.SwitchTarget) -> some View {
        if let action = target.action(terminalID: session.terminalID) {
            Button(action: { dispatch(action) }) {
                Text(Self.twoLineLabel(primary: "  \(target.line.primary)",
                                       secondary: target.line.secondary))
            }
        } else {
            // Disabled: current account (checkmark) or not-logged-in (hint).
            let prefix = target.isCurrent ? "✓ " : "  "
            let suffix = target.disabledReason.map { " — \($0)" } ?? ""
            Button {
            } label: {
                Text(Self.twoLineLabel(primary: "\(prefix)\(target.line.primary)\(suffix)",
                                       secondary: target.line.secondary))
            }
            .disabled(true)
        }
    }

    /// Renders a menu row on two lines inside a SwiftUI `Menu`. macOS menus
    /// flatten a `VStack`-based `Button` label to a single line and drop its
    /// per-`Text` styling, so we build one `AttributedString` with an embedded
    /// newline instead: primary line at the default size, a smaller secondary
    /// line (`.caption`, secondary color, two-space indent) after the break.
    /// This is the technique that actually renders two styled lines in a Menu.
    /// When `secondary` is nil we return a plain single-line string so
    /// snapshotless / not-logged-in rows keep their existing treatment.
    static func twoLineLabel(primary: String, secondary: String?) -> AttributedString {
        var result = AttributedString(primary)
        guard let secondary, !secondary.isEmpty else { return result }
        var second = AttributedString("\n  " + secondary)
        second.font = .caption
        second.foregroundColor = .secondary
        result.append(second)
        return result
    }

    private func dispatch(_ action: RowAccountMenu.RowAccountMenuAction) {
        Task {
            await appState.swapTerminalProfile(
                terminalID: action.terminalID,
                newProfileID: action.newProfileID
            )
        }
    }
}
