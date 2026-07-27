# Fleet supervision — design (living draft)

Status: **complete draft, pending operator review.** Captures the decisions
settled in the design conversation of 2026-07-26, after a plain-language
editing pass. Companion to
[`2026-07-26-fleet-supervision-requirements.md`](2026-07-26-fleet-supervision-requirements.md),
which carries the stories (P0-1 … P3-1) this doc cites. This is the ideal-state
design; migration from the current implementation is deliberately out of scope
and will be planned separately.

## 1. The placement test

"Compiled vs. prompt" is the wrong distinction. Behavior can live in three
places. Each place has its own test:

- **Compiled (daemon)** — facts and safeguards that must hold no matter what a
  model says. These include deriving state, gathering facts, enforcing the
  operating posture, keeping the ledger, verifying facts before sending, and
  scheduling. Ask two questions: *If this were wrong, would the rest of the
  system be built on a lie?* And: *Must it run for forty agents every cycle
  without calling a model?*
- **Authored artifacts (files, resolved through three tiers)** — choices on
  which two reasonable repositories or operators could differ. Examples
  include what counts as stuck, local rules, and what response a situation
  calls for. Team-specific behavior cannot be compiled. It also cannot be left
  for the supervisor to invent, because invented judgment cannot be reviewed,
  versioned, or passed between shifts.
- **The supervisor's reasoning** — only decisions that require reading text
  produced during the current shift. These include choosing a context-aware
  next step from an agent's actual transcript (P0-7), sorting and wording
  escalations, and making judgment calls that policy explicitly assigns to the
  supervisor. A threshold or state calculation placed in the prompt is a fact
  disguised as judgment.

The requirements brief names six specific items and asks where each one landed.
The applications appear throughout this document; this table collects them for
a quick audit:

| Named item | Home | Where argued |
| --- | --- | --- |
| State derivation | Compiled. It is fact; a wrong answer poisons everything downstream, and it runs for the whole fleet every cycle. | §2 |
| Intervention thresholds | Compiled default numbers, global. Per-repo tuning is deliberately deferred (§15). Crossing a threshold produces a case; the response is judged. | §2, §13 |
| Cooldowns and dedup | Excluded by the brief (solved elsewhere). The sliver in this design — "intervention already in flight" and "re-check pending" checks — is compiled into the sweep. | §4 |
| Per-repo policy | Authored: the playbook (advisory prose) plus standing rules (binding, operator-ratified). | §5, §8 |
| Mode enforcement (P0-3) | Compiled: the verb gate. Capability gating, never prompt wording. | §3 |
| The shift/morning account | Compiled: a ledger written by the verb handlers; views are queries; the supervisor adds attributed notes only. | §6 |

**This placement means the daemon, not the supervisor, drives the loop.** A
compiled sweep follows the same pattern as the existing hibernation sweep: a
cheap polling tick and a pure decision function. It calculates state, applies
the mechanical reasons not to act, and wakes the supervisor only when it has a
work order. Waking the supervisor is the result of a check, never the way the
check is performed (P0-6, P1-2). The supervisor never polls or sweeps, and it
never writes state or history directly. The daemon never makes a judgment.
Information and commands flow in one direction: daemon → work order →
supervisor → verb → daemon.

## 2. State model (P0-5, decomposed)

The original requirement is too large as written. Split it by priority:

**P0 — session state.** Record what each agent is doing now: `working`, `idle`,
`awaiting input`, `rate-limited (until?)`, `parked (reason)`, `gone`,
`unknown (why)`. Every stored value includes the value, its source, and the
time it was observed. It is never only an enumeration value. This makes
`unknown` honest and traceable. It also prevents downstream code from using an
old fact without seeing its age.

The sources are existing machine interfaces. The Claude hook → command-line
interface (CLI) → remote procedure call (RPC) pipeline provides working, idle,
and awaiting-input events at no added per-event cost. `scheduled_resumes` plus
classification of the end of the transcript identifies rate limits.
`hibernatedAt`/`hibernateReason` identifies parked agents. tmux pane and process
liveness identifies gone agents. This design adds two things:

1. **Verify before intervening, not before displaying.** Hook events are
   accurate enough for the user interface (UI). Before using a state to justify
   an intervention, however, the daemon checks the pane's live process once.
   This requires one tmux subprocess. If the event and live process disagree,
   the result is loudly reported as `unknown`. The daemon never silently picks
   one input.
2. **Install Claude Code's Notification hook** so "awaiting input" carries a
   structured reason. That reason has two consumers. It rides along in the
   escalation payload, so an operator carrying a stall sees exactly what was
   asked, verbatim — including the prompts a repo's deliberate `ask` rules
   raise, which are escalated rather than answered ("Prompt stalls (P2-3)"
   below). The one-minute re-check (P1-6) also uses it to answer, "Did the agent
   advance past the prompt?"

One more session-state fact comes free from the same source: **context load** —
the tokens currently in a session's context window, read from the last
assistant record's `usage` block at the transcript tail (the same tail read
that already classifies rate limits). The window size (the denominator) is not
in the transcript, so the app carries a small compiled model → window-size
table — a universal fact about models, not about any repo's process. The
statusline is deliberately **not** used as the source: its stdin JSON carries
the same numbers, but claiming the `statusLine` settings key would overwrite a
statusline the operator configured — a display slot the user owns. The data
was always in the transcript; TBD reads it there, and the current pane-read
for context goes away.

**P1 — make existing work facts available overnight.** The daemon already
calculates almost all work state. It gets pull request (PR) status for each
worktree through batched GraphQL requests. It persists `PRStatus`, including
state and a summary of checks. It also sweeps for branch conflicts and detects
merge transitions. Two implementation gaps remain. First, PR fetching runs
only when the app polls, so it stops overnight; move it to the daemon's clock.
Second, a failed fetch looks the same as "no PR"; record
`undetermined (cause)` as a separate result. This needs no new terms or state
calculation.

**P2 — add nothing unless experience proves it is needed.** Do not add verdict
enumerations or a schema for the stages of work. A "work arc" differs by
repository, team, and person. Compiling a fixed set of arcs would recreate the
old system's worst defect. Policy and the supervisor should read the raw facts
the app already has. If operator hooks repeatedly implement the same
calculation in the future, consider moving that specific calculation into the
app.

### Prompt stalls (P2-3): the machine-interface test

P2-3 asks for agents to be advanced past an operator-authored allowlist of
routine permission prompts. The story is honest about the pain and wrong about
the mechanism: an allowlist matched against a rendered dialog is screen-scraping
with extra steps. An earlier draft of this design answered by refusing *all*
dialog advancement — "prevention, never advancement." That overcorrected. It
fused two separate things into one prohibition, and pulling them apart is the
actual rule.

**Scraping is a way of *knowing*. Keystrokes are a way of *acting*.** The ban
belongs on the knowing, and there it is unmoved: reading a rendered terminal to
learn what is on the screen breaks silently when the agent changes its copy,
couples TBD to one agent version, and sits at the wrong layer. Typing into a
pane is a different thing, and it is not exotic — it is how *everything* in
this design is delivered. `intervene` types. The fleet delivery adapter types
(§12). The rate-limit actuator types. A rule that forbade keystrokes would
forbid the system's only way to reach an agent at all.

So the rule is not "never advance a dialog." It is a three-condition test:

> **TBD may drive a dialog if and only if (1) its existence is known from a
> machine interface, (2) its content is known verbatim from a machine
> interface, and (3) its outcome is verifiable from a machine interface. The
> screen is never consulted for any of the three.**

The conditions are conjunctive, and the third is not decoration: acting without
a machine-readable record of what came of it is how an automated answer becomes
unaccountable. Anything that fails any condition is not driven — it is
prevented at the source, or carried to a human. Today exactly one dialog
passes: Claude Code's `AskUserQuestion`.

