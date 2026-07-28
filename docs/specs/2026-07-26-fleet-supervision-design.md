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
The applications appear throughout this document; this list collects them for
a quick audit:

- **State derivation** — compiled (§2). It is fact; a wrong answer poisons
  everything downstream, and it runs for the whole fleet every cycle.
- **Intervention thresholds** — compiled default numbers, global (§2, §13).
  Per-repo tuning is deliberately deferred (§15). Crossing a threshold produces
  a case; the response is judged.
- **Cooldowns and dedup** — excluded by the brief (solved elsewhere). The sliver
  in this design — "intervention already in flight" and "re-check pending"
  checks — is compiled into the sweep (§4).
- **Per-repo policy** — authored, and resolved per **supervision project** (§5,
  §8): the playbook (advisory prose) plus standing rules (binding,
  operator-ratified).
- **Mode enforcement (P0-3)** — compiled: the verb gate (§3). Capability gating,
  never prompt wording.
- **The shift/morning account** — compiled: a ledger written by the verb
  handlers; views are queries; the supervisor adds attributed notes only (§6).

**This placement means the daemon, not the supervisor, drives the loop.** A
compiled sweep follows the same pattern as the existing hibernation sweep: a
cheap polling tick and a pure decision function. It calculates state, applies
the mechanical reasons not to act, and wakes a supervisor only when it has a
work order for that supervisor's project (§5). Waking a supervisor is the result
of a check, never the way the check is performed (P0-6, P1-2). A supervisor
never polls or sweeps, and it never writes state or history directly. The
sweep itself stays single and fleet-wide however many projects exist. The
daemon never makes a judgment.
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

1. **Verify before acting, not before displaying.** Hook events are
   accurate enough for the user interface (UI). Before using a state to justify
   any gated verb, however, the daemon checks the pane's live process once.
   This requires one tmux subprocess. If the event and live process disagree,
   the result is loudly reported as `unknown`. The daemon never silently picks
   one input.
2. **Install Claude Code's `Notification` hook event** so "awaiting input"
   carries a structured reason. The event fires when a permission prompt is
   shown, and its payload carries the "needs your permission" message. It is not
   `PreToolUse`, which fires before *every* tool call and is where an
   agent-native hook can decide a permission itself — that is at-the-source
   configuration (prong 1 below), and it cannot tell anyone that a prompt is
   currently on screen. Only `Notification` can. The event has three consumers.
   It rides along in the escalation payload, so an operator carrying a stall
   sees exactly what was asked, verbatim. It makes a stalled prompt a **case**,
   on the same pipeline `AskUserQuestion` uses ("Prompt stalls (P2-3)" below).
   And the one-minute re-check (P1-6) uses it to answer, "Did the agent advance
   past the prompt?"

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
belongs on the knowing, and there it is unmoved for *compiled code*: TBD's own
logic must never reach a determination by reading rendered text, because that
breaks silently when the agent changes its copy, couples TBD to one agent
version, and sits at the wrong layer. Typing into a pane is a different thing,
and it is not exotic — it is how *everything* in this design is delivered.
`drive` types. The fleet delivery adapter types (§12). The rate-limit actuator
types. A rule that forbade keystrokes would forbid the system's only way to
reach an agent at all.

**The screen is judgment's to read, never code's to interpret.** This is the
sharper form of the no-scraping rule, and stating it here resolves what would
otherwise read as a contradiction later in this section. Rendered terminal text
is a perfectly legitimate input to *judgment*: the operator reads it with their
eyes; a desk can read it with `tbd terminal output <id>`, the raw capture that
already exists; a project's playbook may even ship an advisory script that
classifies that repo's tool prompts and hands the result to the model (§5) — TBD
neither runs nor interprets such a script, it is the desk's to invoke and the
desk's to weigh. What must never happen is TBD's *compiled logic* branching on
that text. Same surface, two consumers, opposite rules: a model may look at the
screen and decide; the daemon may not look at the screen and decide.

Everything below that says "the screen is never consulted" is speaking about the
automatic path — the things TBD does with no judgment in the loop.

So the rule is not "never advance a dialog." For anything TBD does *on its own*,
it is a three-condition test:

> **TBD's compiled machinery may advance a dialog if and only if (1) its
> existence is known from a machine interface, (2) its content is known verbatim
> from a machine interface, and (3) its outcome is verifiable from a machine
> interface. The screen is never consulted for any of the three.**

The conditions are conjunctive, and the third is not decoration: acting without
a machine-readable record of what came of it is how an automated answer becomes
unaccountable. Anything that fails any condition is never advanced automatically
— it is prevented at the source, carried to a human, or handed to judgment,
which acts under a different discipline (`drive --keys`, below). Today exactly
one dialog passes the test: Claude Code's `AskUserQuestion`.

**TBD builds no per-project prompt-approval layer.** Start from what
daemon-spawned fleet sessions actually face.
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
something to match — and building the thing that matches it is exactly what must
not happen. Nothing may stand beside a repo's permission configuration and
contradict it.

The ruling, precisely scoped: **TBD ships no prompt-approval machinery, ever.**
No matcher, no allowlist, no auto-grant, no per-project table of "prompts we say
yes to." That is what "never advanced, never auto-granted" binds — *compiled
machinery* — and no future agent version changes it. Should hooks and records
someday put permission prompts squarely inside all three conditions, TBD still
would not grow the layer, because the objection was never that the facts were
unavailable. It is that a grant list here is the tool overruling the repo's own
decision about when a human is required.

What is emphatically *not* forbidden is a human's delegate exercising judgment.
Answering a permission prompt is an **ad hoc judgment act**: the desk reads the
situation, decides, and acts through the gated `drive` verb under posture and
standing rules, guided by its playbook — whose shipped default advises escalating
when unsure, and says plainly that prompts guarding merges, credentials, or
anything irreversible deserve a human (§5). Crucially, **nothing about that act
accumulates.** There is no memory of "we approved this one before," because
there is no approval layer to remember it in. Every prompt is judged when it
appears, on its own facts, by something that can be asked why.

**Recurrence is a signal, not a workload to automate.** When the morning account
shows the same prompt driven night after night, that is not an argument for
building a rule engine — it is the repo telling you its permission config does
not match how it is actually used. The fix is a reviewed change at the source, in
that repo's settings or the operator's overlay. The tangle gets removed where it
was created, and complexity drains toward the source instead of pooling in TBD.
That is the whole reason to decline the layer: a grant list here would let the
misconfiguration live forever, quietly, in a second place that nobody reviews.

A repo that means "a literal human, never a model" writes that in its playbook;
an operator who wants it enforced binds a scoped `deny` rule on `drive` for that
repo (§8). One sentence each — neither needs machinery.

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

So the automatic path contains no per-dialog key choreography at all. Its
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

**The screen-informed variant: `drive --keys`.** Not every stalled dialog is an
`AskUserQuestion`, and the ones that are not cannot be answered with composer
text — a permission prompt wants a keypress. That path exists. It is
deliberately *not* automatic: it is a desk that has read the screen with
`tbd terminal output <id>`, chosen keys, and sent them through the same gate as
everything else. The three-condition test does not license it and does not
forbid it; the test governs what the daemon does unattended, and this is
judgment acting, which is the distinction drawn at the top of this section.

Because keys make no claims about the world, there is nothing in them to
re-verify at send time — the `--text` variant's send-time integrity check has
nothing to check. **Evidence takes its place**: the action's ledger line records
the screen capture the desk was looking at when it chose those keys (§6). If a
sequence turns out to have been wrong, the record shows exactly what was on the
screen and exactly what was sent, which is the same accountability the
three-condition test buys for the automatic path, obtained a different way.
Sends are named-key and paced, following the rate-limit actuator's precedent.
In attended mode the proposal shows the operator the keys *and* the screen they
aim at, so approving is not an act of faith.

