# PR review v2: specialist fan-out with deterministic bookends — design

Status: **implemented — this pipeline is the `claude-review` merge gate** (§5).
Written 2026-08-03.

Brainstormed per `/tbd-brainstorming`; the four design questions below were answered by
a human. The design is a clean-room adaptation of a mature private review pipeline the
author operates elsewhere; per project convention that system is not named or quoted
here, and every decision is restated on its own merits with its rationale.

---

## 1. Problem

A single-session reviewer — one model session that types its own verdict into
`claude-verdict.txt` — gates merges adequately, but has structural limits:

- **One session, one perspective.** A single reviewer session covers correctness,
  concurrency, repo conventions, and test quality in one pass. Deep checks (the
  premise-audit instructions for guard-shaped PRs) compete with breadth for the same
  turn budget — a large review (#364) once exhausted its turns without writing the
  verdict file.
- **The verdict is model-typed prose.** The session writes `APPROVE`/`REJECT` into
  `claude-verdict.txt` itself. The Stop hook and enforce step check the *format*, but
  nothing ties the token to the findings: a review that lists a High-severity issue and
  writes `APPROVE` passes the gate.
- **Findings are unstructured.** The review is a markdown comment. Nothing downstream
  can count, diff, or re-check findings across rounds.
- **Every push re-reviews.** A rebase that changes no diff content burns a full review.
- **The reviewer cannot see PR discussion.** An author's explanation of why a finding
  needs no code change is invisible, so re-reviews re-raise addressed points.

## 2. Decisions (human-answered brainstorm)

- **Driver shape** — **headless session + subagent fan-out.** One headless review
  session orchestrates parallel specialist subagents (Task tool); each specialist
  writes a findings JSON file; the orchestrator merges them. No interactive PTY
  driver — that machinery (idle nudges, deadline steering, salvage) is for much
  longer sessions than this repo's PRs need.
- **Guard against the merge step losing findings** — **prose, not machinery.** The
  merge prompt requires a per-finding *disposition list* (§3.4) instead of a
  deterministic post-merge reconciliation check. Upgrade trigger recorded in §6.
- **Skip-if-unchanged** — **patch-id skip only.** Skip the re-review when
  `git patch-id` over the diff matches the patch-id recorded in the prior run's
  review comment (§3.5). No discussion-content fingerprint in the first version (§6).
- **PR discussion context** — **yes, trimmed.** Fetch human discussion once, render
  it into a sanitized, fenced, untrusted-data block the reviewer weighs but may not
  take instructions from (§3.6).

## 3. Design

### 3.1 Pipeline shape: deterministic bookends around one model session

```
prepare (script)  →  review session (model, fan-out)  →  validate (script)  →  post + enforce (script)
```

Everything before and after the model session is plain Python: argument in, files out,
no network beyond one `gh` boundary, unit-testable with hand-built fixtures. The model
session's only contract is "write these files"; scripts own every machine-read decision.
This is the inverse of a single-session gate, where the session both writes the review
*and* types the verdict token.

The session holds **no GitHub write tool at all** — it does not post its own review. It
writes `review-result.json`; the post step renders that file's `comment_body` into the
comment it publishes (§3.5). So the only text that reaches the PR is text `validate.py`
has already accepted, and the workflow — not the model — owns the comment's machine-read
state.

### 3.2 Structured findings

Each specialist writes `findings-<name>.json`, schema-validated by the bookend scripts:

```json
{ "specialist": "correctness",
  "findings": [ { "id": "correctness-1", "file": "Sources/...", "line": 42,
                  "severity": "HIGH", "title": "...", "body": "...",
                  "confidence": 0.8 } ] }
```

Severity vocabulary: `HIGH` / `MEDIUM` / `MINOR` (the scale this repo's reviews have
always published, so the posted format reads the same). A JSON-schema file in the
workflow directory is the single source of truth; validation failures list the offending
file and field.

Both anchors are nullable, and the optional fields are too. Repo-wide, convention, and
architectural findings have no single line — and often no single file either, being
properties of the tree rather than of one path. A model writing one emits `"line": null`
and `"file": null`, the natural JSON. A schema that accepted omission but rejected null
would fail the whole gate closed on precisely the category of finding least amenable to
mechanical judgment, which is a systematic blind spot rather than a random one.
Tolerating what the model naturally produces is more robust than a prompt instruction
nothing can enforce. Renderers assemble the location from whichever anchors exist and
omit it entirely when neither does — never a `file:null` or `None:42` placeholder — so an
unanchored finding still reaches the reader. The same reasoning covers `body`,
`confidence`, `note`, and `comment_body`: each may already be omitted, so a null is that
same absence spelled differently, and none has a consumer that reads it as more than
text-or-nothing. `line` may be omitted as well as nulled; `file` stays required, so a
model must state the anchor even when the answer is "there isn't one".

The nullable set stops there, and the line is where a null stops meaning "absent" and
starts meaning "broken". `id` keys the disposition-coverage check, `severity` computes
the verdict, `title` is the finding's content, `specialist` is the lens's identity, and
`findings`/`disposition` are iterated by the validator: a null in any of them is a
malformed run with no safe reading, and the gate keeps failing closed on it. A `note` is
nullable on a `kept` or `merged` disposition entry and not on a `downgraded` or `dropped`
one, where a stated reason is the whole point.

Initial specialist set (2, deliberately small):

- **correctness** — the diff's logic, plus the existing premise-audit instructions for
  guard/safety-shaped PRs, plus
  concurrency & platform correctness: NIO event-loop discipline, actor isolation,
  clock/date seams, unbundled-executable constraints.
- **conventions** — CLAUDE.md rules: default-off flags, TUI screen-scraping,
  public-repo leaks, migration triple-update, spec-required changes, and the
  theory-placement lens per `docs/theory-placement.md` (flag a compiled theory —
  a fork, constant, threshold, or default two reasonable projects could answer
  differently — that no PR description or committed spec shows a human chose).

### 3.3 Merge step

The orchestrator (same session, after specialists return) merges the findings lists:
dedup (same file within a few lines = same finding), severity reconciliation, and the
summary prose for the review comment. Output is one `review-result.json` holding the
final findings array, the disposition list, and the comment body.

### 3.4 Disposition list (the prose accounting rule)

The merge step is a model call, and model calls can silently lose findings — the failure
looks identical to a genuinely clean review, which is what makes it dangerous. The
deterministic defense (a post-merge script that fails the job if a serious specialist
finding is unaccounted for) was considered and **deliberately not built in the first
version**; the
human decision was to try prose first.

Instead, the merge prompt requires a disposition entry for *every* specialist finding:

```
correctness-1: kept (final-3)
correctness-2: merged into conventions-1 (same root cause)
conventions-1: downgraded MEDIUM→MINOR — <reason>
correctness-3: dropped — <reason>
```

The disposition list is embedded in the posted review comment inside a collapsed
section, so a silent drop is at least *visible* to a human reading the review, and the
validate script checks only its *presence* (an ID-coverage count), not its judgment.

### 3.5 Pinned merge base, deterministic verdict, one review comment per run, patch-id skip

- **Pinned merge base**: the prepare script resolves `git merge-base origin/<base>
  HEAD` and records the SHA in `skip-decision.json` and in the prepare step's
  `merge_base` output; the session prompt hands that literal SHA to the orchestrator
  and to each specialist. The prepare script is the last point in the job at which
  the checkout's history is known intact — the review action's session setup
  re-fetches the base branch at limited depth and can graft `origin/<base>` into a
  ref with no common ancestor (measured on PR #614) — so a ref name is not a usable
  diff basis anywhere downstream of it. The prompt therefore instructs
  `git diff <merge-base> HEAD`, which is the same diff as
  `git diff origin/<base>...HEAD` and keeps patch-ids comparable, and forbids naming
  `origin/<base>` in a diff at all: against a moved ref a two-dot diff succeeds and
  reports other PRs' merged work as this PR's reverts, which is worse than no review.
- **Fail closed with no merge base**: if the merge base does not resolve, the prepare
  script prints a `::error::` annotation naming the failure as review infrastructure
  rather than a verdict, and exits non-zero *without writing* `skip-decision.json` or
  `discussion-context.txt`. The step runs under `set -euo pipefail`, so the job fails
  and every downstream step is skipped: nothing is posted and no patch-id/verdict
  marker is recorded. That last part is the point — a run that cannot see the true
  diff must not cache a verdict about it, so the next run reviews fresh.
- **Verdict**: the validate script computes `APPROVE`/`REJECT` from
  `review-result.json` — REJECT iff any unaddressed `HIGH` or `MEDIUM` finding survives
  the merge. The model never types the verdict. The Stop hook gates on the *artifact*
  rather than on a token: it refuses to end the session until `review-result.json`
  exists and parses. The enforce step is fail-closed — a missing file is a red check.
  The validate script also enforces specialist-set completeness
  (`--expected-specialists`): if any named
  specialist contributed no *valid* findings file it fails closed with no verdict
  written. The diagnostic distinguishes the two causes, because they send an
  operator to different places: a lens that produced nothing (e.g. the orchestrator
  merged before all background specialists completed) versus one that ran and had
  its file rejected by schema validation a moment earlier. Reporting the second as
  the first is a false lead toward an orchestrator race that isn't there.
- **One review comment per run, carrying its own state**: a full-review run posts a
  NEW comment; nothing is edited in place. `render_comment.py` builds the body as
  three machine-read marker lines — a `<!-- claude-review-v2 -->` sentinel plus
  `<!-- last-reviewed-patch-id: … -->` and `<!-- last-verdict: … -->` — then the
  model's `comment_body` prose verbatim, then a one-line attribution naming the
  patch-id this comment reviewed. The markers lead the body, so the next run's
  parser (which takes the first match) reads workflow-written state even though the
  prose below it is model-authored and could contain marker-shaped text. Because the
  workflow composes and posts the body, the model needs no GitHub write tool and the
  state never passes through its hands.
- **Priors collapse rather than pile up**: before posting, the run minimizes every
  earlier review comment of its own on the PR — the App's own comments whose body
  starts with the sentinel — with GitHub's `minimizeComment` mutation, classifier
  `OUTDATED`.
  Minimizing *before* the post is what guarantees a run can never collapse its own
  review: the comment it is about to create is not in the set it just enumerated. The
  reviews stay on the PR as collapsed history; only the newest is open.
- **Why collapsing priors carries no flag of its own**: minimizing runs on every
  full-review run, with no user gesture, and mutates persisted PR state — the shape the
  "large or risky new behavior ships behind a default-off flag" convention exists for.
  The convention triggers on the mutation, not on the verdict: it would apply just as
  much to a check nothing merged on, because the mutation still fires on every live PR
  and visibly collapses comments on a public thread. "Nothing gates on it" is not the
  same as "it does not run."
  The exemption rests instead on how small the mutation is. It is confined to the App's
  own prior review comments by an authorship-plus-sentinel selector — a human comment
  quoting the sentinel is never touched — it destroys no content (a minimized comment is
  collapsed, not deleted, and `unminimizeComment` reverses it), and its blast radius is
  bounded by exactly the selector a per-comment flag would gate, so the flag would buy
  no containment the selector does not already provide. Collapsing prior reviews is also
  the behavior the pipeline is *for*: a flag defaulted off would ship the pile-up this
  section exists to prevent. The behavior was requested directly by the repository owner
  rather than originated by the pipeline's authors, which is the human judgment the
  convention ultimately asks for; if a maintainer later wants the exemption withdrawn,
  the selector is the natural gate to put a flag on.
- **Rendering never fails the step**: an absent or malformed `review-result.json`, or
  blank prose, yields a degraded body — a machine-rendered list of the recorded
  findings, or a plain note — plus a `::warning::` explaining the degradation. A
  REJECT computed from severities must never post as a bare set of markers with
  nothing to act on. Pass/fail is `validate.py`'s alone.
- **Ordering inside the post step**: verdict gate, render, minimize, post, enforce.
  The verdict is checked FIRST, so a run with no trustworthy verdict posts nothing at
  all; the REJECT exit comes LAST, so a rejecting review always reaches the author it
  is addressed to. Minimizing and posting are both best-effort — each warns and
  continues rather than masking the verdict.
- **Skip**: the prepare script computes `git patch-id --stable` over
  `git diff <merge-base> HEAD`; if it equals the patch-id recorded in the newest sentinel-led
  comment, the run short-circuits and re-asserts the recorded verdict without spending
  a review. This path writes NOTHING to the PR: it posts no comment and minimizes
  none. The prior review is still the current review of an unchanged diff, so it stays
  visible and unannotated, and the re-assertion is the check result itself. A new
  human comment does **not** defeat the skip in the first version. Pushing a commit is
  the only way to re-request a review: patch-id over a fixed merge base is
  deterministic, so re-running the check recomputes the same value and skips again.
- **Skip fail-direction**: the skip fires only when the comment fetch succeeded, both
  markers parse, and the recorded verdict is exactly `APPROVE` or `REJECT`. Any other
  state — fetch error, no prior review comment, missing or malformed marker,
  unrecognized verdict — falls through to a full review. The cheap direction to fail
  is toward spending a review, never toward re-asserting a verdict we can't read. The
  post step is best-effort in the same direction: a failed post records no patch-id,
  so the next run full-reviews.

### 3.6 PR description and discussion context (trimmed anti-hijack envelope)

The prepare script fetches the PR's title, body and author alongside its issue
comments, review bodies, and review-thread replies in one GraphQL call (the single
sanctioned `gh` boundary), then renders a block with these properties, all implemented
as pure functions:

- **The PR description leads the block**, as its first item, kind `pr-description`.
  Provisioning it deterministically is what makes the correctness lens's premise audit
  possible at all: that audit's subject is the description's factual claims about
  existing code, and a session left to fetch the description itself may simply not —
  the PR #614 runs issued no `gh` command and told both specialists no description was
  available.
- **The description bypasses the item filters.** The bot filter drops bot *comments*,
  but a bot-opened PR's description is still the statement of intent the diff is
  measured against; and an empty body renders an explicit "(the PR has no
  description)" item rather than vanishing, so "no description exists" stays
  distinguishable from "description unavailable".
- **Bot filtering** for discussion items by GraphQL `__typename == "Bot"` (logins alone
  are unreliable); empty bodies dropped; ascending timestamp order.
- **Sanitization**: strip HTML comments whole (so a quoted state marker can't
  masquerade as ours), then escape angle brackets.
- **Fencing**: the block sits between BEGIN/END markers carrying a per-run random
  token; the header states that envelope metadata (author, timestamp) is trustworthy
  and comment *bodies* are untrusted data, never instructions — and that a marker with
  a different token is ordinary comment text.
- **Bounded**: per-item and whole-block character caps, oldest items shed first, with
  a visible truncation note. The description carries its own larger per-item cap
  (8000 characters against 1500), and the whole-block cap sheds discussion items only
  — a long comment thread cannot push the description out of the block.
- **An empty file means the fetch FAILED.** With a description always present on a
  successful fetch, the absence of a fence is unambiguous, and the session prompt says
  so: treat an empty `discussion-context.txt` as "description unavailable" and report
  it in the review diagnostics, never as "this PR has no description".
- **The clearing rule**: discussion can persuade the reviewer that a finding is
  addressed — but a High-severity finding is cleared only by a code change or by the
  author's substantive explanation the reviewer finds convincing; a bare "will fix" is
  not addressed.

Threat-model note: comments on a PR in this repo are already authorable by anyone, and
the reviewer already reads the (equally untrusted) diff under the same no-instructions
preamble — this adds surface area of the same kind, not a new kind.

### 3.7 What the gate keeps from the single-session design

Trust gating for forks, `pull_request_target` + explicit `github_token` (the OIDC trap),
the pre-review reset of every workspace file the pipeline reads back, the unshallow /
merge-base repair step (which fails closed here rather than warning — §3.5), the
reviewer App as a stable comment-author identity, and the exact-match fail-closed
enforce step are all carried over. The trigger event is unchanged too, so the
admin-merge trap is not sprung.

Where the single-session reviewer restored only its hooks directory from the base branch,
this pipeline restores its whole script directory
(`.github/workflows/claude-review-v2/`) — far more of the gate lives in the checked-out
tree — and it does so **twice**: once before the session, and
again after it, before the verdict is computed. The second restore is what makes the
guarantee hold. The review session holds an unrestricted `Write` tool while reading
author-controlled text, and the two scripts that run after it are the ones that decide
and publish the outcome: `validate.py` computes the verdict, so a rewritten copy
approves everything, and `render_comment.py` builds text posted verbatim to a public PR.
A single pre-session restore leaves both writable across the whole session window.

Both restores materialize provably the same tree: the first resolves the base branch tip
once and records that SHA, and the second checks out that exact SHA rather than a ref a
later fetch could move. The re-restore cannot clobber the session's work, because every
file the session and its specialists produce lives in the workspace root, not in the
restored directory. The session prompt states that this directory is deliberately held
at base content — otherwise the reviewer either reports the divergence as stray
contamination, or (worse, and silently) reads base text for paths the PR changed and
reviews code that is not in the PR.

## 4. Testability (a design driver, not an afterthought)

- **Pure policy, fixture-driven tests.** Every decision the scripts make — skip or
  review, verdict from findings, discussion rendering, marker parsing, disposition
  coverage, comment-body rendering — is a pure function taking scalars/dicts. Tests
  hand-build inputs; no clocks, no subprocesses, no network. `gh` is called through one
  module-level function that tests monkeypatch. The three scripts are `prepare.py`
  (skip decision + discussion context), `validate.py` (schemas, disposition coverage,
  verdict), and `render_comment.py` (the posted comment's body), each with a test
  module beside it.
- **Renderer and parser pinned against each other.** `render_comment.py` writes the
  state markers `prepare.py` reads back, so the round trip is tested end to end rather
  than each end against a hand-written fixture — including the case where model prose
  contains marker-shaped text, which must not displace the workflow's own markers.
- **Stub-API end-to-end test.** A stdlib `ThreadingHTTPServer` fakes the model API:
  canned SSE turn sequences, request *N* answered by turn *N−1*, `tool_use` blocks to
  script subagent spawns and file writes. The real `claude` CLI runs headless against
  it via `ANTHROPIC_BASE_URL` + a sandboxed `HOME`/`CLAUDE_CONFIG_DIR` (isolation via
  config dir, not `--settings`, which leaks the runner's global config). This exercises
  the *actual* session contract — Stop hook, findings files, result file — with zero
  tokens and full determinism. One gotcha worth pinning in a test: the CLI streams; a
  non-SSE response makes it silently retry a byte-identical request, which a naive
  request count misreads as progress.
- **The workflow's own shell is executed by tests, not just read.** The post/enforce
  step is where the pipeline's ordering guarantees live — verdict gate before any post,
  minimize before post, REJECT exit after it — and shell nothing runs is correct only by
  inspection. A test helper extracts a step's `run:` block from the workflow file **by
  step name** (a rename fails the tests loudly rather than leaving them asserting on
  nothing) and executes it under bash with a stub `gh` on `PATH` that records every
  invocation. Assertions are on the recorded call ORDER, not only on outcomes: an
  inverted minimize/post pair and a verdict gate moved below the post are each caught.
  The impostor cases — a human comment opening with the sentinel, an App comment without
  it — run against the real `jq` selector, since a stubbed selector would test the stub.
  Step *position* (the re-restore sits between the session and the verdict) is a
  structural assertion over the same by-name lookup.
- **Where tests run**: scripts are Python 3 stdlib (the workflow already runs on
  `ubuntu-latest`, where the Swift toolchain is absent); a small CI job runs pytest
  over the workflow's script directory. The stub-API e2e test runs where a `claude`
  binary is available and is skipped otherwise, so it cannot flake CI on toolchain
  drift.

## 5. Where this pipeline sits

This pipeline **is** the merge gate. Its job is named `claude-review` in
`.github/workflows/claude-code-review.yml`, which is what satisfies the required
`claude-review` check on `main`.

### What the promotion rests on

**It rests on cost, not on a demonstration of superiority.** Two reviewers charge two
full model reviews per push, and the second is not worth its price. Stating that
plainly is what makes the rest of this section legible: this pipeline gates because
one reviewer is what the project will pay for, not because a comparison established it
as the better one.

A stronger basis was available and is not claimed — triaging each commit where the two
pipelines disagreed, and promoting on the strength of that triage. That triage is
unpaid, so deficiencies in this gate are expected to surface in flight rather than to
have been caught beforehand. The rollback trigger below exists for that reason.

The evidence that does exist runs in both directions and is worth recording.

- **The divergence count settles nothing.** Across a soak of 21 commits on 7 branches,
  both pipelines concluded on 17; 8 of those disagreed, every one in the same direction
  — this pipeline failing where the single-session reviewer passed. That reads as a
  stricter reviewer only until the causes are separated: at least two were a schema bug
  that failed the gate closed with no verdict at all (nullable finding anchors, since
  fixed). A contaminated signal is precisely why a count cannot substitute for
  per-case triage.
- **The qualitative evidence is the stronger half.** On this pipeline's own promotion
  PR it returned findings the single-session reviewer missed while approving the same
  diff: a retained workflow that could not do the job its comments claimed, and a
  graduation criterion asserted in this spec but left unanswered. Both were correct.
  The reverse also holds — the single-session reviewer has caught convention breaches
  in this spec that the fan-out missed — which is the case against retiring a second
  opinion, made from the same window.

**Residual risk.** With one reviewer there is no second opinion, and a bug that fails
this gate closed blocks merges outright rather than showing a red advisory check beside
a working gate. A PR that would *fix* such a bug is not exempt: the pipeline is always
restored from the base branch, so a repair reaches the gate only after it merges, which
is why the recovery path below is an admin merge rather than a re-run.

**Rollback trigger.** Requiredness is reverted — this job renamed back and the
single-session reviewer's `pull_request_target:` trigger restored — when failures that
are not REJECT verdicts stop being isolated: when admin-merging around the gate has
become the routine way changes land rather than an occasional recovery. Recovering a
single blocked PR does not need the rollback: an admin merge of the fix is enough, and
is the expected first response.

The condition is deliberately a judgment rather than a count. Nothing enforces it, and
the decision it informs is a human's; a number would only invite arguing that this
week's failures fell one short. What it has to do is make an obvious pattern impossible
to keep explaining away one PR at a time.

The naming follows from how GitHub matches a required check: **by job name, not by
workflow file**. That makes the job key the load-bearing identifier and gives the
arrangement two properties worth stating outright.

- **The gate lives entirely in the tree.** Naming the job `claude-review` satisfies
  the branch-protection requirement directly, so which pipeline gates merges is a
  workflow-file question, not a repository-settings one — and no admin merge is in
  play, because the trigger event (`pull_request_target`) is unchanged.
- **Exactly one job may carry the name.** Two jobs named `claude-review` would both
  report into the same required context, and which one the gate reads becomes a
  race. The single-session predecessor is therefore retained as
  `claude-code-review-legacy.yml` with its job renamed `claude-review-legacy`, and
  with `workflow_dispatch` as its only trigger so no PR event starts it — keeping it
  inert is what avoids spending two full model reviews on every PR for one verdict.

  It is a **restoration source, not a live fallback**: dispatching it reviews nothing,
  because every step that reads `github.event.pull_request.*` is empty outside a PR
  event, so the trust step finds no author and the run exits at the fork gate. Reviving
  it means re-adding a `pull_request_target:` trigger and renaming the job — a
  deliberate edit, not a button. What retaining the file buys is that the edit is small
  and reviewable rather than a reconstruction from git history. It should be deleted
  once nobody would reach back for it, or as soon as it stops working.

The pipeline selects its comments by its own `<!-- claude-review-v2 -->` sentinel
rather than by the action's sticky-comment mode (§3.5), so it never contends with the
legacy workflow over a comment identity, including if that workflow is ever revived.

That sentinel keeps the `v2` spelling because it is live state: the workflow's `jq`
selectors match the literal verbatim when fetching and when minimizing priors, and it
is already stamped into the review comments on every open PR. (`prepare.py` never sees
the sentinel — it parses the `last-reviewed-patch-id` and `last-verdict` markers out of
the comment those selectors already picked.) Renaming it orphans those comments —
priors stop being collapsed, and skip decisions read no prior state.
The pipeline's script directory, `.github/workflows/claude-review-v2/`, keeps its name
for the same reason at lower stakes: it is path-pinned by the workflow's restore steps
and the whole test suite.

## 6. Explicitly out of scope for the first version — with named upgrade triggers

- **Deterministic drop guard** (post-merge reconciliation script): add it the first
  time a disposition list is found to have silently omitted or misaccounted a
  MEDIUM+ specialist finding. The disposition list makes this observable; the guard
  makes it fail closed.
- **Discussion fingerprint** (new comments defeat the patch-id skip): add it the first
  time an author's clarifying comment goes unreviewed because the skip suppressed a
  round.
- **Resume-based retry loop**: a bounded workflow loop of run → check
  `review-result.json` → `claude -p --resume <session_id>` with a corrective
  prompt. Session state persists under `CLAUDE_CONFIG_DIR` and resumed requests
  carry the full prior history. **A resume may not assume that in-flight work
  survived the previous invocation.** Measured on PR #604: the review step
  returned success after 184s with both specialists still working, and no
  `findings-*.json` was present in the workspace afterwards. That measurement
  does not establish *why* the files are absent — whether the specialists were
  killed with the process, or the action stopped consuming the CLI's output
  stream at the first result message and so never saw their work — and a
  separate diagnosis of the same failure attributes it to the abandoned stream.
  The loop is therefore built against the disk under either reading: check what
  is actually there, re-fan-out whatever is missing rather than waiting to
  collect a fan-out already in flight, and point the corrective prompt at
  whichever `findings-*.json` did survive, whose content never enters the
  orchestrator's own transcript. The stub-API e2e test
  (`.github/workflows/claude-review-v2/tests/e2e/test_resume_loop.py`) records
  the small-scale behavior — a
  specialist still pending about 3 seconds at session end does land its file —
  which is two orders of magnitude below a real specialist's ten minutes and so
  says nothing about the case above. Two mechanics are mandatory:
  reset all three of the Stop hook's state files between invocations — its nudge
  counter, its start stamp, and its hold counter (a stale counter at the ceiling
  silently disarms the nudge; a stale hold counter at its cap disarms the hold;
  a stale stamp puts the hold deadline in the past and disarms it a second way
  — all measured), and keep
  each invocation's own liveness intact, since a resume that stalls the same way
  buys nothing. The session-liveness repair in
  `2026-08-10-review-orchestrator-liveness-design.md` addresses the
  died-incomplete case directly; add this loop only if reviews still die
  incomplete after it.
- **Interactive PTY driver** (mid-flight nudges, deadline steering): the named
  fallback if session-liveness repairs at the prompt and hook layer stop
  holding — in particular for sessions that wedge rather than end, which no
  between-invocation loop can reach.
- **Inline review comments**: findings state their file path and line numbers inside
  the one review comment rather than being anchored to diff lines.

## 7. Open questions

- Whether the orchestrator + specialists fit comfortably in one headless session's turn
  budget on the largest realistic PR. The turn budget carries headroom for the
  investigation requirements (§3.3), and a session that runs out fails closed rather
  than approving, so the failure is visible; the answer arrives from real PRs.
  A session that stalls rather than exhausting its budget is a different failure
  with its own design (`2026-08-10-review-orchestrator-liveness-design.md`).
- Whether `MINOR` findings should feed the verdict at all (currently: no).