**A repo's `ask` rules fail the test, and would be refused even if they
passed.** Start from what daemon-spawned fleet sessions actually face.
`ClaudeSpawnCommandBuilder` hard-codes `--dangerously-skip-permissions` on both
Claude spawn paths, and the Codex spawn passes
`--dangerously-bypass-approvals-and-sandbox`. Those flags remove the agent's
*default* permission checks; they do not silence a repo's explicit ones. A
repo's own committed Claude settings can carry `permissions.ask` rules, and an
`ask` rule still prompts under the bypass flag — by design, because it is the
repo deliberately requesting a human at a point it chose. This is real, not
hypothetical: one target repo in the motivating fleet gates PR merges
(`gh pr merge*`, plus the merge and auto-merge API routes) and
production-credential fetches this way, precisely so an agent has to get a
human before doing those things. So the allowlist P2-3 asks for *would* have
something to match — and matching it is exactly what must not happen. An
allowlist that auto-grants a repo's deliberate `ask` is the tool overruling the
repo's own decision about when a human is required.

That is an **authority** ruling, not a mechanical one, and it must be stated in
a form the test cannot erode. Should some future agent version ship hooks and
records that put permission prompts squarely inside all three conditions,
`ask`-rule prompts would *still* not be auto-answered. The repo asked for a
human; TBD's job is to fetch one. If a given ask fires too often to survive a
night, the fix is at its source — a reviewable settings change in the repo or
in the operator's overlay — never a TBD-side grant list.

Alongside those asks, the residual dialog zoo still stalls agents: folder
trust, `/login`, plan-mode approval, `AskUserQuestion`, and first-run dialogs.
Folder trust looks solved and isn't: `ClaudeTrustSeeder` pre-answers it for
scratch spaces only — its `guard worktree.isScratch else { return }` returns
early for repo-backed worktrees — and a fleet worktree is a path Claude has
never been trusted at, exactly as fresh and untrusted as a scratch dir. Seeding
trust for non-scratch worktrees is prong 2's first piece of new work, not
existing coverage. `ask`-rule prompts join the zoo as its one permission-shaped
member — and they are the one member that is deliberate. Measured against the
test, one other member of that zoo separates from the rest.

**`AskUserQuestion` passes all three conditions today** — not as an aspiration,
but on machinery already in the tree:

1. **Existence.** TBD's Claude settings overlay
   (`Sources/TBDDaemon/Hooks/ClaudeHookOverlay.swift`) already registers
   `PreToolUse` and `PostToolUse` hooks matched on `AskUserQuestion`. The
   pre-hook fires *before* the picker renders. The daemon learns the dialog
   exists from an event, not from a screen.
2. **Content.** That same pre-hook carries the full structured payload — the
   questions, their options, headers, the multi-select flag, and the
   `tool_use_id` — into the daemon's in-memory pending-question store. It is
   the *only* machine source of that content while the dialog is live: TBD's
   pending-question work in May established empirically that the transcript
   JSONL does not contain the `tool_use` record mid-dialog, which is exactly
   why the hook bridge was built. Verbatim, structured, before render.
3. **Outcome.** Once the dialog resolves, the `tool_result` lands in the
   transcript in a stable shape TBD already parses. What was answered is a
   machine fact afterward, not an inference.

No other member of the zoo has even one of the three. That is why this is
written as a test and not as a list: the list would have to be maintained
against every agent release, while the test re-evaluates itself every time a
machine interface appears or disappears.

**Actuation: dismiss and reply — never select.** The obvious way to answer a
picker is to arrow or type a digit to the intended option and press Enter. That
is refused, and refused for the original reason. Option choreography depends on
the rendered ordering and on where the highlight currently sits, and TBD
observes neither. Getting it wrong does not fail loudly — it selects the
neighboring option and reports success. Choosing "B" by counting keystrokes is
scraping with the reading step replaced by a guess.

So there is no per-dialog key choreography anywhere in this design. The
sequence is one shape for every question:

1. **Dismiss with Escape.** Escape closes the picker and can never select — the
   same property the rate-limit actuator already relies on, where a blind Enter
   could have confirmed a paid plan upgrade and Escape could not.
2. **Wait for the dialog's resolution signal** — the `PostToolUse` hook
   clearing the pending entry. A machine signal, never a timer. Nothing is
   typed into a session that may still have a modal on screen.
3. **Deliver the response as ordinary composer text** through the standard
   delivery adapter, with §12's acknowledgement path verifying it landed: the
   ledger marker appears in the transcript, or the send is retried once and
   then escalated.

The answer is therefore a sentence rather than a keystroke, which is a gain and
not a compromise. "B, but only after you have checked X" costs nothing extra;
neither does "none of these — here is the thing you did not consider." A picker
can only return one of its own options. The composer can return judgment.

**This is the `answer` verb (§3), gated like every other consequential verb.**
In attended mode the proposal *is the relayed question*: it carries the agent's
questions and options verbatim alongside the supervisor's proposed response and
its reasoning, so the operator can approve it or simply answer differently
themselves. The queue entry is the dialog, delivered at last to the human it
was always addressed to. In autonomous mode the verb executes through the
standing-rules gate and writes its action line. The response need not be an
answer at all: "these options are underspecified — work through the tradeoffs
and ask me again" is a legitimate response, and so is a redirect. Which
response a question warrants is playbook judgment (§5); the mechanism is
identical either way.

**How the question becomes a case.** The hook stays an unconditional dumb
reporter — no posture check on the agent side, ever. It reports; the daemon
owns posture and already receives every event. The fork lives in the daemon's
RPC handler: when a shift is active and the terminal's repo resolves in
automation (§8), a pending question becomes a case, and the event **hastens an
immediate mini-tick for that terminal** instead of waiting for the next sweep.
Same pure decision function, triggered by an event rather than the clock, so
the daemon still drives the loop (§1). **The work order carries the question
payload verbatim out of the daemon's store**, so the supervisor fetches
nothing — which dissolves the need for any new read surface. Nothing is
ledgered for the question itself; facts are not ledger lines. The question
snapshot rides in the `answer` action's line, or in the escalation line if the
supervisor punts.

**Store hygiene, and what a restart costs.** The pending store's time-to-live
is a garbage-collection backstop for stranded entries, not a dialog's clock. It
must never expire a still-live dialog during a shift: resolution comes from the
`PostToolUse` clear, not from elapsed time. The store staying memory-only is
fine under §7's restart rule. A mid-shift daemon restart degrades honestly —
the awaiting-input state persists, so the case still knows a question is
pending, but its content is gone, and the case reports that loudly rather than
quietly. The supervisor's options are then to dismiss and ask the agent to
restate its question as text, or to escalate. Never to guess at what was asked.

So the design answers the stall in three prongs, each at a different moment:

1. **Tool-permission behavior is fixed at the source — TBD never
   counter-configures it.** The one place that decides what prompts is the
   agent's own permission config: the repo's committed settings, plus the
   operator's per-repo claude-settings overlay, which already deep-merges into
   the per-session `--settings` file at spawn. TBD delivers that overlay and
   stops there. It grows no counter-setting that auto-answers what a repo's
   settings deliberately ask about — "the repo says always ask before merging;
   the tool says always grant merge requests" is two configs fighting each
   other, and a standing waste of both tokens and the reader's trust in either
   setting. TBD invents no matching language, stores no conditions, and
   evaluates nothing at runtime; an `ask` that survives spawn is honored as an
   escalation (prong 3). If overnight operation shouldn't stall on a given ask,
   the fix is to change that ask rule at its source — a reviewable settings
   change in the repo or in the operator's overlay — never a TBD-side grant
   list. The same holds should non-skip-permissions fleet spawns ever ship:
   the operator's allowlist is `permissions.allow` in that same config,
   enforced by the agent's own engine.
2. **Config-answerable dialogs — pre-answered by seeders before spawn**, one
   seeder per agent kind, following the `ClaudeTrustSeeder` precedent.
   `ClaudeTrustSeeder` is precedent for the *pattern* only — it seeds scratch
   spaces and returns early for repo worktrees — so carrying trust seeding to
   non-scratch fleet worktrees is work this prong names, not work that already
   exists. A dialog that has a config answer is answered before it can ever be
   drawn.