**This needs no verb of its own — it is `drive --text` (§3).** Answering a
question is mechanically the send path this design already has: clear the way,
deliver composer text, verify it landed, write the action line, re-check. Two
things about it look like they might warrant their own verb. Neither survives
contact.

The first is **the dismissal, which is a delivery-adapter concern rather than a
supervisory act.** *Any* `drive` aimed at a session sitting on a dialog needs
that dialog gone before composer text can land — whether the case was raised by a
pending question or by an idle timer that happened to fire while a picker was up.
So the adapter does ESC-then-paste, under one strict guard: **it dismisses only
dialogs the daemon machine-knows** — a pending `AskUserQuestion` in the store,
which is to say a dialog that passed the three-condition test above. A session
sitting on a dialog TBD cannot identify is never blind-Escaped. The delivery
**refuses and writes an anomaly**, because a blind Escape into an unidentified
modal is precisely the screen-blind actuation this section has spent its length
refusing. Dismissal follows the knowledge, not the intent.

The second is **the "this is a response" quality, which the case carries and the
verb does not need to.** The action line's state snapshot *is* the pending
question (§6), so the record already says what was being answered, verbatim. The
attended-mode proposal shows the operator that same question alongside the
supervisor's proposed reply, for the same reason. Account views label these lines
as answers by reading the snapshot. A separate verb would have added a word to
the vocabulary and nothing to the record.

What the operator experiences is unchanged. In attended mode the proposal *is the
relayed question* — the agent's questions and options verbatim, plus the proposed
response and its reasoning — and the operator approves it or answers differently
themselves. The queue entry is the dialog, delivered at last to the human it was
always addressed to. In autonomous mode it executes through the standing-rules
gate and writes its action line. The response need not be an answer at all:
"these options are underspecified — work through the tradeoffs and ask me again"
is a legitimate reply, and so is a redirect. Which one a question warrants is
playbook judgment (§5); the mechanism is `drive` either way.

*What collapsing it costs* is recorded in §15 rather than hidden: a standing rule
can no longer say "may answer when asked, but may not nudge unprompted" — nor
"text yes, keys no" — because all of it is one verb. Those distinctions are
speculative until a real shift asks for one, and the amendment path is a subverb
namespace in the rule vocabulary (`drive.keys`), never condition language.

**How the question becomes a case.** The hook stays an unconditional dumb
reporter — no posture check on the agent side, ever. It reports; the daemon
owns posture and already receives every event. The fork lives in the daemon's
RPC handler: when a shift is active and the terminal's project resolves in
automation (§8), a pending question becomes a case, and the event **hastens an
immediate mini-tick for that terminal** instead of waiting for the next sweep.
Same pure decision function, triggered by an event rather than the clock, so
the daemon still drives the loop (§1). The case goes to the desk that owns the
terminal's project (§5) — the same desk that would have received it from an
ordinary tick, holding the same one playbook. **The work order carries the
question payload verbatim out of the daemon's store**, so the supervisor fetches
nothing — which dissolves the need for any new read surface. Nothing is
ledgered for the question itself; facts are not ledger lines. The question
snapshot rides in the `drive` action's line as the state that justified it,
or in the escalation line if the supervisor punts.

**Permission prompts reach a desk the same way.** The `Notification` event
(above) rides the identical pipeline: an unconditional dumb-reporter hook, the
daemon holding the fact, and — with a shift active and the terminal's project in
automation — a **case** plus an event-hastened mini-tick. One pipeline, two
sources; the only difference is what the case carries and therefore what
judgment it warrants.

Two words earn their precision here, because the rest of this document leans on
them. A **case** is daemon → desk: a fact the sweep or an event surfaced, with
no claim about what should happen. An **escalation** is desk → operator: a
judgment that a human is needed, with an exact item and a recommendation (§3).
A permission-prompt case is *not* automatically an escalation. Whether it
becomes one is exactly the judgment the desk is there to make.

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
   `drive --text` — today that is `AskUserQuestion` and nothing else. Everything
   that fails the test still becomes a case, by the `Notification` event that
   reports it: it is never *automatically* advanced, and it reaches a desk, which
   escalates it or judges it and acts with `drive --keys`. A firing `ask` rule
   lands here, and no compiled grant list ever answers it — see the
   no-approval-layer ruling above.

The story's "never past anything else" clause is then enforced *structurally*
rather than by an allowlist's precision — and the structure is the absence of an
approval layer, not the absence of an actuator. Nothing TBD compiles ever decides
that a class of prompts may be granted; there is no list to be wrong, because
there is no list. What can advance a prompt is a judgment, made once, about one
prompt, by a delegate operating under a posture gate and leaving a record. One
consequence for the rest of this document: the `approve-a-prompt` verb stays
removed from the verb set (§3, §8), and nothing here restores it under another
name. `approve-a-prompt` was a blanket, model-free auto-grant — the tool deciding
in advance that a whole class of questions needed no human. `drive` decides
nothing in advance and grants nothing at all; it delivers one act that a
judgment chose and the record can be audited against.

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
`drive` shares the typing with that machine, and nothing else. That machine was
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
- *What is consequential* is policy (per project, per verdict) — two reasonable
  projects can reasonably differ.
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

This list is the single normative inventory of the supervisor's capabilities.
Every other mention of a verb in this document defers to it.

- **`drive`** — **gated.** Act on a fleet agent's session (the send path of §4
  step 7), in one of two payload variants.
  - `--text` delivers a re-verified message — also how an agent's
    `AskUserQuestion` is answered, the adapter clearing a machine-known dialog
    first (§2).
  - `--keys` sends named keys the desk chose after reading the screen; nothing
    to re-verify, so the ledger line carries the capture it read instead (§2,
    §6).
  - *Attended:* becomes a proposal showing exactly what will happen — the
    message text, or the keys and the screen they aim at. When the target has a
    pending question, that proposal *is* the relayed question: the agent's
    questions and options verbatim, plus the supervisor's proposed response and
    reasoning, so the operator approves it or answers differently themselves. No
    separate verb marks this — the action's state snapshot is the question (§6),
    so the record and the queue can both tell an answer from an unprompted nudge
    without the vocabulary growing (§2).
  - *Autonomous:* executes; ledger line.
- **`wake`** — **gated.** Unpark and resume a parked session. *Attended:*
  becomes a proposal. *Autonomous:* executes; ledger line.
- **`pause`** — **gated.** Halt a runaway session (§13). *Attended:* becomes a
  proposal. *Autonomous:* executes; ledger line.
- **`escalate`** — ungated. Queue an exact question for the operator.
  *Attended:* ledger line; appears in the queue immediately. *Autonomous:*
  ledger line; batched for morning.
- **`note`** — ungated. Attributed prose into the account. Ledger line in both
  modes.

Every verb is both a `tbd supervise <verb>` CLI command and an RPC method, so
nothing exists only as a button (§10). `approve-a-prompt` is deliberately
absent, and nothing here restores it under another name: see §2's prompt-stalls
subsection for the difference between a blanket auto-grant and one judged reply
delivered as text.

There are **three gated verbs** — `drive`, `wake`, `pause` — and **two ungated**
ones, `escalate` and `note`.

