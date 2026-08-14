# Fleet supervision — waking parked sessions: the wake program

Status: **normative sub-document of the fleet-supervision design.** Extracted
from §4 of
[`2026-07-26-fleet-supervision-design.md`](2026-07-26-fleet-supervision-design.md)
to keep that document readable; it carries the same authority as the section it
came from, and `design §N` below refers to that document's sections. It
specifies the project-authored wake program that decides whether a parked
session should be woken: TBD's obligation to that program is sufficient public
surfaces, never guardrails, and TBD keeps no compiled wake gate and no
actuation rails of its own. The live half's counterpart — the sweep program,
held to a compiled liveness contract this program deliberately lacks — is the
sibling sub-document
[`2026-08-01-fleet-supervision-sweep-program-design.md`](2026-08-01-fleet-supervision-sweep-program-design.md);
the asymmetry between the two is argued there (§11). This document also holds the dated source note
(2026-07-29 field observations) that belongs beside the script that consults
it rather than in the design: freshness is authored on both sides of the
process boundary, and which source tells the truth is data. The requirements
doc carries the matching stories (P0-2, P0-8, P1-1, P1-2, P1-3, P1-4, P3-1) and
the **Built/Enabled** classification
([`2026-07-26-fleet-supervision-requirements.md`](2026-07-26-fleet-supervision-requirements.md)).

## Why the wake decision lives outside TBD

Compiling the wake decision into the sweep — a global "outstanding work" fact
list of commits not on the default branch, uncommitted changes, an open PR,
failing checks, whose any-true verdict makes a parked session a wake case — is
wrong in both its mechanism and its price argument, and field measurement shows
how wrong. The commit-identity fact reads true forever for a squash-merged
branch — the merge lands as one new commit whose diff matches none of the
branch's own — so finished work can never clear such a gate: 33 of 70 active
worktrees on a live fleet (and 24 of 24 on the night that motivated P1-2) were
merged work the sweep would have woken every cycle, one of them into a resume
that would have spent 750k tokens re-entering work merged five days earlier.
The false-wake price is not "a few tokens"; it is systematic, correlated with
the forge's most common merge style. And the defect is structural, not a bug:
completion is a fact about intent and forge state — squash merges, abandoned
PRs, parked-on-purpose experiments are all invisible to git — so no compiled
git-fact list can express it. The old system's wake.py knew this: its verdict
let a MERGED pull request overrule `git cherry` outright — a precedence no
any-true fact list can express.

The answer is not a better fact list. **The wake decision sits outside the
daemon — and outside the desk — entirely.**

## The design

- **A project that wants automated wakes authors a wake program**: an external
  script — the old wake.py, owned properly this time — seeded once from a
  shipped reference and never rewritten by the tool. It reads what is parked
  and why from TBD's public surfaces (`hibernateReason`, the terminal and
  worktree listings), derives live git and forge facts itself, decides in its
  own vocabulary — including anything project-local the daemon could never
  know: marker files, claim conventions, closeout state — composes wake text
  from those verified facts, and actuates through `tbd terminal wake --prompt`,
  atomic with the resume. Everything it needs already exists; the old wake.py
  ran exactly this loop as an ordinary process. Its defect was never location
  but ownership: shipped content, rewritten over the operator's edits on every
  boot. Authored in-project, the org-specific residue that poisoned the old
  script — closeout commands, review-bot names — becomes legitimate, because
  it is their file.
- **No model is involved.** The old wake.py proved routine waking is a pure
  facts-to-text mapping; its classification and composition never called one.
  The desk's only role was invoking the script, which a scheduler does better.
  Routine waking therefore never reaches a desk. The public
  `tbd terminal wake` survives for judgment — a desk may still conclude from
  a case that a session should be up — but no case is ever raised *for the
  purpose of* waking.
- **TBD guards nothing here — its obligation is sufficiency, not guardrails.**
  There is no compiled choke point at actuation — no capacity hold, no
  in-flight dedup, no send-time freshness check through which every
  wake must pass. Such a choke point would make TBD the guarantor of a program
  TBD does not run, does not schedule, and — seeded once, never clobbered —
  cannot repair. A wake program's correctness is its author's, like any cron
  job's. What TBD owes instead is that everything the program needs is a
  public, documented, stable surface: parked state and `hibernateReason` in
  the listings; the supervision
  switch readable (`tbd supervise status --json`); per-profile
  usage facts readable (P1-1 — `tbd profile list --json`, contract in
  [`../capacity-facts.md`](../capacity-facts.md)); and
  `tbd terminal wake --prompt` with its existing race-safety — an
  already-awake session reports `woken:false` and receives nothing, the one
  property that must hold no matter who calls, and it already does. The
  reference script honors every rail the choke point would have enforced —
  switch off means exit quietly, rate-limited or
  capacity-exhausted means hold — as authored conduct with a worked example,
  not as law. Send-time freshness (P0-8) is likewise the program's
  discipline: derive facts live, immediately before composing, as the old
  wake.py always did — and it is the discipline for desk sends too. The
  daemon verifies nothing for anyone; freshness is authored on both sides of
  the process boundary. Wakes are recorded like every actuation the daemon
  executes — a row in the general actuation log (design §6), a record and
  never a gate; nothing here depends on supervision coverage, and nothing
  here writes supervision ledger lines.