3. **Everything that still stalls is a genuine question** — either because it
   was never routine, or because a repo's settings deliberately made it a
   question and prong 1 declines to answer for them. Genuine questions are not
   noise to suppress; they are routed, and the test decides where. A question
   that passes all three conditions becomes a case the supervisor answers with
   `answer` — today that is `AskUserQuestion` and nothing else. Everything that
   fails surfaces as an awaiting-input case and is escalated to the operator,
   unadvanced and never auto-granted. A firing `ask` rule always lands in the
   second group, by the authority ruling above, however good its machine
   interfaces ever get.

The story's "never past anything else" clause is then enforced *structurally*
rather than by an allowlist's precision — enforced by the test rather than by
the absence of a mechanism. A dialog TBD cannot see through a machine interface
is a dialog TBD cannot drive, and no prompt wording or operator list can change
that, because the gap is in the facts and not in the policy. One consequence
for the rest of this document: the `approve-a-prompt` verb stays removed from
the verb set (§3, §8), and `answer` is not its return. `approve-a-prompt` was a
blanket, model-free auto-grant of permission prompts — the tool deciding in
advance that a whole class of questions needed no human. `answer` is one judged
response to one question whose text the daemon holds verbatim, gated by
posture, delivered as text, and recorded. It grants nothing.

None of this makes stalls cheap to ignore, and nothing above slows detection.
The one-minute re-check (P1-6, §4 step 8, §12) still notices a stalled agent
within a minute of an intervention, and the sweep still raises awaiting-input
as a case. Prevention plus fast escalation is how "a trivial prompt doesn't
cost a night" is actually met — the night is lost to a prompt nobody *sees*,
not to a prompt nobody auto-answers.

*Cautionary prior art.* The old system shipped `safe_wedges.txt`: a list of
command prefixes (`gh api`, `git`, `gh pr comment/edit/review/ready`,
`gh issue`, with a "never `gh pr merge`" note) consumed by an out-of-tree
screen-scraping babysitter (`~/.fleet/babysitter_daemon.py`) that typed
approvals into panes. The wedges failed the machine-interface test twice over,
and the two failures are independent. First, the *content*: the babysitter knew
what it was approving only by reading the rendered TUI — condition 2 satisfied
by scraping, which is to say not satisfied, with condition 3 never attempted at
all. Second, the *vocabulary*: the list was written in matching language the
tool invented for itself rather than read from the config that actually decides,
and it was too coarse to ratify — a bare `git` prefix would have waved through
`git push --force`, and a bare `gh api` prefix would have auto-approved the very
merge and auto-merge API calls a repo's `ask` rules deliberately gate. A list
written in a vocabulary the tool invented, matched against text the tool
scraped, is two guesses stacked. Note what the new rule does *not* rescue here:
`answer` shares the typing with that machine, and nothing else. That machine was
checked on 2026-07-27: `~/.fleet/` is absent, no process is running, and no
`launchd` job remains.

## 3. The two modes (P0-2, P0-3)

There is one operating posture: **off / attended / autonomous**. It is a
configuration column in the daemon. It can be set from the app and CLI, is
broadcast when it changes, and survives a restart, just like every other daemon
toggle.

**A note on the name.** The requirements brief calls this posture
"human-supervised" (P0-2). It is renamed here because "supervised" collided with
the subsystem's own name: this subsystem *is* fleet supervision, and the
supervisor supervises the fleet in both modes. The posture names the human's
side of the relationship — an operator is in the loop, and consequential verbs
queue for them — not the supervisor's. "Autonomous" is unchanged.

**Enforcement controls capabilities; it does not rely on prompt wording.** The
supervisor acts only through daemon commands, called verbs. In attended mode,
the daemon turns consequential verbs into proposals. The call succeeds, but
the daemon adds the action to a queue instead of executing it. No prompt can
confuse the supervisor into acting autonomously because the verb cannot execute
in that mode. The verb handlers write ledger rows. The supervisor therefore
cannot misreport its actions because it is not the reporter.

**The human-in-the-loop split: authored *what*, compiled *how*.**
- *What is consequential* is policy (per repo, per verdict) — two reasonable
  repositories can reasonably differ.
- *How a human is involved* uses one compiled mechanism: the
  **approve-before-act proposal queue**. The posture switch applies to the
  entire fleet, so it must make the same promise everywhere. A single queue and
  interaction pattern also let the operator clear the morning queue in minutes
  (P0-10).
- The veto-window variant (act after a cancellable delay) is rejected outright:
  a missed veto allows an action that was never approved. That would silently
  turn attended mode into autonomous mode, exactly the false promise P0-3 is
  intended to prevent.

Compiled defaults are as conservative as possible. In attended mode, every
verb that affects the fleet becomes a proposal. In autonomous mode, verbs
execute and questions are collected into escalation batches. Standing rules
(§5) can relax these defaults. Files shipped by a repository cannot.

### The verbs (normative)

This table is the single normative inventory of the supervisor's capabilities.
Every other mention of a verb in this document defers to it.

| Verb | What it does | Gated? | Attended mode | Autonomous mode |
| --- | --- | --- | --- | --- |
| `intervene` | Deliver a re-verified message to a fleet agent (the send path of §4 step 7) | gated | Becomes a proposal | Executes; ledger line |
| `wake` | Unpark and resume a parked session | gated | Becomes a proposal | Executes; ledger line |
| `pause` | Halt a runaway session (§13) | gated | Becomes a proposal | Executes; ledger line |
| `answer` | Respond to an agent's `AskUserQuestion` — dismiss the dialog, reply as composer text (§2) | gated | Becomes a proposal that *is* the relayed question: the agent's questions and options verbatim, plus the proposed response and reasoning. The operator approves it or answers differently themselves | Executes; ledger line |
| `escalate` | Queue an exact question for the operator | ungated | Ledger line; appears in the queue immediately | Ledger line; batched for morning |
| `note` | Attributed prose into the account | ungated | Ledger line | Ledger line |
| `learn` | Append to the repo's learnings file | ungated | Ledger line | Ledger line |

Every verb is both a `tbd supervise <verb>` CLI command and an RPC method, so
nothing exists only as a button (§10). `approve-a-prompt` is deliberately
absent, and `answer` is not it under another name: see §2's prompt-stalls
subsection for the difference between a blanket auto-grant and one judged reply
delivered as text.

## 4. The wake-to-action loop

Example flow in autonomous mode at 2:00 a.m. with forty agents:

1. **Tick.** The daemon sweeps the fleet table in its own process. It uses no
   model and starts no subprocesses. It silently skips agents that are working,
   or parked with no outstanding work. It writes no log and wakes nobody.
2. **Hit.** An agent has been idle for 40 minutes and has uncommitted work.
   Before doing anything, the daemon checks the mechanical reasons to stop: a
   never-touch flag, a rate limit, insufficient quota, an intervention already
   in progress, or a pending re-check timer.
3. **Corroborate.** The daemon checks the pane's live process once. If it
   disagrees with the hook state, the daemon records `unknown` in a prominent
   ledger line and stops. It must not guess.
4. **Work order.** The daemon prepares a case file. It includes the agent's
   identity, session state and its age, work facts, the repository's selected
   playbook, and the transcript path. If one tick finds several cases, the
   daemon puts them in one work order and wakes the supervisor once.
5. **Wake.** The daemon delivers the order through the adapter for that kind of
   agent, just as it would for any other session. The supervisor is an ordinary,
   visible session in its own worktree (P0-4). An operator can open its tab,
   watch it think, and type into it.
6. **Judgment.** The supervisor reads the transcript and writes a specific next
   step. It never sends only "continue" (P0-7). This is the loop's only model
   reasoning.