*Lineage, recorded once so a returning reader is not confused by older drafts.*
The send verb was called `send`, then `intervene`, and is now `drive`; `answer`
was collapsed into it, and `learn` was removed outright. `answer` went because
answering *is* the send path and neither of its apparent differences needed a
verb (§2). The `intervene` → `drive` rename came with a second collapse: an
earlier plan split text-sending from key-sending into two verbs, on the theory
that a message was the lighter act. It is not — a message to an agent running
with permissions bypassed is arbitrary instruction injection (§8, reason 4), so
the split encoded a safety boundary that does not exist, and with one gate
stance covering both there was nothing left for two verbs to say. Same collapse
test as `answer`: identical gate semantics means one verb. `learn` went with the
whole machine-appended memory tier — same-shift memory is a `note`, durable
cross-shift knowledge is repo advisory content with a home and a change process
already (§8). The operator's side of the queue is a separate surface with its own
command (`resolve`, §10), not a verb the supervisor holds.

Every gated verb is additionally bound to its desk's project (§5): a verb whose
target lies outside the calling desk's project is refused before posture or
standing rules are consulted.

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
   identity, session state and its age, work facts, the project's resolved
   playbook, and the transcript path. Cases are grouped by project (§5): if one
   tick finds several cases in the same project, they travel as one work order
   and wake that project's desk once. Cases in different projects never share a
   work order.
5. **Wake.** The daemon delivers the order through the adapter for that kind of
   agent, just as it would for any other session. If the project has no desk yet
   this shift, the daemon spawns one first — desks are lazy, so a project that
   stays quiet all night is never created. Each supervisor is an ordinary,
   visible session in its own worktree (P0-4). An operator can open its tab,
   watch it think, and type into it.
6. **Judgment.** The supervisor reads the transcript and writes a specific next
   step. It never sends only "continue" (P0-7). This is the loop's only model
   reasoning.
7. **Act through the daemon, never around it.** `tbd supervise drive …`.
   The daemon performs three steps. First, for a `--text` payload it
   **re-verifies** every external claim in the message against live sources at
   send time; an old premise stops the send and returns the conflicting facts
   (P0-8). (A `--keys` payload asserts nothing, so there is nothing to
   re-verify — its integrity requirement is the screen capture recorded on the
   ledger line instead, §2.) Second, it **checks
   posture**. In attended mode, a consequential action becomes a proposal.
   The supervisor uses the same code path in either mode. Third, the daemon
   **delivers** the message through the adapter and **writes the ledger line
   itself**.
8. **Short follow-up.** The act arms a one-minute re-check (daemon timer, in
   memory). The result is recorded as an outcome line referencing the action
   (§6). A new blocked state
   becomes a new case within one minute instead of fifteen (P1-6).
9. **Everything else costs nothing.** The other agents: zero tokens, zero sends.
   The other projects: no desk spawned, nothing woken.

**What per-project desks cost (P0-6, restated honestly).** The sweep is
unchanged — one global, model-free pass over the whole fleet, whatever the
project count. A quiet project is free in the strongest sense: its desk is never
spawned, so it holds no context and burns no tokens. What the grouping gives up
is cross-project batching. A tick with cases in three projects wakes three
desks where a single fleet desk would have woken once. Each of those wakes is
smaller — one project's cases, one playbook, not the fleet's — so token cost
roughly washes; what rises is the *wake count*. That is the honest price of the
one-desk-per-policy invariant (§5), and it buys something no amount of careful
prompt wording can: a desk cannot mistake one project's policy for another's,
because it never holds another's.

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
surface. From there it is an ordinary case: judgment, then `drive` through
the same gate as every other verb. Full mechanics, including the
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
  pretends to provide the supervisor's judgment. A dark desk darkens its own
  project only: other projects' desks are separate sessions and keep working,
  and the anomaly line names which project lost its judgment layer.

## 5. Supervision projects and where policy lives

### The supervision project

**One desk per policy.** A single fleet-wide desk holds several repos' playbooks
in context at once, which means it must *remember* which policy governs the
action in front of it. An earlier draft called that mixing survivable — the
playbooks were labeled, after all. But labeling is a prompt-level defense, and
§3 already refuses to rest enforcement on prompt wording. The fix is structural
rather than advisory: never put two policies in one context.

The unit that makes that possible is the **supervision project**.

- **Every repo belongs to exactly one project.** The default is that each repo
  *is* its own project — a singleton, named by the repo, declared nowhere. A
  monorepo declares nothing. An operator who never groups anything never meets
  the concept.
- **Multi-repo projects are operator-declared**, for genuinely coupled work
  spanning repos — the case a monorepo would have solved by being one repo. A
  declared project names its member repos and designates **one policy source**:
  a named member repo's `.agents/supervision.md`, or an operator-level file.
  Related repos share one policy *by design*, so within a project there is
  nothing left to mix.
- **Policy resolves per project** — one playbook per desk.
- **One desk per project**, spawned the first time that project has a case
  in a shift and disposed at shift end (§9). A desk's work orders contain only
  its project's cases and its one playbook.

**The singleton case must collapse exactly.** With nothing declared — the state
every installation starts in — every project is one repo, policy resolution is
the per-repo three-tier lookup described below, and a repo with a case gets a
desk holding one playbook. That is precisely the
per-repo design this document carried before the grouping layer existed. The
grouping *unwraps*: it is not a mode to be in, it is a generalization whose
degenerate case is the previous design exactly. Any behavior that differs
between "no projects declared" and the pre-grouping design is a bug, not a
feature.

**The gate binds each desk to its project.** A verb arriving from a desk whose
target worktree lies outside that desk's project is refused in compiled code,
before posture or standing rules are consulted (§3, §8). This deserves stating
as a security property rather than as tidiness: the blast radius of a confused,
mis-briefed, or prompt-injected supervisor shrinks from the whole fleet to one
project. A desk that reads a hostile instruction in some agent's transcript can,
at worst, act on repos it was already supervising.

**What stays global.** The project is the unit of judgment and action. It is
deliberately not the unit of everything:

- **One posture switch**, fleet-wide. P0-2 asks for a single gesture to hand the
  fleet over; per-project switches would be N gestures and N chances to leave
  one on.
- **One shift, one `ledger.jsonl`, one `account.md`, one morning queue.**
  Escalations and proposals from every desk land in the same needs-you batch.
  The ledger envelope gains a project tag (§6), so every line says which desk
  acted and the account can *group* by project without being *split* by it.

A shift per project was considered and rejected. It would multiply every
lifecycle surface — shift IDs, directories, opening and closing lines,
heartbeats, morning views — to express something membership already expresses:
a project the operator does not want acted on is marked out of automation (§8),
which costs one mark and no new machinery. And an operator's morning does not
decompose by project; it decomposes by what needs an answer.

**Membership changes by `move`, never by add/remove.** Regrouping a repo is one
command — `tbd supervise project move <repo> --to <project|singleton>`, with
`--to singleton` restoring the default. An add/remove pair is deliberately not
offered: with "every repo belongs to exactly one project" as the invariant, a
`remove` leaves a repo belonging to nothing and an `add` can put it in a second
place, so the pair can express states the model forbids and every caller would
have to sequence them correctly. `move` cannot express them at all.

**Project mutations take effect on the next tick.** A definition edited
mid-shift is legal; it just does not retroactively change a desk that is already
running against the old shape. Any live desk whose project definition changed is
**recycled through §9's replacement path** — flush, tear down, respawn with the
new membership and the newly resolved playbook. So there is exactly one moment
of change, it is the same mechanism as a context recycle, and no desk is ever
left bound to a definition that no longer exists.

