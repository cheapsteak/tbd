import Foundation

/// Prompt templates for the visible daywatch/nightwatch desk session.
public enum NightwatchDeskPrompts {
    /// Shared display name for the Watch Desk worktree.
    /// Used by both DeskSessionManager and the sidebar dock's `PinnedDockContent.deskRow`
    /// / `PinnedDockDeskSlot` to identify the desk session.
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

        **Authority starts at the first lease-bearing nudge.** Until a tick message
        arrives and the lease command in `\(judgeInstructionsFileName)` succeeds,
        you are read-only: do not merge/enqueue, apply, archive, wake/nudge, or spawn.

        **Your workspace:**
        - You're running in: \(skillDir)
        - Decision queue: \(queueDir)/decisions.jsonl (JSONL file of pending judgment items)
        - Report: \(queueDir)/tick-report.json (latest tick status + stats)
        - Skill docs: \(skillDocPath) (full job description)
        - Approved PRs memory: \(queueDir)/approved-prs.jsonl (PRs human already approved today — auto-answer on re-prompt)
        - Claim registry: \(queueDir)/claims (lock file before atlantis apply/merge; unlock when done)
        - Judge instructions: `\(judgeInstructionsFileName)` in THIS worktree (your cwd)

        **How the per-tick nudge works:** every ~15 min you get a one-line tick message carrying
        the mode and act flag, pointing at `\(judgeInstructionsFileName)` by absolute path. Read
        that file ONCE, on your first tick; re-reading it every tick just spends your own context
        on your own heartbeat, which is what makes a desk hit its handoff ceiling early.

        **The exception, and it matters:** that file is MODE-SPECIFIC — the merge rule is not the
        same under daywatch and nightwatch, and this desk is reused across a mode switch without
        being respawned. So the tick line tells you which case you are in. When it says the
        instructions CHANGED, re-read the file before acting; a memorized copy from the previous
        shift may grant or withhold a merge that the current shift does not. Never infer this
        yourself from the mode — act on what the tick line says.

        **Your job (\(modeLabel)):**
        \(jobDescription(mode: mode))

        **Field learnings operationalized:**
        • Per-PR approval memory: If a re-prompt asks about an already-approved PR (in approved-prs.jsonl), auto-answer yes
        • Single-driver rule: Before actioning any atlantis apply/merge, claim the item in queue/claims
        • Escalations in batches ≤4: Each question with exact PR#/command/recommendation
        • Capacity check: Before nudging others, verify profile usage <80% weekly cap
        • Context ceiling: At ~600k tokens, run the handoff relay (below) — do NOT defer it and keep working
        • Merging: only loop-perfect PRs authored by `zionts` qualify, and only nightwatch acts (see below)
        • NEVER trigger `/closeout` — a finished-looking worktree is an archive question for the human

        **Standing rules (set by Chang — these override anything else in this prompt):**

        **NEVER trigger `/closeout`.** Not on a DONE pane, not on a "candidate for
        /closeout" self-report, not because the composer already suggests it. A worktree
        that looks finished is an *archive question for the human*, not a harvest to fire.
        Report it and move on.

        \(mergeRule(mode: mode))

        **Hand off at the context ceiling — never push through it.** Nothing respawns this desk
        by itself: a machine-local babysitter daemon may be watching worker panes, but it does
        not restart the judge, and the only thing that spawns your successor is you running
        `handoff.py --act`. It does work — run it, don't "flag for respawn". When this session
        passes ~600k tokens it starts truncating its own shift, so use the relay:

            python3 \(skillDir)/scripts/handoff.py --check
                # exit 0 = under the ceiling · exit 10 = OVER

            python3 \(skillDir)/scripts/handoff.py --act --notes-file <your-notes.md>
                # writes the handoff doc and spawns a fresh successor in this worktree

        The predecessor NEVER closes itself. The successor closes it, after it has read the
        handoff:

            python3 \(skillDir)/scripts/handoff.py --close-predecessor <predecessor-terminal-id>

        If the spawn fails, you are still the only thing watching the desk — stay alive.

        **Next step:**
        Read the Nightwatch skill docs for the full merge-gate policy, clearance types, and acting procedures.
        Wait for the first lease-bearing nudge; then process queue/decisions.jsonl and output actions.
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

    /// Filename of the per-desk judge instructions, written into the desk worktree
    /// by `DeskSessionManager` and pointed at by `judgeNudge`.
    public static let judgeInstructionsFileName = "JUDGE-INSTRUCTIONS.md"