7. **Act through the daemon, never around it.** `tbd supervise intervene …`.
   The daemon performs three steps. First, it **re-verifies** every external
   claim in the message against live sources at send time. An old premise stops
   the send and returns the conflicting facts (P0-8). Second, it **checks
   posture**. In attended mode, a consequential action becomes a proposal.
   The supervisor uses the same code path in either mode. Third, the daemon
   **delivers** the message through the adapter and **writes the ledger line
   itself**.
8. **Short follow-up.** The act arms a one-minute re-check (daemon timer, in
   memory). The result is recorded as an outcome line referencing the action
   (§6). A new blocked state
   becomes a new case within one minute instead of fifteen (P1-6).
9. **Everything else costs nothing.** The other agents: zero tokens, zero sends.

**"Outstanding work" is a compiled, global fact list.** Step 1's parked-session
skip turns on one question: does any of these hold? Commits on the branch that
are not on the default branch; uncommitted changes in the worktree; an open PR
that is not merged; failing or missing required checks on an open PR; or an
undetermined result from any of those probes — which is its own loud case, and
is never silently treated as "nothing outstanding." That list is fixed and
identical in every repo.

The trade is deliberate and worth stating plainly: a repo cannot alter *whether*
a wake happens, only what the wake *warrants* — through its playbook, after the
supervisor is already awake. The requirements brief's P1-4 worked example ("the
check yields a verdict; the repo decides what the verdict warrants") is honored
at the warrant step, not at the wake step. Letting repos hook the wake step
would put authored code inside the model-free sweep that runs for forty agents
every cycle. The cost of getting it wrong the other way is small: a false wake
spends a few supervisor tokens and ends in a note.

**One case arrives by event rather than by tick: a pending `AskUserQuestion`.**
The `PreToolUse` hook already reports every one of them to the daemon
unconditionally, with no posture check on the agent side — the daemon owns
posture and sees every event anyway. The fork is in the daemon's RPC handler:
with a shift active and the terminal's repo in automation (§8), a pending
question becomes a case and **hastens an immediate mini-tick for that
terminal**, running the same pure decision function the clock would have run
minutes later. The work order carries the question payload verbatim from the
daemon's store, so the supervisor fetches nothing and needs no new read
surface. From there it is an ordinary case: judgment, then the `answer` verb
through the same gate as every other verb. Full mechanics, including the
dismiss-and-reply actuation and what a mid-shift restart costs, are in §2's
prompt-stalls subsection.

Boundary cases:
- **Supervisor can't decide** → `tbd supervise escalate` with the exact item,
  exact proposed command, and recommendation. Those lines appear unchanged in
  the morning queue. An answer becomes a durable decision and is never asked
  again (P1-5).
- **Supervisor stuck or gone** → it is a session like any other; the same
  machinery watches it. The sweep continues to collect mechanical facts, but
  makes no judgments. It reports the failure prominently. The daemon never
  pretends to provide the supervisor's judgment.

## 5. Where policy lives

**In-repo directory: `.agents/`** — the name describes its audience, not a
specific tool. It contains local process guidance for any tool that drives
agents. TBD owns particular *filenames*, never the directory. It must accept
and never alter files it does not recognize. In the ideal state, worktree
lifecycle hooks also live there (`.agents/hooks/…`), leaving one location in
the repository. `.worktree-hooks/`, `conductor.json`, and `.dmux-hooks/` become
deprecated levels in the lookup order, using resolver machinery that already
exists.

**The playbook — `supervision.md`, prose read by the supervisor.** The existing
three-level lookup chooses it in this order: the operator's per-repository copy
(`~/tbd/repos/<id>/supervision.md`, file-backed editor in the app) →
`.agents/supervision.md` in the repo → the tool's shipped default. First match
wins. The system uses the whole file and never merges levels. Every work order
includes the playbook for each agent. An order spanning two repositories
contains two labeled playbooks.

- **One playbook, not one per mode.** Mode arrives as context in the work
  order; per-mode advice is a prose section ("When running autonomously: …").
  Separate files for each mode would make prompt wording appear to enforce the
  mode and would invite promises the daemon cannot enforce. Any mode-specific
  behavior that must *bind* must become a standing rule that the daemon
  enforces.
- **Seeding without overwriting:** tool-provided content lives only in the level
  the tool owns: the shipped default, which updates may freely replace. The
  operator and repository levels are written exactly once. An explicit
  "Customize playbook…" action copies in the current default, and the tool
  never writes them again. It never reconciles these files at startup.
- The shipped default contains only universals (what stuck means, smallest
  intervention that restores progress, escalate instead of guessing, one
  intervention per agent per wake). One of those universals concerns questions
  specifically: **often the first move on an `AskUserQuestion` is not to answer
  it but to ask the agent that raised it to think through the tradeoffs of its
  own options in more detail, so the eventual decision is better informed.**
  That is advice, which is why it is prose here and not compiled — §2's
  `answer` verb carries a redirect exactly as readily as an answer, and the
  playbook is where the choice between them belongs. The default contains no
  commands, bot names, or organization-specific content.

**There is no `supervision.json`.** An earlier draft included a small,
structured policy file for the daemon to enforce. It would have held overrides
for consequential verbs, never-act lists, and thresholds. That content now
lives in the standing-rules store, which the daemon needs anyway:

1. **Compiled conservative defaults** cover a brand-new repo safely.
2. **Operator actions become standing rules**: approving a proposal offers
   "and everything like this" — scoped by verb / repo / worktree, for the shift
   or forever. One row, one click.