**Naming note.** TBD's schema has repos and nothing above them; supervision is
the first subsystem to need a grouping layer. The word chosen is *project*. It
is deliberately supervision configuration for now — a key in the operator's
rules file (§8), not a new TBD-wide schema entity with its own table, UI noun,
and lifecycle. If other subsystems later want the same grouping, graduating it
into the schema is a conscious step taken then and argued on its own merits.

### Where the files live

**In-repo directory: `.agents/`** — the name describes its audience, not a
specific tool. It contains local process guidance for any tool that drives
agents. TBD owns particular *filenames*, never the directory. It must accept
and never alter files it does not recognize. In the ideal state, worktree
lifecycle hooks also live there (`.agents/hooks/…`), leaving one location in
the repository. `.worktree-hooks/`, `conductor.json`, and `.dmux-hooks/` become
deprecated levels in the lookup order, using resolver machinery that already
exists.

**The playbook — `supervision.md`, prose read by the supervisor.** Resolution
runs **per project**, three levels, first match wins: the operator's
project-level copy → the project's designated repo file
(`.agents/supervision.md`) → the tool's shipped default. The system uses the
whole file and never merges levels.

For a singleton project the levels are the existing per-repo ones — the
operator's copy at `~/tbd/repos/<id>/supervision.md` (file-backed editor in the
app), then that repo's `.agents/supervision.md` — which is the collapse
property above holding at the file layer, not a special case in the code. For a
declared project, the operator's copy lives beside the project's definition
(`~/tbd/supervision/projects/<name>/supervision.md`) and the repo level is
whichever member repo the project designated.

**Every work order carries exactly one playbook**, because a desk supervises
exactly one project. There is no such thing as an order spanning two
policies — that is the invariant the project exists to create.

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
  `drive` carries a redirect exactly as readily as an answer, and the
  playbook is where the choice between them belongs. A second universal covers
  the chat channel: **when an operator answers an escalation by typing in the
  desk's tab, proceed on that guidance, and say so — "acting on this now;
  record it from the queue so it sticks."** The desk cannot resolve its own
  escalation (§10), so without that nudge the answer is real for one context and
  absent from the record. A third covers permission prompts, since answering one
  is an ad hoc judgment with no approval layer behind it (§2): **escalate when
  unsure, and treat prompts guarding merges, credentials, or anything
  irreversible as deserving a human.** The default contains no commands, bot
  names, or organization-specific content.

**A playbook may ship advisory scripts, and TBD never runs them.** A project
that wants its own tool prompts classified can put a script in its `.agents/`
directory and tell the desk, in playbook prose, to run it — typically over
`tbd terminal output <id>`, the raw capture that already exists — and weigh what
it returns. This stays on the right side of the screen rule (§2) precisely
because TBD is not in the loop: the daemon neither invokes the script nor
interprets its output, and no compiled behavior branches on it. It is one more
input to a model's judgment, in the tier that is allowed to read screens. A
script that wanted to *bind* behavior would have to become a standing rule
through the usual ratification path, where a human reads it first.

**There is no `supervision.json`.** An earlier draft included a small,
structured policy file for the daemon to enforce. It would have held overrides
for consequential verbs, never-act lists, and thresholds. That content now
lives in the standing-rules store, which the daemon needs anyway:

1. **Compiled conservative defaults** cover a brand-new repo safely.
2. **Operator actions become standing rules**: approving a proposal offers
   "and everything like this" — scoped by verb / project / repo / worktree, for
   the shift or forever. One row, one click.
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
**pin**. The sweep orders cases within each project's work order pinned-first
(the pin state worktrees already carry), then by case age, and that project's
supervisor works the list top-down. Ordering is within a work order, so it never
has to rank one project against another. Pinning is already how an operator
marks what matters, so priority
costs no new schema and no new concept. Like every fact, ordering only shapes
attention — it never changes what any verb is allowed to do.

## 6. The account (P0-9, P1-7)

**The ledger is the account; everything else is a view of it.**

- `~/tbd/shifts/<shift-id>/ledger.jsonl` — an append-only file with one
  JavaScript Object Notation (JSON) object per line, written **only by daemon
  code at the moment it acts**. It supports these line kinds:
  **action** records a drive, wake, or pause, including the payload, the state
  snapshot that justified it, and the posture. A separate
  **outcome** line references the action's ID and records what was observed.
  **lifecycle** records shift open, shift close, posture changes, and desk
  recycles (§9). **proposal** and
  **resolution** record proposed actions and their results. **escalation** and
  **resolution** record questions and their answers. **decision** records a
  standing rule created from any source. **anomaly** records an unknown state,
  an old premise found during send-time verification, a failed fetch, or a dark
  supervisor. Deliberate inaction is recorded as seriously as action. **note**
  is the one kind whose content is supervisor-authored prose — attributed prose
  added with `tbd supervise note`, written by the daemon's verb handler like
  every other line, and unable to change any other line. The supervisor may
  reference lines and contribute prose; it can never author an action, an
  outcome, or the account.
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

Every line shares one envelope —
`{ "id", "ts", "shift", "posture", "project", "kind" }` — plus a payload
determined by its kind. The envelope is what makes the views in this section
plain queries: filter by kind, window by `ts`, group by `shift` or by
`project`. The project tag is what lets one shared ledger stay honest about
which desk acted: with per-project desks (§5) the account groups by project
without being split into per-project files. Lines the daemon writes on its own
behalf rather than a desk's — shift open and close, sweep-level anomalies —
carry a null project, which is the accurate answer and not a gap.

What each kind's payload carries:

- **`action`** — the verb, the target (worktree / terminal / repo), the payload
  (message text for `drive --text`, the named keys for `drive --keys`), and the
  state snapshot — with its source and observed-at — that justified it. For
  `drive --keys`, that snapshot includes **the screen capture the desk read when
  choosing those keys**, the evidence that stands in for send-time
  re-verification (§2). When a drive answers a pending question, the snapshot
  **is** the question payload, verbatim: no separate line records the question
  (a pending question is a fact, and facts are not ledgered), and no separate
  verb marks the answer — reading the snapshot is what distinguishes a reply
  from an unprompted nudge (§2).
- **`outcome`** — a reference to the action, one of the three §12 results, and
  the observed-at of that observation.
- **`proposal`** — everything an `action` carries, plus the supervisor's
  reasoning and the age of the state it reasoned from.
- **`resolution`** — a reference to the proposal or escalation, the result
  (approved / rejected / answered / expired), the scope choice if one was made,
  and the operator's optional explanation.
- **`escalation`** — the exact item, the exact proposed command, and the
  recommendation.
- **`decision`** — the rule created, its lifetime (shift or always), and its
  origin.
- **`anomaly`** — the category and the detail.
- **`note`** — the author, the text, and optional references to other lines.
- **`lifecycle`** — opening, closing, posture change, or desk recycle; this is
  the kind behind every line §9 describes.

Two representative lines, an action and the outcome that later references it:

