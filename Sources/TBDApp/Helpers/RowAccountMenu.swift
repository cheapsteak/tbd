import Foundation
import TBDShared

/// Typed presentation model for the hover-revealed "…" worktree-row menu,
/// headlined by per-session account switching.
///
/// Pure composition on top of `ProfileUsagePresentation` /
/// `ProfileLoginPresentation` — no AppKit, no strings past the boundary. The
/// view (`RowAccountMenuView`) lowers this model to a SwiftUI `Menu`; the swap
/// itself is a typed `RowAccountMenuAction` carrying the terminal + target
/// profile, dispatched by the view to `AppState.swapTerminalProfile`. Nothing
/// string-typed crosses back.
enum RowAccountMenu {
    // MARK: - Typed model

    /// One switch-target row inside a session's "Switch account" submenu: a
    /// logged-in profile the session could be forked onto, or a disabled
    /// not-logged-in / current-account row.
    struct SwitchTarget: Equatable, Identifiable {
        /// Profile this row targets. `nil` is never used — every target is a
        /// concrete profile (ambient is not offered as a switch destination
        /// here; the info header already names it).
        let profileID: UUID
        /// Two-line row content: "Work — a@b.co" over an indented, spelled-out
        /// usage line ("5h 0% · resets 23:10 · wk 76% · Fable 100%"). The
        /// secondary line is nil for not-logged-in / snapshotless profiles.
        let line: ProfileUsagePresentation.MenuLineModel
        /// True when this profile is the session's current account: shown with
        /// a checkmark and disabled (no-op swap).
        let isCurrent: Bool
        /// True when the profile has a detected login and can be forked onto.
        /// Not-logged-in profiles render disabled with `disabledReason`.
        let isSelectable: Bool
        /// Disabled-row explainer, e.g. "run /login first". nil when selectable
        /// (and not the current account).
        let disabledReason: String?

        var id: UUID { profileID }

        /// The action a click emits — nil for disabled rows (current account or
        /// not-logged-in), so the view can render them non-interactive.
        func action(terminalID: UUID) -> RowAccountMenuAction? {
            guard isSelectable, !isCurrent else { return nil }
            return RowAccountMenuAction(terminalID: terminalID, newProfileID: profileID)
        }
    }

    /// One Claude session in the worktree: an info header line plus the
    /// switch-account targets for that session's terminal.
    struct Session: Equatable, Identifiable {
        let terminalID: UUID
        /// "Claude 1", the tab label, etc. — human handle for the session.
        let label: String
        /// Account descriptor for the info header: "a@b.co (Work)",
        /// "ambient (terminal login)", "profile removed — …".
        let accountDescriptor: String
        /// Switch-account destinations, ordered for the picker (healthiest
        /// selectable first, not-logged-in last).
        let switchTargets: [SwitchTarget]
        /// True when the session is mid-run (activityState == .working). The
        /// seamless switch interrupts the current run, so the submenu footer
        /// warns about it. Cheap advisory; no confirm dialog for v1.
        let isBusy: Bool

        var id: UUID { terminalID }

        /// Per-session submenu footer: the shared switch caption, plus an
        /// interrupt warning when the session is mid-run.
        var switchFooter: String {
            isBusy
                ? "\(RowAccountMenu.switchAccountCaption) \(RowAccountMenu.interruptsRunSuffix)"
                : RowAccountMenu.switchAccountCaption
        }
    }

    /// Whole-menu model: the worktree's Claude sessions (each with its own
    /// switch submenu) plus the shared footer caption. `nil` when the worktree
    /// has no Claude sessions (the "…" menu still exists for non-account items,
    /// but `RowAccountMenu` contributes nothing).
    struct Model: Equatable {
        let sessions: [Session]
        /// Static explainer shown once at the bottom of the account section.
        let footer: String

        var isEmpty: Bool { sessions.isEmpty }
    }

    /// A resolved switch request: fork `terminalID`'s session onto
    /// `newProfileID`. Dispatched by the view to
    /// `AppState.swapTerminalProfile(terminalID:newProfileID:)`.
    struct RowAccountMenuAction: Equatable {
        let terminalID: UUID
        let newProfileID: UUID
    }

    // MARK: - Copy

    static let switchAccountLabel = "Switch account"
    static let notLoggedInReason = "run /login first"
    /// Whole-menu footer under the account section.
    static let footerCaption =
        "Switching account resumes this session in place on the new account — its context re-reads uncached once."
    /// Per-session "Switch account" submenu caption.
    static let switchAccountCaption =
        "Resumes in this tab on the new account."
    /// Appended to the submenu caption when the session is mid-run.
    static let interruptsRunSuffix = "— interrupts current run"

    // MARK: - Composition

    /// Build the account section for a worktree's "…" menu. Claude sessions in
    /// tab order; each carries its current-account descriptor and a full list of
    /// switch targets (current checkmarked+disabled, not-logged-in disabled).
    static func model(terminals: [Terminal],
                      profiles: [ModelProfileWithUsage],
                      timeZone: TimeZone = .current) -> Model {
        let claudeTerminals = terminals.filter { $0.kind == .claude || $0.isClaudeResumable }
        var claudeIndex = 0
        let sessions: [Session] = claudeTerminals.map { terminal in
            claudeIndex += 1
            return session(terminal: terminal,
                           fallbackIndex: claudeIndex,
                           profiles: profiles,
                           timeZone: timeZone)
        }
        return Model(sessions: sessions, footer: footerCaption)
    }

    /// One session's row: label, current-account descriptor, and switch targets.
    static func session(terminal: Terminal,
                        fallbackIndex: Int,
                        profiles: [ModelProfileWithUsage],
                        timeZone: TimeZone = .current) -> Session {
        Session(
            terminalID: terminal.id,
            label: sessionLabel(terminal: terminal, fallbackIndex: fallbackIndex),
            accountDescriptor: ProfileUsagePresentation.accountDescriptor(
                profileID: terminal.profileID, profiles: profiles
            ),
            switchTargets: switchTargets(currentProfileID: terminal.profileID,
                                         profiles: profiles,
                                         timeZone: timeZone),
            isBusy: terminal.activityState == .working
        )
    }

    /// Human handle for a session. Prefers the terminal's own label; falls back
    /// to "Claude N" using the caller's Claude-session index.
    static func sessionLabel(terminal: Terminal, fallbackIndex: Int) -> String {
        if let label = terminal.label?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return label
        }
        return "Claude \(fallbackIndex)"
    }

    /// Switch destinations for a session, in picker order. Every logged-in
    /// profile is a row: the current account is checkmarked + disabled, others
    /// are selectable; not-logged-in profiles are disabled with the /login hint.
    static func switchTargets(currentProfileID: UUID?,
                              profiles: [ModelProfileWithUsage],
                              timeZone: TimeZone = .current) -> [SwitchTarget] {
        ProfileUsagePresentation.sortedForPicker(profiles).map { entry in
            let selectable = ProfileUsagePresentation.isSelectable(entry)
            let isCurrent = entry.profile.id == currentProfileID
            return SwitchTarget(
                profileID: entry.profile.id,
                line: ProfileUsagePresentation.menuLine(for: entry, timeZone: timeZone),
                isCurrent: isCurrent,
                isSelectable: selectable,
                disabledReason: selectable ? nil : notLoggedInReason
            )
        }
    }
}
