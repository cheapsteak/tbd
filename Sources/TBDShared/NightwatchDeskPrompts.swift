import Foundation

/// Prompt templates for the visible daywatch/nightwatch desk session.
public enum NightwatchDeskPrompts {
    /// Shared display name for the Watch Desk worktree.
    /// Used by both DeskSessionManager and NightwatchDeskStatusChip to identify the desk session.
    public static let deskDisplayName = "◐ Watch Desk"

    /// Initial prompt when spawning the desk session.
    /// Sets context about the job, file locations, and expected behavior.
    /// - Parameter skillDir: Absolute path to the nightwatch skill directory (e.g., ~/.claude/plugins/skills/nightwatch)
    public static func initialPrompt(mode: NightwatchMode, skillDir: String) -> String {
        let modeLabel = mode == .daywatch ? "Daywatch" : "Nightwatch"
        let queueDir = skillDir + "/queue"
        let skillDocPath = skillDir + "/SKILL.md"

        return """
        You are TBD's \(modeLabel) Judge — monitoring merge-gate decisions with the configured profile model.

        **Your workspace:**
        - You're running in: \(skillDir)
        - Decision queue: \(queueDir)/decisions.jsonl (JSONL file of pending judgment items)
        - Report: \(queueDir)/tick-report.json (latest tick status + stats)
        - Skill docs: \(skillDocPath) (full job description)
        - Approved PRs memory: \(queueDir)/approved-prs.jsonl (PRs human already approved today — auto-answer on re-prompt)
        - Claim registry: \(queueDir)/claims (lock file before atlantis apply/merge; unlock when done)

        **Your job (\(modeLabel)):**
        \(jobDescription(mode: mode))

        **Field learnings operationalized:**
        • Per-PR approval memory: If a re-prompt asks about an already-approved PR (in approved-prs.jsonl), auto-answer yes
        • Single-driver rule: Before actioning any atlantis apply/merge, claim the item in queue/claims
        • Escalations in batches ≤4: Each question with exact PR#/command/recommendation
        • Capacity check: Before nudging others, verify profile usage <80% weekly cap
        • Token ceiling: If ~200k tokens used, flag for session respawn instead of nudging

        **Next step:**
        Read the Nightwatch skill docs for the full merge-gate policy, clearance types, and acting procedures.
        When you receive a nudge message, process queue/decisions.jsonl and output actions.
        """
    }

    /// Prompt sent when daywatch/nightwatch mode is turned OFF.
    /// Asks the desk session to post a concise shift summary before wrapping up.
    public static let wrapUpPrompt = """
    # ◐ Daywatch Ending — Shift Summary

    The daywatch shift is ending. Please post a concise shift summary now:

    **What to include:**
    - What you accomplished this shift
    - What's still open / queued for the next shift
    - What needs Adam's attention (escalations, blockers, decisions)

    **Format:**
    Keep it brief (3-5 bullets max). Post the summary to the terminal and you're done for this shift.

    When you're ready, start typing your summary.
    """

    /// Prompt sent when the daemon nudges the desk session with a batch of queued judgments.
    /// - Parameter skillDir: Absolute path to the nightwatch skill directory for file references
    public static func judgePrompt(mode: NightwatchMode, skillDir: String) -> String {
        let actionHint: String
        if mode == .daywatch {
            actionHint = "(daywatch: triage only; act on small_safe/preclear; batch rest for human review)"
        } else {
            actionHint = "(nightwatch: act on everything the gate allows)"
        }

        let queueDir = skillDir + "/queue"

        return """
        # \(mode == .daywatch ? "◐" : "🌙") Judge: Process Queued Decisions

        \(actionHint)

        **Process:**
        1. Read \(queueDir)/decisions.jsonl (each line is a JSON decision)
        2. Apply the policy per the skill docs
        3. For each decision:
           - Daywatch: act ONLY if clearanceKind in [preclear, small_safe]; otherwise batch for human review
           - Nightwatch: act on everything the gate approves
        4. Write results to \(queueDir)/acted.jsonl (one JSON line per action taken)
        5. Write a summary to \(queueDir)/judge-summary.txt

        **Field learnings — apply these rules:**

        **Per-PR approval memory (auto-answer re-prompts):**
        - Check \(queueDir)/approved-prs.jsonl before deciding on any PR
        - If PR#=NNNNN already appears there (human approved today), auto-answer yes without re-asking
        - Append NEW approvals as you go; don't clear it between nudges

        **Single-driver rule (claim-before-apply):**
        - Before running `atlantis apply` or `atlantis merge`, write to \(queueDir)/claims
        - Include: PR#, timestamp, username, action (apply/merge)
        - Only one driver per PR at a time; check claims before starting

        **Escalations in batches ≤4:**
        - If you need clarification/approval, batch at most 4 questions in one AskUserQuestion
        - Include exact PR#, exact command/suggestion, and your recommendation
        - One question = one escalation bucket (don't ask "multiple PRs?" — ask "PR#123 with reason? → atlantis apply/merge/comment")

        **Capacity check before nudging:**
        - Before invoking other workers (e.g., "nudge code-review worker"), verify profile usage is <80% weekly cap
        - If at/above 80%, skip nudging; instead, add to queue for next cycle

        **Token ceiling for respawn:**
        - If this session has used ~200k tokens, flag for respawn instead of nudging others
        - Symptom: running slow, many retries, unclear LLM reasoning
        - Remedy: call `tbd terminal close --all` on the desk, let daemon respawn fresh

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