```json
{"id":"a3f1","ts":"2026-07-27T02:41:09Z","shift":"s-0714","posture":"autonomous","project":"acme-web","kind":"action","verb":"drive","target":{"worktree":"1B7E2C90","terminal":"6D40F3A1"},"message":"The rebase conflict is in Package.resolved …","state":{"session":"idle","source":"hook+pane-verify","observedAt":"2026-07-27T02:40:58Z"}}
{"id":"a3f2","ts":"2026-07-27T02:42:11Z","shift":"s-0714","posture":"autonomous","project":"acme-web","kind":"outcome","action":"a3f1","result":"landed-and-acting","observedAt":"2026-07-27T02:42:09Z"}
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
  enforced at the command gate, plus the project definitions (§5) and the
  automation membership and default stance that ride on them (§8). The operator
  owns the file. It is atomically
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

## 8. Remembered things: two kinds, two homes

There are exactly two places durable knowledge lives, and they need precise
names because they are easy to confuse:

1. **Binding rules** — enforced by the daemon at the verb gate, no model in the
   loop: `~/tbd/supervision/standing-rules.json`. The format is structured
   because prose cannot be enforced without interpretation. It is local to the
   operator because the operator must approve any rule that binds their daemon
   ("repos advise; operators bind"). Rules are created only by operator actions:
   approval generalization, prose promotion, or CLI. A small settings surface
   makes them inspectable. That surface is a view of the file with a list,
   links to origins, and a revoke action. The file remains the source of truth.
2. **The playbook** — advisory prose, human-curated, travels with the repo
   (`.agents/supervision.md`, three-tier, resolved per project §5). The tool
   never writes it after seeding.

### How a shift's experience reaches the playbook (P2-1)

An earlier draft had a third kind: raw prose the machine appended to a
per-project `learnings.md` via a `learn` verb, included in every future work
order, taking effect immediately. It is **removed**, because it was bridging two
different needs and existing machinery serves each of them better.

**Within a shift, a learning is a `note`.** Notes are in the shift record, and
the shift record is what every replacement desk is briefed from (§9) and what
the account renders. A desk that discovers at 1 a.m. that a repo's test suite
needs a warm cache does not need a new file to tell its 4 a.m. successor —
that was never the hard part.

**Across shifts, a learning is repo advisory content, and that has a home and a
change process already: the playbook, changed by a reviewed commit.** So at
shift end, if learning-shaped notes exist, the desk's flush step (§9) **proposes
spawning a capture worker** — an ordinary worker worktree, briefed to fold the
shift's learnings into that project's `.agents/supervision.md` and open a PR.
Spawning a worker is consequential, and it is deliberately *not* a verb: it
arrives as a **proposal** in the same queue as everything else, survives shift
end like every other unresolved item (§9), and is approved in the morning batch
alongside the rest. Supervision uses the machinery it supervises — a worktree, an
agent, a PR, a review — rather than inventing a private channel for its own
memory.

This also collapses a promise the removed tier only gestured at. That draft
already said a learning worth keeping was promoted into the playbook by "a human
commit" — but named no mechanism, so it was a follow-up someone had to remember.
Now the commit *is* the mechanism, and the curation step is ordinary PR review.

**The trade-off, stated plainly.** Cross-shift learning now costs PR latency,
and it cannot take effect silently. Both are the point. Nothing becomes standing
advice for a repo without a human reading the diff — which is the same authority
principle as "repos advise; operators bind," applied to the tool's own output.
The gap this leaves — a lesson learned tonight does not steer tonight's other
desks — is covered by notes within a shift and is not worth a file that every
future work order must carry and no one ever reviews.

The two remaining kinds connect in one controlled way. The supervisor
encounters something in the shift record that keeps mattering and looks like a
hard rule; it proposes making it binding; one approval turns it into a standing
rule. A single confirmation connects prose to enforcement.

### Why the binding tier is structured at all (post-#509 accounting)

GitHub now has merge authority, so few verbs remain behind the gate:
`drive`, `wake`, and `pause` (§3). A fourth, `approve-a-prompt`, was removed
along with the P2-3 resolution (§2) and stays removed: it was a blanket,
model-free auto-grant of permission prompts, and nothing in this design grants a
permission on an agent's behalf. Answering an agent's question does not restore
it and did not earn a verb of its own — it advances exactly one dialog, the one
whose existence, verbatim content, and outcome all reach the daemon through
machine interfaces, by dismissing it and replying as text through `drive`.
That is judgment delivered on the ordinary send path, never an auto-grant, which
is why it sits behind this same gate rather than beside it. It is reasonable to
ask whether prose could replace the binding tier. It cannot, for exactly four
reasons. The design must not grow beyond what these reasons require:

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
4. **`drive` injects instructions — in either variant.** Fleet agents run with
   permission checks skipped, so a supervisor message can carry any instruction
   at all to an agent with full tool access. A reply to a question is the same
   text through the same composer; and keys are, if anything, *less* constrained
   — a keypress can accept a permission prompt the repo raised precisely to stop
   an agent. This is the argument that collapsed the two into one verb (§3), and
   it cuts the same way here: both need the gate, neither is the lighter act.
   Merge authority could move to the code-hosting service, but only TBD controls
   this action. No other system can enforce the gate in front of it.

Because the scope is small, the rule store remains a flat list with scope,
verb, stance, and lifetime. It has no language for conditions, no rule
interactions, and no Secure Hash Algorithm (SHA) pinning. The remaining risks
do not justify anything more complex.

### What the gate is and is not protecting against

This must be said plainly, because a gate invites the reader to assume more than
it delivers. **Every process here runs as one user.** The daemon, the app, the
fleet agents, and the desks share a uid, and desks have shells. Nothing at the
operating-system level stops a desk from invoking an operator-only CLI command,
calling any RPC method directly over the socket, or editing
`standing-rules.json` on disk. A desk that decided to do those things could.

So the gate, the daemon-only ledger write path, and the desk→project binding
(§5) are protection against **confusion, drift, and prompt injection travelling
the paved road** — the harness offers a desk verbs and nothing else, so the
overwhelmingly likely failure (a model doing the wrong available thing, or a
model talked into it by text it read in a transcript) has no path to the wrong
outcome. They are emphatically *not* protection against an adversarial process
running as the same user and deliberately going around them. That boundary would
require OS-level sandboxing — separate uids, a restricted socket, or a broker
process — which this design deliberately does not build and should not pretend
to. Naming the limit is the point: the value of the four reasons above is
undiminished by it, because every one of them is about what a *cooperating but
fallible* supervisor can be relied upon to do.

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
  "projects": {
    "acme-checkout": {
      "repos": ["<repo-id>", "<repo-id>"],
      "policy": { "repo": "<repo-id>" }
    }
  },
  "automation": { "default": "in", "projects": { "acme-checkout": "out" } },
  "rules": [
    {
      "id": "<uuid>",
      "verb": "drive",
      "scope": { "project": "acme-checkout" },
      "stance": "allow",
      "origin": { "shift": "<shift-id>", "ledger": "<line-id>" },
      "createdAt": "2026-07-27T03:12:00Z"
    }
  ]
}
```

`projects` holds **only declared multi-repo projects.** A repo named in no
project is its own singleton, implicitly named by the repo — so an installation
that groups nothing has an empty (or absent) `projects` object, and the file
looks exactly as it did before the grouping layer. Each declared project lists
its member `repos` and designates one `policy` source: `{ "repo": … }` for a
member repo's `.agents/supervision.md`, or `{ "operator": true }` for the
operator-level file (§5). A repo may appear in at most one project; the loader
rejects the file if one appears twice, because "exactly one" is the property the
whole grouping rests on.

`scope` has exactly four shapes — `{}` (fleet-wide), `{ "project": … }`,
`{ "repo": … }`, and `{ "worktree": … }` — and nothing richer; there is still no
language for conditions, by the argument above. The project shape is a scope,
not a condition: it names a set the operator already declared, and the gate
resolves it by lookup rather than by evaluating anything. `stance` is `allow` or
`deny`. `origin` links every rule to the ledger line that created it, which is
what the inspection surface's "why" link resolves (§10): no rule exists without
a recorded reason for existing.