3. **Playbook prose promotes by one confirmation**: the first time the
   supervisor encounters a sentence that sounds like a hard rule ("never touch
   an open PR without a human"), it asks once, "make this standing?" A yes
   converts the prose into a logged, binding rule.

This implements one authority principle: **repos advise; operators bind.** A
repository file must not control tool behavior on an operator's machine before
a human approves it. Treating that behavior as normal would be a security
problem. The tradeoff is explicit: a repository cannot ship a binding rule
without one confirmation on each installation. Conservative defaults and the
queue protect the period before confirmation. If teams later need identical
rules on many machines with no confirmation, the promotion flow is the place
to add that capability.

**Specific-session designations (P1-3) are database (DB) flags, not policy
files.** "Don't poke *my* live session" refers to a runtime object that exists
for hours. A UI or CLI action sets a flag for that terminal or worktree,
following the `keepWarm` precedent. The sweep checks the flag mechanically.
Repository files contain rules about *kinds* of things. The DB records operator
choices about *particular* things.

P1-3's other half — *worktrees whose progress matters most get looked at
first* — reuses an existing operator gesture the same way: the worktree
**pin**. The sweep orders cases in the work order pinned-first (the pin state
worktrees already carry), then by case age, and the supervisor works the list
top-down. Pinning is already how an operator marks what matters, so priority
costs no new schema and no new concept. Like every fact, ordering only shapes
attention — it never changes what any verb is allowed to do.

## 6. The account (P0-9, P1-7)

**The ledger is the account; everything else is a view of it.**

- `~/tbd/shifts/<shift-id>/ledger.jsonl` — an append-only file with one
  JavaScript Object Notation (JSON) object per line, written **only by daemon
  code at the moment it acts**. It supports these line kinds:
  **action** records an intervention, wake, pause, or answer, including the
  message text, the state snapshot that justified it, and the posture. A separate
  **outcome** line references the action's ID and records what was observed.
  **lifecycle** records shift open, shift close, posture changes, and desk
  recycles (§9). **proposal** and
  **resolution** record proposed actions and their results. **escalation** and
  **resolution** record questions and their answers. **decision** records a
  standing rule created from any source. **anomaly** records an unknown state,
  an old premise found during send-time verification, a failed fetch, or a dark
  supervisor. Deliberate inaction is recorded as seriously as action. **note**
  and **learning** are the two kinds whose content is supervisor-authored prose
  — a note is attributed prose added with `tbd supervise note`, and a learning
  records an append to a repo's learnings file made with `tbd supervise learn`
  (§8). Both are written by the daemon's verb handlers like every other line,
  and neither can change any other line. The supervisor may reference lines and
  contribute prose; it can never author an action, an outcome, or the account.
- Its structure prevents several false claims: an action nobody performed
  because only verb handlers write action lines; an outcome nobody observed
  because outcomes come from the re-check; and certainty the system did not
  have because unknowns are anomalies, not values.
- Quiet ticks write nothing. Sweep liveness is one status field, not forty
  lines an hour.
- **`account.md`** sits beside the ledger. The daemon regenerates this view
  after every append, and the side panel displays it live. Nobody writes the
  account directly. The supervisor can only add attributed notes *into* it.
  Markdown is the record's presentation; JSON Lines (JSONL) is its source.
  Markdown cannot be the source because parsing prose back out of a display
  format would repeat the screen-scraping mistake in a file.
- **End-of-shift and morning views are queries** over the shift's time window.
  The views are done (actions + outcomes), open (unresolved proposals and
  escalations), needs-you (the escalation batch), went-wrong (anomalies), and
  now-binding (decisions). A closing supervisor narrative is a final note *on
  top of* the generated report. It adds context but does not author the record.

### Ledger line shape

Every line shares one envelope — `{ "id", "ts", "shift", "posture", "kind" }` —
plus a payload determined by its kind. The envelope is what makes the views in
this section plain queries: filter by kind, window by `ts`, group by `shift`.

| Kind | Payload carries |
| --- | --- |
| `action` | The verb, the target (worktree / terminal / repo), the message text, and the state snapshot — with its source and observed-at — that justified it. For `answer`, that snapshot includes the question payload verbatim: no separate line records the question, because a pending question is a fact and facts are not ledgered |
| `outcome` | A reference to the action, one of the three §12 results, and the observed-at of that observation |
| `proposal` | Everything an `action` carries, plus the supervisor's reasoning and the age of the state it reasoned from |
| `resolution` | A reference to the proposal or escalation, the result (approved / rejected / answered / expired), the scope choice if one was made, and the operator's optional explanation |
| `escalation` | The exact item, the exact proposed command, and the recommendation |
| `decision` | The rule created, its lifetime (shift or always), and its origin |
| `anomaly` | The category and the detail |
| `note` | The author, the text, and optional references to other lines |
| `learning` | The target repo and the appended text — the durable content lives in `~/tbd/repos/<id>/learnings.md` (§8); this line is the record of the append |
| `lifecycle` | Opening, closing, posture change, or desk recycle — this is the kind behind every line §9 describes |

Two representative lines, an action and the outcome that later references it:

```json
{"id":"a3f1","ts":"2026-07-27T02:41:09Z","shift":"s-0714","posture":"autonomous","kind":"action","verb":"intervene","target":{"worktree":"1B7E2C90","terminal":"6D40F3A1"},"message":"The rebase conflict is in Package.resolved …","state":{"session":"idle","source":"hook+pane-verify","observedAt":"2026-07-27T02:40:58Z"}}
{"id":"a3f2","ts":"2026-07-27T02:42:11Z","shift":"s-0714","posture":"autonomous","kind":"outcome","action":"a3f1","result":"landed-and-acting","observedAt":"2026-07-27T02:42:09Z"}
```

Field lists beyond this are implementation detail and will grow. The envelope,
the set of kinds, and the never-claims above are the contract.

## 7. Persistence and storage map

Three categories determine where data belongs. **Live coordination state** is
read to allow or block behavior, affects the system's next action, can be
changed by concurrent actors, and appears live. **Append-only history** is
never used to allow or block behavior; an error there produces an inaccurate
account, not a wrong action. The third category is **human-authored process**.

- **DB: the posture. One config column. Nothing else supervision-specific.**
  Every gated verb reads it. Both the app and CLI can set it, and all surfaces
  must see the same value immediately after a change. That is the purpose of
  the shared configuration object.
- **Shift directory** (`~/tbd/shifts/<shift-id>/`): `ledger.jsonl` +
  `account.md`. The proposal queue is **not a separate data store**. It is an
  in-memory view of the ledger: created proposals minus resolved proposals.
  The daemon rebuilds it at startup by replaying the file. It checks expiry
  when the operator approves a proposal by asking, "Is this proposal still
  current?" No background process writes expiry. This removes the only race
  between multiple writers and therefore the need for a table. Shift-scoped
  decisions are ledger events viewed in the same way. They end with the shift,
  and the shift directory contains everything needed for debugging or sharing.
- **Durable files**: `~/tbd/supervision/standing-rules.json` — the rules
  enforced at the command gate, including repo automation membership and its
  default stance (§8). The operator owns the file. It is atomically
  rewritten after each operator action and can be edited by hand. The daemon
  reloads it after a change because these are the operator's rules. It also
  loads the file into memory for per-verb lookups. Every change appends a
  ledger line. The current rules and the history of how they were created
  therefore live in the appropriate places. The playbook tiers (§5) are also
  durable files.
- **In-memory, deliberately not durable**: active one-minute re-check timers
  and the sweep's temporary tracking. A daemon restart during a shift loses
  them. The result is a one-cycle delay, not a broken promise. State used to
  gate an action needs durability only when an operator or mode label has made
  a promise about it.
- **Crash rule** (replay finds an approved proposal with no action line):
  never automatically execute an old approval. Report it as an anomaly:
  "approved at 7:58, daemon restarted before acting; approve again if still
  wanted." This applies the rule that uncertainty must lead to inaction to the
  supervision machinery itself.

Net property: **supervision adds one column to TBD's database.** Everything
else it knows is in files a human can open.

## 8. Remembered things: three kinds, three homes

These categories need precise names because they are easy to confuse:

1. **Binding rules** — enforced by the daemon at the verb gate, no model in the
   loop: `~/tbd/supervision/standing-rules.json`. The format is structured
   because prose cannot be enforced without interpretation. It is local to the
   operator because the operator must approve any rule that binds their daemon
   ("repos advise; operators bind"). Rules are created only by operator actions:
   approval generalization, prose promotion, or CLI. A small settings surface
   makes them inspectable. That surface is a view of the file with a list,
   links to origins, and a revoke action. The file remains the source of truth.
2. **The playbook** — advisory prose, human-curated, travels with the repo
   (`.agents/supervision.md`, three-tier). The tool never writes it after
   seeding.
3. **Learned knowledge (P2-1)** — raw, uncurated prose appended by the machine:
   `~/tbd/repos/<id>/learnings.md`, appended via `tbd supervise learn`,
   ledger line per append, included in every future work order for that repo.
   It takes effect immediately. When an entry proves useful, a *human commit*
   promotes it into the repo playbook. The tool freely rewrites only files it
   owns. The supervisor's desk has no repo checkouts, and the daemon never
   commits to repos.

The categories connect in one controlled way. The supervisor considers a
learning. If it continues to matter and looks like a rule, the supervisor
proposes making it binding. One approval turns it into a standing rule. A
single confirmation connects prose knowledge to binding rules.

### Why the binding tier is structured at all (post-#509 accounting)

GitHub now has merge authority, so few verbs remain behind the gate:
`intervene`, `wake`, `pause`, and `answer` (§3). A fifth, `approve-a-prompt`,
was removed along with the P2-3 resolution (§2) and stays removed: it was a
blanket, model-free auto-grant of permission prompts, and nothing in this design
grants a permission on an agent's behalf. `answer` does not restore it. It
advances exactly one dialog — the one whose existence, verbatim content, and
outcome all reach the daemon through machine interfaces — by dismissing it and
replying as text, which is judgment delivered through the ordinary send path,
never an auto-grant. That is why it belongs behind this gate rather than outside
the verb set. It is reasonable to ask whether prose could replace the binding
tier. It cannot, for exactly four reasons. The design must not grow beyond what
these reasons require:

1. **The attended-mode promise (P0-3).** The verb gate consults posture and
   rules without using a model. If prose could relax them, the system would
   either remain maximally conservative forever or let the supervisor control
   its own capabilities by interpreting prose. The latter would make the mode
   label a false promise again.
2. **"Never re-ask me" (P1-5).** The daemon's queue would repeat the question.
   Only a remembered approval at the gate can prevent it from asking again at
   3 a.m., 4 a.m., and 5 a.m.
3. **Never-lists must hold when nobody is watching.** When the model is the
   only active decision-maker, a binding rule cannot depend on a prompt.
4. **`intervene` injects instructions, and so does `answer`.** Fleet agents run
   with permission checks skipped. A supervisor message can contain any
   instruction for an agent with full tool access, and a reply to a question is
   the same text arriving through the same composer. Merge authority could move
   to the code-hosting service, but only TBD controls these actions. No other
   system can enforce the gate in front of them.

Because the scope is small, the rule store remains a flat list with scope,
verb, stance, and lifetime. It has no language for conditions, no rule
interactions, and no Secure Hash Algorithm (SHA) pinning. The remaining risks
do not justify anything more complex.

The storage decision is settled: standing rules are a **file**
(`~/tbd/supervision/standing-rules.json`), loaded into memory at startup,
checked in memory for every verb, atomically rewritten after each operator
action, and reloaded after a manual edit. "Structured" describes the format and
its reader: the gate cannot interpret sentences. It does not imply database
storage. With tens of rules and one writer at a time, a database adds nothing.

### The file shape

```json
{
  "version": 1,
  "automation": { "default": "in", "repos": { "<repo-id>": "out" } },
  "rules": [
    {
      "id": "<uuid>",
      "verb": "intervene",
      "scope": { "repo": "<repo-id>" },
      "stance": "allow",
      "origin": { "shift": "<shift-id>", "ledger": "<line-id>" },
      "createdAt": "2026-07-27T03:12:00Z"
    }
  ]
}
```

`scope` has exactly three shapes — `{}` (fleet-wide), `{ "repo": … }`, and
`{ "worktree": … }` — and nothing richer; there is no language for conditions,
by the argument above. `stance` is `allow` or `deny`. `origin` links every rule
to the ledger line that created it, which is what the inspection surface's "why"
link resolves (§10): no rule exists without a recorded reason for existing.

The file carries **only lifetime-always rules.** A shift-scoped rule is a
decision line in that shift's ledger, projected into the same in-memory rule set
the gate consults (§7), and gone when the shift ends. So the logical rule shape —
scope, verb, stance, lifetime — is realized across two stores, split on the
lifetime field, which is exactly why the file itself needs no lifetime field.

Automation membership is the dedicated `automation` object rather than a rule
with a special verb: same file, same loader, same gate, but a distinct question
("may the daemon act in this repo at all?") that is asked before any verb is
considered.

### Repo automation membership (operator-configurable)

Which repos the supervisor may act on is an operator setting, not a design
constant. It has two pieces:

- **A default stance**, chosen by the operator: default-in (every repo is
  automatable unless marked out) or default-out (no repo is automatable until
  marked in). The system ships with default-in, because the autonomous posture
  is already an explicit operator choice and this matches the old system's
  watch-everything behavior; an operator who wants deliberate per-repo
  onboarding flips one control.
- **A per-repo mark**: in, out, or follow-the-default. Only explicit marks
  are stored; a repo with no mark follows the default, so flipping the default
  never requires touching individual repos.

Both live in `standing-rules.json` in the same file as the verb rules — same
loader, same gate, one source of truth for "may the daemon act
here." Membership is checked before any verb executes **and before proposals
are created**: a repo that resolves to *out* generates no proposals in
attended mode and no actions in autonomous mode. It still appears in the
fact sweep and the account — observability is never gated, and "repo X needed
attention but is out of automation" is the honest report. Because membership
is enforced at the same model-free gate as the never-lists, it holds when
nobody is watching (reason 3 above).

### Prior art in the current system (and what #509 changed)

Before the redesign, the system represented these concepts in four ways. It
had a hardcoded `STANDING_RULE` prompt string, which compiled one team's
closeout command and review-bot name into the app. This is the exact warning
example from the brief. The merge gate had a `clearance` table with
per-PR, SHA-pinned operator approvals that code enforced. A prompt asked the
desk agent to consult `approved-prs.jsonl`, so it was binding only until the
model forgot, which is the false mode promise described in P0-3. Finally, the
desk's notes file served as both memory and action log, creating the
"self-report" problem in P1-7.

PR #509, merged on 2026-07-26, correctly deleted the merge gate and its
clearance and audit stores because GitHub branch protection now decides whether
a PR may merge. This has two consequences. First, the clearance table is
history, not a reason for this design. Its shape happened to be useful: scoped,
enforced, revocable, and auditable. But the four reasons above provide the full
case for standing rules; deleted code does not. Second, after #509 the system
has **no** enforced mechanism for operator decisions. The verb gate and
standing rules will be the first such mechanism, not an upgrade.

## 9. Shift lifecycle (P2-2)

- **A shift is born from the posture switch, and only from it.** off →
  attended/autonomous creates a shift ID, creates
  `~/tbd/shifts/<id>/`, writes the opening ledger line, and starts the
  supervisor. A switch between attended ↔ autonomous during a shift keeps
  the *same* shift and adds a posture-change ledger line. Every action line
  already records its posture. Only switching to off ends a shift.
- **The desk is a scratch space, tracked by ID** rather than by its display
  string. It receives the supervision skill through the plugin mechanism. Its
  first delivered message is an opening briefing with the posture, a summary
  of standing rules, and anything unresolved from the previous shift. The
  daemon gets those unresolved items by replaying the previous shift's ledger.
  Escalations never silently disappear when a shift ends.
- **Shift end is a teardown with a caller.** The sequence is: stop the sweep →
  make a time-limited request for a closing note → render the final
  `account.md` → write the closing ledger line → dispose of the desk by ending
  its session and deleting its scratch worktree. The note adds context but is
  not required; a dead supervisor cannot block closing. All durable data
  already lives outside the desk. Desks accumulated in the old system because
  nothing initiated cleanup. Here, the same operator action that ends the shift
  initiates cleanup.
- **Each shift starts fresh on purpose.** No resumed supervisor context.
  Continuity lives in artifacts: the playbook, standing rules, learnings, and
  earlier ledgers. The *system* learns; one session's context does not. If a
  supervisor dies during a shift, the daemon writes an anomaly line, creates a
  replacement in the same shift, and briefs it with the account so far.
- **Off is meaningful**: no shift exists, nothing observes the fleet, the last
  shift's residue is fully on disk. No half-on states.

### Supervisor context recycling

The supervisor runs all night and receives work orders full of playbooks and
transcripts, so its context grows fast — and a session cruising at a huge
context pays for that context on every turn. Waiting for auto-compaction is the
expensive path. Instead, the daemon recycles the desk deliberately, using the
mid-shift replacement path above. This works because of a decision already
made: the supervisor externalizes everything durable as it goes (ledger,
standing rules, learnings, account, escalations). **Its handoff document
already exists — it is the shift record.**

The sequence, all daemon-driven:

1. **Detect** — the supervisor is a session like any other, so its context
   load is already a session-state fact. Threshold: a compiled default, around
   200k tokens (§13).
2. **Hold** — the daemon stops delivering work orders to the desk. New cases
   queue; the sweep keeps running; the fleet stays watched. The recycle waits
   until the supervisor is idle with no case in flight.
3. **Flush** — a bounded request, same shape as the shift-end closing note:
   "anything in your head not yet in artifacts, write it now as notes or
   learnings." If the supervisor is wedged, the recycle proceeds without it —
   that is exactly the crash path, which was already designed to be
   survivable.
4. **Recycle** — tear down the desk session, spawn fresh into the same shift,
   and deliver the standard replacement briefing (posture, standing rules,
   account so far, open escalations) **plus the predecessor's transcript
   path**. Anything that lived only in the old context — a hunch
   mid-investigation, steering the operator typed earlier — is not lost; it is
   demoted from context to disk, and the new supervisor can search its
   predecessor's transcript on demand without paying for that history on every
   future turn. A ledger line links the old session ID to the new one.

**This runs automatically, in both modes, with no proposal.** Everything else
consequential in this design needs a gesture or a gate; this deliberately does
not. Recycling the desk touches no fleet agent and destroys no work state,
because the desk was built disposable — it is self-maintenance of the
supervision machinery, not an act on the fleet. It appears in the account
("3:12 a.m. — supervisor recycled at 214k context, 4 learnings flushed"), not
in the proposal queue. If a recycle ever loses something that mattered, that
is an artifact-externalization bug to fix — the answer is "that should have
been in the record," never "a human should have approved the recycle."

**Fleet agents are explicitly excluded from this.** Auto-compaction is fine
for them; no handoff templates, recycle flags, or compaction counters exist
for fleet sessions. The per-agent context fact is available for free (§2), and
its only fleet-facing use is informational: a wake case may mention a parked
session's context load, as input to judgment.

*Note on the brief:* the requirements brief deferred supervisor self-handoff
("assume the supervisor persists for the shift"). This section overrides that
deferral by operator decision, and the reason is worth recording: the deferral
assumed handoff was a hard open problem, and the shift-record design had
already solved it as a side effect.

## 10. Operator surfaces (intent, not screens)

Principle: **you take action where you already read the relevant information.**

- **The account panel is also the inbox.** The "needs you" section of the live
  `account.md` *is* the queue. Each proposal shows the target, exact message,
  supervisor reasoning, and age of its state. Approve and reject controls
  appear beside it. Approval also offers scope choices: this once / this shift
  / always for this repo. This is the only user interface (UI) that creates
  standing verb rules; automation membership is managed in the Fleet
  Supervision settings tab below. A rejection can include an optional one-line
  explanation,
  which reaches the supervisor in its next work order. Each escalation shows
  the exact item, exact command, recommendation, and an answer box. Every
  action is also a CLI verb (`tbd supervise queue/approve/reject/answer`).
  Nothing exists only as a button.
- **The supervisor's tab stays a plain conversation.** Typed instructions are
  conversation. It steers the session but does not set policy. The two durable
  channels for rules are
  the playbook (advisory) and standing rules (binding); the chat is neither.
  If you type something rule-shaped, the supervisor may propose making it
  standing through the normal ratification path.
- **Fleet supervision gets its own Settings tab.** It replaces the current
  Settings section and holds the automation-membership section — the
  default-in/default-out control and the per-repo in/out/follow-default list
  (§8) — alongside the standing-rules inspection surface described next. The
  tab takes the subsystem's name; "automation" survives only in the membership
  setting's own name, where it is precise (in or out of automation = may the
  daemon act here on its own). Both are views of `standing-rules.json`,
  following the house file-backed-settings pattern: tilde-abbreviated path
  shown, copy button, manual edits respected.
  Every control has a CLI twin (`tbd supervise automation ...`).
