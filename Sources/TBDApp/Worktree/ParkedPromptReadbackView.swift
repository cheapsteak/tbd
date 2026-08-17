import SwiftUI
import TBDShared

/// A prompt still sitting in a worktree's `pending_prompt` column, snapshotted
/// for the read-back sheet
/// (`docs/specs/2026-08-10-queued-prompt-on-create-design.md`, "Undeliverable
/// prompts").
///
/// `id` is the worktree's ID — one prompt per worktree, so that is the identity
/// `.sheet(item:)` wants.
struct ParkedPromptReadback: Identifiable, Equatable {
    let id: UUID
    let worktreeName: String
    let text: String
    /// Whether delivery ends with Enter. Carried through Deliver-now so
    /// re-parking cannot silently flip a staged message into a sent one.
    ///
    /// Mirrors the column rather than the composer's own default, and resolves
    /// an absent bit through `Worktree.pendingPromptSubmitResolved` — the same
    /// property the daemon's delivery path reads. Showing anything else would
    /// misreport what delivery will actually do.
    let submit: Bool
    /// Where this message is in its life. The one discriminator behind both
    /// surfaces, computed here so they cannot disagree about the same text.
    let phase: ParkedPromptPhase

    /// Whether the worktree is archived. Archiving does not clear the column,
    /// and a revive deliberately does not deliver a prompt parked before it —
    /// so an archived row's text can never reach an agent, and Copy is the only
    /// action that means anything. This is where retained text is most at risk
    /// of becoming unreachable, which is exactly why the read-back reaches it.
    let worktreeIsArchived: Bool

    /// The read-back for `worktree`, or nil when it is holding nothing.
    ///
    /// One rule, in one place: the status-bar entry appears exactly when this
    /// is non-nil, and the sheet's content is what this returns, so nothing can
    /// advertise a message the sheet would then fail to show.
    ///
    /// The daemon clears `pendingPrompt` the moment the paste succeeds, so a
    /// non-empty column means the text has not been placed in the agent's
    /// composer yet — because the agent is not ready, or because nothing will
    /// ever receive it. `phase` is which.
    /// `terminals` are the worktree's, and decide the phase: whether the
    /// daemon has yet had an agent to deliver to. Defaults to none, which is
    /// the pre-spawn shape — every caller that HAS the list should pass it.
    init?(worktree: Worktree, terminals: [Terminal] = []) {
        guard let text = worktree.pendingPrompt, !text.isEmpty else { return nil }
        self.id = worktree.id
        self.worktreeName = worktree.displayName
        self.text = text
        self.submit = worktree.pendingPromptSubmitResolved
        self.worktreeIsArchived = worktree.status == .archived
        self.phase = ParkedPromptPhase.resolve(
            isArchived: worktreeIsArchived, terminals: terminals)
    }

    /// Whether an unpark actually failed, and why.
    ///
    /// An unpark is `park` with no text, and `park` reports that outcome as a
    /// **refusal** — nothing ended up parked, which is precisely what was
    /// asked for. So the refusal naming the unpark is the success answer, and
    /// every other status means the column still holds the text. Reading one
    /// string off an RPC result is unlovely; inferring "it worked" from a
    /// refusal without reading it would be worse.
    static func discardRefusal(_ result: WorktreeSetPendingPromptResult) -> String? {
        switch result {
        case .refused(let reason):
            return reason.contains("unparked") ? nil : reason
        case .parkedForSpawn, .awaitingReady:
            // The daemon parked something for a request that carried no text.
            // Nothing was discarded, and saying otherwise would leave the
            // operator believing a notice had been cleared.
            return "the daemon kept the message parked"
        }
    }

    /// Whether this worktree's primary terminal is a plain shell — one of the
    /// spec's named undeliverable causes, and the one the app can see.
    ///
    /// Mirrors the daemon's `PendingPromptCoordinator.primaryAgentTerminal`:
    /// terminals list oldest-first and the primary is created before the setup
    /// tab, so "no agent-kind terminal at all" is "the primary is a shell".
    /// The distinction matters because `park` answers `.parkedForSpawn` in both
    /// this case and the pre-spawn one, and only the pre-spawn one is a promise
    /// that can be kept — here the spawn has already happened and no later one
    /// is coming.
    ///
    /// An EMPTY list is not a shell primary: nothing has spawned yet (or the
    /// app has not loaded this worktree's terminals), which is exactly the case
    /// where a parked prompt still rides the next spawn's argv. The ambiguity
    /// resolves toward offering delivery, because being wrong that way costs a
    /// re-park and being wrong the other way withholds a working action.
    static func primaryIsPlainShell(terminals: [Terminal]) -> Bool {
        guard !terminals.isEmpty else { return false }
        return !terminals.contains { ($0.kind ?? .shell) != .shell }
    }
}