The file carries **only lifetime-always rules.** A shift-scoped rule is a
decision line in that shift's ledger, projected into the same in-memory rule set
the gate consults (§7), and gone when the shift ends. So the logical rule shape —
scope, verb, stance, lifetime — is realized across two stores, split on the
lifetime field, which is exactly why the file itself needs no lifetime field.

Automation membership is the dedicated `automation` object rather than a rule
with a special verb: same file, same loader, same gate, but a distinct question
("may the daemon act in this project at all?") that is asked before any verb is
considered.

### Project automation membership (operator-configurable)

Which projects the supervisor may act on is an operator setting, not a design
constant. **Membership sits at the project level because the project is the
acting unit** — a desk acts for a project, so "may the daemon act here" is a
question about a project, and marking half of a declared project out of
automation would mean a desk supervising repos it may not act on. It has two
pieces:

- **A default stance**, chosen by the operator: default-in (every project is
  automatable unless marked out) or default-out (no project is automatable until
  marked in). The system ships with default-in, because the autonomous posture
  is already an explicit operator choice and this matches the old system's
  watch-everything behavior; an operator who wants deliberate onboarding flips
  one control.
- **A per-project mark**: in, out, or follow-the-default. Only explicit marks
  are stored; a project with no mark follows the default, so flipping the
  default never requires touching individual entries. Singletons are marked by
  their repo's implicit project name, so per-repo membership is still exactly
  one mark per repo when nothing is declared.

Both live in `standing-rules.json` in the same file as the verb rules and the
project definitions — same loader, same gate, one source of truth for "may the
daemon act here, and as whom." Membership is checked before any verb executes
**and before proposals are created**: a project that resolves to *out* generates
no proposals in attended mode and no actions in autonomous mode, and its desk is
never spawned. It still appears in the fact sweep and the account —
observability is never gated, and "project X needed attention but is out of
automation" is the honest report. Because membership is enforced at the same
model-free gate as the never-lists, it holds when nobody is watching (reason 3
above).

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
  attended/autonomous creates a shift ID, creates `~/tbd/shifts/<id>/`, and
  writes the opening ledger line. It starts **no desks**: at shift open there is
  nothing yet to supervise, and a desk exists to hold one project's cases. A
  switch between attended ↔ autonomous during a shift keeps the *same* shift and
  adds a posture-change ledger line. Every action line already records its
  posture. Only switching to off ends a shift.
- **Desks are born lazily, one per project, on that project's first case.**
  A project with a quiet night never gets a desk at all (§4). Each desk is a
  scratch space tracked by ID rather than by its display string, receives the
  supervision skill through the plugin mechanism, and is bound to its project at
  the gate for its whole life (§5). Its first delivered message is an opening
  briefing: the posture, the standing rules that apply to its project, its one
  resolved playbook, and anything unresolved from the previous shift **for that
  project**. The daemon gets those unresolved items by replaying the previous
  shift's ledger and filtering on the project tag (§6). Escalations never
  silently disappear when a shift ends — but an escalation whose project gets no
  case the next night waits in the morning queue rather than being briefed into
  a desk that was never created, which is why the queue and not the desk is the
  durable home for anything needing a human.
- **Shift end is a teardown with a caller, and it disposes every desk.** The
  sequence is: stop the sweep → make a time-limited request to each live desk
  for a closing note **and, where the shift produced learning-shaped notes, a
  capture proposal** (spawn a worker to fold them into that project's
  `.agents/supervision.md` as a PR — §8) → render the final `account.md` →
  write the closing ledger line → dispose of each desk by ending its session and
  deleting its scratch worktree. The capture proposal outlives the desk that
  raised it: it is an ordinary unresolved queue item, and unresolved items
  already survive shift end, so the operator approves or drops it in the morning
  batch like everything else. Notes add context but are not required; a dead supervisor cannot
  block closing, and neither can three of them. All durable data already lives
  outside the desks. Desks accumulated in the old system because nothing
  initiated cleanup. Here, the same operator action that ends the shift disposes
  of every desk the night created — a count the ledger knows, so none can be
  missed.
- **Each shift starts fresh on purpose.** No resumed supervisor context.
  Continuity lives in artifacts: the playbook, standing rules, and earlier
  ledgers. The *system* learns; one session's context does not. If a
  supervisor dies during a shift, the daemon writes an anomaly line, creates a
  replacement for that project in the same shift, and briefs it with its
  project's account so far.
- **Off is meaningful**: no shift exists, nothing observes the fleet, the last
  shift's residue is fully on disk. No half-on states.

### Supervisor context recycling

A desk runs all night and receives work orders full of playbooks and
transcripts, so its context grows fast — and a session cruising at a huge
context pays for that context on every turn. Waiting for auto-compaction is the
expensive path. Instead, the daemon recycles a desk deliberately, using the
mid-shift replacement path above. This works because of a decision already
made: a supervisor externalizes everything durable as it goes (ledger,
standing rules, notes, account, escalations). **Its handoff document
already exists — it is the shift record.**

Recycling is **per desk**, evaluated independently for each: a busy project's
desk may recycle twice in a night while three quiet projects' desks never do.
The sequence, all daemon-driven:

1. **Detect** — a supervisor is a session like any other, so its context
   load is already a session-state fact. Threshold: a compiled default, around
   250k tokens (§13).
2. **Hold** — the daemon stops delivering work orders to *that* desk. Its new
   cases queue; the sweep keeps running; other projects' desks are unaffected;
   the fleet stays watched. The recycle waits until that supervisor is idle with
   no case in flight.
3. **Flush** — a bounded request, same shape as the shift-end closing note:
   "anything in your head not yet in artifacts, write it now as notes." If the
   supervisor is wedged, the recycle proceeds without it — that is exactly the
   crash path, which was already designed to be survivable.
4. **Recycle** — tear down that desk's session, spawn fresh into the same shift
   and the same project, and deliver the standard replacement briefing (posture,
   standing rules, that project's account so far, its open escalations, its one
   playbook) **plus the predecessor's transcript path**. Anything that lived only in the old context — a hunch
   mid-investigation, steering the operator typed earlier — is not lost; it is
   demoted from context to disk, and the new supervisor can search its
   predecessor's transcript on demand without paying for that history on every
   future turn. A ledger line links the old session ID to the new one.

**This runs automatically, in both modes, with no proposal.** Everything else
consequential in this design needs a gesture or a gate; this deliberately does
not. Recycling a desk touches no fleet agent and destroys no work state,
because desks were built disposable — it is self-maintenance of the
supervision machinery, not an act on the fleet. It appears in the account
("3:12 a.m. — acme-web desk recycled at 261k context, 4 notes flushed"), not
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