- **Standing rules get a simple inspection surface** with the rule list, scope,
  origin, and a revoke action. The origin links to the ledger for the shift
  that created the rule. The file-backed view shows the tilde path, provides a
  copy button, and respects manual edits. Its purpose is to answer "why did the
  daemon do that on its own?" at a glance.
- **Morning flow**: open TBD → open the last shift's account → answer the
  needs-you batch in minutes (P0-10). Each answer creates a decision line.
  Each "never again" is a scope choice attached to an answer the operator is
  already giving.

## 11. Capacity awareness (P1-1, decomposed)

- **P0 — never poke a rate-limited agent**: this requires no extra work because
  rate limiting is already session state.
- **P1 — fleet-wide hold**: several agents capped at once → hold interventions
  until the limit window resets. The daemon already has usage snapshots for
  each profile.
- **P2 or never — cross-account rebalancing**: not compiled, ever. It presumes
  a particular arrangement of multiple accounts and requires workflow
  judgment. If it exists, it must be a playbook instruction for a supervisor
  that already has the usage facts.

## 12. Delivery acknowledgement

The send call cannot confirm delivery. One adapter sends without an
acknowledgement, and the other can fail if a turn changes at the wrong time.
The design already has a later observation that can confirm delivery:
**the one-minute re-check also checks acknowledgement.** Every sent message
includes its ledger ID as a marker. During the re-check, the daemon reads two
machine facts: whether the session transcript contains the marker, and whether
the session state changed to `working`. It records one of three results as an
outcome line referencing the action:

- *Landed and acting* — done.
- *Landed but still blocked* — a fresh case within a minute (P1-6).
- *Not landed* — retry delivery once. If the second re-check still finds
  nothing, stop, write an anomaly line, and escalate. Two silent failures
  indicate a structural problem with the session. A third send without
  evidence would risk duplicate-message bugs.

This requires no new machinery. The timer already exists for P1-6, the
transcript path is recorded for each terminal, and the marker is the ledger ID
the daemon already writes.

### Delivery adapters: parity for the fleet, a channel for the desk

Which adapter a session can be reached by is itself a per-session fact, with
the same source-and-freshness treatment as any other fact.

**Fleet agents: `terminal.send` (paste + submit), the mechanism that exists
today.** This is the parity choice. Claude Code's research-preview Channels
interface was validated as a prototype
(`docs/research/2026-07-26-claude-code-channels/findings.md`, landed on
`main` separately): it delivers a
message without touching the composer, but it needs agent-side integration (an
MCP config and a startup flag with per-session consent), which collides with
TBD's no-agent-cooperation constraint for sessions the user owns. Fleet
delivery stays typing; overnight, composers are empty and the draft-safety gap
is theoretical.

**The desk alone: channel-first, with a verified fallback.** The desk is TBD's
own infrastructure — TBD spawns it, owns its configuration, and disposes of
it — so the no-cooperation constraint does not apply, and the desk is also the
one session where a human and the daemon share a composer, which is exactly
where draft-safe delivery pays. At desk spawn the daemon performs a
**handshake**: emit a channel ping, then read the desk transcript for the
channel envelope. Confirmed → the channel is the shift's adapter. Not
confirmed (consent declined, feature removed, registration silently failed) →
`terminal.send` for the shift, with one anomaly line noting degraded delivery.
Mid-shift, the acknowledgement path above extends naturally: a channel send
that fails acknowledgement twice is redelivered by typing and the adapter is
marked degraded. The handshake decouples correctness from the channel's
research-preview status entirely — the feature disappearing in an update
demotes delivery to typing within one re-check cycle, recorded, no human
needed.

A side benefit: channel messages arrive in a typed envelope
(`<channel source kind>`), so work orders and follow-ups are attributable and
distinguishable from operator typing in the same session.

**The consent question — options recorded for a later choice, in preference
order.** The development-channel consent prompt is interactive and
per-session; a 3 a.m. desk recycle has nobody present to answer it. The
options, none decided here:

1. **Approved plugin channel** (plain `--channels`, no dev-consent flow; TBD
   already ships a plugin into every spawn). Caveat: approval requires
   Anthropic review, which is unlikely to be granted for TBD — listed for
   completeness, not counted on.
2. **Pre-seed the consent** if it persists in any config file, following the
   `ClaudeTrustSeeder` precedent (TBD already pre-answers Claude's
   folder-trust dialog for scratch spaces). Legitimate for the desk
   specifically: the consent warns that an external process can inject turns,
   and the desk's external process is the daemon that owns it. Needs
   investigation — "per-session" in the findings suggests it may not persist.
3. **Manual consent when the shift start is attended** — the operator answers
   the prompt once when flipping the posture. Unattended recycles then run
   degraded until the next attended start.
4. **Fallback, always available: typing.** If every route fails, the desk
   runs on `terminal.send` like the fleet, and the account says so.

