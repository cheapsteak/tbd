import Foundation
import Observation

/// Holds prompt cards on screen after their dialog has closed, until the
/// transcript catches up or a bounded timeout passes.
///
/// A dialog closes before its tool result reaches the transcript — about
/// 170 ms locally, a few seconds remotely. Without this, an answered card
/// would flick back to an ordinary pending row in that gap, and an appended
/// card (no row on disk yet) would vanish and reappear as a row. So:
/// - an answered card keeps showing its answer until the merge reports its
///   prompt settled (the tool result landed) or `retainFor` elapses;
/// - a card whose dialog closed some other way (answered in the terminal, the
///   session moved on) is held read-only for the same bounds;
/// - a card with no `tool_use_id` (`prompt-<id>`) can never be settled by a
///   row, so the timeout is what retires it.
///
/// Keyed by prompt id, which is unique across targets. The pane reports what
/// is live through ``observe(live:for:)`` and what has settled through
/// ``settle(_:)``, both from `.onChange`, never during a body evaluation;
/// ``cards(live:for:)`` is the read the body makes.
///
/// The answer controller (the interactive cards) calls
/// ``markAnswered(_:summary:)`` once a delivery succeeds.
@MainActor
@Observable
final class PromptCardRetention {
    private struct Held: Equatable {
        var presentation: PendingPromptPresentation
        let generation: UInt64
    }

    /// Prompt id → the card held for it. Observed: a change re-renders the
    /// panes that read ``cards(live:for:)``.
    private var held: [String: Held] = [:]

    /// What each target last reported live, so a prompt that disappears can be
    /// told apart from one that was never seen.
    @ObservationIgnored private var lastLive: [PromptAnswerTarget: [String: PendingPromptPresentation]] = [:]
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation: UInt64 = 0

    @ObservationIgnored private let retainFor: Duration
    @ObservationIgnored private let clock: any Clock<Duration>

    /// Called with a prompt id when its card retires on the timeout, so
    /// whoever keeps per-prompt state (the answer controller's drafts and
    /// delivery states) can drop it — a card retired this way is never
    /// reported settled.
    @ObservationIgnored var onRetire: (@MainActor (String) -> Void)?

    init(retainFor: Duration = .seconds(30),
         clock: any Clock<Duration> = ContinuousClock()) {
        self.retainFor = retainFor
        self.clock = clock
    }

    /// The cards a pane merges for `target`: the live prompts (an answered one
    /// still live shows its answer), then every held card that is no longer
    /// live, oldest first, marked ``PendingPromptPresentation/isLive`` false.
    func cards(live: [PendingPromptPresentation],
               for target: PromptAnswerTarget) -> [PendingPromptPresentation] {
        var out = live.map { prompt -> PendingPromptPresentation in
            guard let held = held[prompt.promptID], held.presentation.phase != .open else {
                return prompt
            }
            var shown = prompt
            shown.phase = held.presentation.phase
            return shown
        }
        let liveIDs = Set(live.map(\.promptID))
        let extra = held.values
            .map(\.presentation)
            .filter { $0.target == target && !liveIDs.contains($0.promptID) }
            .sorted { ($0.createdAt, $0.promptID) < ($1.createdAt, $1.promptID) }
            .map { held -> PendingPromptPresentation in
                var heldOnly = held
                heldOnly.isLive = false
                return heldOnly
            }
        out.append(contentsOf: extra)
        return out
    }

    /// Records what `target` reports live now. A prompt that was live on the
    /// previous report and is not any more is held as ``PromptCardPhase/closed``
    /// — unless it is already held (answered from the card), which keeps its
    /// answer and its original timeout.
    ///
    /// A prompt held as closed that is live again (a provider's poll missed
    /// it once, or a hook reconnected under the same id) is released: the
    /// dialog is open, so the card must be answerable again rather than
    /// read "Answered elsewhere". An answered hold is kept — TBD's answer is
    /// on its way, and the dialog has not caught up.
    func observe(live: [PendingPromptPresentation], for target: PromptAnswerTarget) {
        let now = Dictionary(live.map { ($0.promptID, $0) }, uniquingKeysWith: { first, _ in first })
        let before = lastLive[target] ?? [:]
        lastLive[target] = now.isEmpty ? nil : now
        for promptID in now.keys where held[promptID]?.presentation.phase == .closed {
            release(promptID)
        }
        for (promptID, prompt) in before where now[promptID] == nil && held[promptID] == nil {
            var closed = prompt
            closed.phase = .closed
            hold(closed)
        }
    }

    /// Forgets what `target` last reported live, for a pane that stops showing
    /// it. Without this, a pane mounted again later would compare its first
    /// report against the old one and hold every prompt that closed in the
    /// meantime as "Answered elsewhere". Cards already held keep their
    /// timeouts.
    func forgetLive(for target: PromptAnswerTarget) {
        lastLive[target] = nil
    }

    /// TBD delivered an answer to `prompt`; show `summary` until the tool
    /// result lands or the timeout passes.
    func markAnswered(_ prompt: PendingPromptPresentation, summary: String) {
        var answered = prompt
        answered.phase = .answered(summary: summary)
        hold(answered)
    }

    /// Drops held cards whose tool result reached the transcript — the merge's
    /// `settled` set.
    func settle(_ promptIDs: Set<String>) {
        for promptID in promptIDs where held[promptID] != nil {
            release(promptID)
        }
    }

    /// The phase a held card shows, or nil when nothing is held for the id.
    func heldPhase(for promptID: String) -> PromptCardPhase? {
        held[promptID]?.presentation.phase
    }

    /// How many cards are held. For tests.
    var heldCount: Int { held.count }

    private func hold(_ presentation: PendingPromptPresentation) {
        timers.removeValue(forKey: presentation.promptID)?.cancel()
        generation &+= 1
        let armed = generation
        held[presentation.promptID] = Held(presentation: presentation, generation: armed)
        let clock = self.clock
        let delay = retainFor
        let promptID = presentation.promptID
        timers[promptID] = Task { [weak self] in
            try? await clock.sleep(for: delay)
            // The generation, not cancellation, decides: a settle or a re-hold
            // that landed while this task was waking has moved past it.
            self?.retire(promptID, generation: armed)
        }
    }

    private func retire(_ promptID: String, generation: UInt64) {
        guard held[promptID]?.generation == generation else { return }
        release(promptID)
        onRetire?(promptID)
    }

    private func release(_ promptID: String) {
        held.removeValue(forKey: promptID)
        timers.removeValue(forKey: promptID)?.cancel()
    }
}