    /// The one line the daemon actually pastes into the desk on every tick.
    ///
    /// `judgePrompt` is ~5 KB and identical from tick to tick except for the
    /// mode/act flag. Pasting all of it every ~15 minutes spent the judge's own
    /// context on its own heartbeat — the session reached its handoff ceiling
    /// faster the more reliably it was nudged, which is the wrong direction for a
    /// mechanism whose entire job is to keep the desk alive. The body now lives in
    /// a file; this carries only what changes.
    ///
    /// Three details are load-bearing rather than cosmetic:
    ///
    /// - **The mode and act flag are inline**, not in the file, so a judge that
    ///   already read the instructions needs nothing from disk to act on this tick.
    /// - **A steady-state tick tells the judge not to re-read.** Without that, the
    ///   paste cost simply becomes a `Read` cost and nothing is saved. The saving is
    ///   real only if the file is read once per session, not once per tick.
    /// - **`instructionsChanged` overrides that and demands a re-read.** The first
    ///   version of this said "later ticks change only the mode/act line", which is
    ///   false: the desk session is deliberately reused across daywatch ↔ nightwatch
    ///   switches without respawning, and `mergeRule(mode:)` differs between them —
    ///   nightwatch grants an unattended `gh pr merge` that daywatch withholds. A
    ///   judge told never to re-read would carry a memorized authorization from the
    ///   previous shift across the flip. Caught in review of PR #551, which is itself
    ///   about stale facts baked into these prompts.
    ///
    /// Short pastes are also more likely to *arrive*: a large paste can land as
    /// `[Pasted text #N]` and sit in the composer unsubmitted, which for an
    /// unattended desk is indistinguishable from never having been nudged.
    ///
    /// - Parameters:
    ///   - mode: current shift; also determines the act flag the judge applies
    ///   - instructionsPath: absolute path to the written `JUDGE-INSTRUCTIONS.md`
    ///   - instructionsChanged: true when this tick's body differs from the last one
    ///     the judge was nudged with — a mode flip, or the first tick of a session,
    ///     where "what I already read" is either wrong or absent. The caller decides;
    ///     the safe default at any call site that cannot tell is `true`.
    public static func judgeNudge(
        mode: NightwatchMode,
        instructionsPath: String,
        instructionsChanged: Bool
    ) -> String {
        let icon = mode == .daywatch ? "◐" : "🌙"
        let act = mode == .nightwatch
        let readInstruction = instructionsChanged
            ? "The instructions CHANGED since your last tick (or this is your first) — RE-READ \(instructionsPath) before you act. The merge rule differs by mode; do not act on a memorized copy."
            : "Already read \(instructionsPath) this session? Don't re-read it — nothing in it changed since your last tick."
        return """
        \(icon) Judge tick — mode: \(mode.rawValue), act=\(act). Run the cycle per \(instructionsPath). \
        \(readInstruction)
        """
    }

