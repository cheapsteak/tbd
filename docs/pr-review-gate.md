# Claude PR review merge gate

`main` requires the `claude-review` status check to pass before a PR can merge
(alongside `test` and `Lint`). The check is produced by the `claude-review` job in
[`.github/workflows/claude-code-review.yml`](../.github/workflows/claude-code-review.yml),
which runs the specialist fan-out pipeline described in
[`docs/specs/2026-08-03-pr-review-fanout-design.md`](specs/2026-08-03-pr-review-fanout-design.md):
deterministic script bookends around one model session that fans out to two
specialist subagents.

**Branch protection matches a required check by job NAME, not by workflow file.**
Exactly one job across `.github/workflows/` may therefore be named `claude-review`;
a second one would report into the same required context. That is why the retired
single-session reviewer, kept as a restoration source in
[`claude-code-review-legacy.yml`](../.github/workflows/claude-code-review-legacy.yml),
names its job `claude-review-legacy` and triggers only on `workflow_dispatch`.
Dispatching it reviews nothing — see [below](#the-legacy-single-session-workflow) for
why, and for what reviving it actually takes.

## How a PR is gated

1. **Trigger.** The workflow runs on `pull_request_target`, so it executes in the
   base-repo context with repository secrets — the only way a public repo can run
   a token-bearing review on a fork PR. It fires for same-repo and fork PRs alike.
2. **Trust gate (per-step).** A PR is *trusted* when the branch was pushed to this
   repo, or the author has **push access** to it (`admin` / `maintain` / `write`
   from `GET /repos/{owner}/{repo}/collaborators/{user}/permission`). Only trusted
   PRs have their head checked out and reviewed. An **untrusted fork** never has
   its code checked out or executed, and it produces a **failing** `claude-review`
   check (not a skipped one that would silently satisfy the required gate). To get
   an untrusted fork reviewed, a maintainer pushes the branch to this repo.

   The gate deliberately checks *effective permission*, not the PR's
   `author_association`. `COLLABORATOR` is handed to anyone invited to collaborate
   at **any** level — read-only and triage included — and `MEMBER` would cover every
   org member if this repo ever moved under an org. Because a trusted author gets
   their branch's tooling executed next to the review secrets (see below), the gate
   must admit only people who could already push a branch here and run this workflow
   directly. Two implementation notes: on a **public** repo the endpoint returns
   `read` for a total stranger rather than 404, so `read` and `none` are both
   untrusted; and the probe runs on every event (its result is ignored for same-repo
   PRs) so each run logs the permission it resolved. A failed probe is untrusted for
   forks and harmless for same-repo branches. The default `GITHUB_TOKEN` reads this
   endpoint with only `contents: read` — verified in Actions — so the reviewer App
   token is still minted after the gate rather than before it.
3. **Prepare.** `prepare.py` resolves the PR's merge base with the base branch and
   pins that SHA for the rest of the run, computes the head diff's patch-id over
   it, and reads the markers off the newest prior review comment. When the
   patch-ids match, the run re-asserts the recorded verdict as its own check result
   and spends no review; otherwise it runs the full pipeline. A missing or
   unreadable prior comment fails toward a full review, never toward a skip. A
   merge base that cannot be resolved fails the job outright — see
   [below](#the-merge-base-goes-missing-two-ways-and-only-one-is-repairable-in-the-workflow).
   The same script fetches the PR's description and discussion and writes them to
   `discussion-context.txt` for the session to read.
4. **Review.** One model session orchestrates two specialist subagents
   (`correctness`, `conventions`). Each specialist writes a schema-validated
   `findings-<name>.json`; the orchestrator merges them into `review-result.json`
   with a per-finding disposition list and the review comment's prose. The session
   holds **no GitHub write tool** — it posts nothing.
5. **Verdict.** `validate.py`, not the model, computes the verdict: it
   schema-validates the findings and the merged result, checks the disposition list
   accounts for every specialist finding id, and writes `REJECT` to `verdict.txt`
   iff any HIGH or MEDIUM finding survives the merge, otherwise `APPROVE`. It also
   checks the fan-out was *complete* — every lens named in the job's
   `REVIEW_SPECIALISTS` must have produced a findings file the schema accepts — so
   half a review can never read as a clean one. A `Stop` hook keeps the session
   alive long enough to produce that material; see
   [below](#keeping-the-session-alive-long-enough-to-report). The job then enforces
   the verdict with an exact string match: `APPROVE` passes, `REJECT` blocks the
   merge, and anything else (missing / malformed / killed session) fails closed.

Every file the pipeline reads back out of the workspace — `review-result.json`,
`verdict.txt`, `skip-decision.json`, `discussion-context.txt`, `findings-*.json` —
is deleted after checkout, before anything runs, so a PR cannot pre-commit a forged
`verdict.txt=APPROVE` or a skip decision and approve itself.

## Keeping the session alive long enough to report

The review session runs headless, where ending a turn ends the whole process — and a
specialist subagent still working when that happens does not get its findings file
onto disk. A review that needs roughly ten minutes must therefore be held open, while
a session that will never produce a result must still terminate. Four mechanisms
split that difference; the thresholds and the reasoning behind them are in
[`docs/specs/2026-08-10-review-orchestrator-liveness-design.md`](specs/2026-08-10-review-orchestrator-liveness-design.md).

- **The hook holds, uncounted, while specialist findings are pending.**
  [`claude-review-v2/hooks/stop-hook.sh`](../.github/workflows/claude-review-v2/hooks/stop-hook.sh)
  runs every time the session tries to end, and learns which files to expect from
  the job-level `REVIEW_SPECIALISTS` variable — the same declaration that supplies
  `validate.py`'s `--expected-specialists`, so a hook and a validator that must
  agree about the lens set cannot drift apart. While any expected
  `findings-<name>.json` is absent or unparseable, the hook blocks the stop with a
  reason telling the orchestrator its specialists are still running, and **spends
  none of its nudge budget** doing so: a session that cannot comply yet is not a
  session refusing to. The hold is bounded by a 25-minute wall clock, past which
  the hook stands aside — measured from the session's first stop attempt, not from
  the start of the job.
- **Each hold sleeps 30 seconds before it blocks.** A block costs a turn, and the
  session's `--max-turns` budget runs out well before 25 minutes of holding would;
  sleeping spends wall clock instead, which is what makes the deadline the real
  bound. Two numbers follow from it and must move together: the hook's command
  timeout in `hooks/settings.json` is 60 seconds, strictly greater than the sleep,
  because a hook killed mid-sleep emits no block at all; and the defensive cap of
  60 holds is 30 minutes of sleeping, so the 25-minute deadline still binds first.
- **The hook nudges, boundedly, once only the merge is missing.** When every
  expected findings file is present and parses but `review-result.json` is not
  there, the model has all its inputs and is simply not writing the merge. The hook
  blocks with instructions for writing that file and counts the block, giving up
  after five. The count applies to this state alone.
- **The hook always exits 0.** Empty stdin, an absent `jq`, an unwritable state
  file — none of them may wedge the session, because allowing a stop is never a
  gate bypass. `validate.py` fails closed downstream regardless. Two of those cases
  resolve toward releasing rather than holding: state that cannot be persisted
  defeats both bounds at once, so the hook stands aside instead of holding forever,
  and with `jq` off `PATH` a present non-empty file counts as ready, so a finished
  review is never reported as a running one.
- **The job carries `timeout-minutes: 45`.** A session that wedges rather than ends
  would otherwise run to GitHub's six-hour cap while the author waits on a check
  that never reports.

### Telling a stalled session from a rejected diff

A red `claude-review` is not always a rejected diff, and the two call for opposite
responses. `validate.py` writes no `verdict.txt` on any validation failure, so the
distinguishing error line in the job log is what an operator reads:

- **A stalled session** — `the review session produced NOTHING: no specialist
  findings file and no review-result.json`. No lens reported and no merge was
  written, so no code was reviewed at all. Treat it as an infrastructure failure
  rather than a verdict, and read nothing into it about the diff. Re-running the
  check may clear it, because the underlying failure is a race; a stall that
  recurs is a pipeline defect to fix, not a check to re-run.
- **A partial fan-out** — one lens named as having produced no findings file while
  another reported. The session ran and the review is incomplete.
- **A findings file the schema rejected** — a lens named as having produced a file
  that failed validation, printed directly beneath the schema error itself. That
  lens *did* run; its output was discarded, and the schema error above is the thing
  to act on.
- **A broken invocation** — `--expected-specialists` supplied while naming no lens,
  which is what an unset or blank `REVIEW_SPECIALISTS` expands to. Nothing can be
  checked, so nothing is trusted.

All four fail closed, and none of them posts a review comment: the post step runs
only behind a trustworthy verdict. A stall is therefore something you read in the
run — `validate.py` writes the diagnosis to the job log — never on the PR. Whatever
a step annotation or check summary shows alongside it is the workflow's and GitHub's
rendering of a failed step; the log line is the part the scripts guarantee.

## Trusted fork PRs need `allow-unsafe-pr-checkout`

`actions/checkout` v7.0.0 added a hard refusal to check out a fork PR head under
`pull_request_target` (and `workflow_run`), and **backported it to the floating
`v4` tag in v4.4.0 on 2026-07-20** — so a workflow pinned to `actions/checkout@v4`
picked up the breaking change without any edit. Its condition is purely
`event_name` plus `head.repo != base.repo`; it has no view of the author-trust step
that precedes it. The result was that *every* fork PR — including a
`COLLABORATOR`'s — failed the required `claude-review` check at checkout (PR #545).

The checkout step therefore sets `allow-unsafe-pr-checkout: true`. Because that
step is already gated on `trusted == true`, the opt-in restores exactly the
pre-v4.4.0 behavior and adds no new exposure: untrusted fork code still never
reaches the checkout.

### The merge base goes missing two ways, and only one is repairable in the workflow

The review's entire subject is the PR's diff against its merge base, so a missing
merge base is the one infrastructure failure that can make the gate produce a
*confident wrong answer* rather than no answer. Two mechanisms destroy it, at
opposite ends of the job.

**A fork PR's checkout is shallow even with `fetch-depth: 0`.** The head SHA is not
reachable from any base-repo branch, so `actions/checkout` fetches that commit on
its own and the clone stays shallow — `origin/<base>` ends up holding a single
commit with no common ancestor with `HEAD`. Measured on PR #545, the first fork PR
through this gate:

```
git rev-parse --is-shallow-repository   -> true
git log --oneline origin/main | wc -l   -> 1
git diff origin/main...HEAD             -> fatal: no merge base
```

**The review action's own session setup re-fetches the base branch at limited
depth**, inside the session step and therefore after every workflow-level guard.
When the base branch has advanced since checkout, that fetch force-moves
`refs/remotes/origin/<base>` to the new tip and records that tip in `.git/shallow`
— a graft that severs the ref's ancestry in a repo that was complete a moment
before. Measured on PR #614, runs 31497107005 and 31504414058: the workflow's
merge-base step verified a merge base (8b9b9b8) in both runs, and inside the
session `git merge-base origin/main HEAD` then failed and
`git diff origin/main...HEAD` reported `fatal: no merge base`. The failure is
reproducible locally with `git fetch --depth=1 origin main` into a complete clone
after the remote branch has moved.

That second mode is what makes this dangerous rather than merely degrading. A
three-dot diff simply errors; a two-dot diff against the *moved* ref succeeds and
reports every other PR merged in the interval as if this PR reverted it. In run
31504414058 that produced a REJECT whose findings cited files the PR never touched.
A review that cannot see the diff is recoverable; a review that confidently
describes a different diff is not.

**The merge base is therefore pinned, not re-derived.** `prepare.py` runs before
either mechanism can act, resolves `git merge-base origin/<base> HEAD` once, and
records the SHA in `skip-decision.json` and in the prepare step's `merge_base`
output. The session prompt hands that literal SHA to the orchestrator and to each
specialist, instructs them to diff with `git diff <merge-base> HEAD`, and forbids
naming `origin/<base>` in a diff at all — in any form, three-dot, two-dot, or
two-argument. A SHA-addressed diff walks no ancestry and both of its endpoints are
local objects, so the graft cannot corrupt it. `git diff origin/<base>...HEAD` and
`git diff <merge-base> HEAD` are the same diff, which is also what keeps patch-ids
comparable with the markers earlier runs recorded.

Pinning protects the diff; it cannot protect history walks. When the PR is up to
date with its base, the grafted commit sits on HEAD's own ancestry, and
`git blame` / `git log <path>` stop there silently — blame attributes every older
line to the boundary commit. The prompt therefore tells the session how to detect
the graft (`cat .git/shallow` — the `Bash(cat:*)` grant already covers it), to
avoid premise-audit conclusions that depend on history beyond the boundary, and to
note the limitation in the review diagnostics.

**Both merge-base checks fail closed, and say they are not verdicts.** The **Ensure
a merge-base with the base branch** step runs `git fetch --unshallow origin` when
(and only when) the clone is shallow — `--unshallow` errors on a complete repo —
then resolves the merge base. If that fails it fetches the base branch explicitly
and retries — with `--unshallow` when a shallow boundary still exists, because a
plain fetch into a shallow repo stops at the boundary and adds no ancestry; if it
fails again the step prints an `::error::` naming
the failure as review infrastructure, not a verdict on the PR, and exits 1.
`prepare.py` applies the same rule at its own layer: an unresolvable merge base
aborts the run non-zero *without writing* `skip-decision.json` or
`discussion-context.txt`, which fails the job and skips every downstream step. So
an aborted run posts nothing and records no patch-id or verdict marker — the next
run reviews from scratch rather than inheriting a cached opinion formed without a
diff. Don't relax either check on the assumption `fetch-depth: 0` covers this; it
doesn't, and a merge base verified at one step says nothing about the next.

### The PR's description reaches the session deterministically

`prepare.py` fetches the PR's title, body, and author through the same GraphQL call
that collects the discussion, and renders them as the first item inside
`discussion-context.txt`'s untrusted-data fence, kind `pr-description`. Nothing
depends on the model choosing to run `gh pr view` — in the PR #614 runs the session
ran no `gh` command at all, and its orchestrator told both specialists that no PR
description was available to them. The description is the premise the correctness
specialist audits ("extract every factual claim the PR description makes about
existing code"), so a lens that never receives it is auditing nothing.

Four properties follow from that role:

- **It bypasses the bot filter**, which drops bot-authored *comments*. A
  bot-opened PR's description is still the statement of intent the diff is measured
  against.
- **An empty body renders an explicit "(the PR has no description)" item**, so the
  session can tell a PR that has no description from a description it could not
  obtain.
- **It carries its own 8000-character cap**, against 1500 for a discussion item,
  and the whole-block cap sheds only discussion items — a long comment thread can
  never push the description out of the block.
- **An empty `discussion-context.txt` means the fetch failed.** With a description
  always present on success, the empty file is unambiguous, and the prompt tells the
  session to treat it as "description unavailable" and to report it in the review
  diagnostics.

The description is sanitized exactly like every other body: HTML comments stripped
whole (so a quoted state marker cannot masquerade as the pipeline's own), then
angle brackets escaped.

### What a trusted author's branch can execute

The opt-in is only defensible because of the push-access gate above, so it is worth
being explicit that "we never build the PR" does **not** mean "we never run its
code." The review job runs on `ubuntu-latest` and never invokes `swift build`, but
the checked-out tree still reaches three execution paths:

- **`.mcp.json`.** `claude-code-action` unconditionally sets
  `enableAllProjectMcpServers = true` when it writes its settings file, so MCP
  servers declared in a repo-root `.mcp.json` are launched at startup with no
  approval step. A branch that adds one gets arbitrary command execution directly.
- **Project hooks.** `.claude/settings.json` is tracked here and registers a
  `PreToolUse` hook running `.claude/hooks/guardrails/dispatch.py` on every `Bash`
  and `Skill` call. Both files come from the checked-out branch, and the reviewer
  always runs `Bash`. Restoring the pipeline directory from base does not prevent
  this: the action merges the `settings:` input into `~/.claude/settings.json` (the
  *user* layer, lowest priority) rather than passing `--settings`, and hooks merge
  additively across layers — so the base-branch Stop hook cannot displace or
  suppress a project-layer hook the branch adds.
- **`CLAUDE.md`.** Every tracked `CLAUDE.md` is auto-loaded as instructions and is
  branch-controlled, against an allowlist that carries read-only `gh` and `git`
  subcommands plus `Read`/`Write`/`Glob`/`Grep`/`Task`.

The job holds `CLAUDE_CODE_OAUTH_TOKEN`, the minted reviewer App token, and
default-branch cache scope. The accepted residual risk is therefore precisely: an
author who already has push access can run code beside those secrets — which they
could equally do by pushing a branch. Anyone below push access cannot reach any of
it. Keep that equivalence intact when editing the trust step; it is the entire
argument for the opt-in.

**Land changes to this workflow from a branch in this repo, never from a fork.**
Under `pull_request_target` the workflow config is read from the *base* branch, so
a fork PR that fixes the review workflow is still reviewed by the unfixed version
and blocks itself. (Same root cause as the trigger-change bootstrap gap above.)

## Changing the workflow's trigger needs an admin merge

GitHub picks the workflow version to run from different refs per event: a
`pull_request` event reads the config from the **PR head**, while a
`pull_request_target` event reads it from the **base branch**. A PR that changes
the *trigger event itself* therefore matches neither the old nor the new trigger
and gets no `claude-review` run — which leaves the required check unreported and
the PR blocked. That is a one-time bootstrap gap: land such a PR with an admin
merge, after which every subsequent PR is gated normally.

## Reading a review comment

The gate's comment behavior is worth knowing before you read a reviewed PR:

- **One comment per review, posted by the workflow.** The review session holds
  no GitHub write tool at all. It writes `review-result.json`; the workflow
  renders that file's `comment_body` into a comment body and posts it. Nothing
  is edited in place, so each review of each diff stays on the record as its own
  comment.
- **Each comment carries its own machine-read state.** Three leading HTML
  comments — a `<!-- claude-review-v2 -->` sentinel plus the reviewed patch-id
  and the computed verdict — sit above the prose. The next run reads its skip
  decision off the newest such comment, so there is no separate state comment to
  keep in sync. **The sentinel's literal text is live state and must not be
  renamed**: it is matched verbatim by `prepare.py` and by the workflow's `jq`
  selectors, and it is already stamped into the review comments on every open PR,
  so changing it orphans them — priors stop being collapsed and skip decisions
  read no prior state.
- **Earlier reviews are collapsed as outdated.** Before posting, the run
  minimizes every earlier sentinel-led comment of its own (GitHub's
  `minimizeComment`, classifier `OUTDATED`). History collapses instead of piling
  up. Minimizing happens before the post, which is what makes it impossible for
  a run to collapse the review it is about to publish.
- **The pipeline scripts are the base branch's, never the PR's.** The workflow
  restores `.github/workflows/claude-review-v2/` from the base branch before the
  review session and again after it, from the same recorded base SHA, so the
  scripts that compute the verdict and render the posted comment are base
  content no matter what the PR committed or the session wrote. Two consequences
  when you review a PR that changes that directory: the check exercises the
  *base* scripts, so a fix to them proves itself only after merge, and the
  session sees base content on disk (its prompt says so, and points it at
  `git show HEAD:<path>` for the PR's version).
- **A skipped review writes nothing.** When the diff's patch-id matches the last
  reviewed one, the run posts no comment and minimizes none — the prior review
  is still the current review of an unchanged diff — and re-asserts the recorded
  verdict as its own check result.

## The legacy single-session workflow

[`claude-code-review-legacy.yml`](../.github/workflows/claude-code-review-legacy.yml)
holds the single-session reviewer the fan-out pipeline replaced: one session that
covered every concern in one pass and typed its own `APPROVE`/`REJECT` into
`claude-verdict.txt`, gated by the Stop hook in
[`claude-review-hooks/`](../.github/workflows/claude-review-hooks/).

**It is a restoration source, not a fallback you can run.** Dispatching it reviews
nothing: outside a PR event every `github.event.pull_request.*` expression is empty, so
the author-trust step probes permissions for an empty login, fails, and the run exits at
the fork gate with a misleading "this PR is from a fork" error before any review logic
runs. Reviving it means re-adding a `pull_request_target:` trigger and renaming the job
back — a deliberate edit and merge. Keeping the file means that edit is small and
reviewable instead of a reconstruction from git history.

Two things keep it inert until then:

- Its only trigger is `workflow_dispatch`, so no PR event starts it. Running two
  full model reviews per PR is exactly the cost retiring it removed.
- Its job is named `claude-review-legacy`, so it cannot report into the required
  `claude-review` context.

Because dispatch runs against a branch rather than a PR, a hand-triggered run has no
`github.event.pull_request` and reviews nothing — treat it as a diagnostic of the
workflow itself. Delete the file once the fan-out gate has held across enough real
PRs that nobody would reach back for it, or as soon as it stops working: a
restoration source that has quietly rotted is worse than none.

## Operational notes

- The gate is **fail-closed on infrastructure**: if the Anthropic API is down or
  `CLAUDE_CODE_OAUTH_TOKEN` expires, trusted PRs block until it recovers. An admin
  can temporarily drop `claude-review` from the required contexts to override.
- Reviews post as a **dedicated GitHub App whose slug contains "claude"** (e.g.
  `tbd-claude-reviewer[bot]`), minted per run via `actions/create-github-app-token`
  from the `CLAUDE_REVIEWER_APP_ID` / `CLAUDE_REVIEWER_APP_PRIVATE_KEY` secrets. The
  App is the gate's **stable comment-author identity**: the fetch, minimize, and post
  steps all select prior reviews by *this login plus the sentinel*, so a comment
  posted under any other identity is invisible to the next run's skip decision. We
  can't use the OIDC→Claude App token because that exchange 401s under
  `pull_request_target` (anthropics/claude-code-action#1017), and a plain
  `GITHUB_TOKEN` posts as `github-actions[bot]`, which collides with every other
  workflow's comments. (The legacy workflow needs the same App for a different
  reason: the action's sticky-comment matcher in `create-initial.ts` recognizes its
  own prior comment only when the author is the Claude App or a `Bot` whose login
  contains `claude`, and has no config input to change that.)
- The gate is a **status check**, not a required-approval count. (The App's approval
  *could* count toward required reviews if we ever want that, but the computed
  verdict is what enforces High/Medium blocking today.)
- **A green `claude-review` can predate the workflow that would produce it now.**
  Branch protection has `strict: false` — PRs need not be up to date with `main` — and
  a `pull_request_target` check does not re-run because the base branch's workflow
  changed. So a PR already open when this file changes keeps whatever verdict it
  already has, from whatever the workflow was then. The check name is the same and the
  green tick looks identical, which is the whole problem. After any change to what the
  gate *does*, push to (or re-run the check on) an open PR before merging it if you
  want the current pipeline's opinion rather than the one it happened to get.