/// Where a parked first message is in its life — the single discriminator
/// behind the pane banner and the status-bar entry, so the two can never claim
/// different things about the same text.
///
/// There are only two states, and that is the point. Delivery is one paste,
/// and the column is cleared the moment that paste succeeds, so text still in
/// the column has either not been placed yet or could not be. There is no
/// third "delivered but unproven" state to name: an unsubmitted draft sitting
/// in a composer leaves no machine-readable trace — the transcript records
/// submitted turns only, and reading the screen is banned — so a claim about
/// whether it arrived would be a guess wearing a state's clothes.
///
/// `.undeliverable` therefore carries only causes the app can see for itself
/// and be right about. The daemon's own failures (a paste that threw, a dead
/// pane, an expired readiness wait) surface through the notification it already
/// records; the app does not infer them from the column.
enum ParkedPromptPhase: Equatable {
    /// Parked, waiting to be typed into the agent's composer. Nothing has been
    /// attempted and nothing is wrong — this is the state the pane banner
    /// exists to reassure about, and the overwhelmingly common one.
    case pending
    /// Nothing will ever receive this, for a reason the app can see. The
    /// status-bar entry's state, and failures-only by construction.
    case undeliverable(ParkedPromptUndeliverable)

    var undeliverableReason: ParkedPromptUndeliverable? {
        if case .undeliverable(let reason) = self { return reason }
        return nil
    }

    /// The explanation the composer opens with — what is actually true here.
    /// A pending message has not been placed yet, and must never be described
    /// as a failure; an undeliverable one says why and points at Copy.
    func explanation(submit: Bool) -> String {
        switch self {
        case .undeliverable(let reason):
            return reason.message
        case .pending:
            return submit
                ? "TBD types this into the agent's composer as soon as it is ready, then sends it. Edit it here if you want to change it first."
                : "TBD types this into the agent's composer as soon as it is ready, and leaves it for you to send. Edit it here if you want to change it first."
        }
    }

    /// Pending unless the app can see that delivery is impossible. Anything it
    /// cannot see reads as pending, which is both the truth most of the time
    /// and the failure mode worth having: a message described as still coming
    /// costs a glance, one described as failed costs trust.
    static func resolve(isArchived: Bool, terminals: [Terminal]) -> ParkedPromptPhase {
        if isArchived { return .undeliverable(.archived) }
        if ParkedPromptReadback.primaryIsPlainShell(terminals: terminals) {
            return .undeliverable(.noAgent)
        }
        return .pending
    }
}

/// Why a parked prompt can never be delivered — the causes the app can see for
/// itself, each of which disables Deliver-now and says so instead of offering
/// an action that would fail.
enum ParkedPromptUndeliverable: Equatable {
    /// The worktree is archived. Reviving it will not deliver the prompt.
    case archived
    /// The spawn already happened and produced a plain shell, so there is no
    /// agent — and no later spawn is coming.
    case noAgent

    /// What the operator reads. Every one of these ends by pointing at Copy,
    /// which is the action that still works.
    var message: String {
        switch self {
        case .archived:
            return """
                This worktree is archived, so this message can no longer be delivered — reviving \
                it will not place a prompt parked beforehand. The text is still here — copy it \
                and paste it wherever you need it.
                """
        case .noAgent:
            return """
                This worktree's primary terminal is a plain shell, so there is no agent to deliver \
                to. The text is still saved — copy it and paste it wherever you need it.
                """
        }
    }

    /// The short form, for the disabled button's tooltip.
    var help: String {
        switch self {
        case .archived: return "This worktree is archived — a parked prompt can no longer be delivered."
        case .noAgent: return "This worktree's primary terminal is a plain shell — there is no agent to deliver to."
        }
    }
}