- **The program schedules itself, and watches itself.** Cadence is a
  requirement; daemon ownership of it is not. The reference script runs its
  own loop — under launchd, or however its operator starts it — and a scheduler outside
  the daemon survives the daemon being down, which is P3-1's shape obtained
  for free (detection survives; actuation still needs the daemon up, which is
  all P3-1 ever asked). Liveness is the author's, like the rest of the
  program's correctness: TBD does not track when the program last ran. The
  reference script ships the self-monitoring pattern instead. A heartbeat
  file it rewrites on every run, carrying a summary and a next-run-by
  promise. launchd `KeepAlive` for the crash half, so the common death mode
  self-heals. On startup, a comparison of now against its own last heartbeat,
  so every crash-and-recovery reports its own gap ("dark 02:00–05:10, 3 runs
  missed") in the program's own log. And for the one death mode nothing can
  self-report — a job unloaded, or never installed — a paired external
  watchdog: a trivial second cron alerting on a stale heartbeat file, or a
  dead-man's URL pinged each run (`tbd notify` gives such a watchdog an
  operator-notification path through TBD itself, design §10). The accepted residue is named in design
  §16: in the account, a dead wake program over parked sessions looks exactly
  like the legitimate no-program default. If field use shows that ambiguity
  biting, the pre-planned escape hatch is one file read — the account
  renderer surfacing the heartbeat file's age against its own next-run-by
  promise at a conventional path — added then, not built now.
- **The default is silence, and merge means silence.** A project with no wake
  program gets no automated wakes: parked worktrees appear in the account with
  their work facts — a merged PR renders as done-and-archivable, commits with
  no PR as an attention item — and a human or a desk acts on what the report
  shows. The shipped reference script encodes the settled answers: a MERGED
  pull request suppresses every commit-derived signal (merged is an absorbing
  state, so even a stale status is safe to trust in that direction); a failure
  to determine state fails closed to "verify first," never to "done"; and a
  merge is never itself a reason to wake — a worktree that looks finished is
  an archive question for the human. A project whose convention differs (say,
  a post-merge closeout ritual) edits its own program; the tool ships no
  opinion it cannot be argued out of.

## A dated source note in the reference script (2026-07-29)

These are **observations from one week of one fleet, recorded as a dated
comment block in the shipped reference script — not spec law.** They live there
precisely so they can be edited, disagreed with, or rot without anyone touching
a design document: which API tells the truth this week is transient forge
weather, the same bucket as a repo slug or a machine's fleet snapshot. They are
written down at all because freshness is entirely an authored concern (P0-8,
requirements doc), and an authored discipline is only as good as the source it
consults — a re-derivation that consults a lying oracle is worse than none,
because it returns confidence.

Measured in the field, 2026-07-29:

- **Prefer the forge's REST reads over `gh`'s GraphQL for pull-request state.**
  GraphQL was observed serving 17.5-hour-stale state that was internally
  self-consistent — nothing in the response looked wrong. The REST read was
  correct every time it was compared.
- **Use `git ls-remote` when a head SHA must be certain.** After a force-push
  it reported the new head about 20 seconds before the API did.
- **Treat TBD's own listed PR status as display-tier.** It carries an
  observed-at for a reason (design §2); derive forge facts yourself rather
  than composing a wake from a cache that was seen reporting "Ready to merge"
  for pull requests merged days earlier.
- **Trust a stale MERGED; never trust a stale OPEN.** This one is not weather —
  it is the forge-independent semantics already recorded above: merged is an
  absorbing state, so an old MERGED is still true, while an old OPEN says
  nothing about now. It is playbook-tier and belongs in any program's verdict
  logic, whatever the sources of the week turn out to be.

## The guarantee TBD does make: sufficient, stable surfaces

The requirements doc's **Built/Enabled** classification names the obligation
precisely: P1-2 is Enabled — TBD guarantees that a
program written against its public surfaces *can* implement the story, not
that TBD implements it. Two consequences with teeth:

- **The reference script is the conformance test.** It may use only
  documented public surfaces. A fact it cannot obtain that way is a failed
  conformance check and a concrete, scoped API request — today the list has
  one entry, per-profile usage facts (P1-1) — and that is the mechanism by
  which TBD's surface grows: pulled by a real consumer, one argued piece at a
  time, never pushed by speculation.
- **Those surfaces become a contract.** Listing output shapes,
  `hibernateReason` values, wake semantics and exit codes stop being
  incidental CLI output the moment an external program is the sanctioned
  implementation of a P1 story. Migration and future changes must treat them
  as versioned interfaces. This is the one genuinely new cost of the
  outside-first posture, accepted here rather than discovered later.

## What the sweep keeps

What the sweep keeps is exactly the part that is universal. Its live half —
idle and stuck detection, prompt cases, runaway counters — is model-free and
the daemon's. Work facts (design §2) are derived on the daemon's clock; they
feed the account and the report lines above. They are not a wake gate anywhere
in compiled TBD.

One scope line, so nothing re-inflates here: worktree-local artifacts a wake
program reads are per-checkout, and **team-wide work-status syncing is out of
scope** — a program that wants cross-machine state uses the forge, which is
what it is for.
