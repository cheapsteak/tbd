import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "queued-prompt")

/// Owns the prompt an operator parked at worktree creation, and every write to
/// the `worktree.pending_prompt` column
/// (design `docs/specs/2026-08-10-queued-prompt-on-create-design.md`).
///
/// **There is one delivery path: paste.** The prompt is written to the column,
/// the coordinator waits for the primary agent's `SessionStart` hook, waits out
/// the measured settle (`pendingPromptSettleDelay`) that hook does not cover,
/// and types the text into the pane — pressing Enter only when the operator
/// ticked "send immediately". Nothing observes what happens next: staged text
/// enters no conversation, fires no hook, and produces no state change TBD can
/// see, and reading the pane is banned. A successful paste is the whole of what
/// can be known, so it is what the column is cleared on.
///
/// **Exactly one writer clears the column, and it is
/// `deliverParkedPrompt`** — a compare-and-swap naming the text it just watched
/// reach the pane. `park` is the only other writer, and it only ever *sets*
/// (or, on a deliberate unpark, empties on the operator's own gesture). The
/// spawn path does not touch the column at all; it only tells this actor that a
/// primary terminal row now exists. Every read-and-clear race the earlier
/// two-writer design had is unreachable rather than fixed.
///
/// **Armed state is in memory, deliberately**, matching `DeliveryVerifier`'s
/// choice that a restart costs cadence and never data. The text itself is in
/// the column and survives; what dies with the daemon is the *arming*, so after
/// a restart a parked prompt surfaces as a recoverable prompt rather than
/// typing into a session unbidden.
actor PendingPromptCoordinator {
    /// Ceiling on how long the delivery waits for the primary agent's
    /// `SessionStart` hook after its pane exists.
    ///
    /// Not a judgement about when an agent is stuck — it is a generous ceiling
    /// on how long a spawned process takes to emit its first hook, and it
    /// expires *loudly* into the recovery path (a notification, with the text
    /// still in the column) rather than deciding anything. The wait itself is
    /// normally seconds: the pane already exists before this timer is armed,
    /// which is what `notePrimaryTerminalExists` is for.
    static let pendingPromptReadinessTimeout: Duration = .seconds(120)

    /// How long delivery lets a pane settle after `SessionStart` before it
    /// types into it.
    ///
    /// **`SessionStart` is not evidence that the agent can receive input.** The
    /// hook says a session exists; the TUI has not necessarily attached its
    /// input handling, and until it enables bracketed-paste mode (DECSET 2004)
    /// a paste is swallowed whole — empty composer, nothing typed.
    ///
    /// **Measured on this machine against live Claude panes**, by bisecting
    /// unsubmitted pastes at increasing offsets after the hook: **+0.07s lost,
    /// +0.42s lost, +0.72s landed, +1.15s landed**, and everything beyond
    /// landed. The dead window is roughly the first half-second after the hook.
    /// A second is that window doubled — cheap insurance on a path where the
    /// operator is already waiting.
    ///
    /// **There is no readiness event to wait for instead, which is why this is
    /// a duration and not a signal.** tmux 3.6a exposes no format for a pane's
    /// bracketed-paste state: the full format list (`display-message -a -p`)
    /// carries none, and `client_termfeatures` advertising `bpaste` describes
    /// the *client's* capability, never the pane's DECSET 2004 state.
    /// `pane_key_mode` does flip `VT10x` → `Ext 2` when the TUI starts, and it
    /// is the obvious candidate — but it flips **~2.9s before** the hook, so it
    /// cannot discriminate the bad window at all. Do not reach for it.
    ///
    /// Applied unconditionally, including for an agent whose row already proves
    /// readiness: that row may have been stamped by a hook that landed
    /// milliseconds ago, which is exactly the dangerous case.
    ///
    /// It is the *only* mitigation for that window, by design. Nothing observes
    /// whether the paste took, so nothing can correct it — re-measure this
    /// value if Claude Code's startup changes. The method is the bisect above:
    /// unsubmitted pastes at increasing offsets after `SessionStart`, judged by
    /// whether the words reach the composer.
    static let pendingPromptSettleDelay: Duration = .seconds(1)

    private let db: TBDDatabase
    private let subscriptions: StateSubscriptionManager?
    private let clock: any Clock<Duration>

    /// The daemon-internal send seam: paste `text` into `terminalID`, verbatim
    /// and with **no** `<tbd-dispatch/>` envelope, pressing Enter iff `submit`.
    /// Answers whether the bytes reached the pane.
    ///
    /// Settable after construction because the router that owns the send core
    /// is built from a value snapshot of the `WorktreeLifecycle` that already
    /// has to carry this coordinator — the same post-construction wiring
    /// `RPCRouter.deliveryVerifier` uses. `nil` means no send path is wired
    /// (mock mode, most unit tests), which is treated as a failed delivery
    /// rather than a silent success.
    private var deliver: (@Sendable (_ terminalID: UUID, _ text: String, _ submit: Bool) async -> Bool)?

    /// Worktrees whose prompt this daemon session parked **before any primary
    /// agent existed**, and which are still waiting for their pane.
    ///
    /// Membership is the licence to type, and it is spent: `park` grants it
    /// only on the no-pane branch, and the first `notePrimaryTerminalExists`
    /// consumes it. So a parked prompt is armed at most once, by the pane it
    /// was actually waiting for. A later spawn for the same worktree — a
    /// revive, a Watch Desk session, anything after a daemon restart — finds no
    /// licence and types nothing, which is what keeps retained text from
    /// becoming an unattended delivery into a conversation it was never written
    /// for. The operator recovers it from the worktree's row, and pressing
    /// Deliver-now re-parks, which grants the licence again.
    private var awaitingPane: Set<UUID> = []

    /// Worktrees already told that their parked text was not typed into a pane
    /// that came up without the licence above. Once per worktree per daemon
    /// session: the text stays in the column, so every subsequent spawn would
    /// otherwise repeat the same notice.
    private var strandedAnnounced: Set<UUID> = []

    /// One in-flight readiness wait per worktree, keyed by worktree id — this
    /// feature holds one prompt per worktree, not a queue, so a second park
    /// replaces the first here as well as in the column.
    private var arms: [UUID: Arm] = [:]

    private struct Arm {
        /// Generation token. A second park disarms the first and installs a new
        /// record under the same key; the old cycle is still suspended and will
        /// wake up to find it no longer owns the slot. Without this it would
        /// clear its successor's arming and announce a timeout that never
        /// happened.
        let id: UUID
        let terminalID: UUID
        /// The readiness signal arrived before the waiter parked. Recorded
        /// rather than dropped, because `arm` inserts this record
        /// synchronously and only then suspends.
        var ready: Bool
        var continuation: CheckedContinuation<Bool, Never>?
    }

    /// Every delivery cycle still running, keyed by its generation token —
    /// including cycles a later park superseded, which are still winding down.
    /// Each removes itself on the way out, so this is bounded by concurrency
    /// rather than by history.
    private var inFlight: [UUID: Task<Void, Never>] = [:]

    /// How many delivery cycles are still running. For tests that need one
    /// specific cycle to have retired while another is deliberately still
    /// parked on its readiness wait, which `awaitPendingDeliveries` cannot
    /// express.
    var inFlightCycleCount: Int { inFlight.count }

    init(
        db: TBDDatabase,
        subscriptions: StateSubscriptionManager? = nil,
        deliver: (@Sendable (_ terminalID: UUID, _ text: String, _ submit: Bool) async -> Bool)? = nil,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.db = db
        self.subscriptions = subscriptions
        self.deliver = deliver
        self.clock = clock
    }

    func setDeliver(
        _ deliver: @escaping @Sendable (_ terminalID: UUID, _ text: String, _ submit: Bool) async -> Bool
    ) {
        self.deliver = deliver
    }

    // MARK: - Parking

    /// Park `text` for this worktree's primary agent.
    ///
    /// Refuses — parking nothing — when the soak flag is off, the worktree does
    /// not exist or is archived, or its primary terminal is a plain shell or a
    /// parked (hibernated) agent. A `nil` or empty `text` unparks instead,
    /// which is also a refusal: nothing ended up parked.
    ///
    /// Every eligibility question is answered **before** the column is written,
    /// so a refusal never has to undo a write it just made.
    func park(
        worktreeID: UUID, text: String?, submit: Bool
    ) async -> WorktreeSetPendingPromptResult {
        guard await queuedPromptEnabled() else {
            return .refused(reason: """
                queued prompts are disabled (config.queued_prompt_enabled is off) — nothing was \
                parked. Enable it with the config.setQueuedPrompt RPC.
                """)
        }
        guard let worktree = (try? await db.worktrees.get(id: worktreeID)) ?? nil else {
            return .refused(reason: "worktree not found: \(worktreeID.uuidString)")
        }

        // Whitespace-only text is nothing to say. The app trims before it
        // sends, but the RPC is reachable by the CLI and by any other daemon
        // client, and a pane full of spaces followed by Enter is a turn the
        // operator did not ask for. Emptiness is judged on the trimmed text;
        // what gets parked is the original bytes, because the paste path's
        // whole contract is that the model sees exactly what was composed.
        //
        // Answered first, and unconditionally: Discard has to work on a
        // worktree that has since been archived, or whose primary turned out to
        // be a shell, and both of those are refusals below.
        if (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                try await db.worktrees.setPendingPrompt(
                    worktreeID: worktreeID, text: nil, submit: submit)
            } catch {
                return .refused(reason: "could not unpark the prompt: \(error)")
            }
            disarm(worktreeID: worktreeID)
            awaitingPane.remove(worktreeID)
            strandedAnnounced.remove(worktreeID)
            return .refused(reason: "no prompt text — the worktree was unparked")
        }

        // An archived worktree has no terminal rows — archive deletes them — so
        // it looks exactly like a worktree still being created, and the honest
        // answer for the two is opposite. A prompt parked here would sit in the
        // column forever: never delivered, never expired, never mentioned. The
        // refusal says that now rather than letting the app promise delivery on
        // the daemon's behalf.
        guard worktree.status != .archived else {
            return .refused(reason: """
                this worktree is archived, so no agent is coming up to receive the prompt — \
                nothing was parked. Revive it first, then send the prompt.
                """)
        }

        // "Not yet" and "not ever" look the same from here, and only the first
        // may answer `.parkedForSpawn`. `PrimaryTerminal.spawnIsStillComing` is
        // what tells them apart: a worktree with no rows at all, or with none
        // but the blocking `preSession` hook's tab, still has its primary spawn
        // ahead of it. A worktree holding any other terminal has had that spawn
        // already, and whatever it produced is not an agent — so there is
        // nothing to park for, and saying so now is better than a promise the
        // daemon cannot keep.
        let primary = await primaryAgentTerminal(worktreeID: worktreeID)
        if primary == nil {
            let terminals = (try? await db.terminals.list(worktreeID: worktreeID)) ?? []
            guard PrimaryTerminal.spawnIsStillComing(terminals: terminals) else {
                return .refused(reason: """
                    this worktree's primary terminal is not an agent, so a prompt cannot be \
                    delivered to it — nothing was parked.
                    """)
            }
        }

        // A parked agent's pane is a bare shell. Hibernation kills the agent
        // process and `respawn-window`s the pane to a login shell while the row
        // keeps `kind == .claude` — so the kind check above says "agent" about a
        // pane with no composer in it, and the text would be typed at a prompt
        // (and, with the submit bit set, run as a command line). Waking is the
        // operator's gesture, so the honest answer now is a refusal, not a
        // promise to deliver whenever the session happens to come back.
        if let primary, primary.isParked {
            return .refused(reason: """
                this worktree's primary agent is hibernated, so its pane is a bare shell rather \
                than a composer — nothing was parked. Wake the session, then send the prompt.
                """)
        }

        do {
            try await db.worktrees.setPendingPrompt(
                worktreeID: worktreeID, text: text, submit: submit)
        } catch {
            return .refused(reason: "could not park the prompt: \(error)")
        }
        strandedAnnounced.remove(worktreeID)
        // `arm` disarms for itself, but the no-pane branch below never reaches
        // it, and a prompt that replaced an armed one must not leave the old
        // arming running.
        disarm(worktreeID: worktreeID)

        guard let primary else {
            // Nothing to type into yet. The licence to type when a pane turns
            // up is granted here and nowhere else, and the readiness ceiling
            // starts when `notePrimaryTerminalExists` spends it — a `preSession`
            // hook can run for ten minutes, and a ceiling that started now
            // would expire before the agent ever existed.
            awaitingPane.insert(worktreeID)
            return .parkedForSpawn
        }
        awaitingPane.remove(worktreeID)
        arm(worktreeID: worktreeID, terminal: primary)
        return .awaitingReady
    }

    /// A primary terminal row now exists for this worktree — the spawn path's
    /// only involvement with a queued prompt.
    ///
    /// **It passes no prompt and writes no column.** It says one thing: the
    /// pane the parked prompt was waiting for is up. That is what makes the
    /// readiness ceiling meaningful behind a ten-minute `preSession` hook, and
    /// it is what keeps the spawn path out of the one race this feature has.
    ///
    /// Types nothing without the licence `park` granted on its no-pane branch.
    /// A prompt whose licence died with a daemon restart, or that was retained
    /// after an undeliverable outcome and met a later spawn, is announced once
    /// and left in the column for the operator.
    func notePrimaryTerminalExists(worktreeID: UUID, terminalID: UUID) async {
        guard await queuedPromptEnabled() else { return }
        // The column is the one authority on whether a prompt is outstanding;
        // `awaitingPane` only says whether this session may type it. Consulting
        // the set first would announce a stranded prompt for a worktree whose
        // prompt was delivered and cleared minutes ago.
        guard let worktree = try? await db.worktrees.get(id: worktreeID),
              worktree.pendingPrompt?.isEmpty == false else { return }
        guard awaitingPane.remove(worktreeID) != nil else {
            guard strandedAnnounced.insert(worktreeID).inserted else { return }
            await notifyUndeliverable(
                worktreeID: worktreeID, terminalID: terminalID, reason: """
                    A prompt parked for this worktree is still waiting: TBD did not type it into \
                    this session. The text is still saved — the prompt icon on this worktree's row \
                    will copy it or deliver it now.
                    """)
            return
        }
        guard let terminal = try? await db.terminals.get(id: terminalID) else {
            await notifyUndeliverable(
                worktreeID: worktreeID, terminalID: terminalID, reason: """
                    A prompt parked for this worktree was not delivered: its agent's pane could not \
                    be found. The text is still saved — the prompt icon on this worktree's row will \
                    copy it or deliver it now.
                    """)
            return
        }
        // A plain shell has no composer and no agent: nothing about a queued
        // prompt makes sense there, and pasting it would run the operator's
        // words as a command line.
        guard (terminal.kind ?? .shell) != .shell else {
            await notifyUndeliverable(
                worktreeID: worktreeID, terminalID: terminalID, reason: """
                    A prompt parked for this worktree was not delivered: its primary terminal is a \
                    plain shell, not an agent. The text is still saved — the prompt icon on this \
                    worktree's row will copy it or deliver it now.
                    """)
            return
        }
        // The row decides readiness, as everywhere else. The caller created it
        // after the pane existed, so if `SessionStart` has already landed the
        // row says so — and forcing "not ready" here would throw that away and
        // wait for a second hook that is never coming, burning the whole
        // ceiling and ending in a "did not report a session" notice about a
        // live agent.
        arm(worktreeID: worktreeID, terminal: terminal)
    }

    // MARK: - Readiness

    /// Whether this terminal's session has already announced itself, so no
    /// further `SessionStart` is coming and waiting for one would only burn the
    /// ceiling.
    ///
    /// **Not `claudeSessionID`.** A fresh Claude spawn is created with a
    /// pre-chosen `--session-id`, so that field is populated before the process
    /// has even started — reading it as readiness would paste into a booting
    /// TUI. `transcriptPath` and a non-`unknown` `activityState` are written by
    /// hook traffic (`terminal.sessionEvent`, `terminal.activityEvent`), which
    /// is the fact wanted, and both legs are machine interfaces rather than
    /// screen text.
    ///
    /// They are not written *exclusively* by hooks — parking a session stamps
    /// `activityState = .idle` (`TerminalStore.setHibernated`) and window
    /// recreation stamps `.unknown` (`clearRecreated`). Neither weakens the
    /// answer here: a parked session did once announce itself, and a recreated
    /// window reads as not-yet-announced, which is the truth in both cases.
    static func hasAnnouncedItself(_ terminal: Terminal) -> Bool {
        if let path = terminal.transcriptPath, !path.isEmpty { return true }
        return terminal.activityState != .unknown
    }

    /// The `SessionStart` hook fired for a terminal — the machine signal that
    /// the agent is up. Never screen text.
    func noteSessionReady(worktreeID: UUID, terminalID: UUID) {
        guard var armed = arms[worktreeID], armed.terminalID == terminalID else { return }
        armed.ready = true
        let continuation = armed.continuation
        armed.continuation = nil
        arms[worktreeID] = armed
        continuation?.resume(returning: true)
    }

    /// Await every delivery cycle still in flight — including ones a later
    /// park superseded, which is what makes "the discarded wait stayed quiet"
    /// assertable rather than a race the test usually wins.
    ///
    /// For tests, which drive the clock and then need the cycle's writes to
    /// have landed before they read the column. Production never waits on
    /// these; that is the point of arming them.
    func awaitPendingDeliveries() async {
        // A cycle removes itself as it exits, so re-snapshot until the set is
        // empty rather than awaiting one generation and calling it done.
        while !inFlight.isEmpty {
            for task in inFlight.values { await task.value }
        }
    }

    // MARK: - Arming and delivery

    private func arm(worktreeID: UUID, terminal: Terminal) {
        // Disarm FIRST, always. Overwriting `arms[worktreeID]` while an
        // incumbent record holds a continuation orphans it: nothing can resume
        // it afterwards, because every resumer (`noteSessionReady`,
        // `expireReadiness`) matches on the generation token that just left the
        // slot. The cost is a task suspended for the life of the daemon, an
        // `inFlight` entry that never retires, a `SWIFT TASK CONTINUATION
        // MISUSE` report, and an `awaitPendingDeliveries()` that never returns.
        disarm(worktreeID: worktreeID)
        let armID = UUID()
        arms[worktreeID] = Arm(
            id: armID,
            terminalID: terminal.id,
            ready: Self.hasAnnouncedItself(terminal),
            continuation: nil)
        inFlight[armID] = Task { [weak self] in
            guard let self else { return }
            await self.runDeliveryCycle(
                worktreeID: worktreeID, terminalID: terminal.id, armID: armID)
            await self.retire(armID: armID)
        }
    }

    private func retire(armID: UUID) {
        inFlight[armID] = nil
    }

    /// Retire this worktree's arming: the superseded cycle wakes, finds it no
    /// longer owns the slot, and leaves quietly.
    ///
    /// **The cycle's task is deliberately not cancelled.** A delivery is not
    /// one atomic act — `performTerminalSend` pastes the body and then presses
    /// Enter, and both run through `runBoundedProcess`, which treats
    /// cancellation of the enclosing task as a hard deadline: it kills the
    /// child and throws. Cancelling between those two steps leaves the
    /// operator's words sitting unsubmitted in the composer, where the next
    /// cycle's paste lands on top of them and its Enter submits both as one
    /// prompt. Nothing is prevented in exchange: a superseded cycle checks that
    /// it still owns the arming before it types at all, and the clear is a
    /// compare-and-swap on the text it delivered.
    private func disarm(worktreeID: UUID) {
        guard let armed = arms.removeValue(forKey: worktreeID) else { return }
        armed.continuation?.resume(returning: false)
    }

    private func runDeliveryCycle(worktreeID: UUID, terminalID: UUID, armID: UUID) async {
        let ready = await awaitReadiness(
            worktreeID: worktreeID, terminalID: terminalID, armID: armID)
        // A newer park (or an unpark) superseded this cycle while it waited.
        // It owns nothing now: it must not clear the successor's arming, must
        // not deliver, and above all must not announce a timeout for a prompt
        // that has been replaced.
        guard arms[worktreeID]?.id == armID else { return }
        guard ready else {
            arms[worktreeID] = nil
            await notifyUndeliverable(
                worktreeID: worktreeID, terminalID: terminalID, reason: """
                    A prompt parked for this worktree was not delivered: its agent did not report \
                    a session within \(Self.pendingPromptReadinessTimeout). The text is still \
                    saved — the prompt icon on this worktree's row will copy it or deliver it now.
                    """)
            return
        }
        await deliverParkedPrompt(
            worktreeID: worktreeID, terminalID: terminalID, armID: armID)
        if arms[worktreeID]?.id == armID { arms[worktreeID] = nil }
    }

    /// Whether `armID` still owns this worktree's arming. A cycle a later park
    /// superseded owns nothing: it must not type, must not clear the column,
    /// and must not speak to the operator about a prompt that has been
    /// replaced.
    private func isCurrent(worktreeID: UUID, armID: UUID) -> Bool {
        arms[worktreeID]?.id == armID
    }

    /// Wait for the readiness signal, bounded by `pendingPromptReadinessTimeout`
    /// on the injected clock. Answers `true` when the hook arrived.
    private func awaitReadiness(worktreeID: UUID, terminalID: UUID, armID: UUID) async -> Bool {
        // Only this cycle's own record answers. Reading the slot without
        // checking whose record is in it would let a superseded cycle inherit
        // its replacement's readiness and deliver on its behalf.
        guard let armed = arms[worktreeID], armed.id == armID else { return false }
        if armed.ready { return true }
        let timeout = Task { [clock] in
            try? await clock.sleep(for: Self.pendingPromptReadinessTimeout)
            guard !Task.isCancelled else { return }
            // No `await`: an unstructured `Task` created inside an actor
            // inherits its isolation, so this is a direct call.
            self.expireReadiness(worktreeID: worktreeID, armID: armID)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // Actor-isolated, so this runs before any signal can be observed:
            // either readiness already arrived, or the waiter is registered.
            guard var armed = arms[worktreeID], armed.id == armID,
                  armed.terminalID == terminalID else {
                continuation.resume(returning: false)
                return
            }
            if armed.ready {
                continuation.resume(returning: true)
                return
            }
            armed.continuation = continuation
            arms[worktreeID] = armed
        }
    }

    private func expireReadiness(worktreeID: UUID, armID: UUID) {
        guard var armed = arms[worktreeID], armed.id == armID,
              let continuation = armed.continuation else { return }
        armed.continuation = nil
        arms[worktreeID] = armed
        continuation.resume(returning: false)
    }

    /// Read the parked text, paste it verbatim, and clear the column on a paste
    /// that reached the pane.
    ///
    /// **This is the only place the column is cleared after a delivery, and it
    /// is the invariant the whole design rests on.** Read-then-clear rather
    /// than a read-and-clear take: the column is the recovery store, and a
    /// prompt cleared ahead of a paste that then failed would be a prompt the
    /// operator cannot get back.
    ///
    /// The clear is a compare-and-swap against the text that was actually
    /// delivered. The settle and the send both suspend, and a second park can
    /// land anywhere in there; an unconditional clear would destroy that newer
    /// prompt while its own cycle, reading an empty column, returned silently —
    /// no delivery, no notification, after the operator was told
    /// `.awaitingReady`.
    ///
    /// **A paste tmux reports as delivered may still be discarded by a TUI that
    /// was not reading its pty, and nothing can tell.** Staged text enters no
    /// conversation, fires no hook, and changes no state TBD can observe;
    /// reading the pane is banned. That is accepted, and the measured settle
    /// above is the mitigation — not a verification pass, which would have to
    /// invent evidence it cannot have.
    private func deliverParkedPrompt(worktreeID: UUID, terminalID: UUID, armID: UUID) async {
        guard let worktree = try? await db.worktrees.get(id: worktreeID),
              let text = worktree.pendingPrompt, !text.isEmpty else { return }
        // Submitting is opt-in, and `Worktree.pendingPromptSubmitResolved` is
        // where that is decided once — for this send and for the read-back
        // sheet that tells the operator what this send will do.
        let submit = worktree.pendingPromptSubmitResolved

        guard let deliver else {
            await notifyIfCurrent(
                worktreeID: worktreeID, armID: armID, terminalID: terminalID, reason: """
                    A prompt parked for this worktree was not delivered: this daemon has no send \
                    path wired. The text is still saved — the prompt icon on this worktree's \
                    row will copy it or deliver it now.
                    """)
            return
        }

        // Let the pane past the measured dead window before typing into it.
        // `SessionStart` says a session exists, not that its TUI is reading the
        // pty, and there is no event that says the latter — see
        // `pendingPromptSettleDelay`, which carries the measurement.
        try? await clock.sleep(for: Self.pendingPromptSettleDelay)

        // ─── Re-asked immediately before typing, because both can change
        // under a suspended delivery ───
        //
        // This cycle has been suspended twice by now — through a readiness wait
        // bounded at 120s, and through the settle — and the eligibility answered
        // at `park` is a fact about a moment that has passed.
        //
        // The flag is the operator's kill-switch, and a switch that cannot stop
        // what is already in flight is not one: turning queued prompts off while
        // a cycle waits must stop the typing, not merely stop the next park.
        guard await queuedPromptEnabled() else {
            await notifyIfCurrent(
                worktreeID: worktreeID, armID: armID, terminalID: terminalID, reason: """
                    A prompt parked for this worktree was not delivered: queued prompts were \
                    switched off while it was waiting. The text is still saved — the prompt icon \
                    on this worktree's row will copy it, and can deliver it once queued prompts \
                    are enabled again.
                    """)
            return
        }
        // And the pane may have hibernated in that window — the agent process
        // killed and the pane respawned to a bare shell, with the row still
        // reading `kind == .claude`. Typing here would put the operator's words
        // at a shell prompt and, with the submit bit set, run them. The row is
        // the fact; the pane's rendered text is never consulted.
        guard let terminal = try? await db.terminals.get(id: terminalID) else {
            await notifyIfCurrent(
                worktreeID: worktreeID, armID: armID, terminalID: terminalID, reason: """
                    A prompt parked for this worktree was not delivered: its agent's pane could \
                    not be found. The text is still saved — the prompt icon on this worktree's \
                    row will copy it or deliver it now.
                    """)
            return
        }
        guard !terminal.isParked else {
            await notifyIfCurrent(
                worktreeID: worktreeID, armID: armID, terminalID: terminalID, reason: """
                    A prompt parked for this worktree was not delivered: its agent hibernated \
                    before the text could be typed, so its pane is a bare shell rather than a \
                    composer. The text is still saved — wake the session, then use the prompt \
                    icon on this worktree's row to deliver it.
                    """)
            return
        }

        // A park that landed during the settle armed its own cycle and owns the
        // delivery now. Without this check both cycles would type, and the
        // model would read the prompt twice — which is what "Deliver Now"
        // pressed twice looks like from here. It stays the LAST thing before
        // the send, so the guards above cannot widen the window it closes.
        guard isCurrent(worktreeID: worktreeID, armID: armID) else { return }

        guard await deliver(terminalID, text, submit) else {
            await notifyIfCurrent(
                worktreeID: worktreeID, armID: armID, terminalID: terminalID, reason: """
                    A prompt parked for this worktree could not be typed into its agent. The text \
                    is still saved — the prompt icon on this worktree's row will copy it or \
                    deliver it now.
                    """)
            return
        }
        // No generation check here, deliberately: the compare-and-swap is the
        // check. A cycle a later park superseded still delivered its own text,
        // and if the column has moved on the swap simply does not fire — which
        // is a stronger guarantee than a token comparison, because it also
        // covers a park that lands between the comparison and the write.
        do {
            _ = try await db.worktrees.clearPendingPrompt(
                worktreeID: worktreeID, ifTextIs: text, submit: submit)
        } catch {
            logger.warning("""
                queued prompt delivered to terminal \(terminalID.uuidString, privacy: .public) but \
                the column could not be cleared: \(error, privacy: .public)
                """)
        }
    }

    /// Notify only while this cycle still owns the arming — see `isCurrent`.
    private func notifyIfCurrent(
        worktreeID: UUID, armID: UUID, terminalID: UUID?, reason: String
    ) async {
        guard isCurrent(worktreeID: worktreeID, armID: armID) else { return }
        await notifyUndeliverable(
            worktreeID: worktreeID, terminalID: terminalID, reason: reason)
    }

    // MARK: - Facts and notices

    private func queuedPromptEnabled() async -> Bool {
        (try? await db.config.get())?.queuedPromptEnabled ?? Config.queuedPromptDefault
    }

    /// The worktree's primary agent terminal, or `nil` when none has spawned.
    /// The rule itself is `PrimaryTerminal.agent(in:)`, shared with the app so
    /// the two cannot end up describing different rows as the primary.
    private func primaryAgentTerminal(worktreeID: UUID) async -> Terminal? {
        PrimaryTerminal.agent(in: (try? await db.terminals.list(worktreeID: worktreeID)) ?? [])
    }

    /// Records a daemon notification and broadcasts it — the pattern
    /// `notifyPreSessionProblem` uses. The column is left holding the text, so
    /// the notice is a pointer at something recoverable rather than an epitaph.
    private func notifyUndeliverable(
        worktreeID: UUID, terminalID: UUID?, reason: String
    ) async {
        logger.warning("""
            queued prompt undeliverable for worktree \(worktreeID.uuidString, privacy: .public): \
            \(reason, privacy: .public)
            """)
        do {
            let notification = try await db.notifications.create(
                worktreeID: worktreeID,
                type: .attentionNeeded,
                message: reason,
                terminalID: terminalID
            )
            subscriptions?.broadcast(delta: .notificationReceived(NotificationDelta(
                notificationID: notification.id, worktreeID: notification.worktreeID,
                type: notification.type, message: notification.message,
                terminalID: notification.terminalID
            )))
        } catch {
            logger.error("""
                failed to record the undeliverable-prompt notification: \
                \(error.localizedDescription, privacy: .public)
                """)
        }
    }
}