**Driving the consent prompt with keystrokes is refused**, whatever the
options above yield: it fails all three conditions of §2's machine-interface
test — no hook announces it, no payload carries its text, and no record shows
what was answered — so finding it requires scraping the screen or timing
keystrokes blind, and auto-typing "yes" into a consent dialog defeats the
dialog while leaving it in place as theater. Degraded delivery is the honest
failure mode.

## 13. Runaway detection (P2-4)

Compiled counters detect possible runaway behavior; the supervisor judges the
response. Each cycle collects inexpensive facts from interfaces the daemon
already reads. These facts are the number of turns in the current window,
counted from appended transcript JSONL records without parsing their content;
the rate of hook events; and whether commits or the diff stayed unchanged
across N cycles, which the git sweep already knows. Each threshold is a
compiled global default. Per-repository overrides are deliberately deferred
(§15): the old system had none, numeric tuning does not fit the standing-rules
shape (§8 deliberately has no language for parameters), and a new repo-table
column would quietly break §7's one-column property. If real shifts prove a
repo needs different numbers, a repo-table column is the house pattern for it —
added as a conscious amendment to §7, not a side effect.

Crossing a threshold does not itself cause an action. It creates a case in the
next work order, such as "agent Y: 31 turns, no commits in 90 minutes." The
supervisor reads the transcript and decides. If the agent is truly looping, it
uses `pause`. This is a consequential verb, so it becomes a proposal in
attended mode and passes through the standing-rules gate in autonomous mode.
If the agent is making legitimate progress on a hard problem, the supervisor
adds a note and leaves it alone.

**The design deliberately rejects automatic pauses at a threshold.** Counters
cannot distinguish "burning quota without progress" from "thinking hard."
Pausing a working agent by mistake would destroy trust in overnight
supervision.

### The compiled numbers

Every number this document names, collected in one place so a reader never has
to hunt for the value that governs a behavior:

| Number | Default | Where it acts |
| --- | --- | --- |
| Idle-intervention threshold | 40 min | §4 step 2 |
| Post-intervention re-check | 60 s | §4 step 8, §12 |
| Delivery retries before anomaly | 2 sends | §12 |
| Supervisor recycle threshold | ~200k tokens of context | §9 |
| Runaway: turns in window | 30 turns | §13 |
| Runaway: no-progress window | 90 min with no commits | §13 |
| Heartbeat staleness | 10 min | §14 |

**All of these are compiled constants at parity — no new config columns.** That
preserves §7's one-column property, which is a real property of the design and
not an accounting convenience: the moment numbers become columns, "where is this
system's state?" stops having a one-line answer. If real shifts prove a number
wrong, promoting that one number to a config column is a conscious amendment to
§7, argued on its own merits — the same posture taken toward per-repo threshold
overrides (§15).

## 14. Out-of-band heartbeat (P3-1)

On every sweep tick, the daemon writes a small `status.json` file in the shift
directory. It contains the posture and last-sweep timestamp. The watchdog is an
optional `launchd` job with one rule: *if a shift claims to be active and the
status file has not changed in about 10 minutes, raise a notification.* It
reads a file instead of the socket or DB, so a dead daemon cannot make the
watchdog unavailable. The watchdog never acts on the fleet. It can only alert
the operator; it cannot pretend to be the supervisor. A down daemon therefore
means silence plus an alarm. This applies the rule that uncertainty must lead
to inaction at the largest scale.

## 15. Deliberately not built

- **A verdict enum / work-arc schema** — interpretations of work differ by
  repository, team, and person. A compiled classification would recreate the
  old system's defect.
- **`supervision.json`** — melted into standing rules; repos advise, operators
  bind.
- **Per-mode playbooks** — one playbook receives the mode as context. Separate
  files would invite promises the daemon does not enforce.
- **The act-with-veto-window human-in-the-loop (HITL) variant** — a missed veto
  allows an unapproved action. Attended mode must not silently become
  autonomous mode.
- **Cross-account rebalancing** — assumes one person's account arrangement. If
  it exists at all, it is playbook prose for a supervisor that already has the
  usage facts.
- **Auto-pause on runaway counters** — see §13.
- **Prompt advancement from outside** — no mechanism selects within a rendered
  dialog, and none acts on screen-read state. The one sanctioned path is §2's
  three-condition machine-interface test: dismiss with Escape and reply as
  composer text, permitted only for a dialog whose existence, verbatim content,
  and outcome all reach the daemon through machine interfaces. Today
  `AskUserQuestion` is the only dialog that qualifies. Everything else stays as
  it was: routine permission prompts prevented at spawn (the agent's own
  permission config, delivered through the settings overlay), config-answerable
  dialogs pre-answered by seeders, and genuine questions escalated. See §2.
- **Per-repo threshold overrides** — global compiled defaults only, at parity.
  Numbers do not fit the standing-rules shape, and a repo-table column would
  break the one-column property (§7); if operation proves the need, that
  column is the house pattern for it, added as a conscious amendment. See §13.
- **A supervisor patrol loop** — the daemon drives the loop and wakes the
  judgment layer with work orders. See §16 for the cost of this choice.
- **Repo-shipped binding rules** — binding requires approval from each
  operator. If teams later require shared binding rules, the promotion flow is
  where that capability can return.
- **DB tables for the queue, decisions, or ledger** — the queue is a view
  derived from the ledger, decisions live in a file, and each shift has its own
  JSONL ledger. Supervision adds one column to the database.
- **A supervisor-authored account** — the record produces the summary. The
  supervisor can add context through attributed notes but cannot author the
  account.
- **Fleet-agent context management** — auto-compaction is fine for fleet
  sessions. No handoff templates, recycle flags, or compaction counters for
  agents; the context fact is informational only (§2, §9). Deliberate
  recycling exists solely for the supervisor's own session (§9).
- **The statusline as a data source** — its stdin JSON carries context data,
  but claiming the `statusLine` settings key would overwrite the operator's
  own statusline. The same numbers live in the transcript, which TBD already
  reads (§2).

## 16. The strongest argument against this design

**The judgment layer can only be as insightful as the triggers that wake it.**
The supervisor is strictly reactive. It reasons only about cases the sweep can
detect mechanically, such as idle agents, blocked agents, and counters that
cross thresholds. Anything the sweep cannot describe never reaches the
judgment layer. Three agents failing in the same way for the same system-wide
reason may arrive as three separate cases, or may not arrive at all. A pattern
that develops across the night has no path into a work order. A more expensive
patrolling supervisor might notice such a pattern precisely because it was
looking without being told what to find.

The design makes the system affordable (P0-6) and enforceable (P0-3) by limiting
its only reasoning component to the facts that compiled code measures. If that
limit is too restrictive, operators will ask, "Why didn't the supervisor notice
X overnight?" The place to address that problem is a periodic, low-frequency
digest work order. It would present a fleet-wide summary as a case once every N
cycles. This would restore patrol-like analysis at a limited cost without
reversing the architecture. This document deliberately does not design that
feature. It should be built only when the need is real.

Two secondary honest costs:

- **Cold start.** Conservative defaults and operator approval make the first
  few nights heavy on approvals. The system becomes more useful only as
  standing rules and learnings accumulate. An operator who does not make that
  investment will see a repetitive queue and may decide the subsystem is
  useless. The old system worked on the first night *for its one team* because
  its policy was built into the product. Supporting different teams introduces
  a training cost for each operator. The design assumes confirmation will be
  cheap enough because it appears as a scope choice on an answer the operator
  is already giving. Training should therefore happen during normal use.
- **Safe-and-useless is a quiet failure mode.** The system is designed to be
  honest about uncertainty. If the event pipeline breaks down, the night will
  contain many unknown states and the system will correctly do nothing.
  Anomaly lines call this out in the account. Even so, a broken sensor layer can
  look like an empty, calm night. Distinguishing "nothing happened" from
  "nothing was seen" requires reading the anomaly section. The account renderer
  should make nights with many unknown states visually unmistakable.
