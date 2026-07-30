import AppKit
import SwiftUI

/// The provider-authentication call to action, shared by the two surfaces
/// that show it: `RemoteSessionDetailView` (in place of the generic
/// "Detached / Reattach" overlay, which would just fail again) and the
/// sidebar provider header's popover.
///
/// What it deliberately does NOT offer is a "Reattach" primary button: while
/// the provider can't authenticate, a fresh `attach` dies on connect, so
/// offering it as the main action sends the user down a path that cannot
/// work. The primary action is the provider's own remediation instead.
///
/// The remediation command is shown verbatim, selectable and copyable, so a
/// user who would rather run it in their own terminal can — TBD never hides
/// what it is about to execute.
struct RemoteProviderAuthCTAView: View {
    let presentation: RemoteProviderAuthPresentation
    /// Whether to include the contract's reassurance that the remote session
    /// is unaffected. Shown on the session detail pane (where the user is
    /// looking at one specific session) and omitted in the sidebar popover,
    /// which is provider-level chrome with no session in view.
    var showsSessionReassurance = false
    /// Invoked when the user asks to run the command. The caller owns the
    /// terminal presentation, since a popover can't host its own sheet.
    let onRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("\(presentation.providerName) needs authentication")
                    .font(.headline)
            } icon: {
                Image(systemName: "key.slash")
                    .foregroundStyle(SuffixRowIndicator.attention.color)
            }

            Text(presentation.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if showsSessionReassurance {
                // Contract-correct framing: the PROVIDER is what can't
                // authenticate. Only `list`/`events` are authoritative about
                // a session's fate, and neither an attach exiting nor an
                // expired credential says anything about it.
                Text("The session keeps running remotely.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let command = presentation.command {
                commandRow(command)
                Button(presentation.actionLabel) { onRun() }
                    .buttonStyle(.borderedProminent)
            } else {
                // No command to run — the provider told us what's wrong but
                // not how to fix it, so the label is shown as plain text
                // rather than a button that would do nothing.
                Text(presentation.actionLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    private func commandRow(_ command: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy command")
        }
    }
}

/// One in-flight remediation run, driving `.sheet(item:)`.
///
/// SELF-SUFFICIENT by design: it carries the whole presentation alongside
/// the command, so the sheet renders entirely from this value and never
/// re-reads live provider health. Health is expected to change while the
/// sheet is open — clearing `.needsAuth` is the whole point of running the
/// command — and a sheet whose content is conditioned on the CTA still
/// existing collapses to an empty view mid-login while staying presented:
/// no terminal, no Done button, Escape the only way out.
///
/// It is also an item rather than a bool because `.sheet(isPresented:)` +
/// `if let` can structurally present an empty sheet the same way.
struct RemoteRemediationRun: Identifiable, Equatable {
    let presentation: RemoteProviderAuthPresentation
    let command: String

    /// Both halves participate: two providers could in principle offer the
    /// same command string, and `.sheet(item:)` re-presents on id change.
    var id: String { "\(presentation.providerName)\u{1}\(command)" }

    /// `nil` when the presentation has no command — there is nothing to run,
    /// so there is no sheet to present.
    init?(_ presentation: RemoteProviderAuthPresentation) {
        guard let command = presentation.command else { return nil }
        self.presentation = presentation
        self.command = command
    }
}

/// Runs the provider's remediation command in a REAL terminal, hosted by the
/// same `LocalPTYTerminalRepresentable` the provider `attach` uses.
///
/// A real PTY (rather than a captured subprocess) is the point: these
/// commands are interactive login flows — they prompt, they open browsers,
/// they read a code back from the user — and none of that works without a
/// controlling terminal.
/// Everything it renders comes from the `run` it was handed, never from
/// live provider health — see `RemoteRemediationRun`.
struct RemoteRemediationTerminalSheet: View {
    let run: RemoteRemediationRun
    private var presentation: RemoteProviderAuthPresentation { run.presentation }
    private var command: String { run.command }
    @EnvironmentObject var appearance: AppearanceSettings
    @Environment(\.dismiss) private var dismiss
    @State private var exitCode: Int32?
    @State private var hasExited = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.actionLabel)
                    .font(.headline)
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            .padding(12)
            Divider()

            LocalPTYTerminalRepresentable(
                argv: RemoteRemediationCommand.loginShellArgv(command: command),
                // No `TBD_CONTRACT_VERSION`: this is a user-facing command,
                // not a contract verb invocation.
                environment: TerminalPanelView.makeViewerEnvironment(
                    base: ProcessInfo.processInfo.environment),
                appearance: appearance,
                onExit: { code in
                    exitCode = code
                    hasExited = true
                }
            )
            .frame(minWidth: 680, minHeight: 380)

            Divider()
            HStack {
                if hasExited {
                    Text(exitCode.map { "Command exited (code \($0))" } ?? "Command exited")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }
}
