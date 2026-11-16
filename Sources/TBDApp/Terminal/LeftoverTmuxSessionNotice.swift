import SwiftUI
import TBDShared

/// What a terminal host shows in place of a terminal whose row is still
/// running in a tmux server (`TerminalPanePresentation.showsLeftoverTmuxNotice`).
///
/// TBD can no longer show, send to or end a tmux session, so this says how to
/// end it — `LeftoverTmuxSession.notice(server:)` names the server's
/// `kill-server` command — and offers Check Again, which asks the daemon to
/// look at the server once more. A server that has stopped gets the row parked,
/// and the host then shows the parked pane in place of this notice; one still
/// running is refused, and that refusal is shown under the notice.
///
/// Mounts no terminal engine and attaches to nothing: the session is not one
/// TBD can reach.
struct LeftoverTmuxSessionNotice: View {
    let terminalID: UUID
    /// The repo's tmux server: the `-L` name the notice's command takes.
    let server: String

    @Environment(AppState.self) private var appState
    /// What the daemon said when it refused the last Check Again, or nil.
    @State private var refusal: String?
    /// Whether a Check Again is in flight. A second click while it runs is
    /// dropped.
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Still running in tmux", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(LeftoverTmuxSession.notice(server: server))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(LeftoverTmuxSession.checkAgainTitle, action: checkAgain)
                    .disabled(checking)
                if checking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let refusal {
                Text(refusal)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Asks the daemon to probe the row's tmux server again, through the same
    /// recreate request every terminal host uses. A recreate it carries out
    /// arrives as the row's new state, which moves the host off this notice;
    /// a refusal stays here, in the daemon's words.
    private func checkAgain() {
        guard !checking else { return }
        checking = true
        refusal = nil
        Task {
            defer { checking = false }
            refusal = await appState.recreateTerminalWindow(terminalID: terminalID)?.message
        }
    }
}
