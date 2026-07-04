import SwiftUI
import TBDShared

/// Hover-revealed "…" menu for a worktree row. Headlined by per-session account
/// info + switch-account (fork the session onto another logged-in profile).
///
/// Pure lowering of `RowAccountMenu.Model` — the composition lives in the
/// testable helper; this file only maps typed rows to SwiftUI `Menu`/`Button`
/// and dispatches the typed `RowAccountMenuAction` to `AppState`.
struct RowAccountMenuView: View {
    let worktree: Worktree
    @EnvironmentObject var appState: AppState

    private var menuModel: RowAccountMenu.Model {
        RowAccountMenu.model(
            terminals: appState.terminals[worktree.id] ?? [],
            profiles: appState.modelProfiles
        )
    }

    var body: some View {
        Menu {
            menuContent(menuModel)
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption)
                .frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
        Menu(RowAccountMenu.switchAccountLabel) {
            ForEach(session.switchTargets) { target in
                switchTargetButton(session: session, target: target)
            }
        }
    }

    @ViewBuilder
    private func switchTargetButton(session: RowAccountMenu.Session,
                                    target: RowAccountMenu.SwitchTarget) -> some View {
        if let action = target.action(terminalID: session.terminalID) {
            Button(action: { dispatch(action) }) {
                Text("  \(target.title)")
            }
        } else {
            // Disabled: current account (checkmark) or not-logged-in (hint).
            let prefix = target.isCurrent ? "✓ " : "  "
            let suffix = target.disabledReason.map { " — \($0)" } ?? ""
            Button("\(prefix)\(target.title)\(suffix)") {}
                .disabled(true)
        }
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