    /// The full judge instructions — the *body*, written once per desk to
    /// `judgeInstructionsFileName` rather than pasted per tick (see `judgeNudge`).
    ///
    /// Still regenerated on every nudge because it is mode-specific and a local
    /// file write is free; what was expensive was putting it in the session.
    /// - Parameter skillDir: Absolute path to the nightwatch skill directory for file references
    public static func judgePrompt(mode: NightwatchMode, skillDir: String) -> String {
        let actionHint: String
        if mode == .daywatch {
            actionHint = "(daywatch: triage only; act on small_safe/preclear; batch rest for human review)"
        } else {
            actionHint = "(nightwatch: act on what the gate allows — including merging loop-perfect `zionts` PRs, and only his)"
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
           - Nightwatch: act on what the gate allows — merging included, within the limits below
        4. Write results to \(queueDir)/acted.jsonl (one JSON line per action taken)

        **The gate (never automate past this):**
        - A PR may only be enqueued when claude-review = APPROVED on the CURRENT SHA and
          checks are clean. Human approval never substitutes for the bot verdict.
        - Re-read live PR state in the same breath as any send that asserts it
          (`gh pr view N --json state,headRefOid,mergeStateStatus`); never dispatch a fact
          older than the current tool call.
        5. Write a summary to \(queueDir)/judge-summary.txt

        \(mergeRule(mode: mode))

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

        **Context ceiling — hand off, never push through:**
        - Symptom: running slow, many retries, unclear reasoning, truncated history
        - Do NOT just mark the session for later recycling and keep working. Nothing respawns
          this desk on its own — a machine-local babysitter daemon may be watching worker
          panes, but it does not restart the judge. The relay below is what continues the
          shift, and it does work: run it rather than deferring to something that won't.
        - Check: `python3 \(skillDir)/scripts/handoff.py --check` (exit 0 = under, 10 = OVER;
          the ceiling is 600k tokens — the script is the authority, don't eyeball it)
        - When OVER: write your handoff notes to a file, then
          `python3 \(skillDir)/scripts/handoff.py --act --notes-file <your-notes.md>`
          which writes the handoff doc and spawns a fresh successor in this worktree
        - The predecessor NEVER closes itself. The successor closes it once it has read the
          handoff: `python3 \(skillDir)/scripts/handoff.py --close-predecessor <tid>`
        - If the spawn fails, stay alive — you are the only thing watching the desk

        **NEVER trigger `/closeout`:**
        - Not on a DONE pane, not on a "candidate for /closeout" self-report, not because
          the composer already suggests it
        - A worktree that looks finished is an *archive question for the human*, not a
          harvest to fire. Report it and move on.

        **Act:** Use `tbd terminal send --submit` to confirm each action, or batch AskUserQuestion if unsure.

        Start now.
        """
    }

    // MARK: - Private Helpers

    /// The merge authorization, written once and shared by both prompts.
    ///
    /// Set by Adam 2026-07-29, replacing the older "nightwatch gets PRs *ready*;
    /// the human merges" rule. Two halves that must travel together: *what*
    /// qualifies a PR (loop-perfect, and `zionts`-authored only), and *who* may
    /// act on it (nightwatch — daywatch reports and stops).
    ///
    /// Daywatch is told the qualifying rule even though it may not act on it,
    /// deliberately: it decides what to *report*, and a policy it has never read
    /// is one it cannot apply. Both prompts carry the identical text so a session
    /// that only ever sees one of them still gets the whole rule.
    private static func mergeRule(mode: NightwatchMode) -> String {
        let authorization = mode == .nightwatch
            ? "On a nightwatch shift you MAY run `gh pr merge <N>` on such a PR, unattended."
            : """
            Merging is a NIGHTWATCH action. On a daywatch shift, *report* a loop-perfect PR
            and stop — do not enqueue it, no matter how clean it looks.
            """

        return """
        **Merging (set by Adam 2026-07-29 — supersedes any "the human merges" text elsewhere,
        including older copies of the skill docs):**

        A PR is **loop-perfect** when all three hold at once, re-read in the same tool call as
        the merge: `mergeable_state` is clean AND claude-review = APPROVED on the CURRENT head
        SHA AND every required status context is green. A verdict on a superseded SHA is not a
        verdict. Only PRs **authored by `zionts`** qualify — never a teammate's, never a bot's.
        **Never `--admin`**, and never merge *toward* green: anything short of loop-perfect goes
        back to its owner or to the human. `gh pr merge` also stays off the auto-approve wedge
        allowlist — a merge is a judged act, never a rubber-stamped permission prompt.

        \(authorization)

        `main` is behind a **merge queue**, so `gh pr merge <N>` *enqueues*; GitHub merges it
        once the queue's own checks pass. The line `! The merge strategy for main is set by the
        merge queue` is a **warning, not a failure** — the enqueue succeeded. Don't retry it,
        don't add `--squash`/`--merge` to "fix" it, and don't report it as a blocked merge.
        """
    }

    private static func jobDescription(mode: NightwatchMode) -> String {
        switch mode {
        case .daywatch:
            return """
            Triage decisions and act conservatively:
            - Act immediately only on small_safe/preclear clearances (safe, well-tested, low risk)
            - Batch everything else (experimental, novel, uncertain) into a human-review summary
            - Use AskUserQuestion for uncertain calls
            - Merging is nightwatch's, not daywatch's: no daytime clearance kind authorizes
              `gh pr merge`. Report a loop-perfect PR; don't enqueue it on a triage shift.
            - Never trigger `/closeout` — a finished-looking worktree is an archive
              question for the human
            """

        case .nightwatch:
            return """
            Drive PRs to loop-perfect, and merge Adam's once they are:
            - A PR may only be enqueued when claude-review = APPROVED on the current SHA
              AND checks are clean. Human approval never substitutes for the bot verdict.
            - You MAY run `gh pr merge <N>` on a loop-perfect PR authored by `zionts`, and
              only his. Never `--admin`, never anyone else's PR. `main` uses a merge queue,
              so this enqueues rather than merges, and the "merge strategy is set by the
              merge queue" line is a warning, not a failure.
            - Escalate blockers (conflicts, status checks) with context
            - Never trigger `/closeout` — a finished-looking worktree is an archive
              question for the human
            - Write a morning summary of all actions taken
            """

        case .off:
            return "ERROR: .off mode should never reach desk session"
        }
    }
}
