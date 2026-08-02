# Fleet supervision — design (living draft)

Status: **complete draft, pending operator review.** Captures the decisions
settled in the design conversation of 2026-07-26. The wake decision for parked
sessions lives outside the daemon, in a project-authored wake program specified
in the sub-document
[`2026-07-26-fleet-supervision-wake-program.md`](2026-07-26-fleet-supervision-wake-program.md);
TBD's obligation to programs it does not run is sufficient public surfaces,
never guardrails. Case detection for live agents is likewise authored — a
project-owned sweep program that reads TBD's public fact and record surfaces,
composes the briefings its desk receives, and is held to a compiled liveness
contract, specified with the desk-briefing mechanics in the sub-document
[`2026-08-01-fleet-supervision-sweep-program-design.md`](2026-08-01-fleet-supervision-sweep-program-design.md). §12 pins dispatch-versus-delivery semantics, and the daemon
never inspects message content — freshness is authored discipline on both sides
(§15, and P0-8 in the requirements doc). Companion to
[`2026-07-26-fleet-supervision-requirements.md`](2026-07-26-fleet-supervision-requirements.md),
which carries the stories (P0-1 … P3-1) this doc cites, the **Built/Enabled**
classification, and the outside-first migration rule. This is the ideal-state
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

The three tests share one tie-breaker: **compile only what user-land cannot do
well, because compiled behavior is the hardest kind to change.** A compiled
path changes by rebuild and release — and, once flagged, by migration — while
an authored artifact changes by editing a file. So a behavior that passes no
compiled test decisively belongs outside, where a project can iterate on it
freely, and it migrates inward only on field evidence (the requirements doc's
Built/Enabled ratchet). The wake decision for parked sessions and the case
decision for live agents both sit outside the daemon on this rule. Any future
descope, and any proposal to compile something new in, argues from the same
rule — the motivation for wanting change differs case by case; the placement
philosophy does not.

The requirements brief names six specific items and asks where each one landed.
The applications appear throughout this document; this list collects them for
a quick audit:

- **State derivation** — compiled (§2). It is fact; a wrong answer poisons
  everything downstream, and it runs for the whole fleet every cycle.
- **Intervention thresholds** — authored: named constants in the shipped
  sweep program, editable the moment a project takes its customize copy (§13,
  and the
  [sweep-program sub-document](2026-08-01-fleet-supervision-sweep-program-design.md)
  §7). Crossing a threshold puts a case in a briefing; the response is judged.
- **Cooldowns and dedup** — excluded by the brief (solved elsewhere). The sliver
  in this design — "intervention already in flight" and "re-check pending" —
  is checked at verb time, inside the acting verbs' preconditions (§3), where
  the target is explicit in the call; open-case dedup across evaluations is
  the sweep program's own discipline in its own files (sub-document §7).
- **Per-repo policy** — authored, and resolved per **supervision project** (§5,
  §8): the playbook (advisory prose, including mode definitions) plus the
  operator's selections in `supervision.json`.
- **Mode enforcement (P0-3)** — **descoped** (§3). There is no enforcement: a
  mode is authored conduct, and what the daemon supplies is the record and the
  operator's selection of which mode is active.
- **The shift/morning account** — compiled: a ledger written by the verb
  handlers; views are queries; the supervisor adds attributed notes only (§6).
- **The wake decision for parked sessions** — authored: a project-owned wake
  program outside the daemon (the
  [wake-program sub-document](2026-07-26-fleet-supervision-wake-program.md)).
  Compiled TBD keeps nothing of it, not even actuation rails: TBD's obligation
  is sufficient public surfaces (the requirements doc's Built/Enabled
  classification), never guardrails on a program it does not run. The sweep
  program's remit is live agents only.

