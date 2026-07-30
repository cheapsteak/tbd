# Fleet supervision — design (living draft)

Status: **complete draft, pending operator review.** Captures the decisions
settled in the design conversation of 2026-07-26, after a plain-language
editing pass. Amended 2026-07-29 after PR #522's field review: the compiled
wake gate for parked sessions is removed in favor of a project-authored wake
program, specified in the sub-document
[`2026-07-26-fleet-supervision-wake-program.md`](2026-07-26-fleet-supervision-wake-program.md);
a same-day follow-up removed the compiled actuation rails the first amendment
had kept — TBD's obligation to external programs is sufficient public
surfaces, never guardrails — and the requirements doc carries the matching
dated amendments plus the **Built/Enabled** classification and outside-first
migration rule that follow-up introduced. Amended again 2026-07-30, twice: §12
pins dispatch-versus-delivery semantics, and the compiled send-time verifier for
desk messages is removed — freshness is authored discipline in both halves, and
the daemon never inspects message content (§15, and the P0-8 amendment in the
requirements doc). Companion to
[`2026-07-26-fleet-supervision-requirements.md`](2026-07-26-fleet-supervision-requirements.md),
which carries the stories (P0-1 … P3-1) this doc cites. This is the ideal-state
design; migration from the current implementation is deliberately out of scope
and will be planned separately.

## 1. The placement test

"Compiled vs. prompt" is the wrong distinction. Behavior can live in three
places. Each place has its own test:

- **Compiled (daemon)** — facts and safeguards that must hold no matter what a
  model says. These include deriving state, gathering facts, enforcing the
  which mode is active, keeping the ledger, and scheduling. Ask two questions:
  *If this were wrong, would the rest of the system be built on a lie?* And:
  *Must it run for forty agents every cycle without calling a model?*
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
  §8): the playbook (advisory prose, including mode definitions) plus the
  operator's selections in `supervision.json`.
- **Mode enforcement (P0-3)** — **descoped** (§3). There is no enforcement: a
  mode is authored conduct, and what the daemon supplies is the record and the
  operator's selection of which mode is active.
- **The shift/morning account** — compiled: a ledger written by the verb
  handlers; views are queries; the supervisor adds attributed notes only (§6).
- **The wake decision for parked sessions** — authored, since the 2026-07-29
  amendment: a project-owned wake program outside the daemon (the
  [wake-program sub-document](2026-07-26-fleet-supervision-wake-program.md)).
  Compiled TBD keeps nothing of it — a same-day follow-up removed even the
  actuation rails the first draft kept: TBD's obligation is sufficient public
  surfaces (the requirements doc's Built/Enabled classification), never
  guardrails on a program it does not run. The sweep supervises live agents
  only.

**This placement means the daemon, not the supervisor, drives the loop.** A
compiled sweep follows the same pattern as the existing hibernation sweep: a
cheap polling tick and a pure decision function. It calculates state, applies
the mechanical reasons not to act, and wakes a supervisor only when it has a
work order for that supervisor's project (§5). Waking a supervisor is the result
of a check, never the way the check is performed (P0-6). A supervisor
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
   any verb, however, the daemon checks the pane's live process once.
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
that already classifies rate limits). Claude Code's own docs now mark the
transcript format as internal and version-unstable; the design accepts that as
a known-fragile dependency, named here rather than hidden, because no better
machine source for the numerator exists today.

The denominator — the window size — is a different kind of fact than it first
appears, and an earlier draft got it wrong by compiling a model → window-size
table. **The effective window is a session fact, not a model fact.** Claude
Code resolves it per session from the model id, a `[1m]` suffix, a
long-context beta header, environment overrides, and a remote feature flag —
the same model id can be a 200k session or a 1M session. Any out-of-band
source (a compiled table, a public capability dataset, the catalog embedded in
the Claude Code binary) reports *capability*, not the resolved value, and
capability errs in the dangerous direction: a table saying 1M for a session
running at 200k reads one-fifth full at the boundary. The only party that
knows the resolved window is Claude Code itself, and the one surface where it
tells a third party is the statusline: its stdin JSON carries
`context_window.context_window_size` alongside used/remaining percentages.

So the denominator's source is a **statusline tee**. For every session TBD
spawns, the per-session settings overlay installs a statusline wrapper that
writes the stdin JSON where the daemon can read it, then execs the statusline
the operator configured — or exits quietly when there is none. Presence is by
construction for TBD-spawned sessions, and nothing clobbers a display slot the
user owns, which was the earlier draft's reason for refusing the statusline.
Where the tee is absent or has not yet fired — an older Claude Code, a session
TBD did not spawn — the denominator is **unknown and reported as unknown**:
raw token counts with no percentage, never a guessed one. Anything that needs
a number anyway assumes 200k as a labeled assumption, because 200k errs safe —
thresholds fire early, never late. The current pane-read for context goes
away.

**P1 — make existing work facts available overnight.** The daemon already
calculates almost all work state. It gets pull request (PR) status for each
worktree through batched GraphQL requests. It persists `PRStatus`, including
state and a summary of checks. It also sweeps for branch conflicts and detects
merge transitions. Three implementation gaps remain. First, PR fetching runs
only when the app polls, so it stops overnight; move it to the daemon's clock.
Second, a failed fetch looks the same as "no PR"; record
`undetermined (cause)` as a separate result. Third, **the persisted `PRStatus`
is display-tier and must be labeled as such**: wherever it appears on a public
surface it carries its observed-at, and no view — the account least of all —
renders it as current truth. That cache was measured lying, showing "Ready to
merge" for pull requests merged days earlier (PR #522's review), so anything
that must be *right* about forge state derives it live rather than reading the
cache. This is the design's own source-and-observed-at rule applied to TBD's
own store, and it is what compiled TBD owes P0-8 now that the send-time
verifier is gone (P0-8 amendment 2026-07-30). None of the three needs new terms
or state calculation.

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
situation, decides, and acts through `drive`, guided by its project's active
mode and playbook — whose shipped default advises escalating
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

A repo that means "a literal human, never a model" writes that in its playbook —
one sentence, no machinery. And it is worth being blunt about what that does and
does not buy, because the honest answer is the design's whole posture: it is
**advice, like all conduct**, and nothing enforces it. There is no rule to bind,
no scope to deny, no gate to refuse the act (§3). What stands behind that
sentence is a desk that reads its playbook and follows it, and an account that
shows the operator immediately if it did not. That is the trust bet, and §16
argues it against itself rather than hiding it here.

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
`tbd terminal output <id>`, chosen keys, and sent them down the same audited
delivery path as everything else. The three-condition test does not license it
and does not forbid it; the test governs what the daemon does unattended, and
this is
judgment acting, which is the distinction drawn at the top of this section.

Because keys make no claims about the world, a `--keys` payload has no premise
that could go stale — the freshness discipline a `--text` message answers to
(P0-8, and conduct rather than machinery since the 2026-07-30 amendment) has
nothing to bite on here. **Evidence is the requirement instead**: the action's
ledger line records the screen capture the desk was looking at when it chose
those keys (§6). If a
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
always addressed to. Under a bolder mode the desk simply acts, and the daemon
writes its action line. The response need not be an answer at all:
"these options are underspecified — work through the tradeoffs and ask me again"
is a legitimate reply, and so is a redirect. Which one a question warrants is
playbook judgment (§5); the mechanism is `drive` either way.

*What collapsing it costs* is now nearly nothing, and §15 records why. When the
verb gate existed, one verb meant one rule stance covering answers and unprompted
nudges alike. With no rules at all (§3), the distinction lives where it always
belonged: a mode's conduct prose can tell a desk to answer questions freely and
nudge sparingly, in a sentence, without any vocabulary growing.

**How the question becomes a case.** The hook stays an unconditional dumb
reporter — no supervision check on the agent side, ever. It reports; the daemon
knows whether a shift is running and already receives every event. The fork
lives in the daemon's
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
prompt, by a delegate operating under an authored mode and leaving a record. One
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

## 3. Modes and the trust model (P0-2, P0-3)

### Three layers, and no fourth

Everything in this design sorts into three layers, and knowing which layer you
are in answers most questions about where a behavior belongs:

- **Compiled TBD does facts, delivery, and the record.** It derives state,
  gathers work facts, sweeps, composes work orders, delivers messages, and
  writes the ledger. All of it is model-free, and none of it is a judgment. It
  never inspects what a message says: content is the desk's, and so is its
  freshness (P0-8 amendment 2026-07-30).
- **Conduct is authored.** Modes and playbooks — prose, versioned, and
  project-definable — tell a desk what to act on, what to propose, what to
  escalate, and how bold to be.
- **Judgment is the desk's.** Reading a transcript and deciding what a situation
  warrants is the model's work, and nothing else in the system attempts it.

**Enforcement appears nowhere on that list, deliberately.** There is no
capability wall between a desk and its verbs: no allow rules, no deny rules, no
proposal conversion, no gate. The operator's controls are **selection** — is
supervision on, which mode each project runs, which projects are in automation,
which sessions are never touched — and **visibility**: every act is a ledger
line the moment it happens, and the account renders it beside you.