- **The account panel is also the inbox — one inbox, all projects.** The "needs
  you" section of the live `account.md` *is* the queue, and proposals and
  escalations from every desk land in it together, each labeled with its project
  (§6). Each proposal shows the target, exact message, supervisor reasoning, and
  age of its state. Approve and reject controls appear beside it. Approval also
  offers scope choices: this once / this shift / always for this project /
  always for this repo. This is the only user interface (UI) that creates
  standing verb rules; project definitions and automation membership are managed
  in the Fleet Supervision settings tab below. A rejection can include an
  optional one-line explanation, which reaches that project's supervisor in its
  next work order. Each escalation shows the exact item, exact command,
  recommendation, and an answer box. Every one of these is also a CLI command —
  `tbd supervise queue` to read it, `tbd supervise resolve` to act on it (below).
  Nothing exists only as a button.

  **One command resolves the queue: `resolve`.** Approving, rejecting, and
  answering are not three commands, because they are not three acts on the
  record — all three construct the same ledger kind, a `resolution` line that
  differs only in its `result` field (§6). So the command names the category and
  the argument names the act, the shape `gh pr review --approve/--request-changes`
  already made familiar:

  ```
  tbd supervise resolve <id> --approve [--scope this-once|this-shift|always]
  tbd supervise resolve <id> --reject  [--reason "…"]
  tbd supervise resolve <id> --answer  "text" [--scope …]
  ```

  Its counterpart `queue` stays a plain noun and takes filters rather than
  sprouting sibling commands: `--type proposal|escalation`, `--project <name>`,
  and `--resolved` / `--all`. The default is unresolved items — the queue
  *proper*, since the projection is created-minus-resolved (§7). `--resolved` is
  therefore sugar over the ledger's resolution history rather than a second
  view of the queue: a resolved item has *left* the queue, and what comes back
  is the same data the account's done view renders.

  Three things this buys. The **scope choice attaches once**, to the command that
  creates every resolution, instead of being bolted onto two of three sibling
  commands and forgotten on the third. **Future outcomes are arguments, not new
  commands** — a `--dismiss-unanswered` for escalations the operator declines to
  answer costs a flag, not a surface. And **per-type validity becomes flag
  validation**, which can teach: aiming `--answer` at a proposal fails with
  "that's a proposal — `--approve` or `--reject` it," rather than the operator
  discovering an entire command does not apply to the item in front of them. The
  panel keeps its labeled **Approve**, **Reject**, and **Answer** buttons — the
  operator should never have to think in flags — and all three invoke this one
  RPC.
- **A supervisor's tab stays a plain conversation.** Typed instructions are
  conversation. They steer the session but do not set policy. The two durable
  channels for rules are
  the playbook (advisory) and standing rules (binding); the chat is neither.
  If you type something rule-shaped, the supervisor may propose making it
  standing through the normal ratification path.
