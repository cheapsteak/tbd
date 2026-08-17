import Foundation
import SwiftUI
import TBDShared

/// The worktree a queued prompt is being composed for
/// (`docs/specs/2026-08-10-queued-prompt-on-create-design.md`).
///
/// Creating a worktree is fast to *start* and slow to *finish*: `worktree.create`
/// returns as soon as the DB row exists, but the agent appears much later. The
/// modal therefore opens against a target whose real worktree ID does not exist
/// yet, and `resolution` is how it arrives.
///
/// That indirection is what makes "creation is not slowed" structural rather
/// than merely intended: `submitQueuedPrompt` cannot send
/// `worktree.setPendingPrompt` before `worktree.create` has returned, because
/// until then it has no ID to send.
@MainActor
final class QueuedPromptTarget: ObservableObject, Identifiable {
    /// How creation turned out. Set exactly once.
    enum Resolution: Equatable {
        /// The daemon's worktree row exists; this is the ID to park against.
        case created(UUID)
        /// Creation failed. Nothing can be parked — there is no row.
        case failed
    }

    /// The optimistic placeholder's ID. Stable for `.sheet(item:)`, and
    /// deliberately NOT the ID the prompt is parked against — the daemon row
    /// carries a different UUID.
    nonisolated let id: UUID
    let repoID: UUID
    /// The name the row was born with, shown in the modal's title. Two rapid
    /// Cmd+N presses queue two modals, and an unlabelled second one would be
    /// indistinguishable from the first.
    let worktreeName: String

    @Published private(set) var resolution: Resolution?
    private var waiters: [CheckedContinuation<Resolution, Never>] = []

    init(placeholderID: UUID, repoID: UUID, worktreeName: String) {
        self.id = placeholderID
        self.repoID = repoID
        self.worktreeName = worktreeName
    }

    /// Report the outcome of creation. Idempotent — a second call is ignored,
    /// so a late failure path cannot overwrite a success.
    func resolve(_ outcome: Resolution) {
        guard resolution == nil else { return }
        resolution = outcome
        let pending = waiters
        waiters = []
        for continuation in pending { continuation.resume(returning: outcome) }
    }

    /// Suspend until creation resolves. Returns immediately once it has.
    func awaitResolution() async -> Resolution {
        if let resolution { return resolution }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

/// The home for what a NEW first message starts from — the creation modal's
/// checkbox and the Settings ▸ General ▸ Worktrees row, which are two views
/// onto the key below.
///
/// The read-back composer (`ParkedPromptReadbackView`) deliberately does NOT
/// read this key, and must not be wired to it "for consistency": it seeds from
/// the `submit` bit stored with the message on screen, so it can never
/// misreport what delivery will do for that particular message.
enum QueuedPromptComposer {
    /// `UserDefaults` key holding the operator's remembered answer for new
    /// first messages (`docs/specs/2026-08-16-send-immediately-preference-design.md`).
    /// Written by the creation modal's checkbox and by the Settings ▸ General ▸
    /// Worktrees row, which are two views onto this one key.
    ///
    /// Never register a default for this key. The three-state distinction below
    /// holds against the *persistent* domain only, so a
    /// `UserDefaults.register(defaults:)` entry — a natural-looking addition,
    /// since the app already calls that in `TBDApp.swift` and
    /// `TableTranscriptView.swift` — would make `object(forKey:)` answer for a
    /// key nobody chose, collapsing "never chose" back into "chose off". The
    /// tests cannot catch that: they use isolated `UserDefaults(suiteName:)`,
    /// whose registration domains are empty.
    static let sendImmediatelyKey = "queuedPromptSendImmediately"

    /// Whether a NEW first message sends itself once it reaches the composer,
    /// for an operator who has never answered. The choice persists once made,
    /// so this is the value they meet the first time and never again.
    ///
    /// OFF. Delivery types the message in and stops there unless the operator
    /// ticks the box, because sending is what starts a turn nobody watched
    /// begin — and it is the half TBD cannot report on. An unsubmitted draft
    /// leaves no machine-readable trace (the transcript holds submitted turns
    /// only, and reading the screen is banned), so nothing can tell the
    /// operator afterwards whether it went. Opting in makes that choice, and
    /// its consequences, theirs.
    ///
    /// An EXISTING parked message ignores this and shows the bit stored with
    /// it, so the composer never misreports what delivery will do.
    static let sendImmediatelyDefault = false

    /// Resolve the remembered answer, keeping "never chose" distinct from
    /// "chose off".
    ///
    /// The `object(forKey:) as? Bool ??` shape is the point, not a style echo:
    /// `UserDefaults.bool(forKey:)` collapses absent into `false`, and once
    /// those read alike a later change to `sendImmediatelyDefault` either
    /// reaches nobody or overrides deliberate opt-outs — the same destroyed
    /// distinction that made `auto_hibernate_enabled` unflippable.
    ///
    /// `shippedDefault` is a defaulted test seam, not a production knob: it
    /// lets a test prove the absent case *follows* the default rather than
    /// coincidentally matching today's `false`.
    ///
    /// The shipped views read the key through `@AppStorage` and never call
    /// this, so a test here asserts the contract, not those views. This is the
    /// contract in assertable form, and the read site for any future non-view
    /// caller.
    static func resolveSendImmediately(
        defaults: UserDefaults,
        shippedDefault: Bool = sendImmediatelyDefault
    ) -> Bool {
        defaults.object(forKey: sendImmediatelyKey) as? Bool ?? shippedDefault
    }
}

/// Sheet for the prompt an operator composes while a freshly created worktree
/// is still coming up. Presented from `ContentView` on every creation path,
/// gated on the daemon capability `queuedPromptEnabled`.
///
/// Escape parks nothing: the worktree is already being created and keeps
/// running with an idle agent, exactly as before the feature existed. Follows
/// the sheet convention of `ScratchInstructionsView`.
struct QueuedPromptModal: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var target: QueuedPromptTarget

    @State private var draft: String = ""

    /// Remembered across composers, and written the moment the box is ticked —
    /// including when the sheet is then dismissed with Escape. That is what the
    /// gesture means: "I want this on", not "I want this on if I also send this
    /// particular message". Settings ▸ General ▸ Worktrees is where the
    /// preference is audited and reversed.
    @AppStorage(QueuedPromptComposer.sendImmediatelyKey)
    private var sendImmediately = QueuedPromptComposer.sendImmediatelyDefault

    private var isBlank: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("First message for \(target.worktreeName)").font(.headline)
            Text("Typed into the agent's composer as soon as it comes up. The worktree is already being created — you can dismiss this and the worktree keeps going.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SubmittingTextEditor(
                text: $draft,
                onSubmit: { submit() },
                onCancel: { dismiss() }
            )
            .frame(minHeight: 140)
            .padding(4)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

            Toggle("Send immediately", isOn: $sendImmediately)
                .help("On: TBD presses Return, and the agent starts working the moment the message is in. Off: the text waits in the composer for you to read and send. Remembered for future worktrees — change it in Settings ▸ General ▸ Worktrees.")

            HStack {
                Text("↩ to \(sendImmediately ? "send" : "queue") · ⇧↩ or ⌥↩ for a new line")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(sendImmediately ? "Send" : "Queue") { submit() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .disabled(isBlank)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func submit() {
        guard !isBlank else { return }
        appState.submitQueuedPrompt(target, text: draft, submit: sendImmediately)
        dismiss()
    }
}