This is a bet, and §16 records it as one so a future operator who gets burned
knows exactly which paragraph to revisit. The models running these desks are
trusted to follow conduct instructions and are already resistant to prompt
injection; TBD declines to build a second anti-injection mechanism on top of
them. An earlier draft of this document specified a compiled verb gate — posture
consulted on every call, standing allow and deny rules, consequential verbs
converted into proposals. **It is removed in full.** It was machinery built for
a failure mode the operator does not expect these models to exhibit, and every
line of it was weight the design carried for a hypothetical.

### The switch: supervision is on, or off (P0-2)

One configuration column in the daemon, on or off. Settable from the app and the
CLI, broadcast when it changes, surviving restart like every other daemon
toggle. That is P0-2's one-gesture handover for the whole fleet, unchanged in
substance: one gesture, one shift, one ledger, one account, one queue.

**`off` is not a mode.** It is the absence of supervision — no sweep, no desks,
nothing observing — and it stays compiled. It is the only behavioral fork the
switch has.

**The switch's writ runs exactly as far as TBD's own processes.** It stops the
sweep and the desks; it does not reach programs the operator schedules outside
TBD. The [wake program's](2026-07-26-fleet-supervision-wake-program.md) off
gesture is its scheduler's (`launchctl unload`), owned by whoever installed
it — you stop the things you start. The reference wake program reads the
switch from the public status surface and exits quietly when supervision is
off, as authored courtesy rather than as a guarantee TBD enforces (P0-2
amendment, requirements doc).

### Modes are project-defined conduct profiles

A **mode** is a named block of conduct prose: what to act on, what to propose,
what to escalate, how bold to be. Nothing more — and the reason is worth stating,
because it is the discovery that reshaped this section.

**With the gate gone, the daemon has no behavioral fork on mode at all.** The old
attended/autonomous split had exactly two mechanical consequences: consequential
verbs became proposals, and escalations were "batched for morning." The first is
the machinery just removed. The second was always presentation — an escalation is
a ledger line the moment it is written, and "the morning batch" is a query over
the shift window (§6); notifications are out of scope for this design. Nothing
else in the daemon ever branched on posture. So there is no compiled behavior
left for a mode to select, and a mode is free to be what it always effectively
was: instructions.

That is precisely what makes **project-defined modes safe by construction.** A
mode definition is advisory content, and advisory content may travel with a repo
under the standing authority principle — *repos advise; operators bind*. What
binds is not the text. It is the operator's act of **selecting** which mode a
project runs. A repo can ship a mode called `aggressive`; it cannot cause that
mode to be active.

The mechanics:

- **Modes are named sections in the playbook** (§5), resolved per project. The
  shipped default playbook defines `attended` and `autonomous`, so both are
  available to every project without anyone authoring anything. A project may
  define any number of others.
- **Exactly one mode is active per project.** A project with no selection runs
  `attended`, the conservative one.
- **Selection is operator-only**: `tbd supervise mode <project> <mode-name>`, or
  the Settings tab (§10). It is stored in `supervision.json` (§8).
- **Switching is legal at any time, including mid-shift.** It takes effect on the
  next work order, because conduct arrives with each order — no desk recycle is
  needed. The switch writes a ledger line, and **every action line records the
  mode it ran under** (§6), so the account can always answer "what conduct was
  this desk operating under when it did that?"

**What "attended" honestly promises now.** It instructs, and the system makes the
desk's work visible: the ledger is written as each action happens, and the
account panel sits open beside you. It does *not* enforce — nothing stops a desk
running `attended` from driving a session. P0-3 asked for a mode that could not
silently become autonomous; this design answers with immediacy and evidence
rather than a capability wall, and the requirements doc carries a dated descope
amendment saying exactly that.

### The verbs (normative)

This list is the single normative inventory of what a desk can do. Every other
mention of a verb in this document defers to it. **None of them is gated.** What
the daemon does around each one is accounting, never permission.

- **`drive`** — act on a fleet agent's session (the send path of §4 step 7), in
  one of two payload variants.
  - `--text` delivers a message. The daemon does not read it: **freshness here is
    conduct, not machinery** — the shipped playbook's universal says to derive the
    facts live, in the same breath as the send (§5), and the ledger records the
    message verbatim, so a stale premise is *visible* in the account the moment it
    ships rather than prevented at the door (P0-8, amended 2026-07-30). It is also
    how an agent's `AskUserQuestion` is answered, the adapter clearing a
    machine-known dialog first (§2).
  - `--keys` sends named keys the desk chose after reading the screen. Keys
    assert nothing, so no premise can be stale; the ledger line carries the
    screen capture the desk read instead (§2, §6).
- **`wake`** — unpark and resume a parked session. A judgment act: routine
  waking belongs to the project's
  [wake program](2026-07-26-fleet-supervision-wake-program.md), not to any
  desk.
- **`pause`** — halt a runaway session (§13).
- **`escalate`** — put an exact item, proposed command, and recommendation in
  front of the operator. This is how a desk asks; `resolve` is how the operator
  answers (§10).
- **`note`** — attributed prose into the account.

Around every one of them the daemon does the same three things, none of which is
a permission check. It **writes the action line itself**, so a desk cannot
misreport what it did — it is not the reporter (P1-7). The line is honest in
both directions: it asserts *dispatch*, never delivery — whether the message
landed is a separate machine observation (§12) — so the daemon does not
overclaim on its own behalf either. It **arms the one-minute
re-check** (§12). And it **records the active mode and the state snapshot that
justified the act** (§6).

A desk's verbs are addressed to its own project (§5): a call naming a target
outside it is a routing error and is refused as one. That is correctness, not
authority — the desk holds exactly one project's playbook, so acting elsewhere
would mean acting on conduct that does not apply.

Every verb is both a `tbd supervise <verb>` CLI command and an RPC method, so
nothing exists only as a button (§10). `approve-a-prompt` is deliberately absent,
and nothing here restores it under another name: see §2's prompt-stalls
subsection for the difference between a blanket auto-grant and one judged reply
delivered as text.

*Lineage, recorded once so a returning reader is not confused by older drafts.*
The send verb was called `send`, then `intervene`, and is now `drive`; `answer`
was collapsed into it, and `learn` was removed outright. `answer` went because
answering *is* the send path and neither of its apparent differences needed a
verb (§2). The `intervene` → `drive` rename came with a second collapse: an
earlier plan split text-sending from key-sending into two verbs, on the theory
that a message was the lighter act. It is not — a message to an agent running
with permissions bypassed is arbitrary instruction injection — so the split
encoded a safety boundary that does not exist. `learn` went with the whole
machine-appended memory tier: same-shift memory is a `note`, and durable
cross-shift knowledge is repo advisory content with a home and a change process
already (§8). The operator's side of the queue is a separate surface with its own
command (`resolve`, §10), never a verb the supervisor holds.

## 4. The wake-to-action loop

Example flow in autonomous mode at 2:00 a.m. with forty agents:

1. **Tick.** The daemon sweeps the fleet table in its own process. It uses no
   model and starts no subprocesses. It silently skips agents that are working.
   Parked sessions are skipped as such: the sweep records their work facts for
   the account, but waking them is never its call — that is the
   [wake program's](2026-07-26-fleet-supervision-wake-program.md). It writes
   no log and wakes nobody.
2. **Hit.** An agent has been idle for 40 minutes and has uncommitted work.
   Before doing anything, the daemon checks the mechanical reasons to stop: a
   never-touch flag, a rate limit, insufficient quota, an intervention already
   in progress, or a pending re-check timer.
3. **Corroborate.** The daemon checks the pane's live process once. If it
   disagrees with the hook state, the daemon records `unknown` in a prominent
   ledger line and stops. It must not guess.
4. **Work order.** The daemon prepares a case file. It includes the agent's
   identity, session state and its age, work facts, the project's resolved
   playbook **with its active mode's conduct** (§3), **any decisions in scope**
   — answers the operator already gave, so the desk knows them and does not
   re-ask (P1-5, §8) — and the transcript path. Cases are grouped by project
   (§5): if one tick finds several cases in the same project, they travel as one
   work order and wake that project's desk once. Cases in different projects
   never share a work order.
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
   The daemon performs two steps, and inspects the payload in neither. First, it
   **delivers** the payload through the adapter — a dispatch that cannot
   succeed fails here, synchronously, as an ordinary error (§12). Second, it
   **writes the ledger
   line itself**, recording the payload verbatim, the active mode, and the state
   snapshot that justified the act (for `--keys`, that snapshot includes the
   screen capture the desk read, §2); the line asserts dispatch, and whether the
   message landed is the re-check's later observation (§12). Nothing here
   verifies what the message claims — that a `--text` message rests on facts
   derived live is the desk's discipline, and the verbatim line is what makes a
   stale premise findable afterward (P0-8, amended 2026-07-30). There is no
   posture check and no proposal conversion in
   this path: a desk that calls `drive` has driven (§3).
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

**Parked sessions are absent from this loop, by the 2026-07-29 amendment.** An
earlier version of this section compiled an "outstanding work" fact list here —
a global any-true verdict that made a parked session a wake case, with the
trade argued as "a false wake spends a few supervisor tokens and ends in a
note." Field measurement falsified both the mechanism and the price; the full
record, and what replaces it, is the
[wake-program sub-document](2026-07-26-fleet-supervision-wake-program.md).

**One case arrives by event rather than by tick: a pending `AskUserQuestion`.**
The `PreToolUse` hook already reports every one of them to the daemon
unconditionally, with no supervision check on the agent side — the daemon knows
whether a shift is running and sees every event anyway. The fork is in the
daemon's RPC handler:
with a shift active and the terminal's repo in automation (§8), a pending
question becomes a case and **hastens an immediate mini-tick for that
terminal**, running the same pure decision function the clock would have run
minutes later. The work order carries the question payload verbatim from the
daemon's store, so the supervisor fetches nothing and needs no new read
surface. From there it is an ordinary case: judgment, then `drive` down the
same audited delivery path as every other verb. Full mechanics, including the
dismiss-and-reply actuation and what a mid-shift restart costs, are in §2's
prompt-stalls subsection.

Boundary cases:
- **Supervisor can't decide** → `tbd supervise escalate` with the exact item,
  exact proposed command, and recommendation. Those lines appear unchanged in
  the morning queue. An answer becomes a durable decision and is never asked
  again (P1-5).
- **Supervisor stuck or gone** → it is a session like any other; the same
  machinery watches it — and both failures converge on the same remediation.
  An earlier draft detected a stuck desk and only *reported* it, an anomaly
  addressed to an operator who is asleep; now detection is the dead-man's
  switch (§9) — a work order with no ledger line by the deadline, or a desk
  `working` past it with nothing ledgered — and firing means replacement
  through §9's path, bounded by the reroll budget. The sweep continues to
  collect mechanical facts throughout and makes no judgments; the daemon never
  pretends to provide the supervisor's judgment. When the budget is spent, a
  dark desk darkens its own project only: other projects' desks are separate
  sessions and keep working, and the anomaly line names which project lost its
  judgment layer.

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

**Each desk is addressed to its own project.** The daemon refuses a desk's verbs
when the target lies outside that project — addressing correctness, not
authority (§3). This deserves stating
as a security property rather than as tidiness: the blast radius of a confused,
mis-briefed, or prompt-injected supervisor shrinks from the whole fleet to one
project. A desk that reads a hostile instruction in some agent's transcript can,
at worst, act on repos it was already supervising.

**What stays global.** The project is the unit of judgment and action. It is
deliberately not the unit of everything:

- **One on/off switch**, fleet-wide (§3). P0-2 asks for a single gesture to hand
  the fleet over; per-project switches would be N gestures and N chances to
  leave one on. Mode *selection* is per project — that is conduct, not
  lifecycle.
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

- **One playbook, all of a project's modes inside it.** A mode is a named
  section of this file (§3), and the active one's text arrives in every work
  order. Keeping them together is what lets a reader see a project's whole
  conduct — every posture it can take — in one place, and it is why selecting a
  mode changes nothing about which file gets resolved. Separate files per mode
  would split that view for no gain, and would invite the reader to imagine the
  daemon choosing between them; it chooses nothing, it delivers the section the
  operator selected.
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
  irreversible as deserving a human.** A fourth is send-time freshness, which
  since the 2026-07-30 amendment lives here and nowhere else: **before
  dispatching any message that asserts external state — a merge, a review, a
  check result — re-derive that state live, in the same breath as the send, and
  from the source that tells the truth rather than the one that answers
  fastest** (P0-8; the daemon verifies nothing, §3). The old system carried this
  same sentence and it was the thing that worked; a desk is a full agent session
  and can run `gh` and `git` itself. The default contains no commands, bot
  names, or organization-specific content.
- **The shipped default also defines the two baseline modes** (§3), so every
  project has `attended` and `autonomous` available without authoring anything.
  `attended` says: act on the unambiguous, propose anything consequential,
  escalate anything you would want a human to see tonight. `autonomous` says:
  act on your judgment, escalate what genuinely needs a decision, and batch the
  rest for morning. Both are prose, and a project that wants different conduct
  writes its own section rather than arguing with these.

**A playbook may ship advisory scripts, and TBD never runs them.** A project
that wants its own tool prompts classified can put a script in its `.agents/`
directory and tell the desk, in playbook prose, to run it — typically over
`tbd terminal output <id>`, the raw capture that already exists — and weigh what
it returns. This stays on the right side of the screen rule (§2) precisely
because TBD is not in the loop: the daemon neither invokes the script nor
interprets its output, and no compiled behavior branches on it. It is one more
input to a model's judgment, in the tier that is allowed to read screens. A
script's output is advice to a model, never an input to compiled behavior.

**There is no `supervision.json`.** An earlier draft included a small,
structured policy file for the daemon to enforce. It would have held overrides
for consequential verbs, never-act lists, and thresholds. That content now
lives in the operator's `supervision.json` and in mode prose (§8):

1. **Compiled conservative defaults** cover a brand-new repo safely.
2. **Operator answers become durable decisions**: resolving a proposal offers
   "and everything like this" — for the shift or for good — and the answer then
   rides in every work order within that scope, so the desk knows it and stops
   asking (P1-5, §8). One click, and it informs rather than permits.
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
  snapshot that justified it, and the active mode. A separate
  **outcome** line references the action's ID and records what was observed.
  **lifecycle** records shift open, shift close, mode changes, and desk
  recycles (§9). **proposal** and
  **resolution** record proposed actions and their results. **escalation** and
  **resolution** record questions and their answers. **decision** records a
  durable answer the operator gave (P1-5, §8). **anomaly** records an unknown state,
  a failed fetch, or a dark supervisor. Deliberate inaction is recorded as
  seriously as action. **note**
  is the one kind whose content is supervisor-authored prose — attributed prose
  added with `tbd supervise note`, written by the daemon's verb handler like
  every other line, and unable to change any other line. The supervisor may
  reference lines and contribute prose; it can never author an action, an
  outcome, or the account.
- Its structure prevents several false claims: an action nobody performed
  because only verb handlers write action lines; an outcome nobody observed
  because outcomes come from the re-check; a delivery nobody received because
  an action line asserts dispatch only — "landed" is an outcome line's claim,
  made on a machine observation, and an action with no confirming outcome by
  its deadline renders as unconfirmed, never as done (§12); and certainty the
  system did not
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
`{ "id", "ts", "shift", "mode", "project", "kind" }` — plus a payload
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
  choosing those keys** — the evidence requirement every screen-informed act
  carries, without which the line is a bug rather than a thin record (§2). When
  a drive answers a pending question, the snapshot
  **is** the question payload, verbatim: no separate line records the question
  (a pending question is a fact, and facts are not ledgered), and no separate
  verb marks the answer — reading the snapshot is what distinguishes a reply
  from an unprompted nudge (§2).
- **`outcome`** — a reference to the action, one of the four §12 results, and
  the observed-at of that observation. Only this line may claim a message
  landed; the action line it references claims dispatch alone (§12).
- **`proposal`** — everything an `action` carries, plus the supervisor's
  reasoning and the age of the state it reasoned from.
- **`resolution`** — a reference to the proposal or escalation, the result
  (approved / rejected / answered / expired), the scope choice if one was made,
  and the operator's optional explanation.
- **`escalation`** — the exact item, the exact proposed command, and the
  recommendation.
- **`decision`** — the answer the operator gave, its lifetime (shift or
  always), its scope, and its origin. Delivered to desks in later work orders as
  an instruction (§8), never consulted as a permission.
- **`anomaly`** — the category and the detail.
- **`note`** — the author, the text, and optional references to other lines.
- **`lifecycle`** — opening, closing, mode change, or desk recycle; this is
  the kind behind every line §9 describes.

Two representative lines, an action and the outcome that later references it:

```json
{"id":"a3f1","ts":"2026-07-27T02:41:09Z","shift":"s-0714","mode":"autonomous","project":"acme-web","kind":"action","verb":"drive","target":{"worktree":"1B7E2C90","terminal":"6D40F3A1"},"message":"The rebase conflict is in Package.resolved …","state":{"session":"idle","source":"hook+pane-verify","observedAt":"2026-07-27T02:40:58Z"}}
{"id":"a3f2","ts":"2026-07-27T02:42:11Z","shift":"s-0714","mode":"autonomous","project":"acme-web","kind":"outcome","action":"a3f1","result":"landed-and-acting","observedAt":"2026-07-27T02:42:09Z"}
```

Field lists beyond this are implementation detail and will grow. The envelope,
the set of kinds, and the never-claims above are the contract.

## 7. Persistence and storage map

Three categories determine where data belongs. **Live coordination state** is
read to allow or block behavior, affects the system's next action, can be
changed by concurrent actors, and appears live. **Append-only history** is
never used to allow or block behavior; an error there produces an inaccurate
account, not a wrong action. The third category is **human-authored process**.

- **DB: the on/off switch. One config column. Nothing else
  supervision-specific.** The sweep reads it. Both the app and CLI can set it,
  and all surfaces must see the same value immediately after a change — that is
  the purpose of the shared configuration object. Mode selections are *not*
  here; they are per-project operator choices in `supervision.json` (§8), which
  keeps this column a single fleet-wide gesture (P0-2).
- **Shift directory** (`~/tbd/shifts/<shift-id>/`): `ledger.jsonl` +
  `account.md`. The proposal queue is **not a separate data store**. It is an
  in-memory view of the ledger: created proposals minus resolved proposals.
  The daemon rebuilds it at startup by replaying the file. It checks expiry
  when the operator approves a proposal by asking, "Is this proposal still
  current?" No background process writes expiry. This removes the only race
  between multiple writers and therefore the need for a table. Shift-scoped
  decisions are ledger events viewed in the same way. They end with the shift,
  and the shift directory contains everything needed for debugging or sharing.
- **Durable files**, two of them, both operator-owned and hand-editable:
  - `~/tbd/supervision/supervision.json` — the project definitions (§5),
    automation membership and its default stance, and the per-project mode
    selections (§8). Atomically rewritten after each operator action; the daemon
    reloads it after a change and holds it in memory for lookups. Every change
    appends a ledger line, so the current selections and the history of how they
    came about live in the appropriate places.
  - `~/tbd/supervision/decisions.jsonl` — **append-only**, holding the
    `always`-scoped decisions that must outlive a shift (§8), plus retraction
    lines. This is the only supervision state that is durable *and* accumulates:
    it exists because P1-5 promises an answer is never re-asked, and a shift
    ledger cannot keep that promise past its own shift. Read at work-order
    composition, never consulted as a permission.

  The playbook tiers (§5) are also durable files.
- **In-memory, deliberately not durable**: active one-minute re-check timers
  and the sweep's temporary tracking. A daemon restart during a shift loses
  them. For the sweep that is a one-cycle delay, not a broken promise. For a
  re-check armed by a send, the lost timer means the acknowledgement
  observation never runs — handled honestly with no recovery sweep, because
  delivery status is computed at query time: the outcome line never appears,
  so the action renders as unconfirmed by construction (§12). Whether anyone
  resolves it later — the envelope is durable in the transcript, so a late
  read usually can — is playbook judgment, not compiled repair.
- **Crash rule** (replay finds an approved proposal with no action line):
  never automatically execute an old approval. Report it as an anomaly:
  "approved at 7:58, daemon restarted before acting; approve again if still
  wanted." This applies the rule that uncertainty must lead to inaction to the
  supervision machinery itself.

Net property: **supervision adds one column to TBD's database** — the on/off
switch. Everything else it knows is in files a human can open: two under
`~/tbd/supervision/`, one directory per shift, and the playbooks in the repos
themselves.

## 8. Remembered things: advice, selection, decisions

Three things persist between shifts. They are easy to confuse because all three
shape what a desk does — and none of them is a permission.

1. **Advice** — the playbook: prose, human-curated, travelling with the repo
   (`.agents/supervision.md`, three-tier, resolved per project §5). It carries
   both general guidance and the named **mode** sections a project can run (§3).
   The tool never writes it after seeding.
2. **Selection** — which mode each project runs, which projects are in
   automation, and how repos group into projects. Operator-owned, stored in
   `~/tbd/supervision/supervision.json`, and the entirety of what "operators
   bind" now means.
3. **Decisions** — answers the operator gave once and should not be asked for
   again (P1-5). These are *instructions* carried to desks in work orders, not
   permissions consulted by code.

### Where P1-5 landed: decisions are instructions

"Never re-ask me" was one of the arguments for a binding tier in an earlier
draft: only a remembered approval at a gate, it said, could stop the queue asking
again at 3 a.m., 4 a.m., and 5 a.m. With the gate gone the requirement remains
and its mechanism gets simpler — because nothing needed permission in the first
place. What the operator wanted was for the desk to *know the answer*.

So `resolve --scope` survives with a smaller and clearer meaning. Answering a
proposal or an escalation with `--scope this-shift` or `--scope always` writes a
`decision`, and decisions are **carried in every subsequent work order while
they are active**. The desk reads "the operator has already said: archive merged
scratch worktrees without asking" and does not ask. It is not *stopped* from
asking. It is informed, which is what actually prevents the repeat.

**Where a decision lives depends on how long it is meant to last**, and this
matters because shift ledgers end with their shift while P1-5 is a promise that
outlives one night:

- **`this-shift`** — the `decision` line in that shift's `ledger.jsonl`, and
  nothing else. It is projected into work orders for the rest of the shift and
  is gone when the shift closes, which is exactly what was asked for.
- **`always`** — the `resolve` handler writes the `resolution` event to the
  shift ledger *as it does for every resolution*, and additionally appends the
  decision to **`~/tbd/supervision/decisions.jsonl`**, an append-only durable
  instruction log beside `supervision.json`. That file is what carries an answer
  from shift 1 to shift 50. Without it there is no mechanism at all for a
  durable decision, since the ledger is per shift and `supervision.json` holds
  only topology and selection.

At work-order composition the daemon merges two sources — the active
`this-shift` decisions from the current ledger and every unretracted line in
`decisions.jsonl` — and includes them as instructions. That merge *is* the
delivery mechanism for P1-5; nothing consults them as permissions, because
nothing needs permission.

**Retraction is an append, not an edit.** An operator who no longer wants a
standing answer appends a retraction line naming the decision's id —
`tbd supervise decisions revoke <id>`, or by hand, since the file is
operator-owned exactly like `supervision.json` (§7). Append-only keeps the
history of what was decided and undecided intact, and it keeps the file's
writer story identical to the ledger's: one writer, no rewriting of the past.
`tbd supervise decisions list` shows what is currently in force.

This is still a real reduction, not a relabeling. The old shape needed the same
answer in two places — a rule the gate consulted and a fact the desk knew — and
the two could drift. Now there is one fact in one shape, written once and
delivered.

### How a shift's experience reaches the playbook (P2-1)

An earlier draft had a further kind: raw prose the machine appended to a
per-project `learnings.md` via a `learn` verb, included in every future work
order, taking effect immediately. It is **removed**, because it was bridging two
different needs and existing machinery serves each of them better.

**Within a shift, a learning is a `note`.** Notes are in the shift record, and
the shift record is what every replacement desk is briefed from (§9) and what the
account renders. A desk that discovers at 1 a.m. that a repo's test suite needs a
warm cache does not need a new file to tell its 4 a.m. successor — that was never
the hard part.

**Across shifts, a learning is repo advisory content, and that has a home and a
change process already: the playbook, changed by a reviewed commit.** So at shift
end, if learning-shaped notes exist, the desk's flush step (§9) **proposes
spawning a capture worker** — an ordinary worker worktree, briefed to fold the
shift's learnings into that project's `.agents/supervision.md` and open a PR. It
arrives as a **proposal** in the same queue as everything else, survives shift end
like every other unresolved item (§9), and is resolved in the morning batch
alongside the rest. Supervision uses the machinery it supervises — a worktree, an
agent, a PR, a review — rather than inventing a private channel for its own
memory.

This also collapses a promise the removed tier only gestured at. That draft
already said a learning worth keeping was promoted into the playbook by "a human
commit" — but named no mechanism, so it was a follow-up someone had to remember.
Now the commit *is* the mechanism, and the curation step is ordinary PR review.

**The trade-off, stated plainly.** Cross-shift learning costs PR latency, and it
cannot take effect silently. Both are the point. Nothing becomes standing advice
for a repo without a human reading the diff — the same authority principle as
"repos advise; operators bind," applied to the tool's own output. The gap this
leaves — a lesson learned tonight does not steer tonight's other desks — is
covered by notes within a shift, and is not worth a file that every future work
order must carry and no one ever reviews.

### The supervision file

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
  "modes": { "acme-checkout": "autonomous" }
}
```

`projects` holds **only declared multi-repo projects.** A repo named in no
project is its own singleton, implicitly named by the repo — so an installation
that groups nothing has an empty (or absent) `projects` object. Each declared
project lists its member `repos` and designates one `policy` source:
`{ "repo": … }` for a member repo's `.agents/supervision.md`, or
`{ "operator": true }` for the operator-level file (§5). A repo may appear in at
most one project; the loader rejects the file if one appears twice, because
"exactly one" is the property the whole grouping rests on.

`automation` is the sweep's configuration: which projects generate cases at all
(below). `modes` records the operator's mode selection per project — a project
absent from the object runs `attended` (§3). Both are selections. Neither is a
rule, and there is nothing in this file for code to evaluate: the loader reads
topology and choices, and every consumer does a lookup.

**What is no longer here, and the reversal that deserves owning.** There is no
`rules` array: no verbs, no scopes, no stances, no lifetimes, no origins. The
verb gate that consumed them is gone (§3), so the vocabulary that fed it went
with it. And the file's *name* is a reversal this document should state plainly
rather than quietly perform: an earlier draft listed `supervision.json` under
"Deliberately not built," on the grounds that its content had melted into the
standing-rules store. The melting ran the other way in the end — the rules
dissolved, and what was left was topology and selection, which is exactly the
small structured file the earlier draft had rejected. §15 records the reversal.

The storage decision is otherwise unchanged: a **file** at
`~/tbd/supervision/supervision.json`, loaded into memory at startup, rewritten
atomically after each operator action, reloaded after a manual edit, and
hand-editable throughout. With tens of entries and one writer at a time, a
database adds nothing.

### Project automation membership (operator-configurable)

Which projects the supervisor watches is an operator setting, not a design
constant, and it is **sweep configuration** — an input-side answer to "which
projects generate cases," in the same family as the never-touch flags of §5.
**Membership sits at the project level because the project is the acting unit**:
a desk works for a project, so "should the daemon be working here" is a question
about a project, and marking half a declared project out would mean a desk
supervising repos it is meant to leave alone. It has two pieces:

- **A default stance**, chosen by the operator: default-in (every project is
  supervised unless marked out) or default-out (none until marked in). The system
  ships with default-in, because turning supervision on is already an explicit
  operator choice and this matches the old system's watch-everything behavior; an
  operator who wants deliberate onboarding flips one control.
- **A per-project mark**: in, out, or follow-the-default. Only explicit marks are
  stored, so flipping the default never requires touching individual entries.
  Singletons are marked by their repo's implicit project name, so per-repo
  membership is still exactly one mark per repo when nothing is declared.

A project that resolves to *out* produces no cases, so no work orders, so no
desk is ever spawned for it. It still appears in the fact sweep and the account —
observability is never withheld, and "project X needed attention but is out of
supervision" is the honest report.

### Prior art in the current system (and what #509 changed)

Before the redesign, the system represented these concepts in four ways. It had a
hardcoded `STANDING_RULE` prompt string, which compiled one team's closeout
command and review-bot name into the app — the exact warning example from the
brief. The old merge gate shipped a `clearance` table of per-PR, SHA-pinned
operator approvals — **designed as enforcement and never wired**: the store was
fully built, `MergeGate.evaluate()` never consulted it, and it had zero
production writers or readers (`docs/nightwatch.md` §1, §3.5). A prompt asked the
desk agent to consult `approved-prs.jsonl`, so it was binding only until the
model forgot. And the desk's notes file served as both memory and action log,
creating the "self-report" problem in P1-7.

PR #509, merged on 2026-07-26, deleted the merge gate and its clearance and audit
stores, because GitHub branch protection now decides whether a PR may merge. Two
of those four defects are worth carrying forward as warnings rather than as
requirements. The `STANDING_RULE` string is why conduct is authored per project
here instead of compiled (§3). The self-report problem is why the daemon writes
every action line itself (§6) — the one piece of this design that genuinely
constrains a desk, and it constrains what a desk can *claim*, never what it can
*do*.

The clearance table is history, not a model — and the manner of its failure is
the sharper lesson. It was *designed* scoped, revocable, and auditable, and it
enforced nothing, because the code that would have consulted it was never
written. Even the old system's binding tier turned out to be aspirational: what
actually survived was the record of what someone intended, not a mechanism. This
design keeps the auditable part deliberately and drops the pretence of
enforcement openly, which is the same trade the old system made by accident
(§3, §16).

## 9. Shift lifecycle (P2-2)

- **A shift is born from the on/off switch, and only from it.** off →
  attended/autonomous creates a shift ID, creates `~/tbd/shifts/<id>/`, and
  writes the opening ledger line. It starts **no desks**: at shift open there is
  nothing yet to supervise, and a desk exists to hold one project's cases. A
  switch between attended ↔ autonomous during a shift keeps the *same* shift and
  adds a mode-change ledger line. Every action line already records the mode it
  ran under. Only switching supervision off ends a shift.
- **Desks are born lazily, one per project, on that project's first case.**
  A project with a quiet night never gets a desk at all (§4). Each desk is a
  scratch space tracked by ID rather than by its display string, receives the
  supervision skill through the plugin mechanism, and is bound to its project at
  its project for its whole life (§5). Its first delivered message is an opening
  briefing: its project's active mode and conduct, its one resolved playbook,
  and anything unresolved from the previous shift **for that
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
  batch like everything else. Notes add context but are not required; a dead
  supervisor cannot
  block closing, and neither can three of them. All durable data already lives
  outside the desks. Desks accumulated in the old system because nothing
  initiated cleanup. Here, the same operator action that ends the shift disposes
  of every desk the night created — a count the ledger knows, so none can be
  missed.
- **Each shift starts fresh on purpose.** No resumed supervisor context.
  Continuity lives in artifacts: the playbook, the operator's selections, and
  earlier ledgers. The *system* learns; one session's context does not. If a
  supervisor dies during a shift, the daemon writes an anomaly line, creates a
  replacement for that project in the same shift, and briefs it with its
  project's account so far.
- **Off is meaningful**: no shift exists, nothing observes the fleet, the last
  shift's residue is fully on disk. No half-on states.

### Supervisor context recycling

A desk runs all night and receives work orders full of playbooks and
transcripts, so its context grows fast. Two mechanisms manage that, and their
relationship is deliberate: **auto-compaction bears survival; deliberate
recycling is an optimization.** An earlier draft had this inverted — it called
waiting for auto-compaction "the expensive path" and made the recycle
machinery the thing standing between a desk and its context ceiling. That
quietly made recycling load-bearing: if it failed to fire, the desk died at
the ceiling — which is exactly how the desk reviewing this design's first
draft came to exist, spawned by hand from a predecessor that hit 200k
mid-shift. Now auto-compaction stays on for desks and is the guarantee: a desk
can never hard-die from context alone, and what compaction loses is
acceptable by this design's own doctrine, because everything durable is
externalized as it happens (ledger, notes, account, escalations). **A desk's
handoff document already exists — it is the shift record.** Recycling remains
preferred whenever it can run — a fresh desk with a clean briefing reasons
better and costs less per turn than a compacted one — but nothing breaks if
it never fires.

Thresholds are **fractions of the session's effective window**, never absolute
token counts. The denominator comes from the statusline tee (§2); absolute
numbers would be wrong on the next model, and the effective window is a
session fact TBD receives rather than knows. As context grows the daemon
sends staged **flush nudges** — bounded requests, same shape as the shift-end
closing note: "anything in your head not yet in artifacts, write it now as
notes" — at rising fullness (§13), so that whenever a recycle or a compaction
lands, the artifacts are already current. When the tee has supplied no
denominator, the daemon nudges against the labeled 200k assumption (§2) —
early, never late — rather than guessing a larger window.

Recycling is **per desk**, evaluated independently for each: a busy project's
desk may recycle twice in a night while three quiet projects' desks never do.
The sequence, all daemon-driven:

1. **Detect** — a supervisor is a session like any other, so its context
   fullness is already a session-state fact (§2). Threshold: a compiled
   default fraction of the effective window (§13).
2. **Hold** — the daemon stops delivering work orders to *that* desk. Its new
   cases queue; the sweep keeps running; other projects' desks are unaffected;
   the fleet stays watched. The recycle waits until that supervisor is idle with
   no case in flight.
3. **Flush** — the final flush nudge, if the staged ones have not already
   emptied the desk's head. If the supervisor is wedged, the recycle proceeds
   without it — that is exactly the crash path, which was already designed to
   be survivable.
4. **Recycle** — tear down that desk's session, spawn fresh into the same shift
   and the same project, and deliver the standard replacement briefing (the
   active mode, that project's account so far, its open escalations, its one
   playbook) **plus the predecessor's transcript path**. Anything that lived
   only in the old context — a hunch
   mid-investigation, steering the operator typed earlier — is not lost; it is
   demoted from context to disk, and the new supervisor can search its
   predecessor's transcript on demand without paying for that history on every
   future turn. A ledger line links the old session ID to the new one.

**This runs automatically, in both modes, with no proposal.** Everything else
consequential in this design either takes an operator gesture or leaves an
action line someone will read; this deliberately does neither. Recycling a desk
touches no fleet agent and destroys no work state, because desks were built
disposable — it is self-maintenance of the
supervision machinery, not an act on the fleet. It appears in the account
("3:12 a.m. — acme-web desk recycled at 261k context, 4 notes flushed"), not
in the queue. If a recycle ever loses something that mattered, that
is an artifact-externalization bug to fix — the answer is "that should have
been in the record," never "a human should have approved the recycle."

### Desk liveness: the dead-man's switch

Context is not the only way a desk fails, and the first external review of
this design supplied the receipt: a desk can stall on its own question, wedge
mid-turn, or sit silent with cases queued — failing exactly like the agents it
exists to catch, while the draft's only answer was an anomaly line addressed
to an operator who is asleep. The desk was the one session in the system with
no liveness contract. Now it has one, and it is compiled.

**The switch triggers on an unanswered work order, never on idleness.** A desk
is *supposed* to be idle most of the night; it is event-woken, not polling —
rerolling any desk idle for an hour would churn healthy quiet desks for
nothing. The meaningful silence is a work order delivered at time T with **no
ledger line from that desk** by T plus the deadline (§13) — no drive, wake,
pause, escalate, or note. Every desk act is already a daemon-written ledger
line, so ledger silence *is* unresponsiveness, and no new observation channel
is needed. The second arm bounds the working state: a desk `working`
continuously past the same deadline with nothing ledgered. Whether it is
wedged or merely lost in thought stops mattering at the deadline — a desk
holds cases, a case unanswered for an hour is the failure the switch exists to
catch, and replacement costs a briefing, not work state. Both arms are the
P1-6 pattern generalized: every message the daemon sends anyone arms a
deadline; only the clock differs.

**Firing means replacement, not reporting.** Anomaly line, then the
replacement path above with the flush skipped — the desk is by definition not
answering — and queued and unanswered cases redeliver to the successor. A
lifecycle line links the sessions, as with any recycle.

**The reroll budget bounds the loop.** If the work order itself is what wedges
the desk — a pathological transcript, a poisoned case — the successor stalls
identically, and an unbounded switch would reroll all night. After two
consecutive stalled desks on the same project (§13), the daemon stops: the
project is marked dark, its cases hold, and the anomaly line is the loudest
thing in the account. This bound is insurance against machinery this section
introduces, not a scar from a lived incident — the old system never rerolled
a desk at all — but the shape has precedent one layer up: five nights of
judge sessions escalating a restart for software that never existed. Repeated
futile acts happen, and they go unnoticed precisely when nobody is watching.

**No third role is needed, and the regress terminates.** Watching a desk
requires no judgment — ledger silence and a timer are facts — so the desk's
watcher is the compiled daemon, the same machinery that watches every other
session. The daemon's own watcher is the out-of-band heartbeat (§14). Nothing
above that is required.

**Fleet agents are explicitly excluded from all of this.** Auto-compaction is
fine for them too; no handoff templates, recycle flags, or compaction counters
exist for fleet sessions. The per-agent context fact is available for free
(§2), and its only fleet-facing use is informational: a report line or a work
order may mention a parked session's context load, as input to judgment. And a
desk never runs its own succession: the primitives to self-replace exist in
the CLI, and the design's answer is that desk lifecycle — spawn, brief,
recycle, dispose — belongs to the daemon, full stop. The desk's whole
contribution to its own replacement is writing notes when asked.

*Note on the brief:* the requirements brief deferred supervisor self-handoff
("assume the supervisor persists for the shift"). This section overrides that
deferral by operator decision, and the reason is worth recording: the deferral
assumed handoff was a hard open problem, and the shift-record design had
already solved it as a side effect. The liveness contract above closes the
remaining gap that review named — a supervisor that fails like the agents it
watches, with nothing watching it.

## 10. Operator surfaces (intent, not screens)

Principle: **you take action where you already read the relevant information.**

- **The account panel is also the inbox — one inbox, all projects.** The "needs
  you" section of the live `account.md` *is* the queue, and proposals and
  escalations from every desk land in it together, each labeled with its project
  (§6). Each proposal shows the target, exact message, supervisor reasoning, and
  age of its state. Approve and reject controls appear beside it. Resolving also
  offers a **scope, which is purely temporal**: this once / this shift / always.
  There is no "always for this project" or "always for this repo" — a decision is
  an instruction about *the question that was asked*, and that question already
  carries its own subject, so a spatial dimension would only restate it. (The
  per-project and per-repo variants were vocabulary inherited from the
  rules-generalization flow, which died with the verb gate; §3.) Project
  definitions and automation membership are managed in the Fleet Supervision
  settings tab below. A rejection can include an
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
  the playbook and its mode sections (§3); the chat is neither. If you type
  something conduct-shaped that should outlast the shift, it belongs in the
  playbook, and the desk may propose a capture PR that puts it there (§8).
- **Chat steers; the act resolves.** These are not two routes to the same
  place, and the difference is worth being exact about. Answering an escalation
  *from the queue* — the panel's Answer button, or `tbd supervise resolve <id>
  --answer "…"` — is a gesture that reaches the daemon, and the daemon then:
  appends the `resolution` ledger line; drops the item from the queue
  projection; turns any scope choice into a `decision` and, if it is
  lifetime-always, a durable decision later work orders carry; delivers the answer to
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
  gestures reaching the daemon, and that authorship *is* the evidence. The
  shipped playbook closes the loop
  from the other side (§5): a desk told something in chat acts on it and says
  "record it from the queue so it sticks."
- **Attending the desk live is now trivial, which resolves a concern the gate
  used to carry.** With no proposal conversion, watching a desk work is just
  reading its tab and its account: you see what it did the instant the ledger
  line lands, and if you want it to do something you type it. There is no
  double-consent problem — no state where an operator has told a desk one thing
  in chat while a queued proposal says another — because chat steers and the
  record is written by the daemon either way (above).
- **Fleet supervision gets its own Settings tab.** It replaces the current
  Settings section and holds three sections, all views of the one
  `supervision.json`: **projects**, **modes**, and **automation membership**.
  - The **projects** section declares multi-repo projects: name it, pick its
    member repos, designate its policy source (a member repo's
    `.agents/supervision.md`, or the operator-level file). Repos in no project
    are listed as the singletons they implicitly are, so the section always
    shows the whole fleet's grouping rather than only the declared part — a
    reader must be able to answer "which desk would act on this repo?" without
    inferring anything.
  - The **modes** section shows each project with its active mode and the modes
    its resolved playbook defines, and lets the operator select among them (§3).
    A project with no selection shows `attended` and says it is the default
    rather than a choice, so "nobody has picked" never reads as "somebody picked
    this."
  - **Automation membership** is the default-in/default-out control plus the
    per-project in/out/follow-default list (§8).
  All three follow the house file-backed-settings pattern: tilde-abbreviated
  path shown, copy button, manual edits respected. Every control has a CLI twin
  (`tbd supervise project ...`, `tbd supervise mode ...`,
  `tbd supervise automation ...`).

  There is deliberately **no rules-inspection surface**, because there are no
  rules to inspect (§3). The question it existed to answer — "why did the daemon
  do that on its own?" — is answered better by the account: every action line
  carries the mode it ran under and the state snapshot that justified it.
- **Morning flow**: open TBD → open the last shift's account → answer the
  needs-you batch in minutes (P0-10). Each answer creates a decision line.
  Each "never again" is a scope choice attached to an answer the operator is
  already giving.

### The CLI surface (normative)

This is the complete `tbd supervise` surface. It is **normative for names
and shapes**: exact flag spellings may grow, command and subcommand names may
not drift. Everything the app can do appears here, because nothing exists only
as a button.

**Desk verbs — acting** (execute, ledger line, 60-second re-check). None is
gated; each is addressed to the calling desk's project (§3, §5).

```
tbd supervise drive --terminal <id> --text "…"
tbd supervise drive --terminal <id> --keys "…"
tbd supervise wake  --worktree <id>
tbd supervise pause --terminal <id> [--reason "…"]
```

`drive --text` delivers a message, unread by the daemon and recorded verbatim
(deriving its facts live is the desk's discipline, §3); when the target sits on
a dialog the adapter clears it first, but **only a dialog the daemon
machine-knows** — an unidentified one makes the delivery refuse and write an
anomaly (§2). `drive --keys` sends named keys the desk chose after reading the
screen: the ledger line records the capture it read, and sends
are paced (§2, §6). `wake` unparks a parked session — a judgment act; routine
waking is the
[wake program's](2026-07-26-fleet-supervision-wake-program.md). `pause` halts
a runaway (§13). Exactly one payload flag per call.

**Desk verbs — recording** (ledger line only).

```
tbd supervise escalate --item "…" --command "…" --recommendation "…"
tbd supervise note     --text "…" [--ref <line-id>]
```

**Operator — the queue.**

```
tbd supervise queue   [--resolved|--all] [--type proposal|escalation] [--project
<name>]
tbd supervise resolve <id> --approve [--scope this-once|this-shift|always]
tbd supervise resolve <id> --reject  [--reason "…"]
tbd supervise resolve <id> --answer  "…" [--scope …]
```

**Operator — the switch and the modes.** Turning supervision on opens a shift;
turning it off closes it (§9). Mode selection is per project and takes effect on
the next work order (§3).

```
tbd supervise on
tbd supervise off
tbd supervise status
tbd supervise mode <project> <mode-name>
tbd supervise mode <project>            # show the active mode and the choices
```

**Operator — projects** (§5).

```
tbd supervise project list
tbd supervise project create <name> --repos <id,…> --policy repo:<id>|operator
tbd supervise project delete <name>
tbd supervise project move   <repo> --to <project|singleton>
```

**Operator — automation membership** (§8).

```
tbd supervise automation default in|out
tbd supervise automation set <project> in|out|follow-default
tbd supervise automation list
```

**Operator — durable decisions** (§8). Only `always`-scoped decisions appear
here; `this-shift` ones live and die in their shift's ledger.

```
tbd supervise decisions list
tbd supervise decisions revoke <decision-id>
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
- **Per-project on/off** — one switch, fleet-wide; "not this project" is an
  automation mark (§5, §8). Mode is per project, but mode is conduct, not
  lifecycle (§3).
- **Rules of any kind — allow, deny, approve-lists, prompt-approvals.** No verb
  is gated, so there is nothing to permit or forbid. The operator's controls are
  selection and visibility; the reasoning, and the bet it rests on, are in §3
  and §16.
- **`posture`** — the tri-state switch became on/off plus per-project mode
  selection (§3). An older draft's `tbd supervise posture attended` is now
  `tbd supervise on` plus `tbd supervise mode <project> attended`.

## 11. Capacity awareness (P1-1, decomposed)

- **P0 — never poke a rate-limited agent**: this requires no extra work because
  rate limiting is already session state.
- **P1 — fleet-wide hold**: several agents capped at once → hold interventions
  until the limit window resets. The daemon already has usage snapshots for
  each profile. Holds bind the desk verbs — the callers TBD runs. The
  [wake program](2026-07-26-fleet-supervision-wake-program.md) holds on its
  own: the same per-profile usage facts must be readable on a public surface
  (the API gap the requirements doc's P1-1 amendment names), and the
  reference script honors them. TBD does not enforce holds against programs
  it does not run.
- **P2 or never — cross-account rebalancing**: not compiled, ever. It presumes
  a particular arrangement of multiple accounts and requires workflow
  judgment. If it exists, it must be a playbook instruction for a supervisor
  that already has the usage facts.

## 12. Delivery acknowledgement

*Amended 2026-07-30, addressing PR #522's review (its second ask: an action
line recording a send nobody received is a false claim no desk authored — the
machinery built to prevent misreporting becomes the source of one). The
changes: action lines assert dispatch rather than delivery; the transport
returns honest errors; acknowledgement is a passive sentinel observation with
a fourth, undetermined result that is never retried; and an action with no
confirming outcome renders as unconfirmed at query time, which is also the
entire restart story.*

**An action line asserts dispatch, never delivery.** The daemon writing the
line itself guarantees exactly one thing: this payload was handed to the
adapter at this moment. Delivery is a separate observation, recorded later as
an outcome line referencing the action. The send call cannot confirm
delivery — one adapter pushes without an acknowledgement, and the other can
fail if a turn changes at the wrong time — and the ledger must never claim
more than the daemon observed (§6). The field failure this guards against is
real: on 2026-07-29 `terminal.send` reported success into a dead pane for
hours while a desk nudged it, and each of those nudges would have stood in the
ledger as delivered work.

**First, the transport stops lying.** A dispatch that cannot succeed must fail
synchronously, at the send call, as an ordinary error the caller sees. That
fix belongs to `terminal.send` itself — a generic primitive that humans,
scripts, hooks, and desks all share — not to supervision machinery; the
migration doc's slice 4 carries it as a dependency. Its two failure classes
differ in kind. A dead pane is detectable from tmux metadata, but only by
deliberate consultation: `send-keys` into a `remain-on-exit` pane *succeeds*
silently, so an honest error means checking `#{pane_dead}` and window
existence, not trusting tmux's exit status. A *wrong* pane produces no error
by any mechanical measure — pane IDs are reused, and keys sent to a stale
coordinate land in a different live session (issue #384) — so target identity
is verified by deliberate comparison before typing. Neither check is a
guardrail; both are the send path telling the truth about its own result.

**Receipt is a passive machine observation; the agent cooperates in nothing.**
Every dispatched payload opens with a one-line envelope carrying the action
line's ledger ID — `<tbd-dispatch id="a3f1" from="supervision-desk"/>` — which
doubles as honest attribution: the receiving agent sees who is addressing it.
No second ID namespace exists; the ledger ID is the identifier, so dispatch,
transcript receipt, and outcome join on one string. When a submitted message
enters the conversation, the agent's own harness writes its verbatim content
into the transcript JSONL, so a tail read finding the envelope is a machine
fact requiring nothing from the agent — no echo, no acknowledgement behavior,
no awareness. It is also the *right* fact, stronger than "keys reached the
pty": a payload swallowed by a modal, discarded mid-generation, or stranded
unsubmitted in the composer never appears in the transcript — exactly the
differential that made the old failures silent. The envelope is the Claude
adapter's implementation of the observation; the Codex adapter gets the same
answer from the app-server protocol's in-protocol acknowledgement; a future
adapter supplies whatever its machine interface offers. The contract is the
result vocabulary below, never the tag.

**The one-minute re-check performs the observation.** The timer already exists
for P1-6 and the transcript path is recorded for each terminal, so this adds
no machinery. During the re-check the daemon reads two machine facts: whether
the transcript contains the envelope, and the session's current state. It
records one of four results as an outcome line referencing the action:

- *Landed and acting* — delivery confirmed, session working. Done.
- *Landed but still blocked* — delivery confirmed, session blocked again: a
  fresh case within a minute (P1-6).
- *Not landed* — positive evidence of non-delivery: the transcript is
  readable, the envelope is absent, and the session is verifiably not
  mid-turn. Retry delivery once. If the second re-check still finds nothing,
  stop, write an anomaly line, and escalate — two silent failures indicate a
  structural problem with the session, and a third send without evidence
  would risk duplicate-message bugs.
- *Undetermined* — the observation could not be made: transcript unreadable,
  session state unknown, adapter result ambiguous. **Never retried.** Written
  as an outcome and an anomaly, then escalated. Retry proceeds only from
  *not landed*, because retrying into uncertainty risks double-instructing an
  agent that did receive the first copy — and a message to an agent running
  with permissions bypassed is arbitrary instruction injection (§3), so
  delivering it twice is not a neutral event.

**No confirming outcome means not-delivered, at query time.** The account
computes delivery status as the join of action and outcome: an action past its
acknowledgement deadline with no confirming outcome renders as unconfirmed,
as loudly as an anomaly. This is the fail-closed rule applied to delivery —
never default to "landed," the way the wake verifier never defaulted to
DONE — and it makes the ledger honest in both directions: the account may
claim "dispatched" on the daemon's word, and may claim "landed" only on a
machine observation. Because the rule lives in the query rather than in an
appended repair, a mid-shift daemon restart needs no recovery sweep: the
restart kills the re-check timer, the outcome line never appears, and the
action renders as unconfirmed by construction (§7). The envelope is durable in
the transcript, so a late read usually still resolves the question — but
whether anyone performs one, re-drives, or shrugs is playbook judgment at next
contact, never compiled repair.

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
(§15): the old system had none, numeric tuning has no home in `supervision.json`
(§8 holds topology and selection, not parameters), and a new repo-table
column would quietly break §7's one-column property. If real shifts prove a
repo needs different numbers, a repo-table column is the house pattern for it —
added as a conscious amendment to §7, not a side effect.

Crossing a threshold does not itself cause an action. It creates a case in the
next work order, such as "agent Y: 31 turns, no commits in 90 minutes." The
supervisor reads the transcript and decides. If the agent is truly looping, it
uses `pause`, and what it does with that judgment is its mode's conduct to say —
a cautious mode tells it to propose and escalate, a bolder one tells it to act
(§3). Either way the daemon records the act, never arbitrates it.
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
| Supervisor recycle preference | 50% of the effective window, per desk | §9 |
| Flush nudges | 50% / 60% / 70% fullness | §9 |
| Unknown-denominator assumption | 200k, labeled | §2, §9 |
| Dead-man deadline (work order unanswered) | 60 min | §9 |
| Reroll budget | 2 consecutive stalled desks per project | §9 |
| Runaway: turns in window | 30 turns | §13 |
| Runaway: no-progress window | 90 min with no commits | §13 |
| Heartbeat staleness | 10 min | §14 |

**All of these are compiled constants at parity — no new config columns.** That
preserves §7's one-column property, which is a real property of the design and
not an accounting convenience: the moment numbers become columns, "where is this
system's state?" stops having a one-line answer. If real shifts prove a number
wrong, promoting that one number to a config column is a conscious amendment to
§7, argued on its own merits — the same stance taken toward per-repo threshold
overrides (§15).

## 14. Out-of-band heartbeat (P3-1)

On every sweep tick, the daemon writes a small `status.json` file in the shift
directory. It contains whether supervision is on, each project's active mode,
and the last-sweep timestamp. The watchdog is an
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
- ~~**`supervision.json`**~~ — **reversed, and the reversal is the honest
  record.** An earlier draft rejected a small structured policy file on the
  grounds that its content had melted into the standing-rules store. The melt
  ran the other way: the rules dissolved entirely with the verb gate (§3), and
  what remained — project topology, automation membership, per-project mode
  selection — is exactly the small structured file that was rejected. It now
  exists, under that name, holding only selections. See §8.
- **The verb gate, and rules of every kind** — allow rules, deny rules, posture
  consulted per call, consequential verbs converted into proposals. Removed in
  full as over-engineering: it was machinery for a failure mode these models are
  not expected to exhibit, and TBD declines to build a second anti-injection
  layer on top of models already resistant to injection. What survives —
  daemon-written ledger lines, the one-minute re-check — survives because it is
  accounting, and would earn its place in a system with no rules at all. This
  bullet named send-time re-verification as a third survivor; it outlasted the
  gate by one revision and then melted too, for the reasons in the next bullet.
  The bet this rests on is named in §3 and revisited in §16.
- **Compiled send-time re-verification for desk messages** — removed 2026-07-30.
  A `drive --text` was to have every external claim in it checked against live
  sources by the daemon, with a stale premise stopping the send. Three reasons it
  went. **Its owner was invented rather than extracted**: the running system
  never compiled this check — it lived in authored content the desk executed
  itself (the old `wake.py` re-deriving truth at wake time, the playbook's
  "re-read live state in the same breath as the send"), and that discipline is
  what actually fixed the failures P0-8 cites. **It was never implementable as
  stated**: compiled code cannot find "every external claim" in free prose
  without a model, so either the desk declares its claims on the call — covering
  only what it chose to declare, which is no stronger than conduct — or the
  daemon parses prose, which is judgment at the wrong layer. **And it was the
  same knife as the verb gate and the wake rails**: the last compiled
  interposition between a desk's judgment and its act, machinery for the careless
  desk §3's trust bet declines to build for. What replaces it is conduct (§5's
  freshness universal) plus visibility (the verbatim ledger line, §6), and one
  small compiled obligation — display-tier honesty for the persisted `PRStatus`
  (§2). The full argument, the field evidence that a faithful re-verification can
  still be lied to by its source, and the failure signature that would justify
  rebuilding it are in the P0-8 amendment (requirements doc); the transient
  per-source reliability findings live as a dated note in the reference wake
  script, where they can rot without touching this document
  ([wake-program sub-document](2026-07-26-fleet-supervision-wake-program.md)).
- **Per-mode playbook files** — a project's modes are named sections of its one
  playbook (§3, §5), so a reader sees every posture a project can take in one
  place. Splitting them across files would also invite the reader to imagine the
  daemon choosing between them; it chooses nothing.
- **The act-with-veto-window human-in-the-loop (HITL) variant** — historical:
  it was rejected when the design still had a proposal queue that converted
  verbs, on the grounds that a missed veto allows an action nobody approved.
  With the gate gone (§3) there is no conversion to add a veto window to, so the
  rejection stands for a mechanism that no longer exists.
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
  Numbers have no home in `supervision.json`, and a repo-table column would
  break the one-column property (§7); if operation proves the need, that
  column is the house pattern for it, added as a conscious amendment. See §13.
- **A supervisor patrol loop** — the daemon drives the loop and wakes the
  judgment layer with work orders. See §16 for the cost of this choice.
- **A compiled wake gate for parked sessions** — removed 2026-07-29 after field
  measurement falsified its cost argument. The "outstanding work" fact list
  survives as report content only; the decision to wake is a project-authored
  wake program, and a project without one gets reports, not wakes. See the
  [wake-program sub-document](2026-07-26-fleet-supervision-wake-program.md).
- **Daemon-owned wake scheduling** — the wake program schedules itself, and a
  scheduler outside the daemon survives the daemon being down (P3-1's shape).
  TBD neither supervises the scheduler nor tracks its liveness: the program
  self-monitors (heartbeat file, launchd `KeepAlive`, a resurrection
  self-report, an external watchdog), and the account renders parked-session
  facts only. See the
  [wake-program sub-document](2026-07-26-fleet-supervision-wake-program.md)
  and §16 for the ambiguity this accepts.
- **Actuation rails for the wake program** — a first draft of the 2026-07-29
  amendment kept a compiled choke point (never-touch, capacity holds,
  in-flight dedup, send-time freshness, a daemon-written ledger line) that
  every wake would pass through. Removed the same day: TBD does not guarantee
  or guardrail a program it does not run and cannot repair. The program's
  inputs and actuation are public surfaces (Built/Enabled split, requirements
  doc); the rails are the program's to honor, and the reference script honors
  all of them.
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
  one `drive` with payload variants. Replying to a question is the send
  path (the dismissal is delivery-adapter behavior, the "this is a response"
  quality rides in the action's state snapshot); and text is not a lighter act
  than keys, since a message to a permissions-bypassed agent is arbitrary
  instruction injection (§3). Identical semantics, one verb. This cost almost
  nothing to begin with and costs nothing now: with no rules to scope, a mode's
  conduct prose draws whatever distinction a project wants — "answer questions
  freely, nudge sparingly" is one sentence. See §2, §3.
- **A per-project prompt-approval layer** — no matcher, no allowlist, no
  auto-grant, no table of prompts TBD says yes to. Answering a permission prompt
  is an ad hoc judgment act through `drive`, and nothing about it accumulates.
  Recurrence is a signal to fix the repo's own permission config, not a workload
  to automate. See §2.
- **Separate `approve` / `reject` / `answer` queue commands** — all three write
  one `resolution` kind differing only in `result`, so one `resolve` command
  names the category and a flag names the act. Scope attaches once; new outcomes
  are flags. The panel keeps three labeled buttons over the one RPC. See §10.
- **Per-project shifts, switches, or ledgers** — the project is the unit of
  judgment and conduct, not of lifecycle. One on/off switch keeps P0-2's
  one-gesture handover; one shift, ledger, account, and morning queue keep every
  lifecycle surface single. "Not this project tonight" is already expressible as
  an automation mark (§8). See §5.
- **A grouping layer in TBD's schema** — *project* is supervision
  configuration: a key in the operator's rules file, not a table, a UI noun, or
  a lifecycle other subsystems must respect. Graduating it is a conscious later
  step if another subsystem ever needs it. See §5.
- **OS-level isolation of desks from the daemon** — everything runs as one
  user, and with the gate gone there is not even a paved-road constraint left to
  circumvent: a desk has a shell and could call any RPC directly. Real isolation
  would need separate uids or a broker. Deliberately out of scope, and named
  rather than implied — it is the same bet as §3, seen from the operating
  system's side.
- **Repo-shipped binding rules** — nothing binds, so nothing can be shipped
  that binds. A repo ships *modes* (§3), which are advice until an operator
  selects one; that selection is what "operators bind" means now.
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
- **A compiled model → window-size table** — an earlier draft carried one.
  Deleted, because the effective window is a session fact, not a model fact:
  Claude Code resolves it per session from suffix, beta header, environment
  overrides, and a remote flag, so any out-of-band source — a compiled table,
  a public capability dataset such as LiteLLM's or OpenRouter's, or the
  catalog embedded in the Claude Code binary — reports capability, not the
  resolved value, and errs unsafe (a 1M capability read against a 200k
  session hides the boundary). The Models API would be authoritative but
  subscription OAuth tokens are contractually and technically scoped to
  Claude Code itself. The statusline tee (§2) is the one source that reports
  the resolved value; wherever it is absent the design says unknown rather
  than consulting a table.
- **Pinning the compaction window at spawn** — rejected. Claude Code clamps
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW` to the model's real window silently, so a
  pin above it leaves TBD believing a denominator that is not in effect and
  every threshold computed from it quietly inert — a dead sensor that looks
  like a calm night. TBD may still *lower* compaction via the percentage
  override as a preference it expresses, but never treats a pin as knowledge.

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

The design makes the system affordable (P0-6) by limiting its only reasoning
components to the facts that compiled code measures. If that
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

### The trust bet

The second criticism is newer and larger, and it deserves to sit beside the
first rather than under it. **This design has no enforcement.** No verb is
gated; no rule can forbid an act; "attended" instructs but does not restrain.
Everything that stops a desk from doing the wrong thing is either authored
conduct it chooses to follow, or an operator noticing afterward in an account
that is, admittedly, written the instant anything happens.

That is a deliberate bet on model quality (§3), and it should be stated at its
strongest against itself. If a desk misreads its mode, or reasons its way past
conduct prose, or is talked into something by text in a transcript it was asked
to read, there is no second line. The action lands, the ledger records it
faithfully, and the operator finds out — with `drive` that may mean an
instruction already delivered to an agent running with permissions bypassed. The
old draft's gate would not have caught most of that either (it could forbid
verbs by scope, not judge intentions), but it would have caught the blunt cases,
and blunt cases are the ones that actually happen at 3 a.m.

What makes the bet reasonable rather than reckless: the models are trusted to
follow instructions and are already injection-resistant, so a second mechanism
inside TBD would duplicate a defense that exists upstream and be weaker than it;
the blast radius is bounded by project (§5) and by automation membership (§8),
which are selection, not enforcement, but do limit *reach*; and the record is
immediate and complete, so nothing is hidden, only late. The bet is that "late
and visible" beats "prevented and complicated" for a single-operator tool whose
worst outcome is a fleet agent given a bad instruction.

**If it proves wrong, this is the paragraph to come back to.** The failure
signature would be an account showing acts an operator would have refused, more
than once, not attributable to a bad transcript or a stale premise. The
minimum honest response is not to rebuild the gate but to make the mode's
conduct sharper and the account louder; the gate returns only if that fails
too, and it returns as what it always was — a blunt scope check, not a mind.

Two secondary honest costs:

- **Cold start.** Conservative defaults and operator approval make the first
  few nights heavy on approvals. The system becomes more useful only as
  playbook and mode refinements accumulate. An operator who does not make that
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
  should make nights with many unknown states visually unmistakable. The
  [wake program](2026-07-26-fleet-supervision-wake-program.md) sits past the
  process boundary, and by the outside-first follow-up TBD does not track its
  liveness: the program self-monitors, and a dead or never-installed wake
  program renders in the account exactly like the legitimate no-program
  default — parked facts, no wakes. That ambiguity is accepted deliberately,
  eyes open: it is this failure mode's sharpest instance, the sub-document
  names the author-side watchdog pattern that answers it, and the escape
  hatch if field use proves it insufficient is one file read (the account
  surfacing the program's own heartbeat age), added then as a dated
  amendment.