- **Chat steers; the act resolves.** These are not two routes to the same
  place, and the difference is worth being exact about. Answering an escalation
  *from the queue* — the panel's Answer button, or `tbd supervise resolve <id>
  --answer "…"` — is a gesture that reaches the daemon, and the daemon then:
  appends the `resolution` ledger line; drops the item from the queue
  projection; turns any scope choice into a `decision` and, if it is
  lifetime-always, a standing rule the gate will consult; carries the answer to
  the owning desk in its next work order; and stops the next shift's briefing
  from raising it again. Typing the same words into a desk's tab does none of
  those five things. Three reasons this is a real distinction and not
  bookkeeping: desk context is disposable *by design* (it recycles mid-shift and
  starts fresh every shift, §9), so a chat-only answer evaporates on a schedule
  the operator cannot see; the desk may not exist when the answer is given at
  all, since the morning queue is usually read after the shift closed and every
  desk was disposed; and the record must never contain consent nobody gave —
  which is why **`resolve` is an operator command and appears nowhere in the
  supervisor's verb set (§3).** Give a desk any form of it and resolutions become
  self-report, the exact defect P1-7 names. Resolutions exist only as operator
  gestures reaching the daemon, and that authorship *is* the evidence. The shipped playbook closes the loop
  from the other side (§5): a desk told something in chat acts on it and says
  "record it from the queue so it sticks."
- **Fleet supervision gets its own Settings tab.** It replaces the current
  Settings section and holds three sections, all views of the one
  `standing-rules.json`: **projects**, **automation membership**, and the
  standing-rules inspection surface described next.
  - The **projects** section declares multi-repo projects: name it, pick its
    member repos, designate its policy source (a member repo's
    `.agents/supervision.md`, or the operator-level file). Repos in no project
    are listed as the singletons they implicitly are, so the section always
    shows the whole fleet's grouping rather than only the declared part — a
    reader must be able to answer "which desk would act on this repo?" without
    inferring anything.
  - **Automation membership** is the default-in/default-out control plus the
    per-project in/out/follow-default list (§8).
  The tab takes the subsystem's name; "automation" survives only in the
  membership setting's own name, where it is precise (in or out of automation =
  may the daemon act here on its own). All three follow the house
  file-backed-settings pattern: tilde-abbreviated path shown, copy button,
  manual edits respected. Every control has a CLI twin
  (`tbd supervise project ...`, `tbd supervise automation ...`).
- **Standing rules get a simple inspection surface** with the rule list, scope,
  origin, and a revoke action. The origin links to the ledger for the shift
  that created the rule. The file-backed view shows the tilde path, provides a
  copy button, and respects manual edits. Its purpose is to answer "why did the
  daemon do that on its own?" at a glance.
- **Morning flow**: open TBD → open the last shift's account → answer the
  needs-you batch in minutes (P0-10). Each answer creates a decision line.
  Each "never again" is a scope choice attached to an answer the operator is
  already giving.

### The CLI surface (normative)

This is the complete `tbd supervise` surface. It is **normative for names
and shapes**: exact flag spellings may grow, command and subcommand names may
not drift. Everything the app can do appears here, because nothing exists only
as a button.

**Desk verbs — gated** (attended → proposal; autonomous → execute, ledger line,
60-second re-check). All three are additionally bound to the calling desk's
project (§5).

```
tbd supervise drive --terminal <id> --text "…"
tbd supervise drive --terminal <id> --keys "…"
tbd supervise wake  --worktree <id>
tbd supervise pause --terminal <id> [--reason "…"]
```

`drive --text` delivers a re-verified message; when the target sits on a dialog
the adapter clears it first, but **only a dialog the daemon machine-knows** — an
unidentified one makes the delivery refuse and write an anomaly (§2).
`drive --keys` sends named keys the desk chose after reading the screen: nothing
to re-verify, so the ledger line records the capture it read instead, and sends
are paced (§2, §6). `wake` unparks a session with outstanding work. `pause`
halts a runaway (§13). Exactly one payload flag per call.

**Desk verbs — ungated** (ledger line only).

```
tbd supervise escalate --item "…" --command "…" --recommendation "…"
tbd supervise note     --text "…" [--ref <line-id>]
```

**Operator — the queue.**

```
tbd supervise queue   [--resolved|--all] [--type proposal|escalation] [--project <name>]
tbd supervise resolve <id> --approve [--scope this-once|this-shift|always]
tbd supervise resolve <id> --reject  [--reason "…"]
tbd supervise resolve <id> --answer  "…" [--scope …]
```

**Operator — posture.** `off → attended|autonomous` opens a shift;
`attended|autonomous → off` closes it (§9).

```
tbd supervise posture
tbd supervise posture off|attended|autonomous
```

**Operator — projects** (§5).

```
tbd supervise project list
tbd supervise project create <name> --repos <id,…> --policy repo:<id>|operator
tbd supervise project delete <name>
tbd supervise project move   <repo> --to <project|singleton>
```

**Operator — automation membership and standing rules** (§8).

```
tbd supervise automation default in|out
tbd supervise automation set <project> in|out|follow-default
tbd supervise automation list
tbd supervise rules list
tbd supervise rules revoke <rule-id>
```

**Deliberately absent**, each with its argument elsewhere in this document:

- **`learn`** — no machine-appended memory tier; same-shift memory is a `note`,
  cross-shift memory is a reviewed playbook PR (§8).
- **`intervene`, `send`, `answer --terminal`** — all three are earlier names or
  splittings of what is now `drive`. The lineage, once, so an older draft does
  not confuse anyone: `send` → `intervene` → `drive`, with `answer` collapsed in
  (answering is the send path, §2) and the text/keys split collapsed in as well
  (a message is not the lighter act, §3). The operator's `resolve --answer` is
  unrelated — different surface, different actor (§10).
- **`approve-a-prompt`** — no blanket auto-grant of permission prompts exists,
  and nothing restores one under another name (§2).
- **Per-desk lifecycle commands** (spawn, recycle, dispose) — desks are daemon
  self-maintenance, born on their project's first case and disposed at shift
  close; there is nothing for an operator to drive (§9).
- **Per-project posture** — one switch, fleet-wide; "not this project" is an
  automation mark, not a posture (§5, §8).

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

### Delivery adapters: parity for the fleet, a channel for the desks

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

**Desks alone: channel-first, with a verified fallback.** A desk is TBD's
own infrastructure — TBD spawns it, owns its configuration, and disposes of
it — so the no-cooperation constraint does not apply, and desks are also the
only sessions where a human and the daemon share a composer, which is exactly
where draft-safe delivery pays. **At every desk spawn** the daemon performs a
**handshake**: emit a channel ping, then read that desk's transcript for the
channel envelope. Confirmed → the channel is that desk's adapter. Not
confirmed (consent declined, feature removed, registration silently failed) →
`terminal.send` for that desk's lifetime, with one anomaly line noting degraded
delivery. The handshake is per desk rather than per shift because desks are now
born and recycled independently (§9): the adapter is a property of a session,
so each new session earns it, and one degraded desk says nothing about the
others.
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
   folder-trust dialog for scratch spaces). Legitimate for desks
   specifically: the consent warns that an external process can inject turns,
   and a desk's external process is the daemon that owns it. Needs
   investigation — "per-session" in the findings suggests it may not persist.
3. **Manual consent when a desk is born attended** — the operator answers the
   prompt when a desk spawns while they are present. Unattended spawns and
   recycles then run degraded until the next attended one.
4. **Fallback, always available: typing.** If every route fails, that desk
   runs on `terminal.send` like the fleet, and the account says so.

**TBD never drives this consent prompt automatically**, whatever the options
above yield. It fails all three conditions of §2's machine-interface test — no
hook announces it, no payload carries its text, no record shows what was
answered — so an automatic attempt would mean scraping the screen or timing
keystrokes blind. And the deeper objection is not mechanical: auto-typing "yes"
into a consent dialog *about the daemon's own right to inject turns* defeats the
dialog while leaving it in place as theater. TBD does not consent to itself.
Degraded delivery is the honest failure mode.

The scope of that refusal is the automatic path, which is the only path that
matters here: this prompt appears at desk spawn, before any desk exists to
exercise judgment about it. §2's `drive --keys` is not a loophole back in — a
desk cannot answer the consent that would have to be answered to create it, and
no desk may drive another desk's spawn.

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
| Supervisor recycle threshold | ~250k tokens of context, per desk | §9 |
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
- **A machine-appended learnings file** (and the `learn` verb and `learning`
  ledger kind that fed it) — a per-project `learnings.md` the desk could append
  to, carried in every future work order, taking effect with no review. Removed
  because it bridged two needs that existing machinery serves better:
  within a shift a learning is a `note` in the record every replacement desk is
  briefed from, and across shifts it is repo advisory content, which already has
  a home (the playbook) and a change process (a reviewed commit). Shift end
  proposes a capture worker that opens that PR instead. The cost — PR latency,
  and no silent adoption — is the feature. See §8.
- **Separate verbs for answering, messaging, and key-sending** — all three are
  one gated `drive` with payload variants. Replying to a question is the send
  path (the dismissal is delivery-adapter behavior, the "this is a response"
  quality rides in the action's state snapshot); and text is not a lighter act
  than keys, since a message to a permissions-bypassed agent is arbitrary
  instruction injection (§8, reason 4). Identical gate semantics, one verb. The
  cost is real and accepted: a standing rule cannot distinguish "may answer when
  asked" from "may nudge unprompted," nor "text yes, keys no." Those are
  speculative until a shift asks for one, and the amendment path is a subverb
  namespace in the rule vocabulary (`drive.keys`) — never condition language,
  which §8 refuses on its own grounds. See §2, §3.
- **A per-project prompt-approval layer** — no matcher, no allowlist, no
  auto-grant, no table of prompts TBD says yes to. Answering a permission prompt
  is an ad hoc judgment act through `drive`, and nothing about it accumulates.
  Recurrence is a signal to fix the repo's own permission config, not a workload
  to automate. See §2.
- **Separate `approve` / `reject` / `answer` queue commands** — all three write
  one `resolution` kind differing only in `result`, so one `resolve` command
  names the category and a flag names the act. Scope attaches once; new outcomes
  are flags. The panel keeps three labeled buttons over the one RPC. See §10.
- **Per-project shifts, postures, or ledgers** — the project is the unit of
  judgment and action, not of lifecycle. One posture switch keeps P0-2's
  one-gesture handover; one shift, ledger, account, and morning queue keep every
  lifecycle surface single. "Not this project tonight" is already expressible as
  an automation mark (§8). See §5.
- **A grouping layer in TBD's schema** — *project* is supervision
  configuration: a key in the operator's rules file, not a table, a UI noun, or
  a lifecycle other subsystems must respect. Graduating it is a conscious later
  step if another subsystem ever needs it. See §5.
- **OS-level isolation of desks from the daemon** — everything runs as one
  user, so the gate protects against confusion and injection through the paved
  road, not against an adversarial same-uid process. Real isolation would need
  separate uids or a broker; deliberately out of scope, and named rather than
  implied. See §8.
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

**The judgment layer can only be as insightful as the triggers that wake it —
and no judgment layer sees the whole fleet at all.** Supervisors are strictly
reactive. They reason only about cases the sweep can detect mechanically, such
as idle agents, blocked agents, and counters that cross thresholds. Anything the
sweep cannot describe never reaches a judgment layer. Three agents failing in
the same way for the same system-wide reason may arrive as three separate cases,
or may not arrive at all. A pattern that develops across the night has no path
into a work order. A more expensive patrolling supervisor might notice such a
pattern precisely because it was looking without being told what to find.

Per-project desks (§5) sharpen this criticism rather than softening it, and the
trade should be stated in both directions. What the grouping *solved* was
policy mixing: a desk can no longer apply one project's playbook to another
project's agent, because it never holds another's — a defect an earlier draft
had to call survivable and defend with careful labeling. What the grouping
*cost* is the last vantage point that spanned everything. Three agents failing
identically in three different projects are now three cases in three desks, none
of which can see the other two, and no amount of reasoning inside any one of
them can recover the pattern. Only two things still span projects: the compiled
sweep, which measures but does not interpret, and the operator reading one
account in the morning. The design has traded a cross-project view that was
never reliable for an isolation guarantee that is.

The design makes the system affordable (P0-6) and enforceable (P0-3) by limiting
its only reasoning components to the facts that compiled code measures. If that
limit is too restrictive, operators will ask, "Why didn't anyone notice X
overnight?" The place to address that problem is the same deferred escape valve
as before: a periodic, low-frequency digest work order presenting a fleet-wide
summary as a case once every N cycles. Under the grouping it wants one
adjustment — it should be a **short-lived fleet-level judgment context** that
reads the account, says what it sees, and exits, rather than a resident desk
with fleet-wide standing. A transient reader breaks no invariant: it holds no
project's policy because it is not deciding any project's action, and it gets
no verbs. That keeps "one desk per policy" intact while restoring the view.
This document deliberately does not design that feature. It should be built
only when the need is real.

Two secondary honest costs:

- **Cold start.** Conservative defaults and operator approval make the first
  few nights heavy on approvals. The system becomes more useful only as
  standing rules and playbook refinements accumulate. An operator who does not make that
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
