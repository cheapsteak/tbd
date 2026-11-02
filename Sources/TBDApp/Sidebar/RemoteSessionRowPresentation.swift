import Foundation
import TBDShared

/// The pure decisions behind a remote-session row: its caption, its staleness
/// note, and what its suffix slot shows. A remote session renders through the
/// same vocabulary a local row does (`RowStatusIndicator.leading`, `.suffix`,
/// `.shouldBoldName`): it is a session first, a remote one second. There is
/// no liveness dot and no attention chip, because local rows never advertise
/// raw process liveness.
///
/// View-free, so `SidebarRowModelFactory` and a test call the same rule.
enum RemoteSessionRowPresentation {
    /// Pure `agentState` + unread-entry → suffix-slot mapping.
    ///
    /// Feeds the SAME `notification` argument a worktree row feeds
    /// `RowStatusIndicator.suffix` — the higher-severity of the row's edge-
    /// triggered unread entry (e.g. `.error` from a nonzero exit) and the
    /// steady-state `agentState` mapped into the same `NotificationType`
    /// vocabulary (`waitingInput` → `.attentionNeeded`). This is a merge of
    /// two inputs into `suffix`'s existing precedence ladder, not a second
    /// ladder: `RowStatusIndicator.suffix` alone still decides what renders.
    /// Without the unread half of this merge, a session that exits nonzero
    /// would render with NO suffix at all (agentState is `.exited`, which
    /// maps to no steady signal) even though `unreadByRemoteSession` holds
    /// `.error` for it — the loudest case rendering as the quietest row.
    ///
    /// The steady half is STEADY, not edge-triggered — deliberately diverges
    /// from local edge semantics. See `AppState.handleRemoteSessionAttentionDelta`'s
    /// doc comment (`AppState+Remote.swift`) for the full rationale: the
    /// contract reports `agent_state` continuously in every poll, exactly
    /// like `.working` (already rendered steady below), and a remote
    /// session has no pane the user can glance at to rediscover it — so
    /// this reads `agentState` fresh on every build rather than relying
    /// solely on the edge-triggered `unreadByRemoteSession` map (which clears
    /// the moment the session is selected, even if it's still waiting).
    ///
    /// The merge runs the unread half through `suffixContribution` first, so
    /// the edge may only ADD what the steady axis cannot express. See that
    /// function for what went wrong when it could also keep asserting
    /// attention the steady axis had withdrawn.
    static func suffixIndicator(
        agentState: RemoteAgentState, unreadType: NotificationType?
    ) -> SuffixRowIndicator? {
        let steadyType: NotificationType? = agentState == .waitingInput ? .attentionNeeded : nil
        return RowStatusIndicator.suffix(
            notification: higherSeverity(
                suffixContribution(of: unreadType, agentState: agentState), steadyType),
            isWorking: agentState == .working,
            isSuspended: false,
            isHibernated: false
        )
    }

    /// What the row's unread entry may contribute to the SUFFIX slot, given
    /// what the agent axis currently says.
    ///
    /// The unread map exists to add signals the steady axis cannot express —
    /// an `.error` from a nonzero exit, a `.responseComplete`. It must never
    /// keep asserting attention the steady axis has since withdrawn, and
    /// `.attentionNeeded` is nothing but a restatement of `waiting_input`.
    ///
    /// Without this, the hand latched. `unreadByRemoteSession` is edge-
    /// triggered and clears only when the user selects the session
    /// (`AppState+Navigation`), while `.attentionNeeded` outranks `isWorking`
    /// in `RowStatusIndicator.suffix` — so a session that asked for input
    /// once, was answered elsewhere, and went back to work kept its hand
    /// until somebody clicked it. Across a fleet that is a wall of hands over
    /// sessions that are all working, which costs the glyph its meaning
    /// exactly when a genuine one appears among them.
    ///
    /// The BOLD name is deliberately left latched: it says "you have not
    /// looked since this happened", which stays true after the session
    /// resumes, and it is cleared by looking. The suffix glyph says "this is
    /// true right now", and that is the claim this function keeps honest.
    static func suffixContribution(
        of unreadType: NotificationType?, agentState: RemoteAgentState
    ) -> NotificationType? {
        // The two types `RowStatusIndicator.suffix` renders as the hand.
        // `.focusRequest` is not currently produced for remote rows
        // (`AppState.remoteUnreadType` yields only `.attentionNeeded`,
        // `.error` and `.responseComplete`), and is covered anyway so that a
        // future edge cannot reintroduce the latch by another name.
        guard unreadType == .attentionNeeded || unreadType == .focusRequest else {
            return unreadType
        }
        return agentState == .waitingInput ? unreadType : nil
    }

    /// The higher-severity of two optional `NotificationType`s (nil sorts
    /// lowest). Uses the existing `NotificationType.severity` ordering — no
    /// new precedence scale invented here.
    static func higherSeverity(_ a: NotificationType?, _ b: NotificationType?) -> NotificationType? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let x?, nil): return x
        case (nil, let y?): return y
        case (let x?, let y?): return x.severity >= y.severity ? x : y
        }
    }

    /// Caption shown under the name. `gone` wins over process `state`: it's a
    /// distinct, more severe axis (absent from the provider's list entirely —
    /// see `docs/remote-provider-contract.md` § Identity & drift — not merely
    /// exited), so the two captions never stack. Exit code is omitted when
    /// the provider didn't report one.
    ///
    /// `staleness`, when non-nil (see `stalenessCaption`), is appended after
    /// a " · " separator — the same combining idiom
    /// `ProfileUsagePresentation.retryingNote` uses for "usage unavailable —
    /// retrying · last data 2h ago". When there's no other caption to
    /// combine with (a plain `running` session under an unhealthy provider),
    /// `staleness` renders alone rather than being dropped: a row that
    /// otherwise looks completely normal during an outage is exactly the case
    /// it exists for.
    static func caption(
        state: RemoteProcessState,
        agentState: RemoteAgentState,
        gone: Bool,
        exitCode: Int?,
        staleness: String? = nil
    ) -> String? {
        RemoteSessionStatePresentation.sidebarCaption(
            terminalState: state,
            agentState: agentState,
            gone: gone,
            exitCode: exitCode,
            staleness: staleness
        )
    }

    /// "as of 2h ago" style note shown when this session's provider isn't
    /// `.ok` — the row-level (as opposed to provider-header-level) staleness
    /// signal. Needed because a remote session grouped into its repo's own
    /// sidebar section sits under a REPO header, nowhere near the provider
    /// header's health glyph — that glyph alone is invisible for a matched
    /// session, so without this, a two-hour outage would leave a grouped row
    /// looking completely fresh (its `agentState` caption reflecting whatever
    /// was last polled, with no cue that it's old). Deliberately reuses
    /// `ProfileUsagePresentation.ageText` — the one relative-age formatter
    /// this codebase already has ("just now"/"3m"/"2h"/"1d") — rather than
    /// inventing a second one. Returns nil when healthy so a fully-working
    /// provider's rows never carry the extra text.
    static func stalenessCaption(
        health: ProviderHealth, lastSuccessfulSnapshotAt: Date, now: Date = Date()
    ) -> String? {
        guard health != .ok else { return nil }
        let age = ProfileUsagePresentation.ageText(since: lastSuccessfulSnapshotAt, now: now)
        // `ageText`'s "just now" already reads as a complete phrase (see its
        // own callers in `ProfileUsagePresentation`) — appending "ago" to it
        // would read as "as of just now ago". Every other bucket ("3m",
        // "2h", "1d") needs the suffix.
        return age == "just now" ? "as of just now" : "as of \(age) ago"
    }
}
