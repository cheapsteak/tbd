# Fleet supervision — waking parked sessions: the wake program

Status: **normative sub-document of the fleet-supervision design.** Extracted
2026-07-29 from §4 of
[`2026-07-26-fleet-supervision-design.md`](2026-07-26-fleet-supervision-design.md)
to keep that document readable; it carries the same authority as the section it
came from, and `design §N` below refers to that document's sections. It records
the 2026-07-29 amendment that removed the compiled wake gate, motivated by
PR #522's field review. The requirements doc carries the matching dated
amendments on P1-2 and P1-4
([`2026-07-26-fleet-supervision-requirements.md`](2026-07-26-fleet-supervision-requirements.md)).

## The reversal, and why

An earlier version of design §4 compiled the wake decision into the sweep: a
global "outstanding work" fact list — commits not on the default branch,
uncommitted changes, an open PR, failing checks — whose any-true verdict made a
parked session a wake case. **Both the mechanism and its price argument were
wrong, and the field review of PR #522 (zionts, 2026-07-29) measured how
wrong.** The commit-identity fact reads true forever for a squash-merged
branch — the merge lands as one new commit whose diff matches none of the
branch's own — so finished work can never clear the gate: 33 of 70 active
worktrees on a live fleet (and 24 of 24 on the night that motivated P1-2) were
merged work the sweep would have woken every cycle, one of them into a resume
that would have spent 750k tokens re-entering work merged five days earlier.
The false-wake price was not "a few tokens"; it was systematic, correlated with
the forge's most common merge style. And the defect was structural, not a bug:
completion is a fact about intent and forge state — squash merges, abandoned
PRs, parked-on-purpose experiments are all invisible to git — so no compiled
git-fact list can express it. The old system's wake.py knew this: its verdict
let a MERGED pull request overrule `git cherry` outright, and the redesign
dropped that precedence when it dropped the verdict enum.

The repair is not a better fact list. **The wake decision leaves the daemon —
and the desk — entirely.**

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
  Routine waking therefore never reaches a desk. The `wake` verb survives for
  judgment — a desk may still conclude from a case that a session should be
  up — but no case is ever raised *for the purpose of* waking.
- **The daemon keeps the choke point, not the decision.** Every wake — from
  the program, a desk, or a human — passes through the same compiled rails at
  actuation: never-touch flags (P1-3), individually rate-limited targets and
  fleet-wide capacity holds (P1-1, design §11), an intervention already in
  flight, and the ledger line the daemon writes at that moment, attributed to
  its caller (P1-7). Freshness belongs here too: the actuation surface
  re-verifies a wake text's external claims exactly as `drive --text` does
  (P0-8) — the check is universal, so it lives at the surface every caller
  shares.
- **The program schedules itself.** Cadence is a requirement; daemon ownership
  of it is not. The reference script runs its own loop — under launchd, or
  invoked at shift open — and a scheduler outside the daemon survives the
  daemon being down, which is P3-1's shape obtained for free. What TBD owes is
  legibility, not supervision of the scheduler: the program's actuation calls
  are already ledger lines, so the account renders when the wake program was
  last heard from, and a shift with parked sessions and a silent wake program
  says so loudly — a dead scheduler must never look like a calm night
  (design §16).
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

## What the sweep keeps

What the sweep loses is exactly the part that was never universal. Its live
half — idle and stuck detection, prompt cases, runaway counters — is
unchanged, model-free, and still the daemon's. Work facts (design §2) are
still derived on the daemon's clock; they feed the account, the actuation
rails, and the report lines above. They are no longer a wake gate anywhere in
compiled TBD.

One scope line, so nothing re-inflates here: worktree-local artifacts a wake
program reads are per-checkout, and **team-wide work-status syncing is out of
scope** — a program that wants cross-machine state uses the forge, which is
what it is for.
