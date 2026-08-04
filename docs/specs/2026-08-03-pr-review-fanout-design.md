# PR review v2: specialist fan-out with deterministic bookends — design

Status: **approved design, pre-implementation**. Written 2026-08-03.

Brainstormed per `/tbd-brainstorming`; the four design questions below were answered by
a human. The design is a clean-room adaptation of a mature private review pipeline the
author operates elsewhere; per project convention that system is not named or quoted
here, and every decision is restated on its own merits with its rationale.

---

## 1. Problem

The current merge gate (`.github/workflows/claude-code-review.yml`, check
`claude-review`) works, but has structural limits:

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
  review comment (§3.5). No discussion-content fingerprint in v1 (§6).
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
This is the inverse of the current gate, where the session both writes the review *and*
types the verdict token.

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

Severity vocabulary: `HIGH` / `MEDIUM` / `MINOR` (matches the current gate's published
scale, so the posted format doesn't change for readers). A JSON-schema file in the
workflow directory is the single source of truth; validation failures list the offending
file and field.

Initial specialist set (2, deliberately small):

- **correctness** — the diff's logic, plus the existing premise-audit instructions for
  guard/safety-shaped PRs (moved here verbatim from the current prompt), plus
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
finding is unaccounted for) was considered and **deliberately not built in v1**; the
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

### 3.5 Deterministic verdict, one review comment per run, patch-id skip

- **Verdict**: the validate script computes `APPROVE`/`REJECT` from
  `review-result.json` — REJECT iff any unaddressed `HIGH` or `MEDIUM` finding survives
  the merge. The model never types the verdict. The existing Stop hook changes duty:
  instead of gating on `claude-verdict.txt` content, it refuses to end the session until
  `review-result.json` exists and parses. The enforce step's fail-closed behavior
  (missing file ⇒ red check) carries over unchanged. The validate script also
  enforces specialist-set completeness (`--expected-specialists`): if any named
  specialist never produced a findings file — e.g. the orchestrator merged before
  all background specialists completed — it fails closed with no verdict written.
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
  earlier v2 review comment on the PR — the App's own comments whose body starts with
  the sentinel — with GitHub's `minimizeComment` mutation, classifier `OUTDATED`.
  Minimizing *before* the post is what guarantees a run can never collapse its own
  review: the comment it is about to create is not in the set it just enumerated. The
  reviews stay on the PR as collapsed history; only the newest is open.
- **Why collapsing priors carries no flag of its own**: minimizing runs on every
  full-review run, with no user gesture, and mutates persisted PR state — the shape the
  "large or risky new behavior ships behind a default-off flag" convention exists for.
  The gate it asks for is already present at a coarser grain: the entire v2 pipeline is
  a non-required shadow check that nothing merges on, which *is* the off position, and
  graduating it to the required check (§5) is the single event at which this behavior
  becomes load-bearing and is re-examined. The mutation itself is also about as small as
  a state mutation gets — it is confined to the App's own prior review comments by an
  authorship-plus-sentinel selector, it destroys no content (a minimized comment is
  collapsed, not deleted, and `unminimizeComment` reverses it), and its blast radius is
  bounded by the same selector that a per-comment flag would gate. A second flag inside
  a check that is itself off would be flag sprawl, which the convention warns against in
  the same breath.
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
  `git diff base...HEAD`; if it equals the patch-id recorded in the newest v2 review
  comment, the run short-circuits and re-asserts the recorded verdict without spending
  a review. This path writes NOTHING to the PR: it posts no comment and minimizes
  none. The prior review is still the current review of an unchanged diff, so it stays
  visible and unannotated, and the re-assertion is the check result itself. A new
  human comment does **not** defeat the skip in v1 (accepted: a human can re-request
  review by pushing or re-running the check).
- **Skip fail-direction**: the skip fires only when the comment fetch succeeded, both
  markers parse, and the recorded verdict is exactly `APPROVE` or `REJECT`. Any other
  state — fetch error, no prior review comment, missing or malformed marker,
  unrecognized verdict — falls through to a full review. The cheap direction to fail
  is toward spending a review, never toward re-asserting a verdict we can't read. The
  post step is best-effort in the same direction: a failed post records no patch-id,
  so the next run full-reviews.

### 3.6 PR discussion context (trimmed anti-hijack envelope)