/// The composer for a first message that is still waiting to reach its agent.
///
/// The text is editable, because the wait is exactly when an operator changes
/// their mind about what to say — and because a message parked behind a
/// ten-minute `preSession` hook is often written before its worktree is fully
/// understood. Copy works when nothing else does, Discard throws the message
/// away, and Deliver stays honestly disabled where delivery cannot happen.
struct ParkedPromptReadbackView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let readback: ParkedPromptReadback

    /// Seeded from the parked text, then owned by the operator.
    @State private var draft: String
    @State private var sendImmediately: Bool

    init(readback: ParkedPromptReadback) {
        self.readback = readback
        _draft = State(initialValue: readback.text)
        _sendImmediately = State(initialValue: readback.submit)
    }

    private var isBlank: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isEdited: Bool { draft != readback.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("First message for \(readback.worktreeName)").font(.headline)
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SubmittingTextEditor(
                text: $draft,
                onSubmit: { submitIfAllowed() },
                onCancel: { dismiss() }
            )
            .frame(minHeight: 140, maxHeight: 300)
            .padding(4)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

            Toggle("Send immediately", isOn: $sendImmediately)
                .help("On: TBD presses Return, and the agent starts working as soon as the message is in. Off: the text waits in the composer for you to read and send.")
                .disabled(undeliverable != nil)

            Text("↩ to deliver · ⇧↩ or ⌥↩ for a new line")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                // Copy takes what is ON SCREEN, edits included — the text the
                // operator is looking at is the text they mean.
                Button("Copy") { appState.copyParkedPrompt(readback, text: draft) }
                Button("Discard") {
                    Task { await appState.discardParkedPrompt(readback) }
                }
                .help("Throw this message away without sending it.")
                .disabled(appState.parkedPromptDeliveryInFlight)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEdited ? "Deliver Edited" : "Deliver Now") { submitIfAllowed() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                // Disabled rather than offered-and-refused where nothing can be
                // delivered: a button that always fails is worse than no
                // button, and Copy is the action that works here. Blank is
                // disabled too — empty text is the UNPARK signal, and Discard
                // is the deliberate way to ask for that.
                .disabled(!canSubmit)
                .help(undeliverable?.help ?? "")
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    /// The one enablement rule, read by both the button and the Return key —
    /// a keystroke must never do what the disabled button cannot.
    private var canSubmit: Bool {
        undeliverable == nil && !isBlank && !appState.parkedPromptDeliveryInFlight
    }

    private func submitIfAllowed() {
        guard canSubmit else { return }
        Task {
            await appState.deliverParkedPromptNow(
                readback, text: draft, submit: sendImmediately)
        }
    }

    private var undeliverable: ParkedPromptUndeliverable? {
        appState.parkedPromptUndeliverableReason(readback)
    }

    private var explanation: String {
        if let undeliverable { return undeliverable.message }
        return readback.phase.explanation(submit: readback.submit)
    }
}

/// The one sheet slot the two prompt surfaces share.
///
/// `ContentView` stacks its modifiers on a single view, and two
/// `.sheet(item:)`s on one view is the neighbouring hazard to the item-swap
/// this feature's presentation queue exists to avoid: which one wins is
/// SwiftUI's business, not the app's. Routing both through one modifier makes
/// "at most one prompt sheet" structural.
enum PromptSheet: Identifiable {
    case compose(QueuedPromptTarget)
    case readback(ParkedPromptReadback)

    var id: UUID {
        switch self {
        case .compose(let target): return target.id
        case .readback(let readback): return readback.id
        }
    }

    /// Which of the two is on screen. Composing wins.
    ///
    /// The precedence is a defensive tiebreak, not the mechanism: both writers
    /// respect the slot, because a swap here is a non-nil→non-nil item change —
    /// the transition the creation queue exists to avoid, and one this type
    /// would otherwise re-introduce from the other direction. `createWorktree`
    /// queues its target while ANY prompt sheet is up (a menu-bar Cmd+N still
    /// fires with one on screen), and `revealParkedPrompt` declines while a
    /// compose modal owns the slot.
    static func presented(
        compose: QueuedPromptTarget?, readback: ParkedPromptReadback?
    ) -> PromptSheet? {
        if let compose { return .compose(compose) }
        if let readback { return .readback(readback) }
        return nil
    }
}