**The daemon anchors the loop; the project decides when and what it notices.**
The daemon maintains the fact snapshot continuously — each live agent's state
with its source and age. The project's **sweep program** — one authored
program owning detection, case memory, and briefing composition; TBD ships a
tool-owned reference program that runs on the daemon's default tick with zero
setup, and a project overrides it with its own (the
[sweep-program sub-document](2026-08-01-fleet-supervision-sweep-program-design.md)
§4, §7) — reads that snapshot through the readout, reads TBD's own record of
what has happened since it last looked through the ledger query
(`tbd supervise ledger`), and submits a composed **briefing** as plain text
to the brief pipe (`tbd supervise brief`). At the pipe the daemon holds one
identity-blind check — the per-project briefing rate limit — prepends its
compiled header (the active mode's name, any pending conduct delta), and
delivers to that project's supervisor — the session the operator appointed
where a binding stands, otherwise the TBD-hosted desk, spawned first if the
project has none this shift (§5, §9). Delivering a briefing is the only thing
that ever starts a supervisor's turn (P0-6): a supervisor never polls or
sweeps on its own, and never writes state or history directly. The daemon,
for its part, never makes a judgment — it keeps the facts, paces the pipe,
delivers, records, and executes verbs behind mechanical preconditions (§3:
"intervention already in flight" and "re-check pending" are checked there, at
the act, where the target is explicit); and it holds the sweep program to a
liveness contract, so a program that stops looking cannot impersonate a calm
night. Information flows in one direction: facts → sweep program → briefing
→ daemon → supervisor → verb → daemon. Parked sessions never enter this
loop: whether to wake one is the wake program's decision (above), never a
sweep concern.

The compiled half keeps the hibernation sweep's economy: fact maintenance is
cheap, in-process, and model-free, and there is one fact store however many
projects exist — only briefings fan out per project.

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
liveness identifies gone agents.

There is no advance corroboration step between those sources and acting,
because no advance check can help: a process alive when a case is cut can be
dead — or a different session in a reused pane — by the time a desk acts
minutes later. Staleness is caught where it bites instead: the send path
verifies, synchronously at the moment of the act, that the target pane is
alive and is the session it claims to be, and fails as an ordinary recorded
error when it is not (§12). Activity states ride hook events with their
observed-at; existence rides the liveness detector; the transport tells the
truth at act time. This design adds one thing:

1. **Install Claude Code's `Notification` hook event** so "awaiting input"
   carries a structured reason. The event fires when a permission prompt is
   shown, and its payload carries the "needs your permission" message. It is not
   `PreToolUse`, which fires before *every* tool call and is where an
   agent-native hook can decide a permission itself — that is at-the-source
   configuration (prong 1 below), and it cannot tell anyone that a prompt is
   currently on screen. Only `Notification` can. The event has three consumers.
   It rides verbatim into the desk's briefing — and onward into any question
   the desk raises on the project's question route (§8) — so an operator
   carrying a stall sees exactly what was asked. It makes a stalled prompt a **case**,
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
appears. **The effective window is a session fact, not a model fact.** Claude
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
user owns, which is what makes the statusline usable as a source at all.
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
merge" for pull requests merged days earlier, so anything
that must be *right* about forge state derives it live rather than reading the
cache. This is the design's own source-and-observed-at rule applied to TBD's
own store, and it is the one new obligation P0-8 places on compiled TBD
(§15). None of
the three needs new terms or state calculation.

**P2 — add nothing unless experience proves it is needed.** Do not add verdict
enumerations or a schema for the stages of work. A "work arc" differs by
repository, team, and person. Compiling a fixed set of arcs would recreate the
old system's worst defect. The principle behind that refusal deserves stating
once in full, because it governs both halves of the design: **TBD has no
theory of work — every project authors one.** What counts as done, stalled, or
abandoned is a team's convention, not a universal; the squash-merge night
proved that a true git fact can answer the wrong question when the convention
(squash merges) lives outside the tool. The same refusal covers timing:
**TBD has no theory of attention** — when the fleet deserves evaluation is
equally a project convention
([sweep-program sub-document](2026-08-01-fleet-supervision-sweep-program-design.md)
§1). For parked sessions both theories are the wake program's; for live
agents, detection is the sweep program's and response is the playbook's. The desk
**applies** its project's theory and escalates when that theory is silent — it
never supplies one of its own, and "is the work done" is never the desk's
question to answer from first principles (§4). Policy and the supervisor
should read the raw facts the app already has. If operator hooks repeatedly
implement the same calculation in the future, consider moving that specific
calculation into the app.

### Prompt stalls (P2-3): the machine-interface test

P2-3 asks for agents to be advanced past an operator-authored allowlist of
routine permission prompts. The story is honest about the pain and wrong about
the mechanism: an allowlist matched against a rendered dialog is screen-scraping
with extra steps. Refusing *all* dialog advancement — "prevention, never
advancement" — would overcorrect: it fuses two separate things into one
prohibition, and pulling them apart is the actual rule.

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
   the *only* machine source of that content while the dialog is live:
   measured directly, the transcript holds no record of the question while
   the picker is open — the `tool_use` line is buffered and flushes only with
   the resolution, nine seconds of file silence spanning one measured dialog
   (`docs/research/2026-07-31-askuserquestion-dismissal/findings.md`) — which
   is exactly why the hook bridge exists. Verbatim, structured, before
   render.
3. **Outcome.** Once the dialog resolves, the `tool_result` lands in the
   transcript in a stable shape TBD already parses, within roughly 200 ms of
   the resolving keystroke (measured, findings doc above). Dismissal
   included: an Escape writes a generic rejection `tool_result`
   (`is_error`, "User rejected tool use") joined to the question by
   `tool_use_id`. And — measured rather than assumed — **Escape fires no
   hook event at all**: no `PostToolUse`, no `PostToolUseFailure`, nothing.
   The transcript record is the *only* machine signal that a dialog was
   dismissed. What happened to a question is a machine fact afterward, not
   an inference.

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
2. **Wait for the dialog's resolution to appear in the transcript.** Escape
   produces no hook event — measured, not assumed (findings doc above) — so
   no hook can be the signal. What Escape produces is transcript records:
   the buffered `tool_use` and the rejection `tool_result` flush together
   within roughly 200 ms of the keystroke, joined to the question by
   `tool_use_id`. That record is the resolution signal — the same tail read
   the daemon already performs, and the same signal that clears the
   pending-question store. A timer never *confirms* anything, but the wait
   is bounded: if the resolution has not appeared within the bound, the flow
   stops, sends nothing, and writes an anomaly — the undetermined shape
   (§12). Nothing is typed into a session that may still have a modal on
   screen.
3. **Deliver the response as ordinary composer text** through the standard
   delivery adapter, with §12's acknowledgement path verifying it landed: the
   ledger marker appears in the transcript, or the send is retried once and
   then written up as an anomaly for the operator.

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
(P0-8, conduct rather than machinery) has
nothing to bite on here. **Evidence is the requirement instead**: the action's
ledger line records the screen capture the desk was looking at when it chose
those keys (§6). If a
sequence turns out to have been wrong, the record shows exactly what was on the
screen and exactly what was sent, which is the same accountability the
three-condition test buys for the automatic path, obtained a different way.
Sends are named-key and paced, following the rate-limit actuator's precedent.
In attended mode the desk suggests such a send instead of making it — an entry
in the project's proposals doc (§6) showing the keys *and* the screen they aim
at, so saying yes is not an act of faith.

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
question (§6), so the record already says what was being answered, verbatim. A
question the desk carries to a human travels with that same verbatim payload,
for the same reason. Account views label these lines
as answers by reading the snapshot. A separate verb would have added a word to
the vocabulary and nothing to the record.

What the operator experiences is unchanged in substance. In attended mode the
desk relays the question — the agent's questions and options verbatim, plus
the proposed response and its reasoning — to wherever the playbook routes this
project's questions (§8), and the operator approves it or answers differently
themselves: the dialog, delivered at last to the human it was
always addressed to. Under a bolder mode the desk simply acts, and the daemon
writes its action line. The response need not be an answer at all:
"these options are underspecified — work through the tradeoffs and ask me again"
is a legitimate reply, and so is a redirect. Which one a question warrants is
playbook judgment (§5); the mechanism is `drive` either way.

*What collapsing it costs* is nearly nothing, and §15 records why. A rules-based
design would have made one verb mean one rule stance covering answers and
unprompted nudges alike. With no rules at all (§3), the distinction lives where
it belongs: a mode's conduct prose can tell a desk to answer questions freely and
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
ordinary tick, holding the same one playbook. **The briefing carries the
question payload verbatim out of the daemon's store**, so the supervisor fetches
nothing — which dissolves the need for any new read surface. Nothing is
ledgered for the question itself; facts are not ledger lines. The question
snapshot rides in the `drive` action's line as the state that justified it,
or travels verbatim in the question the desk routes to a human if the
supervisor punts (§8), with a `note` pointing at where it went.

**Permission prompts reach a desk the same way.** The `Notification` event
(above) rides the identical pipeline: an unconditional dumb-reporter hook, the
daemon holding the fact, and — with a shift active and the terminal's project in
automation — a **case** plus an event-hastened mini-tick. One pipeline, two
sources; the only difference is what the case carries and therefore what
judgment it warrants.

Two words earn their precision here, because the rest of this document leans on
them. A **case** is daemon → desk: a fact the sweep program or an event surfaced, with
no claim about what should happen. An **escalation** is desk → operator: a
judgment that a human is needed, with an exact item and a recommendation,
carried to wherever the playbook routes this project's questions (§8).
A permission-prompt case is *not* automatically an escalation. Whether it
becomes one is exactly the judgment the desk is there to make.

**Store hygiene, and what a restart costs.** The pending store's time-to-live
is a garbage-collection backstop for stranded entries, not a dialog's clock. It
must never expire a still-live dialog during a shift: resolution comes from
the transcript's `tool_result` record, not from elapsed time — and measured
behavior says that record arrives on every resolution path: answer, Escape,
even a tool denied by a hook (findings doc, §2 above). No hook event closes a
dismissed dialog, so any store keyed on hook events alone would strand an
entry on the single most common user gesture; the transcript record is the
closing signal, and the GC covers only what measurement has not. The store staying memory-only is
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
The one-minute re-check (P1-6, §4 step 7, §12) still notices a stalled agent
within a minute of an intervention, and the `Notification` event path still
raises awaiting-input as a case. Prevention plus fast escalation is how "a trivial prompt doesn't
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
  gathers work facts, paces the brief pipe, delivers briefings and messages,
  and writes the ledger. All of it is model-free, and none of it is a
  judgment. It never inspects what a message says: content is the desk's, and
  so is its freshness (P0-8).
- **Conduct is authored.** Modes and playbooks — prose, versioned, and
  project-definable — tell a desk what to act on, what to propose, what to
  escalate, and how bold to be.
- **Judgment is the desk's.** Reading a transcript and deciding what a situation
  warrants is the model's work, and nothing else in the system attempts it.

**Enforcement appears nowhere on that list, deliberately.** There is no
capability wall between a desk and its verbs: no allow rules, no deny rules, no
proposal conversion, no gate. The operator's controls are **selection** — is
supervision on, which mode each project runs, which projects are in
automation — and **visibility**: every act is a ledger
line the moment it happens, and the account renders it beside you.

This is a bet, and §16 records it as one so a future operator who gets burned
knows exactly which paragraph to revisit. The models running these desks are
trusted to follow conduct instructions and are already resistant to prompt
injection; TBD declines to build a second anti-injection mechanism on top of
them. **There is no compiled verb gate** — no posture consulted on every call,
no standing allow and deny rules, no conversion of consequential verbs into
proposals. That machinery would serve a failure mode the operator does not
expect these models to exhibit, and every line of it would be weight the design
carried for a hypothetical.

### The switch: supervision is on, or off (P0-2)

One configuration column in the daemon, on or off. Settable from the app and the
CLI, broadcast when it changes, surviving restart like every other daemon
toggle. That is P0-2's one-gesture handover for the whole fleet, unchanged in
substance: one gesture, one shift, one ledger, one account.

**`off` is not a mode; it is the pause of TBD's authority to act.** The
switch governs acting, and only acting: off stops the default tick from
launching new sweep runs and refuses briefings at the pipe with a distinct
machine-readable paused result (a run already in flight finishes inside its
timeout bound and its submission is refused; external programs are never
signaled — TBD stops only what TBD starts, sub-document §3, §4), and the
actuation preconditions (above) refuse the acting verbs
from that instant — a desk mid-thought when the switch flips can finish
thinking, and its drive returns an ordinary error instead of touching
anything. Everything else continues: desks stay alive and idle, the shift
stays open, and the record keeps filling — enrollment, anomalies, and
`note` still land, so a desk interrupted
mid-judgment can still write down what it was about to do. Watching
continues; touching stops. Flipping back on resumes the same shift with the
same desks at full context: the daemon writes a resumed lifecycle line and
hastens the default tick, so briefings are composed from current state, never from
pre-pause state. Toggling is therefore cheap in both directions — which a
control must be for an operator to actually reach for it.

**Closing a shift is a separate, explicit operator action** — a record
boundary, not a posture, and the two compose freely (§9, §10). Nothing
closes a shift automatically: a shift left paused for a day renders loudly
as exactly that, because a lingering state degrades to loud display, never
to autonomous cleanup.

**The switch's writ runs exactly as far as TBD's own processes.** It stops the
sweep and the desks; it does not reach programs the operator schedules outside
TBD. The [wake program's](2026-07-26-fleet-supervision-wake-program.md) off
gesture is its scheduler's (`launchctl unload`), owned by whoever installed
it — you stop the things you start. The reference wake program reads the
switch from the public status surface and exits quietly when supervision is
off, as authored courtesy rather than as a guarantee TBD enforces (P0-2,
requirements doc).

### Modes are project-defined conduct profiles

A **mode** is a named block of conduct prose: what to act on, what to propose,
what to escalate, how bold to be. Nothing more — and the reason is worth stating,
because it is the discovery that reshaped this section.

**The daemon has no behavioral fork on mode at all.** A mechanical
attended/autonomous split could amount to exactly two things: consequential
verbs becoming proposals, and escalations "batched for morning." The first is
the verb gate this design declines (above). The second is routing — when and
where a desk raises a question is the playbook's conduct (§8), not a daemon
behavior; notifications are out of scope for this
design. Nothing else in the daemon would branch on posture. So there is no
compiled behavior for a mode to select, and a mode is free to be what it
effectively is: instructions.

That is precisely what makes **project-defined modes safe by construction.** A
mode definition is advisory content, and advisory content may travel with a repo
under the standing authority principle — *repos advise; operators bind*. What
binds is not the text. It is the operator's act of **selecting** which mode a
project runs. A repo can ship a mode called `aggressive`; it cannot cause that
mode to be active.

The mechanics:

- **A mode is a name plus prose.** The name lives in `supervision.json`'s
  declared mode list (§8); the conduct it stands for is described in the
  project's playbook (§5), by convention as a section under that name. The
  built-in list is `attended` and `autonomous` — available to every project
  with nobody authoring anything, described in the shipped default
  playbook; a project may declare any number of others.
- **Exactly one mode is active per project.** A project with no selection runs
  `attended`, the conservative one.
- **Selection is operator-only**: `tbd supervise mode <project> <mode-name>`, or
  the Settings tab (§10). It is stored in `supervision.json` (§8).
- **Switching is legal at any time, including mid-shift.** It takes effect on
  the next briefing, whose compiled header names the selection (the conduct
  itself stands in the desk's session layer, sub-document §8) — no desk
  recycle is needed. The switch writes a ledger line, and **every action line
  records the mode it ran under** (§6), so the account can always answer
  "what conduct was this desk operating under when it did that?"

**What "attended" honestly promises now.** It instructs, and the system makes the
desk's work visible: the ledger is written as each action happens, and the
account panel sits open beside you. It does *not* enforce — nothing stops a desk
running `attended` from driving a session. P0-3 asked for a mode that could not
silently become autonomous; this design answers with immediacy and evidence
rather than a capability wall, and the requirements doc records that descope
(P0-3).

### The verbs (normative)

This list is the single normative inventory of what a desk can do. Every other
mention of a verb in this document defers to it. **None of them is gated.** What
the daemon does around each one is accounting, never permission.

**Ungated speaks to conduct; a short list of actuation preconditions speaks
to mechanics.** Inside every acting verb call — after the desk decides,
before any keystroke — the daemon rechecks against current state: the switch
is on, a shift is active, the target lies inside the calling desk's project,
the target is not rate-limited and not under a capacity hold, no intervention
is already in flight for the target, and no act re-check is pending on it.
The last two are the record's own bookkeeping — never double-treat before the
first treatment is assessed (§12) — and they sit here, at the act, because
here the target is explicit in the call (`--terminal <id>`); the brief pipe,
which takes only prose, checks nothing per-agent (sub-document §3). Target
liveness and identity are deliberately absent from this list: they are the
transport's own synchronous checks, made milliseconds later in the same verb
call, and one check with one owner beats the same check in two places (§12). Every item is a yes/no fact the operator or the
machine already owns — a flag, a switch, a timestamp — and none involves
reading the payload or judging the act. This is addressing correctness (§5)
extended from *where* a desk may act to *whether TBD may act at all right
now*, and it is what makes the operator's controls real rather than
advisory: judgment takes minutes, so a briefing's facts are already stale
at act time, and the off switch flipped at 2:03 must beat a drive decided
from a 2:02 briefing and issued at 2:07. A failed precondition refuses the
act — nothing is typed, the CLI returns an ordinary error naming the
condition, and the refusal is recorded (§4 step 6, §6), so the morning shows
near-misses and an operator learns their controls bind. What was removed stays
removed: no rule matching, no content inspection, no posture judgment. The
gate asked "may this desk do this *kind* of thing"; preconditions ask only
"may anything be done *here, now*." The residual race is the milliseconds
between check and keystroke. Preconditions bind the acting verbs; the record
verb (`note`) requires only an active shift and correct
addressing — the record itself never refuses more than that.

- **`drive`** — act on a fleet agent's session (the send path of §4 step 6), in
  one of two payload variants.
  - `--text` delivers a message. The daemon does not read it: **freshness here is
    conduct, not machinery** — the shipped playbook's universal says to derive the
    facts live, in the same breath as the send (§5), and the ledger records the
    message verbatim, so a stale premise is *visible* in the account the moment it
    ships rather than prevented at the door (P0-8). It is also
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
- **`note`** — attributed prose into the account. Also the soft
  cross-reference for questions: when a desk raises something on the
  project's question route (§8), its playbook may tell it to note the
  pointer — "question posted to <channel>, answered <when>" — so the record
  shows a question is out without the record owning the question.

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
would mean acting on conduct that does not apply. The verbs belong to whichever
session holds the supervisor role — the TBD-hosted desk or an operator-appointed
session (§9) — with identical addressing and identical accounting; CLI
reachability for these verbs is one of the four supervisor-capability
requirements (§9), so a session that cannot call them cannot be a supervisor.

Every verb is both a `tbd supervise <verb>` CLI command and an RPC method, so
nothing exists only as a button (§10). `approve-a-prompt` is deliberately absent,
and nothing here restores it under another name: see §2's prompt-stalls
subsection for the difference between a blanket auto-grant and one judged reply
delivered as text.

*Why the list is this short.* Answering a question is not its own verb —
answering *is* the send path, and neither of its apparent differences needs one
(§2). Text-sending and key-sending are not two verbs either: splitting them
would encode a safety boundary that does not exist, since a message to an agent
running with permissions bypassed is arbitrary instruction injection, so they
are payload variants of `drive`. There is no `learn` verb and no
machine-appended memory tier: same-shift memory is a `note`, and durable
cross-shift knowledge is repo advisory content with a home and a change process
already (§8). And there is no `escalate` verb: raising a question to a human
is conduct, not a state transition in TBD's record — the desk writes the
exact item, its proposed command, and its recommendation to wherever the
playbook routes this project's questions, and notes the pointer (§8). The
record attests acts only.

## 4. The wake-to-action loop

Example flow in autonomous mode at 2:00 a.m. with forty agents:

1. **Look.** The project's sweep program runs — here on the daemon's default
   tick, running the shipped reference program (sweep-program sub-document
   §4, §7) — and reads two surfaces. The readout: session states with their
   ages, work facts, runaway counters, pin state. And the ledger query:
   TBD's record of what has happened since the program last looked —
   briefings delivered, acts and their outcomes, anomalies. It evaluates
   them under whatever theory of attention and of work its project authored,
   and against its own case memory: a situation it already briefed, with the
   ledger showing the desk has not yet acted, is skipped rather than
   re-briefed. Parked sessions appear in the readout as facts for
   the account, but waking them is never a sweep concern — that is the
   [wake program's](2026-07-26-fleet-supervision-wake-program.md). A quiet
   evaluation still ends in a submission, with nothing composed — the
   attested "looked, found nothing" (sweep-program sub-document §3, §6).
2. **Compose and submit.** The program finds an agent idle past its
   threshold with uncommitted work and composes the briefing in its own
   voice — the agent's identity, the facts with their ages, what it thinks
   they mean, the transcript path, any operator answer it has read that
   bears on the case — ordering pinned worktrees first (P1-3, §5). It
   submits the text to `tbd supervise brief`. At the pipe the daemon
   applies its one identity-blind check — the per-project briefing rate
   limit — and refuses while paused; it parses nothing, edits nothing, and
   ranks nothing (sweep-program sub-document §3).
3. **Deliver.** The daemon prepends the compiled header — the **name of the
   active mode** (§3; the conduct itself stands in the desk's session layer,
   with mid-shift playbook edits carried as superseding deltas in this same
   header, sweep-program sub-document §8) — writes the delivery line
   request-first with the delivered text's hash and the conduct hash (§6),
   and passes the briefing through. A pending prompt case travels the
   compiled fast path instead (§2), its question payload verbatim out of the
   daemon's store. Briefings are per project by construction (§5): the pipe
   is addressed per project, and one submission wakes that project's desk
   once. Cases in different projects never share a briefing.
4. **Wake.** The daemon delivers the briefing through the adapter for that kind of
   agent, just as it would for any other session. Where the operator has
   appointed a supervisor for the project (§9), the briefing goes to that
   session. Otherwise, if the project has no hosted desk yet this shift, the
   daemon spawns one first — hosted desks are lazy, so a project that
   stays quiet all night never gets one — and spawning installs the
   project's playbook as the desk's standing conduct (sweep-program
   sub-document §8). Each supervisor is an ordinary, visible, TBD-managed
   session (P0-4) — the hosted desk in its own worktree, an appointed
   supervisor in whatever tab the operator chose it from. An operator can
   open its tab, watch it think, and type into it.
5. **Judgment.** The supervisor reads the transcript and writes a specific next
   step. It never sends only "continue" (P0-7). This is the loop's only model
   reasoning, and it runs under the project's authored theory of work (§2): the
   playbook is what says what done and stuck mean here. Where the playbook is
   silent — an idle agent whose work may or may not be finished — the desk's
   move is a note or an escalation, never a completion verdict of its own.
6. **Act through the daemon, never around it.** `tbd supervise drive …`.
   The daemon performs three steps, and inspects the payload in none of them.
   First, it **appends the action line** — the durable request: the payload
   verbatim, the active mode, and the state snapshot that justified the act
   (for `--keys`, that snapshot includes the screen capture the desk read,
   §2). The line exists before any keystroke, so its ID is already durable
   when the delivery envelope quotes it (§12), and no crash window can
   produce a real intervention with no record. Second, it **rechecks the
   actuation preconditions** (§3) against current state; a failure refuses
   the act — nothing is typed, the CLI returns an ordinary error naming the
   condition, and a refusal outcome referencing the action line is written.
   Third, it **dispatches** through the adapter — a dispatch that cannot
   succeed fails here, synchronously, as an ordinary error and a
   transport-failed outcome (§12). The claims form a ladder: the action line
   asserts the request, the synchronous outcome asserts dispatch or refusal,
   and whether the message *landed* is the re-check's later observation
   (§12). Nothing here verifies what the message claims — that a `--text`
   message rests on facts derived live is the desk's discipline (P0-8), and
   the verbatim line is what makes a stale premise findable afterward. There
   is no content check and no proposal conversion in this path: a desk that
   calls `drive` has driven (§3).
7. **Short follow-up.** The act arms a one-minute re-check (daemon timer, in
   memory). The result is recorded as an outcome line referencing the action
   (§6). A new blocked state
   becomes a new case within one minute instead of fifteen (P1-6).
8. **Everything else costs nothing.** The other agents: zero tokens, zero sends.
   The other projects: no desk spawned, nothing woken.

**What per-project desks cost (P0-6, restated honestly).** The compiled fact
side is unchanged — one global, model-free fact store, whatever the
project count. A quiet project is free in the strongest sense: its desk is never
spawned, so it holds no context and burns no tokens. What the grouping gives up
is cross-project batching. A round of evaluations with cases in three projects wakes three
desks where a single fleet desk would have woken once. Each of those wakes is
smaller — one project's cases, one playbook, not the fleet's — so token cost
roughly washes; what rises is the *wake count*. That is the honest price of the
one-supervisor-per-policy invariant (§5), and it buys something no amount of careful
prompt wording can: a desk cannot mistake one project's policy for another's,
because it never holds another's. Two bounds complete the accounting. Desk
count scales with projects-that-have-cases, not with fleet size — so the
worst night is a correlated failure touching many projects at once, which
spawns that many desk processes on a host already running the fleet: a real
memory-and-process cost, and part of why a quiet project costing nothing
matters. And context load moves in the desks' favor: a single fleet desk
absorbing every project's cases, playbooks, and transcript reads concentrates
the whole night in one context window — the shape most likely to hit a
ceiling mid-shift — where sharding by project spreads it.

**Parked sessions are absent from this loop.** A compiled "outstanding work"
fact list here — a global any-true verdict making a parked session a wake case,
traded on the argument that "a false wake spends a few supervisor tokens and
ends in a note" — is refused: field measurement falsified both the mechanism and
the price. The reasoning, and what stands in its place, is the
[wake-program sub-document](2026-07-26-fleet-supervision-wake-program.md).

**One case arrives by event rather than by tick: a pending `AskUserQuestion`.**
The `PreToolUse` hook already reports every one of them to the daemon
unconditionally, with no supervision check on the agent side — the daemon knows
whether a shift is running and sees every event anyway. The fork is in the
daemon's RPC handler:
with a shift active and the terminal's repo in automation (§8), a pending
question becomes a case and **hastens an immediate mini-tick for that
terminal**, running the same pure decision function the clock would have run
minutes later. The delivered briefing carries the question payload verbatim from the
daemon's store, so the supervisor fetches nothing and needs no new read
surface. From there it is an ordinary case: judgment, then `drive` down the
same audited delivery path as every other verb. Full mechanics, including the
dismiss-and-reply actuation and what a mid-shift restart costs, are in §2's
prompt-stalls subsection.

Boundary cases:
- **Supervisor can't decide** → the playbook names where this project's
  questions go — a channel, an issue, a file (§8) — and the desk writes the
  exact item, exact proposed command, and recommendation there, leaving a
  `note` with the pointer so the record shows a question is out. The operator
  answers at the route; the sweep program reads the answer and carries it
  into future briefings, so an answered question is not re-asked (P1-5, §8).
- **Supervisor stuck or gone** → it is a session like any other; the same
  machinery watches it. Detection is one story for both supervisor
  arrangements: the dead-man's switch (§9) — a briefing with no ledger line
  by the deadline, or a supervisor `working` past it with nothing ledgered.
  Remediation forks by ownership. For a hosted desk, detecting a stuck desk
  and only *reporting* it would be an anomaly addressed to an operator who is
  asleep, so firing means replacement through §9's path, bounded by the
  reroll budget. For an appointed supervisor, firing raises the operator
  notification and nothing else — TBD never disposes of, restarts, or spawns
  over the operator's own conversation (§9). The daemon continues to
  collect mechanical facts throughout and makes no judgments; it never
  pretends to provide the supervisor's judgment. When a reroll budget is
  spent, or an appointed supervisor stays dark, the darkness covers its own
  project only: other projects' supervisors are separate sessions and keep
  working, and the anomaly line names which project lost its
  judgment layer.

## 5. Supervision projects and where policy lives

### The supervision project

**One supervisor per policy.** A single fleet-wide desk holds several repos' playbooks
in context at once, which means it must *remember* which policy governs the
action in front of it. Labeling the playbooks would be a prompt-level defense,
and §3 refuses to rest enforcement on prompt wording. The fix is structural
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
- **One supervisor per project.** A project's supervisor is one session, and
  the operator selects which. The shipped default is the TBD-hosted **desk**:
  spawned the first time the project has a case in a shift, disposed at shift
  end (§9). The alternative is **appointment**: the operator binds an existing
  TBD-managed session as the project's supervisor (§9, §10), recorded as a
  per-project selection in `supervision.json` (§8); while a binding stands,
  the hosted default stands down for that project. Throughout these
  documents, **desk** names the session holding the supervisor role —
  whichever arrangement holds it — and *hosted desk* or *appointed supervisor*
  marks the arrangement wherever lifecycle or remediation differ. Either way
  a supervisor's briefings contain only its project's cases, and it stands
  on its one playbook.

**The singleton case must collapse exactly.** With nothing declared — the state
every installation starts in — every project is one repo, policy resolution is
the per-repo three-tier lookup described below, and a repo with a case gets a
desk holding one playbook. That is precisely the plain
per-repo arrangement: one repo, one playbook, one desk. The
grouping *unwraps*: it is not a mode to be in, it is a generalization whose
degenerate case is that arrangement exactly. Any behavior that differs
between "no projects declared" and the plain per-repo arrangement is a bug, not
a feature.

**Each desk is addressed to its own project.** The daemon refuses a desk's verbs
when the target lies outside that project — addressing correctness, not
authority (§3). How the daemon knows the caller's project is deliberately
plain: the desk's terminal environment carries its project's name
(`TBD_PROJECT=<name>`, the same name that keys `supervision.json`, §8),
injected at desk spawn like TBD's other spawn-time env layers — and, for an
appointed supervisor, injected by the appointment operation's relaunch (§9),
which is the same spawn-equivalent moment — and the CLI
sends it ambiently with every verb. A desk never types identity flags, so it
cannot mistype them, and the value survives however far the desk `cd`s while
investigating — location is where a desk is looking, never who it is.
Attribution rides the one-supervisor-per-project invariant: the daemon knows
which session currently holds the named project's supervisor role (it spawned
the desk or performed the appointment, and recycling is sequenced), so the
ledger line is attributed from the daemon's
own records, never from the caller's text. All of this is caller declaration, not
authentication — any process could set the variable, and TBD declines to
build stronger (§3): the capability the verbs wrap is already public surface
(`terminal.send`), so impersonating a desk gains record-keeping and pacing,
not reach; if field use ever shows verb traffic from non-desks, a
spawn-minted per-session token is the evidence-driven next step. This deserves stating
as a security property rather than as tidiness: the blast radius of a confused,
mis-briefed, or prompt-injected supervisor shrinks from the whole fleet to one
project. A desk that reads a hostile instruction in some agent's transcript can,
at worst, act on repos it was already supervising.

Isolation and the trust bet (§3) answer different failures, and neither
substitutes for the other. Trust covers **conduct** — a well-meaning desk
following its playbook, which is the expected case and the one §3 declines to
gate. Isolation covers the two failures conduct cannot reach: **honest
error** — an obedient model under context pressure applying one repo's
convention to another, a mistake rather than a transgression, which structure
prevents by removing the opportunity instead of gating the behavior — and
**compromise**, where containment bounds what a bad night costs. Trusting a
model's conduct and declining to hand it the chance to mix policies are the
same posture, not a contradiction: the drawer is small because the teller is
trusted with the drawer, not with the vault.

**What stays global.** The project is the unit of judgment and action. It is
deliberately not the unit of everything:

- **One on/off switch**, fleet-wide (§3). P0-2 asks for a single gesture to hand
  the fleet over; per-project switches would be N gestures and N chances to
  leave one on. Mode *selection* is per project — that is conduct, not
  lifecycle.
- **One shift, one `ledger.jsonl`, one `account.md`.** Every desk's acts,
  outcomes, and notes land in the same record, with each
  project's proposals doc (§6) linked beside it.
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
running against the old shape. Any live hosted desk whose project definition
changed is
**recycled through §9's replacement path** — flush, tear down, respawn with the
new membership and the newly resolved playbook; an appointed supervisor in the
same position gets the conduct reload instead (§9, sweep-program sub-document
§8) — the same conversation resumed on the newly resolved playbook, since its
session is never torn down. So there is exactly one moment
of change, it is the same reload-or-recycle machinery §9 already runs, and no
desk is ever
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

**Every desk stands on exactly one playbook**, because a desk supervises
exactly one project: the whole file is installed as the desk's standing
conduct at spawn — at the appointment relaunch for an appointed supervisor
(§9) — and every briefing's header names the active mode
(sweep-program sub-document §8). There is no such thing as a briefing
spanning two policies — that is the invariant the project exists to create.

- **One playbook, all of a project's modes inside it.** A mode's name is
  declared in `supervision.json` (§8); the playbook describes its conduct,
  by convention as a section under that name — a convention for the file's
  readers, human and desk, never for the tool: **TBD does not parse the
  playbook.** Compiled code resolves the file's path, hashes its bytes, and
  installs it verbatim; the desk is the only structure-aware reader. Keeping
  every mode in the one file is what lets a reader — and the desk — see a
  project's whole conduct — every posture it can take — in one place, and it
  is why selecting a mode changes nothing about which file gets resolved.
  Separate files per mode would split that view for no gain, and would
  invite the reader to imagine the daemon choosing between them; it chooses
  nothing, it names the selection.
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
  the chat channel: **when an operator answers a question by typing in the
  desk's tab, proceed on that guidance, and write the answer to the project's
  question route (§8) with a `note` saying so — "acting on this now; recorded
  at <route> so it sticks."** Desk context is disposable by design (§9), so
  without that discipline the answer is real for one context, invisible to
  the sweep program, and gone at the next recycle. A third covers permission prompts, since answering one
  is an ad hoc judgment with no approval layer behind it (§2): **escalate when
  unsure, and treat prompts guarding merges, credentials, or anything
  irreversible as deserving a human.** A fourth is send-time freshness, which
  lives here and nowhere else: **before
  dispatching any message that asserts external state — a merge, a review, a
  check result — re-derive that state live, in the same breath as the send, and
  from the source that tells the truth rather than the one that answers
  fastest** (P0-8; the daemon verifies nothing, §3). The old system carried this
  same sentence and it was the thing that worked; a desk is a full agent session
  and can run `gh` and `git` itself. A fifth is decision depth: **before
  driving past any prompt that guards credentials, merges, or anything
  irreversible, be able to say why the agent is asking — not just what it
  asks — reading backward in the transcript until the request makes sense, and
  escalating when it does not.** Its companion rule makes the discipline
  uniform: **write every message as if the target will execute it unchecked —
  never lean on a safety net.** Targets genuinely differ in posture — most
  fleet spawns run with permissions bypassed, yet a repo's explicit `ask`
  rules still prompt even there, the mode can change mid-session from the
  keyboard, and an adopted session may ask about everything — so the same
  drive is a suggestion behind a checkpoint into one session and the final
  checkpoint itself into another (field measurement caught exactly this
  pair). The desk never calibrates to that difference: calibrating means
  predicting what a session will do with a message, and the observation loop
  (§12) sees everything except the irreversible act that completes before the
  re-check — which is precisely the class decision depth already covers.
  Depth follows the content of the act; if an instruction would worry you
  running with no gate behind it, that worry is the signal, whoever the
  target is. The verbatim question in the briefing
  answers "what is being asked"; nothing compiled can answer "with what
  context," because knowing which distant transcript content bears on a
  decision is interpretation, and interpretation is judgment's job (§2). The
  receipt is from the field: a session that refused a prompt injection later
  asked for a production credential — entirely plausible in isolation,
  impossible to judge correctly without the refusal sitting next to it.
  Because those two facts can surface in different cases hours
  apart, the discipline has a second half: **an anomaly like a refused
  injection gets a ledgered note the moment it is seen, so the later,
  plausible-looking request lands next to it** — the desk's shift memory is
  what connects facts across cases. Deep reads cost real tokens and no
  discipline makes them free; the economy is §2's recurrence-is-a-signal
  stance — a repo whose agents keep hitting such prompts fixes its permission
  config at the source rather than buying the desk a bigger reading budget.
  The default contains no commands, bot
  names, or organization-specific content.
- **The shipped default also defines the two baseline modes** (§3), so every
  project has `attended` and `autonomous` available without authoring anything.
  `attended` says: act on the unambiguous, write anything consequential into
  the proposals doc (§6) instead of doing it,
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

**`supervision.json` holds selections, not policy.** There is no *policy* file
the daemon enforces — no overrides for consequential verbs, no never-act lists,
no thresholds. The operator's `supervision.json` (§8) holds only the operator's
selections: project topology, automation membership, and per-project mode
choices. What would-be policy content there is lives in three places instead:

1. **Compiled conservative defaults** cover a brand-new repo safely.
2. **Operator answers live on the project's question route** (§8): the desk
   asks there, the operator answers there, and the sweep program reads the
   answer and carries it into future briefings, so the desk knows it and
   stops asking (P1-5, §8). The answer informs rather than permits. An answer
   worth keeping for good is playbook material, captured by reviewed PR (§8).
This implements one authority principle: **repos advise; operators bind.** A
repository file must not control tool behavior on an operator's machine before
a human approves it. Treating that behavior as normal would be a security
problem. And nothing here needs a promotion mechanism: the playbook already
stands in the desk's session layer, so a rule-like sentence in it
is already advice at full strength, and a sentence that should carry an
operator's endorsement gets it the way all standing knowledge does — a
reviewed change to the playbook, or an answer given on the question route
that the program keeps carrying (item 2).

**Worktree priority (P1-3) is an operator gesture on a particular thing, not
policy.** *Worktrees whose progress matters most get looked at first* reuses
an existing gesture: the worktree
**pin**. The pin state worktrees already carry rides in the readout, and the
shipped sweep program orders each briefing's cases pinned-first, then by case
age, so that project's supervisor works the list top-down (sub-document §7).
Ordering is within one project's briefing, so it never
has to rank one project against another. Pinning is already how an operator
marks what matters, so priority
costs no new schema and no new concept. Repository files contain rules about
*kinds* of things; the DB records operator choices about *particular* things,
and the pin follows that rule the way `keepWarm` does. Like every fact,
ordering only shapes
attention — it never changes what any verb is allowed to do.

## 6. The account (P0-9, P1-7)

**The ledger is the account; everything else is a view of it.**

- `~/tbd/shifts/<shift-id>/ledger.jsonl` — an append-only file with one
  JavaScript Object Notation (JSON) object per line, written **only by daemon
  code at the moment it acts**. It supports these line kinds:
  **action** records a drive, wake, or pause, including the payload, the state
  snapshot that justified it, and the active mode. A separate
  **outcome** line references the action's ID and records what was observed.
  **lifecycle** records shift open, pause, resume, shift close, mode changes,
  and desk recycles (§9). **enrollment** records an agent entering the supervision
  perimeter mid-shift; the shift-open line carries the same fields for every
  agent already present, as a roster snapshot. **delivery** records a briefing
  delivered to a desk (sweep-program sub-document §3, §9).
  **anomaly** records an unknown state,
  a failed fetch, a dark supervisor, or a silent sweep program (a missed
  contact window, sweep-program sub-document §6). Deliberate inaction is recorded as
  seriously as action. **note**
  is the one kind whose content is supervisor-authored prose — attributed prose
  added with `tbd supervise note`, written by the daemon's verb handler like
  every other line, and unable to change any other line. The supervisor may
  reference lines and contribute prose; it can never author an action, an
  outcome, or the account.
- Its structure prevents several false claims: an action nobody performed,
  because only verb handlers write action lines — appended before the adapter
  runs, so a crash can delay an outcome but never hide an act; an outcome
  nobody observed, because outcomes come from the adapter's synchronous
  return or the re-check; a delivery nobody received, because the claims
  ladder from *requested* (the action line) through *dispatched or refused*
  (the synchronous outcome) to *landed* (the observed outcome, §12) — and an
  action with no confirming outcome by its deadline renders as unconfirmed,
  never as done; and certainty the system did not have, because unknowns are
  anomalies, not values.
- Quiet contact writes nothing (sweep-program sub-document §3). Sweep liveness
  is one status field, not forty lines an hour; the shift-close line carries
  the coverage summary.
- The ledger is also readable per project by the sweep program:
  `tbd supervise ledger --project <name> --since <t>` prints a project's
  actions, outcomes, deliveries, and anomalies — the loop-closer that lets a
  program see what TBD did since its last evaluation (sweep-program
  sub-document §3). Read-only, schema-versioned, one of the three public
  sweep surfaces.
- **`account.md`** sits beside the ledger. The daemon regenerates this view
  after every append, and the side panel displays it live. Nobody writes the
  account directly. The supervisor can only add attributed notes *into* it.
  Markdown is the record's presentation; JSON Lines (JSONL) is its source.
  Markdown cannot be the source because parsing prose back out of a display
  format would repeat the screen-scraping mistake in a file.
- **End-of-shift and morning views are queries** over the shift's time window.
  The views are done (actions + outcomes), unconfirmed (actions past their
  deadline with no confirming outcome, §12), went-wrong (anomalies), and
  the notes — including the question pointers desks leave when they raise
  something on the project's question route (§8), with each project's
  proposals doc linked beside them. A closing supervisor narrative is a final note *on
  top of* the generated report. It adds context but does not author the record.

**Proposals are prose, not records.** A proposal is the desk's judgment — "I
think we should do X, and here is why" — not a claim about something that
happened, so it does not belong to the ledger's machinery: the ledger exists
to guard facts against false claims, and a suggestion cannot be a false
claim. When a desk holds back on something consequential (attended mode's
signature move), it writes the suggestion into **that project's proposals
doc** — a markdown file at `~/tbd/shifts/<shift-id>/proposals/<project>.md`,
beside the ledger it relates to, surviving shift close like everything else
in the shift directory. **How the doc is composed is the project's choice.**
The shipped default playbook describes a sane default entry — what act, on
which target, the exact message or keys, the reasoning, and, for anything
screen-informed, the capture it rests on — and a project that wants its
proposals grouped by risk, written as checklists, or in its own house style
says so in its playbook. TBD compiles only the boring parts: the file's
location, and the app showing it with its path. So the record still points at
everything, filing a proposal comes with a one-line `note` — "proposal filed:
rebase strategy for acme-web, see the doc" — which is how the morning account
knows the doc is worth opening. Acting on a proposal is a human act in the
world: the operator does the thing, or tells the desk to — in its tab, or by
an answer on the question route that the sweep program carries into the next
briefing (§8).
There is no approve button, and nothing executes a proposal mechanically.

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

- **`action`** — the durable request, appended before dispatch (§4 step 6):
  the verb, the target (worktree / terminal / repo), the payload
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
- **`outcome`** — a reference to the action and a result: synchronous
  (*dispatched*; *refused*, naming the failed precondition; or
  *transport-failed*) or observed (one of the four §12 results, with the
  observed-at of that observation). Only an observed outcome may claim a
  message landed; the action line it references asserts the request alone
  (§12).
- **`delivery`** — a briefing delivered to a desk: the project, the delivered
  text's hash, and the conduct hash the desk stands on (sweep-program
  sub-document §3, §9). Written request-first, before the adapter runs, and
  it arms the desk dead-man's deadline (§9). "What did this desk actually
  receive, under what conduct" is answerable per briefing from this line.
- **`anomaly`** — the category and the detail.
- **`note`** — the author, the text, and optional references to other lines.
- **`lifecycle`** — opening, pause, resume, closing, mode change, or desk
  recycle; this is
  the kind behind every line §9 describes. The opening line's payload includes
  the roster snapshot: one entry per agent already under supervision, with the
  same fields an enrollment line carries.
- **`enrollment`** — the agent's identity (worktree / terminal), its repo's
  resolved project, the spawn source, and the transcript path. Mechanical
  facts only, written by the daemon when a new agent enters a supervised
  project's perimeter mid-shift; with the shift-open snapshot this makes "what
  was under watch, and since when" a plain query, and "was supervision even
  applying to X at 02:20" answerable after the fact. The transcript path is
  deliberate: its head is the agent's original assignment, so judgment reaches
  "what is this agent for" in one hop, by reference — TBD stores a pointer and
  interprets nothing (§2, §15). The perimeter is the fleet table: a session
  TBD did not spawn is invisible to it, and the account reports that boundary
  honestly rather than implying coverage it does not have.

Two representative lines, an action and the outcome that later references it:

```json
{"id":"a3f1","ts":"2026-07-27T02:41:09Z","shift":"s-0714","mode":"autonomous","project":"acme-web","kind":"action","verb":"drive","target":{"worktree":"1B7E2C90","terminal":"6D40F3A1"},"message":"The rebase conflict is in Package.resolved …","state":{"session":"idle","source":"hook","observedAt":"2026-07-27T02:40:58Z"}}
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
  supervision-specific.** The daemon reads it. Both the app and CLI can set it,
  and all surfaces must see the same value immediately after a change — that is
  the purpose of the shared configuration object. Mode selections are *not*
  here; they are per-project operator choices in `supervision.json` (§8), which
  keeps this column a single fleet-wide gesture (P0-2).
- **Shift directory** (`~/tbd/shifts/<shift-id>/`): `ledger.jsonl` +
  `account.md` + `proposals/<project>.md`, the desk-authored prose of §6.
  Every view over the record is a query of the ledger, rebuilt from the file
  at startup, never a second store. The shift directory contains everything
  needed for debugging or sharing.
- **Durable files**, operator-owned and hand-editable:
  - `~/tbd/supervision/supervision.json` — the project definitions (§5),
    automation membership and its default stance, the per-project mode
    selections, the per-project supervisor bindings (§9), and the
    per-project sweep selections (§8). Atomically
    rewritten after each operator action; the daemon
    reloads it after a change and holds it in memory for lookups. Every change
    appends a ledger line, so the current selections and the history of how they
    came about live in the appropriate places.
  - `~/tbd/supervision/projects/<name>/sweep.py` — a project's customized
    sweep program, written exactly once by the "Customize sweep…" gesture and
    never touched by the tool after (sweep-program sub-document §7). Absent
    for projects running the shipped program.
  The playbook tiers (§5) are also durable files — and the playbook is where
  knowledge that must outlive a shift lives, changed by reviewed PR (§8).
- **In-memory, deliberately not durable**: active one-minute re-check timers
  and the brief pipe's liveness bookkeeping. Timers may live in memory *because*
  everything they encode derives from the durable record — an action line's
  timestamp fixes its observation deadline — so a daemon restart during a
  shift costs cadence, never data. For the default tick that is a one-cycle delay.
  For re-checks, the startup ledger replay
  surfaces actions past their deadline with no outcome, and
  the daemon performs those observations then: the envelope is durable in the
  transcript, so a late read resolves what the timer would have (§12). Until
  it runs, such actions render as unconfirmed by construction — the
  query-time rule, not a recovery sweep.

Net property: **supervision adds one column to TBD's database** — the on/off
switch. Everything else it knows is in files a human can open: two under
`~/tbd/supervision/`, one directory per shift, and the playbooks in the repos
themselves.

## 8. Remembered things: advice, selection, and the question route

Two things persist between shifts inside TBD's own files, and a third
persists deliberately outside them. All three shape what a desk does — and
none of them is a permission.

1. **Advice** — the playbook: prose, human-curated, travelling with the repo
   (`.agents/supervision.md`, three-tier, resolved per project §5). It carries
   both general guidance and the named **mode** sections a project can run (§3).
   The tool never writes it after seeding.
2. **Selection** — which mode each project runs, which projects are in
   automation, how repos group into projects, which session supervises a
   project (the supervisor binding, §9), and each project's sweep
   selections. Operator-owned, stored in
   `~/tbd/supervision/supervision.json`, and the entirety of what "operators
   bind" means.
3. **Questions and answers** — the traffic between a desk that needs a human
   and the human. This lives on the project's **question route**, and the
   route is authored, not compiled.

### Questions and answers: the record attests acts only

**Escalation is conduct.** The playbook names where this project's questions
go — a Slack channel, an issue tracker, a file the operator reads — and that
naming is the whole mechanism: the desk writes the exact item, the exact
proposed command, and its recommendation there; the operator answers there,
in the place their attention already lives; the sweep program reads the
answers and carries them into future briefings; and the program's files are
the durable memory of what has been asked and answered. Never-re-ask (P1-5)
is that authored discipline, demonstrated end to end by the shipped
reference program (sweep-program sub-document §7): before briefing, it
checks its own record of answers and TBD's ledger of deliveries and acts, so
the 3 a.m. answer is not re-asked at 4 a.m. or 5 a.m. The desk is informed,
not stopped — which is what actually prevents the repeat, since nothing here
needs permission in the first place.

The record's part is deliberately small. The `note` verb is the soft
cross-reference: playbooks may tell desks to note a pointer — "question
posted to <channel>, answered <when>" — so the account shows a question is
out, and the morning reader knows where to look. TBD's compiled record
**attests acts only**: every act carries its payload, its timestamp, and its
outcome, daemon-written, and that chain is complete (§6, §12).

**The honest cost, stated plainly.** The record proves every act; it does
not prove approvals. Whether a human agreed before an act lives in the
project's own artifacts — the route, the program's files — not in the
ledger, so an act that should have had an approval behind it is not
mechanically flaggable as missing one, and evidence not captured at the time
cannot be reconstructed later. What the record does guarantee is that the
act itself is visible, verbatim, the instant it happens; whether that act
honored an answer is legible only to a reader who follows the pointers.

Two alternatives were weighed and rejected, and the rationale is worth
keeping because both could return on evidence:

- **A compiled escalation queue** — escalations and resolutions as ledger
  kinds, an operator-only resolve command, answers projected into
  briefings. It buys two real properties: one guaranteed inbox, and
  forgery-proof consent — only operator gestures could write answers, so a
  resolution in the record proved a human said so. Rejected because it
  freezes question routing into the daemon: every project's questions funnel
  through one tool-shaped inbox regardless of where that project's humans
  actually look, and the queue needs a question data model — items, scopes,
  resolution kinds — which is the hardest kind of surface to change once
  desks and operators depend on it. Starting outside is the reversible
  direction: a project routes questions wherever its people already are, and
  a compiled queue can migrate in on field evidence, one piece at a time,
  under the requirements doc's ratchet. Unbuilding a compiled queue that
  projects had shaped their playbooks around would not be reversible in the
  same way.
- **An approval-stamp verb** — `tbd supervise approve`, writing
  operator-gesture consent into the ledger with no queue behind it. It keeps
  forgery-proof consent for irreversible acts at the cost of one verb, and
  nothing else. Rejected for now as machinery with no consumer: nothing in
  the design consults approvals, so the stamp would be a record feature
  waiting for a reader. Revisit on evidence — the failure signature is a
  morning account where "did a human agree to this" is repeatedly
  unanswerable and the answer mattered.

**Knowledge that should outlive the shift has exactly one home: the project's
playbook, changed by a reviewed PR.** That path already exists — the capture
flow (below) folds a shift's learnings into `.agents/supervision.md` — and an
answer the operator finds themselves giving night after night is precisely
a learning worth capturing; the shipped playbook says so, telling desks that
an answer received two shifts running belongs in the capture suggestion.
There is no separate durable decision store, because permanent instructions
kept in a side file are policy nobody reviews — the playbook is where a
project's standing answers live, in the open, with a change history.

### How a shift's experience reaches the playbook (P2-1)

**There is no machine-appended learnings tier** — no raw prose the machine
appends to a per-project `learnings.md` via a `learn` verb, carried into every
future briefing and taking effect immediately. It would bridge two different
needs that existing machinery serves better.

**Within a shift, a learning is a `note`.** Notes are in the shift record, and
the shift record is what every replacement desk is briefed from (§9) and what the
account renders. A desk that discovers at 1 a.m. that a repo's test suite needs a
warm cache does not need a new file to tell its 4 a.m. successor — that was never
the hard part.

**Across shifts, a learning is repo advisory content, and that has a home and a
change process already: the playbook, changed by a reviewed commit.** So at shift
end, if learning-shaped notes exist, the desk's flush step (§9) **suggests
spawning a capture worker** — an ordinary worker worktree, briefed to fold the
shift's learnings into that project's `.agents/supervision.md` and open a PR.
The suggestion is an entry in the project's proposals doc (§6); it survives
shift end as a file on disk like the rest of the shift directory, and the
operator acts on it in the morning
alongside the rest. Supervision uses the machinery it supervises — a worktree, an
agent, a PR, a review — rather than inventing a private channel for its own
memory.

This also makes the promotion concrete rather than gestural. "A learning worth
keeping is promoted into the playbook by a human commit" names no mechanism
unless the commit *is* the mechanism — here it is, and the curation step is
ordinary PR review.

**The trade-off, stated plainly.** Cross-shift learning costs PR latency, and it
cannot take effect silently. Both are the point. Nothing becomes standing advice
for a repo without a human reading the diff — the same authority principle as
"repos advise; operators bind," applied to the tool's own output. The gap this
leaves — a lesson learned tonight does not steer tonight's other desks — is
covered by notes within a shift, and is not worth a file that every future
briefing must carry and no one ever reviews.

### The supervision file

```json
{
  "version": 1,
  "projects": {
    "acme-checkout": {
      "repos": ["<repo-id>", "<repo-id>"],
      "policy": { "repo": "<repo-id>" },
      "sweep": { "script": "~/tbd/supervision/projects/acme-checkout/sweep.py" }
    }
  },
  "automation": { "default": "in", "projects": { "acme-checkout": "out" } },
  "modes": { "acme-checkout": "autonomous" },
  "supervisors": { "acme-checkout": { "terminal": "<terminal-id>" } }
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

`automation` is case detection's configuration: which projects generate cases at all
(below). `modes` holds two things on the default-props chain: the **declared
mode list** — the names a project's operator may select, defaulting to the
built-in pair `attended`/`autonomous` when absent — and the operator's
**selection** per project, defaulting to `attended` (§3). Selection is
validated against the declared list: a lookup within this one file. TBD never
derives the list from the playbook — compiled code does not parse prose
(§5) — so a declared name the playbook says nothing about is simply playbook
silence, which the desk handles as it handles all silence (§4). Both are
selections. Neither is a
rule, and there is nothing in this file for code to evaluate: the loader reads
topology and choices, and every consumer does a lookup.

`supervisors` holds the per-project supervisor bindings (§9): at most one
entry per project — singletons keyed by their implicit repo name, like every
other per-project map here — naming the TBD-managed terminal the operator
appointed. Absence means the shipped default, the TBD-hosted desk. Like the
other keys this is selection, read by lookup; unlike them, a binding is made
real by an operation on the session itself — the appointment relaunch (§9) —
so it is written by the appoint and relieve gestures (§10), each of which
performs that operation and appends a lifecycle ledger line. A binding edited
by hand names a session whose process was never relaunched into the role —
no standing layer, no injected identity — so the daemon reports it as an
anomaly rather than honoring it silently; the appoint gesture is the way to
make a binding real.

**What this file never holds.** There is no `rules` array: no verbs, no scopes,
no stances, no lifetimes, no origins. Nothing is gated (§3), so there is no
vocabulary for a gate to consume. What the file does hold — topology and
selection — is small, structured, and read by lookup, which is why it is a file
at all rather than prose or a table.

The storage decision is otherwise plain: a **file** at
`~/tbd/supervision/supervision.json`, loaded into memory at startup, rewritten
atomically after each operator action, reloaded after a manual edit, and
hand-editable throughout. With tens of entries and one writer at a time, a
database adds nothing. Per-project sweep selection lives here too — the
sweep schedule (TBD's tick or `external`), the declared contact window, and
the custom-program pointer (`sweep.script`, written by the "Customize
sweep…" gesture; sweep-program sub-document §4, §7) — selection-tier
operational choices, still zero rules. This file, hand-edited or driven
through its CLI twins, is the entire operator surface for v1 (§10).

### Project automation membership (operator-configurable)

Which projects the supervisor watches is an operator setting, not a design
constant, and it is **sweep configuration** — an input-side answer to "which
projects generate cases."
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

A project that resolves to *out* produces no cases, so no briefings, so no
desk is ever spawned for it. It still appears in the fact sweep and the account —
observability is never withheld, and "project X needed attention but is out of
supervision" is the honest report.

Coverage is also a recorded event, not only a resolved fact. Because
membership derives — agent → repo → project → mark — a new agent spawned
mid-shift is under supervision the moment it exists, with no config edit and
no desk chore; but nothing about that derivation leaves a trace by itself.
The trace is the ledger's: the shift-open roster snapshot and per-agent
mid-shift `enrollment` lines (§6) are what let the account answer *what was
under watch, and since when* — enrollment as a first-class event, arrived at
by recording the derivation rather than replacing it.

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

## 9. Shift and supervisor lifecycle (P2-2)

- **A shift is born from the switch and ends only by explicit close.**
  Turning supervision on with no shift open creates a shift ID, creates
  `~/tbd/shifts/<id>/`, and writes the opening ledger line with the roster
  snapshot (§6). It starts **no desks**: at shift open there is nothing yet
  to supervise, and a desk exists to hold one project's cases. Turning the
  switch off does **not** end the shift — it pauses it (§3): a paused
  lifecycle line, desks alive and idle, the record still open. Turning it
  back on writes a resumed line and hastens a tick. Briefings do not
  survive a pause — anything still true reappears in a fresh briefing derived
  from current state — and dead-man deadlines (below) suspend while paused
  and rearm on resume, because a briefing unanswered during a pause is the
  system's doing, not a dead desk. Only the explicit close action (§10) ends
  a shift; issued with the switch still on, it finalizes the record and a
  fresh shift opens in the same gesture — how an always-on operator gets
  shift-sized accounts instead of one endless ledger. Every action line
  records the mode it ran under.
- **Hosted desks are born lazily, one per project, on that project's first
  case.** A project with a quiet night never gets a desk at all (§4), and a
  project with an appointed supervisor (below) never gets a hosted one: while
  the binding stands, the hosted default stands down. Each hosted desk is a
  scratch space tracked by ID rather than by its display string, receives the
  supervision skill through the plugin mechanism, and is bound to its project at
  its project for its whole life (§5). Its first delivered message is an opening
  briefing: its project's active mode (the conduct itself installed as its
  standing layer at spawn, sub-document §8), and a pointer to the previous
  shift's account **for that project** — the daemon derives it by replaying
  the previous shift's ledger and filtering on the project tag (§6). Open
  questions never silently disappear when a shift ends: they live on the
  project's question route and in the sweep program's files (§8), which
  outlive every desk by construction — which is why the route and not the
  desk is the durable home for anything needing a human, and why a question
  whose project gets no case the next night still waits where the operator
  reads.
- **Shift end is a teardown with a caller — the explicit close action (§3,
  §10) — and it disposes every hosted desk.** The
  sequence is: stop the default tick and refuse the brief pipe → make a
  time-limited request to each live supervisor
  for a closing note **and, where the shift produced learning-shaped notes, a
  capture suggestion in the proposals doc** (spawn a worker to fold them into
  that project's
  `.agents/supervision.md` as a PR — §8) → render the final `account.md` →
  write the closing ledger line → dispose of each hosted desk by ending its
  session and
  deleting its scratch worktree. The capture suggestion outlives the desk that
  raised it: the proposals doc is a file in the shift directory, so the
  operator acts on it or drops it in the morning
  like everything else. Notes add context but are not required; a dead
  supervisor cannot
  block closing, and neither can three of them. All durable data already lives
  outside the desks. Desks accumulated in the old system because nothing
  initiated cleanup. Here, the same operator action that ends the shift disposes
  of every hosted desk the night created — a count the ledger knows, so none
  can be missed. **An appointed supervisor outlives shifts.** Shift close
  requests its closing note like any other supervisor's, and then leaves it
  alone: the session is the operator's own conversation, and disposal is not
  TBD's to perform. The binding and the installed conduct layer persist
  across shifts until the operator relieves them (below).
- **A daemon restart during a shift resumes it, never forks it.** The active
  shift is derivable from the record alone: the newest shift whose ledger has
  no closing line. On startup the daemon resumes that shift in whatever
  posture the switch persists — running if on, paused if off — with the same
  ID, same directory, same desks, which are ordinary sessions and survive the
  daemon, and runs the overdue-observation scan (§7, §12). A half-finished
  teardown resumes idempotently from its durable steps. Only when no unclosed
  shift exists does turning supervision on open a new one.
- **Each shift starts a hosted desk fresh on purpose.** No resumed desk
  context. Continuity lives in artifacts: the playbook, the operator's
  selections, and earlier ledgers. The *system* learns; one session's context
  does not. An appointed supervisor is the deliberate exception, and carrying
  context across shifts is the point of choosing one: the operator appointed
  it for what it knows, and owns that trade. If a hosted desk dies during a
  shift, the daemon writes an anomaly line, creates a replacement for that
  project in the same shift, and briefs it with its project's account so far;
  a dead appointed supervisor is never replaced — the fork the dead-man's
  switch section below states in full.
- **Closed is meaningful**: after the close, no shift exists, no hosted desk
  survives, and the shift's residue is fully on disk. Off without close is a
  pause and renders as one; closed is the clean zero state — an appointed
  supervisor still exists, because it always existed: it is an ordinary
  session with a binding, not shift residue. There is no
  in-between the record cannot name.

### Appointment: an operator-chosen supervisor

The hosted desk is the shipped default, not the only arrangement. An operator
may **appoint** an existing TBD-managed session as a project's supervisor —
typically a session chosen precisely for the context it already carries. The
binding is a per-project selection: the `supervisors` entry in
`supervision.json` (§8) plus the operator gesture that makes it
(`tbd supervise appoint`, §10). Appointment and relief each write a lifecycle
ledger line. One supervisor binding exists per project — the
one-supervisor-per-project invariant (§5), of which one-hosted-desk-per-project
is the default case — and while a binding stands, the hosted default stands
down for that project: no hosted desk is spawned, and every briefing goes to
the appointed session. When the operator relieves the supervisor, the hosted
default resumes lazily on the next briefing need, exactly as if the project
had never been bound.

**Appointment is an operation, not a registry write.** TBD performs it: the
session's process is relaunched in place, resuming the same conversation —
nothing is lost — with the project's playbook added as a standing conduct
layer and `TBD_PROJECT` injected into the relaunch environment (§5). It is a
spawn-equivalent moment, so an appointed supervisor gets the *same* identity
and conduct mechanics as a hosted desk: the same ambient addressing, the same
standing layer, the same briefing header, the same daemon-written record. No
weaker registry-declaration mode exists — a session either goes through the
relaunch and holds the full mechanics, or it is not a supervisor. The
operation waits for the session to be idle, and it is visible: the pane
restarts — a flicker at an idle moment — which is the honest cost of a real
relaunch. **Release is the symmetric operation**: the same idle-waiting
resume, without the layer and without `TBD_PROJECT`, returning the session to
ordinary life with its conversation intact.

**One mechanism serves every conduct moment.** Resuming a session's process
in place with a changed standing layer and environment is the same mechanism
as the conduct reload that re-baselines a desk after a mid-shift playbook
edit (sweep-program sub-document §8) — and desk spawn is its fresh-start
case, the same layer installed at first launch. Appointment is the reload with
the
layer added and identity injected; relief is the reload with both removed; a
playbook edit is the reload with the layer's value refreshed. There is one
mechanism, and every adapter that can run a supervisor
must have it — which is the next paragraph.

**Supervisor capability is a named per-adapter qualification.** An agent kind
can run a supervisor — hosted or appointed — only when its adapter provides
four things:

- **standing-layer install at (re)launch** — the playbook delivered as a
  standing instruction layer, at spawn and at every resume (sweep-program
  sub-document §8);
- **resume without conversation loss** — relaunching the session's process
  into the same conversation, which appointment, relief, and the conduct
  reload all are;
- **briefing delivery** — a delivery adapter the daemon can push briefings
  through (§12);
- **CLI reachability for the verbs** — the session can call
  `tbd supervise drive|wake|pause|note` (§3).

The Claude Code adapter qualifies today; the Codex adapter qualifies when it
lands. Appointing a session of any other kind is refused at the gesture, with
the reason. Version floors and the per-harness mechanics live with the
adapter facts in the sweep-program sub-document's dated note (§13). The
consequence worth stating twice: there is exactly one conduct-delivery
story — the standing layer — because an agent kind that cannot carry one
cannot be a supervisor at all.

**The layer is installed, never exclusive.** An appointed session stands on
the playbook layer *and* whatever context and instructions it already
carried — which is the point of appointing it: it was chosen for what it
knows. TBD guarantees the layer is present; it never guarantees the layer is
alone. An operator who wants a supervisor with nothing else in its head wants
the hosted default.

**A dangling binding is a loud state, never a silent takeover.** The bound
session hibernating, being archived, or disappearing outright is a state TBD
sees directly in its own records. It writes the anomaly loudly and raises the
operator notification — and the hosted default does *not* silently step in:
the operator chose the supervisor, and TBD does not unchoose it. The
resolution is the operator's relieve gesture, after which the hosted default
resumes lazily as above.

**The strange loop is expressible.** Appointing a fleet agent as its own
project's supervisor — a session receiving briefings about the project it
works in, itself included — is a configuration the gestures can express, and
TBD does not refuse it: refusal would be intent-guessing, and the operator
who makes this binding keeps both pieces.

### Supervisor context recycling

A desk runs all night, receives briefings, and reads transcripts, so its
context grows fast. The machinery in this section — thresholds, flush
nudges, fullness-triggered recycling — is **hosted-desk self-maintenance**:
a hosted desk is disposable by construction, which is what makes tearing one
down and respawning it a non-event. An appointed supervisor is the operator's
own conversation, which TBD never tears down or restarts on its own (the
dead-man's section below carries the same line for liveness); its context is
managed the way the operator manages any of their sessions, with
auto-compaction bearing survival there as everywhere. Two mechanisms manage
a hosted desk's context, and their
relationship is deliberate: **auto-compaction bears survival; deliberate
recycling is an optimization.** Inverting that — treating auto-compaction as
the expensive path and making the recycle machinery the thing standing between
a desk and its context ceiling — would make recycling load-bearing: if it
failed to fire, the desk would die at the ceiling, which is exactly how the
desk that reviewed this design came to exist, spawned by hand from a
predecessor that hit 200k mid-shift. So auto-compaction stays on for desks and
is the guarantee: a desk
can never hard-die from context alone, and what compaction loses is
acceptable by this design's own doctrine, because everything durable is
externalized as it happens (ledger, notes, account, routed questions). **A desk's
handoff document already exists — it is the shift record.** Recycling is
preferred whenever it can run — a fresh desk with a clean briefing reasons
better and costs less per turn than a compacted one — but nothing breaks if
it never fires.

**The context machinery is a capability, not a dependency — a desk must work
without it.** Both of its inputs are specific to the agent kind running the
desk: the fullness number reads a Claude transcript's usage records, and the
window size rides a Claude statusline tee (§2). A desk driven by an agent
that exposes neither — a Codex-driven desk, today — runs with no thresholds,
no flush nudges, and no fullness-triggered recycle, and nothing above breaks,
because survival never rested on this machinery. The layers that must hold
for every desk kind read the record, not the session's internals: the
dead-man's switch watches briefings and ledger lines, and hosted-desk
replacement
briefs from the shift record, so both hold unchanged. Such a desk simply runs
until the shift closes or the dead-man's switch fires — replacement for a
hosted desk, the operator notification for an appointed supervisor (below) —
and the account
shows its context as unknown rather than guessed.

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
2. **Hold** — the daemon stops delivering briefings to *that* desk. New
   submissions for it wait; case detection keeps running; other projects' desks are unaffected;
   the fleet stays watched. The recycle waits until that supervisor is idle with
   no case in flight.
3. **Flush** — the final flush nudge, if the staged ones have not already
   emptied the desk's head. If the supervisor is wedged, the recycle proceeds
   without it — that is exactly the crash path, which was already designed to
   be survivable.
4. **Recycle** — tear down that desk's session, spawn fresh into the same shift
   and the same project (spawning installs its one playbook as standing
   conduct), and deliver the standard replacement briefing (the
   active mode, that project's account so far) **plus the predecessor's
   transcript path**. Anything that lived
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
("3:12 a.m. — acme-web desk recycled at 261k context, 4 notes flushed"),
never as a question to anyone. If a recycle ever loses something that mattered, that
is an artifact-externalization bug to fix — the answer is "that should have
been in the record," never "a human should have approved the recycle."

### Desk liveness: the dead-man's switch

Context is not the only way a desk fails, and field experience supplied the
receipt: a desk can stall on its own question, wedge mid-turn, or sit silent
with cases queued — failing exactly like the agents it exists to catch, and an
anomaly line addressed to an operator who is asleep is no answer. So the desk
does not go without a liveness contract, and the contract is compiled.

**The switch triggers on an unanswered briefing, never on idleness.** A desk
is *supposed* to be idle most of the night; it is event-woken, not polling —
rerolling any desk idle for an hour would churn healthy quiet desks for
nothing. The meaningful silence is a briefing delivered at time T with **no
ledger line from that desk** by T plus the deadline (§13) — no drive, wake,
pause, or note. Every desk act is already a daemon-written ledger
line, so ledger silence *is* unresponsiveness, and no new observation channel
is needed. The second arm bounds the working state: a desk `working`
continuously past the same deadline with nothing ledgered. Whether it is
wedged or merely lost in thought stops mattering at the deadline — a desk
holds cases, a case unanswered for an hour is the failure the switch exists to
catch. Both arms are the
P1-6 pattern generalized: every message the daemon sends anyone arms a
deadline; only the clock differs. **Detection is one story for both
supervisor arrangements** — the switch watches the record, not the session's
internals, so a hosted desk and an appointed supervisor go dark by exactly the
same measure. What firing *does* forks by ownership.

**For a hosted desk, firing means replacement, not reporting.** Replacement
costs a briefing, not work state. Anomaly line, then the
replacement path above with the flush skipped — the desk is by definition not
answering — and queued and unanswered cases redeliver to the successor. A
lifecycle line links the sessions, as with any recycle.

**For an appointed supervisor, firing means the operator notification, and
never more.** TBD does not dispose of, restart, or spawn over the operator's
own conversation — the session was chosen by a human, and remediation of it
belongs to that human. The anomaly line and the notification are the whole
compiled response; the binding stands, the project's cases hold, and the
hosted default does not step in (a dark supervisor is not a relieved one —
the dangling-binding rule above). A compiled resume-nudge for a dark
appointed supervisor is deliberately not built (§15).

**The reroll budget bounds the loop.** If the briefing itself is what wedges
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
(§2), and its only fleet-facing use is informational: an account line or a
briefing may mention a parked session's context load, as input to judgment. And a
desk never runs its own succession: the primitives to self-replace exist in
the CLI, and the design's answer is that hosted-desk lifecycle — spawn, brief,
recycle, dispose — belongs to the daemon, and the supervisor binding to the
operator (§9's appoint and relieve gestures), full stop. The desk's whole
contribution to its own replacement is writing notes when asked.

## 10. Operator surfaces (intent, not screens)

Principle: **you take action where you already read the relevant information.**

- **The account panel shows the live account — one record, all projects.**
  The `account.md` renders beside the operator's work as things happen: acts
  with their outcomes, anomalies, notes, and each project's proposals doc
  linked beside them (§6). A desk's questions are not in it as a queue,
  because TBD holds no queue: questions go where the playbook routes them —
  a channel, an issue, a file the operator already reads (§8) — and the
  account's notes carry the pointers, so the panel tells the operator *that*
  a question is out and *where*, and the answer happens at the route, in the
  place their attention already lives.
- **A supervisor's tab stays a plain conversation.** Typed instructions are
  conversation. They steer the session but do not set policy. The two durable
  channels for rules are
  the playbook and its mode sections (§3); the chat is neither. If you type
  something conduct-shaped that should outlast the shift, it belongs in the
  playbook, and the desk may propose a capture PR that puts it there (§8).
- **Chat steers; the route remembers.** These are not two homes for the same
  answer, and the difference is worth being exact about. An answer written on
  the project's question route is durable and legible to the whole loop: the
  sweep program reads it and carries it into future briefings (§8), and it
  survives every desk recycle and shift close. Typing the same words into a
  desk's tab does neither: a hosted desk's context is disposable *by design*
  (it recycles mid-shift and starts fresh every shift, §9), and even an
  appointed supervisor's compacts on a schedule nobody chose, so a chat-only
  answer evaporates on a schedule the operator cannot see — and the desk may
  not exist when the answer is given at all, since questions are often
  answered in the morning, after every hosted desk was disposed. The shipped
  playbook closes the loop from the desk's side (§5): a desk told something
  in chat acts on it, writes the answer to the route, and says so with a
  `note`. One honesty boundary rides with this: a desk's transcription of a
  chat answer is the desk's report, and the compiled record attests acts
  only (§8) — consent never becomes a record claim, because there is no
  record kind that could carry one.
- **Attending the desk live is trivial, and no gate is missed in making it
  so.** With no proposal conversion, watching a desk work is just
  reading its tab and its account: you see what it did the instant the ledger
  line lands, and if you want it to do something you type it. There is no
  double-consent problem — no state where an operator has told a desk one thing
  in chat while a queued proposal says another — because chat steers and the
  record is written by the daemon either way (above).
- **The operator surface for v1 is `supervision.json` itself, plus the CLI.**
  The file is hand-editable by design (§8) — project topology, automation
  membership, mode selections, sweep selections — atomically rewritten after
  each CLI action and reloaded after a manual edit, and every control is a
  CLI command (`tbd supervise project ...`, `tbd supervise mode ...`,
  `tbd supervise automation ...`, `tbd supervise sweep ...`). App
  presentation of these selections is deliberately deferred to its own
  design pass; this document specs no screens for them. The account panel
  above is the one app surface this design leans on, and it is being built
  separately (P0-9).

  There is deliberately **no rules-inspection surface**, because there are no
  rules to inspect (§3). The question it existed to answer — "why did the daemon
  do that on its own?" — is answered better by the account: every action line
  carries the mode it ran under and the state snapshot that justified it.
- **Morning flow**: open TBD → open the last shift's account → follow its
  question pointers to the route and answer them in minutes (P0-10), with
  the desk's exact item, proposed command, and recommendation already there.
  An answer worth keeping past the shift is playbook material, and the
  capture flow is how it gets there (§8).

### The CLI surface (normative)

This is the complete `tbd supervise` surface. It is **normative for names
and shapes**: exact flag spellings may grow, command and subcommand names may
not drift. Everything the app can do appears here, because nothing exists only
as a button.

**Sweep-program surfaces — detection** (not desk verbs; a desk never sweeps,
§1). The sweep program's three commands, specified in the
[sweep-program sub-document](2026-08-01-fleet-supervision-sweep-program-design.md)
§3:

```
tbd supervise readout --project <name>               # read-only: live-agent facts + machinery state
tbd supervise brief   --project <name>               # briefing text on stdin; empty = quiet contact
tbd supervise ledger  --project <name> --since <t>   # read-only: TBD's own record for the project
```

`readout` and `ledger` print and change nothing. `brief` is how cases reach a
desk: composed briefing text on stdin, delivered under the compiled header
after the per-project rate limit, refused with a pinned exit code while
supervision is paused or no shift is open, and counted as liveness contact
either way (an empty submission is the attested "looked, found nothing").

**Desk verbs — acting** (execute, ledger line, 60-second re-check). None is
gated; each is addressed to the calling desk's project (§3, §5). Desk verbs
carry no identity flags: the calling desk's project rides ambiently from its
spawn environment (`TBD_PROJECT`, §5), and targets are checked against it —
which is also why the sweep-program surfaces above take an explicit
`--project`: their caller runs outside TBD's management and has no
spawn-injected identity.

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
tbd supervise note --text "…" [--ref <line-id>]
```

**Operator — the switch, the shift, and the modes.** Turning supervision on
opens a shift if none is open, and resumes the paused one otherwise; turning
it off pauses acting without closing anything (§3, §9). Closing the shift is
its own explicit action: it finalizes the account and disposes the hosted
desks, and with the switch still on a fresh shift opens in the same gesture
(§9).
Mode selection is per project and takes effect on the next briefing (§3).

```
tbd supervise on
tbd supervise off
tbd supervise shift close
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

**Operator — the supervisor binding** (§9).

```
tbd supervise appoint  <project> --terminal <id>
tbd supervise relieve <project>
```

`appoint` binds an existing TBD-managed session as the project's supervisor.
It is an operation, not a registry write (§9): refused with the reason unless
the session's agent kind holds the supervisor-capability qualification, it
waits for the session to be idle, then relaunches it resuming the same
conversation with the playbook layer installed and `TBD_PROJECT` injected.
`relieve` is the symmetric relaunch without either, restoring the hosted
default (lazily, on the next briefing need). Both write the binding into
`supervision.json` (§8) and append a lifecycle ledger line.

**Operator — automation membership** (§8).

```
tbd supervise automation default in|out
tbd supervise automation set <project> in|out|follow-default
tbd supervise automation list
```

**Operator — the sweep** (sub-document §4, §7).

```
tbd supervise sweep customize <project>   # copy the shipped program, write the pointer — once
```

**Deliberately absent**, each with its argument elsewhere in this document:

- **`learn`** — no machine-appended memory tier; same-shift memory is a `note`,
  cross-shift memory is a reviewed playbook PR (§8).
- **`escalate`, `queue`, `resolve`** — the compiled record attests acts only
  (§8). A desk that needs a human writes to the playbook-named question route
  and notes the pointer; the operator answers there; the sweep program
  carries answers into future briefings. There is no compiled queue to read
  or resolve, and the why-not — with the conditions for revisiting — is §8's
  rejected-alternatives pair.
- **`approve`** — the approval-stamp variant of the same descope: a verb
  writing operator-gesture consent into the ledger. Machinery with no
  consumer today; revisit on evidence (§8).
- **`intervene`, `send`, `answer --terminal`** — there is one send verb,
  `drive`. Answering is the send path rather than a verb of its own (§2), and
  text and keys are payload variants rather than two verbs, since a message is
  not the lighter act (§3).
- **`approve-a-prompt`** — no blanket auto-grant of permission prompts exists,
  and nothing restores one under another name (§2).
- **Per-desk lifecycle commands** (spawn, recycle, dispose) — hosted desks are
  daemon self-maintenance, born on their project's first case and disposed at
  shift close; there is nothing for an operator to drive (§9). `appoint` and
  `relieve` are not the exception: they select *who* supervises — a binding
  gesture, like `mode` — and drive no hosted desk's lifecycle.
- **Per-project on/off** — one switch, fleet-wide; "not this project" is an
  automation mark (§5, §8). Mode is per project, but mode is conduct, not
  lifecycle (§3).
- **Rules of any kind — allow, deny, approve-lists, prompt-approvals.** No verb
  is gated, so there is nothing to permit or forbid. The operator's controls are
  selection and visibility; the reasoning, and the bet it rests on, are in §3
  and §16.
- **`posture`** — there is no tri-state switch: supervision is on/off plus
  per-project mode selection (§3), so what a `posture attended` command would
  express is `tbd supervise on` plus `tbd supervise mode <project> attended`.

## 11. Capacity awareness (P1-1, decomposed)

- **P0 — never poke a rate-limited agent**: this requires no extra work because
  rate limiting is already session state.
- **P1 — fleet-wide hold**: several agents capped at once → hold interventions
  until the limit window resets. The daemon already has usage snapshots for
  each profile. Holds bind the desk verbs — the callers TBD runs. The
  [wake program](2026-07-26-fleet-supervision-wake-program.md) holds on its
  own: the same per-profile usage facts must be readable on a public surface
  (the API gap P1-1 names in the requirements doc), and the
  reference script honors them. TBD does not enforce holds against programs
  it does not run.
- **P2 or never — cross-account rebalancing**: not compiled, ever. It presumes
  a particular arrangement of multiple accounts and requires workflow
  judgment. If it exists, it must be a playbook instruction for a supervisor
  that already has the usage facts.

## 12. Delivery acknowledgement

**The record's claims form a ladder: requested, dispatched, landed.** The
action line is appended durably before the adapter runs, so it asserts
exactly one thing: the daemon accepted this verb and was about to dispatch
this payload at this moment. The adapter's synchronous return writes the
second rung as an outcome — *dispatched*; *refused*, a failed precondition
(§3); or *transport-failed* — and delivery is the third rung, a separate
observation recorded later by the re-check. Request-first ordering means no
crash window can produce a real intervention with no record: an act the
daemon performed is always preceded by its line, and a line whose act never
completed renders as unconfirmed, loudly, by the query-time rule below. The
send call cannot confirm delivery — one adapter pushes without an
acknowledgement, and the other can fail if a turn changes at the wrong
time — and the ledger must never claim more than the daemon observed (§6).
The field failure this guards against is real: `terminal.send` once reported
success into a dead pane for hours while a desk nudged it, and each of those
nudges would have stood in the ledger as delivered work. Waiting for more
failures before building the observation would wait forever: the class is
silent by definition, and that incident itself only surfaced because someone
eventually noticed the absence of any effect.

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
guardrail; both are the send path telling the truth about its own result. A
third class is known but deliberately unbuilt: text sent while a modal prompt
is on screen reaches the dialog rather than the composer, keystrokes becoming
accidental answers. The sentinel already detects the aftermath — a swallowed
payload never reaches the transcript — and no field failure has yet shown the
race itself biting; if one does, the fix joins this family (the send path
refusing when the composer is unreachable) and stays content-blind.

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
  stop and write an anomaly line, loud in the account — two silent failures
  indicate a structural problem with the session, and a third send without
  evidence would risk duplicate-message bugs.
- *Undetermined* — the observation could not be made: transcript unreadable,
  session state unknown, adapter result ambiguous. **Never retried.** Written
  as an outcome and an anomaly, loud in the account. Retry proceeds only from
  *not landed*, because retrying into uncertainty risks double-instructing an
  agent that did receive the first copy — and a message to an agent running
  with permissions bypassed is arbitrary instruction injection (§3), so
  delivering it twice is not a neutral event.

**No confirming outcome means not-delivered, at query time.** The account
computes delivery status as the join of action and outcome: an action past its
acknowledgement deadline with no confirming outcome renders as unconfirmed,
as loudly as an anomaly. This is the fail-closed rule applied to delivery —
never default to "landed," the way the wake verifier never defaulted to
DONE — and it keeps every rung of the ladder honest: *requested* on the
daemon's word, *dispatched* on the adapter's return, *landed* only on a
machine observation. Because the rule lives in the query rather than in an
appended repair, a mid-shift daemon restart cannot corrupt the record: an
action whose observation never ran renders as unconfirmed by construction
(§7). The observation itself is recoverable from the record alone — the
action line's timestamp fixes the deadline, and the envelope is durable in
the transcript — so at startup the daemon replays the ledger, finds actions
past their deadline with no outcome, and performs the same observation late,
writing the outcome the timer would have written (§7). What a restart costs
is cadence, stated plainly: P1-6's sixty-second window degrades to the
startup scan or the next evaluation. What to *do* about a late-confirmed or
unconfirmed act — re-drive, note, shrug — stays playbook judgment, never
compiled repair.

### Delivery adapters: parity for the fleet, a channel for the desks

Which adapter a session can be reached by is itself a per-session fact, with
the same source-and-freshness treatment as any other fact.

**Fleet agents: `terminal.send` (paste + submit), the mechanism that exists
today.** This is the parity choice, and for much of the fleet it is
permanent: older agent versions and future agent kinds may never offer a
message channel, so typing is the floor that delivery stands on when nothing
better exists. Claude Code's research-preview Channels interface was
validated as a prototype
(`docs/research/2026-07-26-claude-code-channels/findings.md`, landed on
`main` separately): it delivers a message without touching the composer, but
it needs agent-side setup and an interactive consent prompt at session
start, so it cannot be assumed for fleet sessions.

Typing carries one known risk, and this design names it rather than waving
it off. If a human has typed something into an agent's composer and not yet
pressed enter, a paste-and-submit delivery sends the human's unsent text
together with the desk's message, as one submitted message *from the human* —
words they never sent, into an agent that acts without asking. A message
channel makes this impossible by construction; typing cannot. Three things
limit how often it happens: supervision only messages stuck-or-idle sessions,
the pause switch stops all delivery while the operator works, and the
subsystem ships behind a default-off flag. None of the three protects the
specific session a human is typing in — that protection, a per-session
never-touch flag, is deferred to its own design pass (§15). The risk is
stated as real and bounded, not theoretical, because TBD has lived this
failure class before: automatic hibernation once ate typed input and had to
be force-disabled by migration.

**Desks alone: channel-first, with a verified fallback.** A desk's process
launch is TBD's own act — TBD spawns the hosted desk and owns its
configuration, and the appointment relaunch is the same spawn-equivalent
moment (§9) — so the no-cooperation constraint does not apply, and desks are
also the
only sessions where a human and the daemon share a composer, which is exactly
where draft-safe delivery pays. **At every desk spawn — the appointment
relaunch included** — the daemon performs a
**handshake**: emit a channel ping, then read that desk's transcript for the
channel envelope. Confirmed → the channel is that desk's adapter. Not
confirmed (consent declined, feature removed, registration silently failed) →
`terminal.send` for that desk's lifetime, with one anomaly line noting degraded
delivery. The handshake is per desk rather than per shift because desks are
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
(`<channel source kind>`), so briefings and follow-ups are attributable and
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
across N cycles, which the git sweep already knows. Each threshold is a named
constant in the shipped sweep program
([sweep-program sub-document](2026-08-01-fleet-supervision-sweep-program-design.md)
§7): tuning is taking the customize copy and editing a constant in a file the
project then owns. Numeric tuning has no home in
`supervision.json` (§8 holds topology and selection, not parameters) and never
becomes a repo-table column — program placement preserves §7's one-column
property permanently.

Crossing a threshold does not itself cause an action. The sweep program
briefs the case — a fact line in the next briefing such as
"agent Y: 31 turns, no commits in 90 minutes." The
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
| Idle-intervention threshold | 40 min | shipped sweep program (sub-doc §7) |
| Post-intervention re-check | 60 s | §4 step 7, §12 |
| Delivery retries before anomaly | 2 sends | §12 |
| Supervisor recycle preference | 50% of the effective window, per desk | §9 |
| Flush nudges | 50% / 60% / 70% fullness | §9 |
| Unknown-denominator assumption | 200k, labeled | §2, §9 |
| Dead-man deadline (briefing unanswered) | 60 min | §9 |
| Reroll budget | 2 consecutive stalled desks per project | §9 |
| Per-project briefing rate limit | 1 briefing / 2 min | sub-doc §3, §10 |
| Paused-refusal exit code (`brief`) | 75 | sub-doc §3, §10 |
| Runaway: turns in window | 30 turns | shipped sweep program (sub-doc §7) |
| Runaway: no-progress window | 90 min with no commits | shipped sweep program (sub-doc §7) |
| Heartbeat staleness | 10 min | §14 |

**All of these are compiled constants at parity — except the rows marked as
shipped-program constants, which ship in the reference sweep program — and none
is a config column.** That
preserves §7's one-column property, which is a real property of the design and
not an accounting convenience: the moment numbers become columns, "where is this
system's state?" stops having a one-line answer. If real shifts prove a number
wrong, promoting that one number to a config column is a conscious change to
§7, argued on its own merits — the same stance taken toward per-repo threshold
overrides (§15).

## 14. Out-of-band heartbeat (P3-1)

On a fixed cadence of its own, the daemon writes a small `status.json` file in
the shift directory. It contains whether supervision is on, each project's
active mode, and each project's last sweep contact. The watchdog is an
optional `launchd` job with one rule: *if a shift claims to be active and the
status file has not changed in about 10 minutes, raise a notification.* It
reads a file instead of the socket or DB, so a dead daemon cannot make the
watchdog unavailable. The watchdog never acts on the fleet. It can only alert
the operator; it cannot pretend to be the supervisor. A down daemon therefore
means silence plus an alarm. This applies the rule that uncertainty must lead
to inaction at the largest scale.

## 15. Deliberately not built

- **A structured proposal pipeline** — a `proposal` ledger kind, approve and
  reject machinery, and an execution path for approvals. Not built, because a
  proposal is judgment, not a fact: the ledger exists to stop false claims
  about what *happened*, and a suggestion cannot be a false claim. Proposals
  are desk-authored prose in a per-project markdown doc (§6), composed to the
  project's own conventions — which is also the shape that worked in
  practice: the predecessor system's for-the-human file was its best-liked
  surface. Deleting the pipeline also deletes its hardest question — who
  executes an approval hours later, after the desks are gone — because acting
  on a suggestion is a human act in the world, not a state transition.
- **Per-session never-touch designations** — deferred to its own design pass,
  not folded into this one. "Don't poke *this* session" is a per-object
  control surface with its own open questions — which object carries the flag
  (terminal or worktree), how an operator discovers it exists, whether it
  expires when they walk away — and answering them as a side effect here
  would shortchange them. Until it lands, the operator's protections are the
  pause switch, project membership marks, and supervision's stuck-or-idle
  targeting; the actuation preconditions (§3) are the seam the flag binds to
  when it arrives.
- **Arbitrary endpoints as supervisors** — binding a project's briefings to
  a chat surface, a webhook, or any other endpoint TBD cannot drive as a
  session. Rejected because the supervisor role's guarantees are exactly the
  four supervisor-capability requirements (§9) — standing conduct installed
  at every (re)launch, resume without conversation loss, briefing delivery,
  and CLI reachability for the verbs — and each of them presumes a harness
  TBD can relaunch. An endpoint that cannot be relaunched could only be
  supported through a weaker registry-declaration mode — a binding with no
  installed conduct and no injected identity — and this design refuses to
  have one: a supervisor that merely *received* briefings, on unknown
  conduct, with unattributable verbs, would hollow out every property §5, §8,
  and §9 establish.
- **A resume-nudge for dark appointed supervisors** — TBD resuming or nudging
  an appointed supervisor that missed its dead-man deadline. Not built: the
  session is the operator's own conversation, and the compiled response to
  its silence is the anomaly line plus the operator notification, never an
  automatic restart (§9). Revisit on field evidence — the failure signature
  is appointed supervisors repeatedly going dark mid-shift with the
  notification arriving too late to matter, in the record, more than once.
- **A verdict enum / work-arc schema** — interpretations of work differ by
  repository, team, and person. A compiled classification would recreate the
  old system's defect. Stated as a principle in §2: TBD has no theory of
  work — every project authors one.
- **An intent column in the state model** — the operator ask behind it is real
  (an escalation should be judged against the goal, not the symptom, and intent
  has been proposed as a fourth §2 column), but a stored "what this agent
  is for" would put a theory of work back in the compiled tier under a new
  name. Intent is authored and carried by the agent's own materials — the
  transcript's opening assignment above all — and the enrollment line's
  transcript pointer (§6) gives judgment one-hop access to it, by reference.
  A per-desk transcript-replay store is a judgment-tier read optimization: if
  it exists, it enters as an advisory tool under the outside-first ratchet,
  never as daemon machinery.
- **A permission-posture fact in the state model** — field measurement showed
  the real difference: the same `drive --text` is a suggestion behind a
  checkpoint into a session that still asks, and the last checkpoint itself
  into one running with permissions bypassed. The design answers with conduct
  rather than a fact: the playbook's assume-unchecked rule (§5) makes the two
  targets indistinguishable from the desk's side, so posture never justifies
  an act — and a fact nothing consumes fails §2's add-nothing test. Reading a
  target's settings to predict whether a given command would be gated is
  rejected outright: it re-implements the agent's permission-resolution
  engine and drifts silently — the compiled window table's mistake in new
  clothes. If experience produces a morning that genuinely turns on "did
  anything stand between the nudge and the consequence," the ground truth is
  the target's transcript, and a compiled fact has a ready machine source:
  hook payloads carry `permission_mode` on most events TBD already consumes
  (though not on `Notification`, and not in the statusline JSON). Recorded
  here so a revisit starts from the source, not the search.
- **The verb gate, and rules of every kind** — allow rules, deny rules, posture
  consulted per call, consequential verbs converted into proposals. Refused in
  full as over-engineering: it is machinery for a failure mode these models are
  not expected to exhibit, and TBD declines to build a second anti-injection
  layer on top of models already resistant to injection. What TBD does build
  around a verb — the daemon-written ledger line, the one-minute re-check — is
  accounting, and earns its place in a system with no rules at all. Send-time
  re-verification is refused on its own grounds too (next bullet). The bet this
  rests on is named in §3 and revisited in §16.
- **Compiled send-time re-verification for desk messages** — the daemon
  checking every external claim in a `drive --text` against live sources, with a
  stale premise stopping the send. Three reasons against. **Its owner would be
  invented rather than extracted**: the running system never compiled this
  check — it lived in authored content the desk executed itself (the old
  `wake.py` re-deriving truth at wake time, the playbook's "re-read live state
  in the same breath as the send"), and that discipline is what actually fixed
  the failures P0-8 cites. **It is not implementable as stated**: compiled code
  cannot find "every external claim" in free prose without a model, so either
  the desk declares its claims on the call — covering only what it chose to
  declare, which is no stronger than conduct — or the daemon parses prose, which
  is judgment at the wrong layer. **And it is the same knife as the verb gate
  and the wake rails**: a compiled interposition between a desk's judgment and
  its act, machinery for the careless desk §3's trust bet declines to build for.
  What stands instead is conduct (§5's freshness universal) plus visibility (the
  verbatim ledger line, §6), and one small compiled obligation — display-tier
  honesty for the persisted `PRStatus` (§2). The full argument, the field
  evidence that a faithful re-verification can still be lied to by its source,
  and the failure signature that would justify building it are in P0-8
  (requirements doc); the transient per-source reliability findings live as a
  dated note in the reference wake script, where they can rot without touching
  this document
  ([wake-program sub-document](2026-07-26-fleet-supervision-wake-program.md)).
- **Per-mode playbook files** — a project's modes are described in its one
  playbook (§3, §5), so a reader sees every posture a project can take in one
  place. Splitting them across files would also invite the reader to imagine the
  daemon choosing between them; it chooses nothing.
- **The act-with-veto-window human-in-the-loop (HITL) variant** — rejected on
  the grounds that a missed veto allows an action nobody approved. It has
  nothing to attach to here in any case: no verb is converted into a proposal
  that a window could sit in front of (§3).
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
- **Per-repo threshold configuration** — no configuration surface exists or is
  deferred: thresholds are named constants in the shipped sweep program, so
  tuning is taking the customize copy and editing a file the project owns.
  Numbers have no home in `supervision.json`
  and never become repo-table columns, preserving the one-column property
  (§7). See §13 and the
  [sweep-program sub-document](2026-08-01-fleet-supervision-sweep-program-design.md).
- **A supervisor patrol loop** — the daemon drives the loop and wakes the
  judgment layer with briefings. See §16 for the cost of this choice.
- **A compiled case-cutting sweep for live agents** — the daemon evaluating
  thresholds and cutting cases itself. What facts mean is authored theory of
  work, and when to look is authored theory of attention; both live in the
  project's sweep program, which runs against the brief pipe and its
  liveness watchdog, with the mechanical not-to-act checks sitting in the
  verbs' own preconditions (§3). The intermediate shapes — a daemon-invoked
  decision script, a
  fully external sweep with no liveness contract, a compiled baseline with an
  authored overlay, a structured evaluation report or agent-list manifest at
  the pipe, a separate renderer hook, compiled open-case dedup — are rejected
  in the
  [sweep-program sub-document](2026-08-01-fleet-supervision-sweep-program-design.md)
  §11.
- **A compiled escalation queue, and the approval-stamp verb** — escalations
  and resolutions as ledger kinds behind an operator-only resolve gesture, or
  the one-verb variant stamping operator consent into the record. Both
  rejected — the record attests acts only; questions ride the playbook-named
  route and answers are the sweep program's memory — with the full rationale
  and the revisit signatures in §8.
- **An advance liveness check before creating a case** — checking the target
  pane's live process at case-creation time buys nothing, because the check
  is stale by the time a desk acts minutes later. The act-time checks are
  the ones that cannot be stale: the transport verifies pane liveness and
  session identity synchronously at the send (§12), and the state model's
  liveness detector already reports gone agents. The one thing an advance
  check would prevent is a rare phantom case — a session that dies silently
  can wake a desk whose send then fails as a recorded transport error — and
  that cost (one desk wake, a few thousand tokens, a self-announcing ending)
  is accepted. A process check also cannot arbitrate among live states:
  working, idle, and awaiting input look identical from outside, so activity
  distinctions ride hook events and their observed-at, full stop.
- **A compiled wake gate for parked sessions** — not built, because field
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
- **Actuation rails for the wake program** — a compiled choke point (capacity
  holds, in-flight dedup, send-time freshness, a daemon-written ledger line)
  that every wake would pass through. Not built: TBD does not guarantee
  or guardrail a program it does not run and cannot repair. The program's
  inputs and actuation are public surfaces (Built/Enabled split, requirements
  doc); the rails are the program's to honor, and the reference script honors
  all of them.
- **A machine-appended learnings file** (and the `learn` verb and `learning`
  ledger kind that fed it) — a per-project `learnings.md` the desk could append
  to, carried into every future briefing, taking effect with no review. Not
  built, because it bridges two needs that existing machinery serves better:
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
  instruction injection (§3). Identical semantics, one verb. The collapse costs
  nothing: with no rules to scope, a mode's
  conduct prose draws whatever distinction a project wants — "answer questions
  freely, nudge sparingly" is one sentence. See §2, §3.
- **A per-project prompt-approval layer** — no matcher, no allowlist, no
  auto-grant, no table of prompts TBD says yes to. Answering a permission prompt
  is an ad hoc judgment act through `drive`, and nothing about it accumulates.
  Recurrence is a signal to fix the repo's own permission config, not a workload
  to automate. See §2.
- **Per-project shifts, switches, or ledgers** — the project is the unit of
  judgment and conduct, not of lifecycle. One on/off switch keeps P0-2's
  one-gesture handover; one shift, ledger, and account keep every
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
- **DB tables for the ledger or its views** — every view over the record is a
  query of the shift's JSONL ledger, rebuilt from the file at startup.
  Supervision adds one column to the database.
- **A supervisor-authored account** — the record produces the summary. The
  supervisor can add context through attributed notes but cannot author the
  account.
- **Fleet-agent context management** — auto-compaction is fine for fleet
  sessions. No handoff templates, recycle flags, or compaction counters for
  agents; the context fact is informational only (§2, §9). Deliberate
  recycling exists solely for the supervisor's own session (§9).
- **A compiled model → window-size table** — refused, because the effective
  window is a session fact, not a model fact:
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
reactive. They reason only about cases their project's sweep program surfaces
from the compiled facts — idle agents, blocked agents, counters past
thresholds. Anything the facts cannot describe, or the program was not written
to notice, never reaches a judgment layer. Three agents failing in
the same way for the same system-wide reason may arrive as three separate cases,
or may not arrive at all. A pattern that develops across the night has no path
into a briefing. A more expensive patrolling supervisor might notice such a
pattern precisely because it was looking without being told what to find.

Per-project desks (§5) sharpen this criticism rather than softening it, and the
trade should be stated in both directions. What the grouping *solved* was
policy mixing: a desk cannot apply one project's playbook to another
project's agent, because it never holds another's — a defect a single
fleet-wide desk could only call survivable and defend with careful labeling.
What the grouping
*cost* is the last vantage point that spanned everything. Three agents failing
identically in three different projects are now three cases in three desks, none
of which can see the other two, and no amount of reasoning inside any one of
them can recover the pattern. Only two things still span projects: the compiled
fact store, which measures but does not interpret, and the operator reading one
account in the morning. The design has traded a cross-project view that was
never reliable for an isolation guarantee that is.

The design makes the system affordable (P0-6) by limiting its only reasoning
components to the facts that compiled code measures. If that
limit is too restrictive, operators will ask, "Why didn't anyone notice X
overnight?" The place to address that problem is the same deferred escape valve
as before: a periodic, low-frequency digest briefing presenting a fleet-wide
summary as a case once every N cycles. Under the grouping it wants one
adjustment — it should be a **short-lived fleet-level judgment context** that
reads the account, says what it sees, and exits, rather than a resident desk
with fleet-wide standing. A transient reader breaks no invariant: it holds no
project's policy because it is not deciding any project's action, and it gets
no verbs. That keeps "one supervisor per policy" intact while restoring the view.
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
verb gate would not have caught most of that either (it could forbid
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

- **Cold start.** Conservative defaults and attended conduct make the first
  few nights heavy on questions. The system becomes more useful only as
  playbook refinements and the project's recorded answers accumulate. An
  operator who does not make that
  investment will see the same questions repeat and may decide the subsystem
  is useless. The old system worked on the first night *for its one team* because
  its policy was built into the product. Supporting different teams introduces
  a training cost for each operator. The design assumes answering will be
  cheap enough because questions arrive where the operator already reads —
  the playbook-named route — with the desk's exact item, proposed command,
  and recommendation attached. Training should therefore happen during
  normal use.
- **Safe-and-useless is a quiet failure mode.** The system is designed to be
  honest about uncertainty. If the event pipeline breaks down, the night will
  contain many unknown states and the system will correctly do nothing.
  Anomaly lines call this out in the account. Even so, a broken sensor layer can
  look like an empty, calm night. Distinguishing "nothing happened" from
  "nothing was seen" requires reading the anomaly section. The account renderer
  should make nights with many unknown states visually unmistakable. The
  [wake program](2026-07-26-fleet-supervision-wake-program.md) sits past the
  process boundary, and by the outside-first rule TBD does not track its
  liveness: the program self-monitors, and a dead or never-installed wake
  program renders in the account exactly like the legitimate no-program
  default — parked facts, no wakes. That ambiguity is accepted deliberately,
  eyes open: it is this failure mode's sharpest instance, the sub-document
  names the author-side watchdog pattern that answers it, and the escape
  hatch if field use proves it insufficient is one file read (the account
  surfacing the program's own heartbeat age), added then.