The prepare script fetches issue comments, review bodies, and review-thread replies in
one GraphQL call (the single sanctioned `gh` boundary), then renders a block with these
properties, all implemented as pure functions:

- **Bot filtering** by GraphQL `__typename == "Bot"` (logins alone are unreliable);
  empty bodies dropped; ascending timestamp order.
- **Sanitization**: strip HTML comments whole (so a quoted state marker can't
  masquerade as ours), then escape angle brackets.
- **Fencing**: the block sits between BEGIN/END markers carrying a per-run random
  token; the header states that envelope metadata (author, timestamp) is trustworthy
  and comment *bodies* are untrusted data, never instructions — and that a marker with
  a different token is ordinary comment text.
- **Bounded**: per-item and whole-block character caps, oldest items shed first, with
  a visible truncation note.
- **The clearing rule**: discussion can persuade the reviewer that a finding is
  addressed — but a High-severity finding is cleared only by a code change or by the
  author's substantive explanation the reviewer finds convincing; a bare "will fix" is
  not addressed.

Threat-model note: comments on a PR in this repo are already authorable by anyone, and
the reviewer already reads the (equally untrusted) diff under the same no-instructions
preamble — this adds surface area of the same kind, not a new kind.

### 3.7 What stays from the current gate

Trust gating for forks, `pull_request_target` + explicit `github_token` (the OIDC trap),
the pre-review verdict-file reset, unshallow/merge-base repair, the reviewer App as a
stable comment-author identity, and the exact-match fail-closed enforce step all carry
over as-is. The trigger event does not change, so the admin-merge trap is not sprung.

Where v1 restores only its hooks directory from the base branch, v2 restores its whole
script directory (`.github/workflows/claude-review-v2/`) — far more of the gate now
lives in the checked-out tree — and it does so **twice**: once before the session, and
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

## 5. Rollout

Per the "large or risky new behavior ships default-off" convention, translated to CI:

1. **Shadow**: land as a separate workflow producing a non-required check
   (`claude-review-v2`) posting its own comments. The existing `claude-review`
   remains the required gate. Soak across several real PRs; compare verdicts. The two
   workflows must not share a comment identity: the action's sticky matcher keys on
   the posting App, so v2 stays out of the action's sticky-comment mode entirely and
   selects its own comments by its own sentinel (and, if that ever proves ambiguous,
   would get its own App) rather than touching the v1 comment.
2. **Graduate**: swap the required check from `claude-review` to `claude-review-v2` in
   branch protection (a settings change, not a workflow change — no admin-merge trap),
   then retire the old workflow.
3. Divergent verdicts during the soak are the review criterion for graduation.

## 6. Explicitly out of scope for v1 — with named upgrade triggers

- **Deterministic drop guard** (post-merge reconciliation script): add it the first
  time a disposition list is found to have silently omitted or misaccounted a
  MEDIUM+ specialist finding. The disposition list makes this observable; the guard
  makes it fail closed.
- **Discussion fingerprint** (new comments defeat the patch-id skip): add it the first
  time an author's clarifying comment goes unreviewed because the skip suppressed a
  round.
- **Resume-based retry loop** (the first upgrade rung if reviews die incomplete): a
  bounded workflow loop of run → check `review-result.json` → `claude -p --resume
  <session_id>` with a corrective prompt. Verified against the real CLI: session state
  persists under `CLAUDE_CONFIG_DIR` and resumed requests carry the full prior history;
  the process does not exit while background specialists are pending, so their findings
  files land before the post-exit check runs. Two mechanics are mandatory: reset the
  Stop hook's nudge-counter file between invocations (a stale counter at the ceiling
  silently disarms the hook — measured), and the corrective prompt must point at the
  on-disk `findings-*.json`, whose content never enters the orchestrator's own
  transcript. Add it the first time the shadow soak produces an incomplete review.
- **Interactive PTY driver** (mid-flight nudges, deadline steering): the last-resort
  rung, only if the resume loop above proves insufficient — e.g. sessions wedging
  rather than ending, which a between-invocation loop cannot reach.
- **Inline review comments**: findings state their file path and line numbers inside
  the one review comment rather than being anchored to diff lines; v1 keeps that.

## 7. Open questions

- Whether the orchestrator + specialists fit comfortably in one headless session's turn
  budget on the largest realistic PR — the shadow soak answers this before anything is
  load-bearing.
- Whether `MINOR` findings should feed the verdict at all (currently: no, matching the
  existing gate's behavior).
