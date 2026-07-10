import Foundation

/// Prompt templates for the visible daywatch/nightwatch desk session.
public enum NightwatchDeskPrompts {
    /// Shared display name for the Watch Desk worktree.
    /// Used by both DeskSessionManager and NightwatchDeskStatusBanner to identify the desk session.
    public static let deskDisplayName = "◐ Watch Desk"

    /// Initial prompt when spawning the desk session.
    /// Sets context about the job, file locations, and expected behavior.
    public static func initialPrompt(mode: NightwatchMode) -> String {
        let modeLabel = mode == .daywatch ? "Daywatch" : "Nightwatch"
        let modelHint = mode == .daywatch ? "Sonnet" : "Opus"

        return """
        You are TBD's \(modeLabel) Judge — a \(modelHint) session monitoring merge-gate decisions.

        **Your workspace:**
        - You're running in the nightwatch skill directory (~/tbd/worktrees/watch-desk-*/scripts)
        - Decision queue: queue/decisions.jsonl (JSONL file of pending judgment items)
        - Report: queue/tick-report.json (latest tick status + stats)
        - Skill docs: /SKILL.md (full job description)

        **Your job (\(modeLabel)):**
        \(jobDescription(mode: mode))

        **Next step:**
        Read the Nightwatch skill docs for the full merge-gate policy, clearance types, and acting procedures.
        When you receive a nudge message, process queue/decisions.jsonl and output actions.
        """
    }

    /// Prompt sent when the daemon nudges the desk session with a batch of queued judgments.
    public static func judgePrompt(mode: NightwatchMode, dryRun: Bool) -> String {
        let actionHint: String
        if dryRun {
            actionHint = "(dry-run: predict actions but do NOT execute)"
        } else if mode == .daywatch {
            actionHint = "(daywatch: triage only; act on small_safe/preclear; batch rest for human review)"
        } else {
            actionHint = "(nightwatch: act on everything the gate allows)"
        }

        return """
        # \(mode == .daywatch ? "◐" : "🌙") Judge: Process Queued Decisions

        \(actionHint)

        **Process:**
        1. Read queue/decisions.jsonl (each line is a JSON decision)
        2. Apply the policy per the skill docs
        3. For each decision:
           - Daywatch: act ONLY if clearanceKind in [preclear, small_safe]; otherwise batch for human review
           - Nightwatch: act on everything the gate approves
        4. Write results to queue/acted.jsonl (one JSON line per action taken)
        5. Write a summary to queue/judge-summary.txt

        **Act:** Use `tbd terminal send --submit` to confirm each action, or batch AskUserQuestion if unsure.

        Start now.
        """
    }

    // MARK: - Private Helpers

    private static func jobDescription(mode: NightwatchMode) -> String {
        switch mode {
        case .daywatch:
            return """
            Triage decisions and act conservatively:
            - Act immediately only on small_safe/preclear clearances (safe, well-tested, low risk)
            - Batch everything else (experimental, novel, uncertain) into a human-review summary
            - Use AskUserQuestion for uncertain calls; never force-merge uncertain PRs
            """

        case .nightwatch:
            return """
            Act on everything the gate approves:
            - Merge PRs cleared by the policy (all clearance kinds)
            - Escalate blockers (conflicts, status checks) with context
            - Write a morning summary of all actions taken
            """

        case .off:
            return "ERROR: .off mode should never reach desk session"
        }
    }
}
