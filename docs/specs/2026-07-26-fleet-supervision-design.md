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
  versioned, or passed between supervisors.
- **The supervisor's reasoning** — only decisions that require reading text
  the fleet has just produced. These include choosing a context-aware
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
  in this design splits: "intervention already in flight" is transport
  serialization — a send queues behind one already mid-flight to the same
  target (§3) — and "re-check pending" is authored conduct, judged with the
  not-to-act facts the readout carries and the act record; open-case dedup
  across evaluations is the sweep program's own discipline in its own files
  (sub-document §7).
- **Per-repo policy** — authored, and resolved per **supervision project** (§5,
  §8): the playbook (advisory prose, including mode definitions) plus the
  operator's selections in `supervision.json`.
- **Mode enforcement (P0-3)** — **descoped** (§3). There is no enforcement: a
  mode is authored conduct, and what the daemon supplies is the record and the
  operator's selection of which mode is active.
- **The account** — attested facts plus an authored story: the actuation log
  and the supervision ledger are written by the daemon at the moment it acts;
  views are queries; the desk's narrative is the journal, displayed beside
  the facts and never matched to them (§6).
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
project has none (§5, §9). Delivering a briefing is the only thing
that ever starts a supervisor's turn (P0-6): a supervisor never polls or
sweeps on its own, and never writes state or history directly. The daemon,
for its part, never makes a judgment — it keeps the facts, paces the pipe,
delivers, records, and executes the public actuations behind mechanical
preconditions (§3); and it holds the sweep program to a
liveness contract, so a program that stops looking cannot impersonate a calm
night. Information flows in one direction: facts → sweep program → briefing
→ daemon → supervisor → send → daemon. Parked sessions never enter this
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
The send types. The fleet delivery adapter types (§12). The rate-limit actuator
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
which acts under a different discipline (the `--keys` send, below). Today exactly
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
situation, decides, and acts through the send, guided by its project's active
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
Folder trust is mostly pre-answered already: `ClaudeTrustSeeder` seeds
scratch spaces unconditionally and non-scratch worktrees whenever
`auto_trust_worktrees` is on (its default), excluding only `foreignHead`
checkouts — contents TBD declines to vouch for. What prong 2 inherits here
is the residue, not the feature: the `foreignHead` carve-out still renders
the dialog, and an operator who turns the setting off has chosen the prompt
deliberately. `ask`-rule prompts join the zoo as its one permission-shaped
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

**The screen-informed variant: the `--keys` send.** Not every stalled dialog is an
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
nothing to bite on here. **Evidence is the requirement instead**: the act's
actuation row records the screen capture the desk was looking at when it chose
those keys (§6). If a
sequence turns out to have been wrong, the record shows exactly what was on the
screen and exactly what was sent, which is the same accountability the
three-condition test buys for the automatic path, obtained a different way.
Sends are named-key and paced — one key at a time with a fixed pause between
them (§13), following the rate-limit actuator's precedent, because an agent's
TUI redraws between keystrokes and keys delivered back-to-back through the pty
get dropped or reordered. The count of keys in one payload is bounded too
(§13): `--keys` is a whitespace-split string, so a quoting mistake turns one
call into a send that types for minutes into a live session, and a bounded
refusal is cheap where an unbounded send is not undoable.
In attended mode the desk suggests such a send instead of making it — an entry
in the project's proposals doc (§6) showing the keys *and* the screen they aim
at, so saying yes is not an act of faith.

**This needs no verb of its own — it is the send with a text payload (§3).**
Answering a question is mechanically the send path this design already has:
log the actuation row, clear the way, deliver composer text, verify it
landed, re-check. Two
things about it look like they might warrant their own verb. Neither survives
contact.

The first is **the dismissal, which is a delivery-adapter concern rather than a
supervisory act.** *Any* send aimed at a session sitting on a dialog needs
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
send does not need to.** The actuation row's state snapshot *is* the pending
question (§6), so the record already says what was being answered, verbatim. A
question the desk carries to a human travels with that same verbatim payload,
for the same reason. Account views label these rows
as answers by reading the snapshot. A separate verb would have added a word to
the vocabulary and nothing to the record.

What the operator experiences is unchanged in substance. In attended mode the
desk relays the question — the agent's questions and options verbatim, plus
the proposed response and its reasoning — to wherever the playbook routes this
project's questions (§8), and the operator approves it or answers differently
themselves: the dialog, delivered at last to the human it was
always addressed to. Under a bolder mode the desk simply acts, and the daemon
logs its actuation row. The response need not be an answer at all:
"these options are underspecified — work through the tradeoffs and ask me again"
is a legitimate reply, and so is a redirect. Which one a question warrants is
playbook judgment (§5); the mechanism is the send either way.

*What collapsing it costs* is nearly nothing, and §15 records why. A rules-based
design would have made one verb mean one rule stance covering answers and
unprompted nudges alike. With no rules at all (§3), the distinction lives where
it belongs: a mode's conduct prose can tell a desk to answer questions freely and
nudge sparingly, in a sentence, without any vocabulary growing.

**How the question becomes a case.** The hook stays an unconditional dumb
reporter — no supervision check on the agent side, ever. It reports; the daemon
knows each project's coverage and already receives every event. The fork
lives in the daemon's
RPC handler: when the terminal's project is effectively on — its mark set
and the brake released (§3, §8) — a pending question becomes a case and is **delivered
immediately**, bypassing the sweep program entirely (sweep-program
sub-document §2): the trigger is a reported fact that needs no theory of
work, and the transcript is blind while the picker is open, so waiting for
anyone's next evaluation would waste the only live signal. This is the one
delivery TBD composes itself — deliberately minimal, **the question payload
verbatim out of the daemon's store** under the compiled header — where every
other briefing is the sweep program's prose. It goes to the desk that owns
the terminal's project (§5), spawned lazily if none exists, holding the same
one playbook, and the supervisor fetches
nothing — which dissolves the need for any new read surface. Nothing is
ledgered for the question itself; facts are not ledger lines. The question
snapshot rides in the send's actuation row as the state that justified it,
or travels verbatim in the question the desk routes to a human if the
supervisor punts (§8), with a journal entry pointing at where it went.

**Permission prompts reach a desk the same way.** The `Notification` event
(above) rides the identical pipeline: an unconditional dumb-reporter hook, the
daemon holding the fact, and — with the terminal's project effectively
on — a **case**, delivered immediately through the same compiled
carve-out. One pipeline, two
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
must never expire a still-live dialog: resolution comes from
the transcript's `tool_result` record, not from elapsed time — and measured
behavior says that record arrives on every resolution path: answer, Escape,
even a tool denied by a hook (findings doc, §2 above). No hook event closes a
dismissed dialog, so any store keyed on hook events alone would strand an
entry on the single most common user gesture; the transcript record is the
closing signal, and the GC covers only what measurement has not. The store staying memory-only is
fine under §7's restart rule. A daemon restart degrades honestly —
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
   a text send — today that is `AskUserQuestion` and nothing else. Everything
   that fails the test still becomes a case, by the `Notification` event that
   reports it: it is never *automatically* advanced, and it reaches a desk, which
   escalates it or judges it and acts with a keys send. A firing `ask` rule
   lands here, and no compiled grant list ever answers it — see the
   no-approval-layer ruling above.

The story's "never past anything else" clause is then enforced *structurally*
rather than by an allowlist's precision — and the structure is the absence of an
approval layer, not the absence of an actuator. Nothing TBD compiles ever decides
that a class of prompts may be granted; there is no list to be wrong, because
there is no list. What can advance a prompt is a judgment, made once, about one
prompt, by a delegate operating under an authored mode and leaving a record. One
consequence for the rest of this document: the `approve-a-prompt` verb stays
absent (§3, §8), and nothing here restores it under another
name. `approve-a-prompt` was a blanket, model-free auto-grant — the tool deciding
in advance that a whole class of questions needed no human. The send decides
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
the send shares the typing with that machine, and nothing else. A field check
of that machine found `~/.fleet/` absent, no process running, and no
`launchd` job remaining.

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
capability wall between a desk and its acts: no allow rules, no deny rules, no
proposal conversion, no gate. The operator's controls are **selection** — is
supervision on, which mode each project runs, which projects are turned on — and **visibility**: every act is an actuation
row the moment it happens, and the account renders it beside you.

This is a bet, and §16 records it as one so a future operator who gets burned
knows exactly which paragraph to revisit. The models running these desks are
trusted to follow conduct instructions and are already resistant to prompt
injection; TBD declines to build a second anti-injection mechanism on top of
them. **There is no compiled verb gate** — no posture consulted on every call,
no standing allow and deny rules, no conversion of consequential sends into
proposals. That machinery would serve a failure mode the operator does not
expect these models to exhibit, and every line of it would be weight the design
carried for a hypothetical.

### The switch: supervision is on, or off (P0-2)

One configuration column in the daemon, on or off — added by migration and
**shipped off**, which is the house default-off-flag rule satisfied by the
switch itself: no second flag hides behind it, and the soak is opt-in
coverage. (Two §12 mechanisms carry default-off flags of their own beside
it: the delivery-verification re-check, which the public send offers every
caller and supervision only shares, and the Channels delivery adapter.)
Settable from the app and the
CLI, broadcast when it changes, surviving restart like every other daemon
toggle. That is P0-2's one-gesture handover for the whole fleet, unchanged in
substance: one gesture, one ledger, one account. The switch is
the fleet **brake**, and only that: supervising anything also takes the
per-project gesture (§8) — `tbd supervise on <project>` — because every
project starts off and there is no default stance. A fleet switched on with
no projects on supervises nothing, and `status` and the account must say so
loudly rather than render it as a calm night. The bare bit is ANDed over the
per-project marks and never writes them, so pulling the brake disturbs no
configuration and releasing it restores exactly the coverage that stood.

**`off` is not a mode; it is the pause of TBD's authority to act.** The
switch governs acting, and only acting: off stops the default tick from
launching new sweep runs and refuses briefings at the pipe with a distinct
machine-readable paused result (a run already in flight finishes inside its
timeout bound and its submission is refused; external programs are never
signaled — TBD stops only what TBD starts, sub-document §3, §4), and the
actuation preconditions (below) refuse identified supervisor sends
from that instant — a desk mid-thought when the switch flips can finish
thinking, and its send returns an ordinary error instead of touching
anything. Everything else continues: desks stay alive and idle, the
record keeps filling — enrollment and anomalies still land — and the
journal is a file needing no authority (§6), so a desk interrupted
mid-judgment can still write down what it was about to do. Watching
continues; touching stops. Flipping back on resumes the
same desks at full context: the daemon writes the release lifecycle line and
hastens the default tick, so briefings are composed from current state, never from
pre-pause state. Toggling is therefore cheap in both directions — which a
control must be for an operator to actually reach for it.

**There is nothing to close.** The record has no boundary gesture: the
ledger is continuous, views over it are windowed queries, and coverage
spans are the marks' own lifecycle lines (§6, §9). A fleet left braked for
a day renders loudly as exactly that, because a lingering state degrades to
loud display, never to autonomous cleanup.

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
sends becoming proposals, and escalations "batched for morning." The first is
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
- **Switching is legal at any time.** It takes effect on
  the next briefing, whose compiled header names the selection (the conduct
  itself stands in the desk's session layer, sub-document §8) — no desk
  recycle is needed. The switch writes a ledger line, and **every act's row
  records the mode it ran under** (§6), so the account can always answer
  "what conduct was this desk operating under when it did that?"

**What "attended" honestly promises now.** It instructs, and the system makes the
desk's work visible: the record is written as each act happens, and the
account panel sits open beside you. It does *not* enforce — nothing stops a desk
running `attended` from driving a session. P0-3 asked for a mode that could not
silently become autonomous; this design answers with immediacy and evidence
rather than a capability wall, and the requirements doc records that descope
(P0-3).

### Acting: one public send, on the record (normative)

There are no desk verbs. Acting on a session is **`tbd terminal send`** —
the public actuation, and the same one verb for every caller of it: a
human's script, the wake program, a sweep program's continuation policy,
the supervisor itself.
Payloads, not verbs: `--text` carries the message and `--submit` sends
it — text without `--submit` is typed and left standing in the composer,
so every delivery this design describes passes both (that pair is also how
an agent's `AskUserQuestion` is answered, the adapter clearing a
machine-known dialog first, §2); `--keys` sends named keys chosen after
reading the screen; interrupt is a keys payload. Splitting text from keys
would encode a safety boundary that does not exist — a message to an agent
running with permissions bypassed is arbitrary instruction injection — and
answering is not its own verb either: answering *is* the send path (§2).
The daemon does not read a text payload: **freshness is conduct, not
machinery** — the shipped playbook's universal says to derive the facts
live, in the same breath as the send (§5) — and the log records the
message verbatim, so a stale premise is *visible* the moment it ships
rather than prevented at the door (P0-8). `--verify` opts into the §12
acknowledgment machinery — confirm the payload landed, within the re-check
deadline (§13) — implemented as a tail read of the target transcript's
JSONL, never a full parse. It presupposes the pair above: verification is
refused without `--submit`, because text left standing in a composer never
enters the conversation and so can never reach a transcript, and refused
with `--keys`, which reaches no transcript at all (§12). Verification is
opt-in because it costs a transcript read; supervision's conduct says to
use it.

**Every send is logged; nobody is the reporter of their own acts.** The
daemon executes every actuation on its own surfaces, so it records each in
the **actuation log** (§6): caller identity as declared, target, payload
verbatim (with the screen capture read, for keys), timestamp, synchronous
result — the observed outcome joining the record when `--verify` ran. The
line asserts *dispatch*, never delivery; landing is a machine observation
(§12). This is P1-7 held at the general tier: the record is written by the
machinery that acted, for every caller, whether supervision exists or not.

**Identity is ambient declaration.** A session TBD spawned carries its
identity in its environment — the supervisor's `TBD_PROJECT` among it
(§5) — and the CLI sends it with every call, so a desk cannot mistype what
it never types. A caller outside TBD's management sends anonymously, and
the log says so. Declaration, not authentication (§5): any process could
set the variable, and TBD declines to build stronger.

**Preconditions bind TBD's hand, keyed on that identity.** When the
ambient supervisor identity is present, the daemon rechecks against
current state inside the call — after the desk decides, before any
keystroke: the brake is released, the target lies inside the calling
supervisor's project and that project is turned on (§8), and the target is
not rate-limited or under a capacity hold. Every item is a yes/no fact the
operator or the machine already owns, none involves reading the payload or
judging the act, and the recheck is what makes the operator's controls
real rather than advisory: judgment takes minutes, so a briefing's facts
are already stale at act time, and the off mark flipped at 2:03 must beat
a send decided from a 2:02 briefing and issued at 2:07. A failed
precondition refuses the act — nothing is typed, the CLI returns an
ordinary error naming the condition, and the refusal is logged, so the
morning shows near-misses and an operator learns their controls bind. A
send without supervisor identity passes none of these gates, because
there is nothing to gate: the marks bind TBD's own autonomous hand, never
a human's (§8 — coverage, never protection). Keying on declared identity
defends exactly the case §16's bet defends — honest error, not malice: a
desk cannot mistype ambient identity, and a desk that *strips* it would be
a misbehaving desk, which no compiled check here aims at. Addressing is
part of the same recheck: a supervisor's sends are confined to its own
project (§5) — correctness, not authority, since the desk holds exactly
one project's playbook, and acting elsewhere would mean acting on conduct
that does not apply. Identical for the hosted desk and an appointed
session (§9); CLI reachability for the public send is one of the four
supervisor-capability requirements (§9).

Two mechanics belong to the transport, for every caller alike: target
liveness and identity, checked synchronously milliseconds later in the
same call (one check with one owner, §12), and **in-flight
serialization** — two sends interleaving into one composer is a transport
bug, so a send queues behind one already mid-flight to the same target.
What was a compiled never-double-treat precondition is conduct now:
whether an agent treated hours ago should be treated again is judgment,
made with the readout's not-to-act facts and the act log in hand — and
two authored layers already prevent the repeat upstream, since the
program's case memory skips re-briefing an untreated case and briefings
carry TBD's act record. The removed gate stays removed: no rule matching,
no content inspection, no posture judgment. The residual race is the
milliseconds between check and keystroke.

**Two in-daemon rails still type outside this verb, and closing that is
known work.** The public send is the only actuation this design describes,
but it is not yet the only compiled code that types into a session. Two
older rails paste through tmux directly: the hosted desk's own nudges and
shift wrap-up prompt, and the rate-limit rail's auto-continue, which types
`continue` once a limit clears. Both write their own actuation rows, so the
record's coverage holds for them — but neither carries the dispatch
envelope and neither can be delivery-verified (§12), and the *absence* of a
row's confirming outcome therefore says nothing about them either way.
That is exactly the wrong way round. These two are unattended sends, made
on no user gesture, into sessions nobody is watching — the shape the
acknowledgement machinery exists for — while the sends that do carry the
envelope usually have a human or a supervisor reading the result. Routing
both through the same actuation the public verb performs, so the envelope
and the observation cover them without a second implementation of either,
is the work that closes this gap; until it lands, "every send" in this
design means every send made through `tbd terminal send`.

*What is deliberately not here.* No **`drive`** — it was send plus the
record, and the record now rides every send, so a supervise-tier wrapper
would duplicate a public capability: the argument that deleted `wake`,
finishing the job. No **`pause`** — halting a runaway is the interrupt
payload, a convenience spelling the payload covers; the reason belongs in
the journal (§6). No **`note`** verb — narrative is the project's journal
file, authored prose in user-land (§6), which also needs no precondition
carve-outs: a file is writable by a stood-down desk without anyone
legislating it (§9). No **`learn`** — near-term memory is a journal
entry, durable knowledge is repo advisory content with a home and a
change process already (§8). No **`escalate`** — raising a question to a
human is conduct: the desk writes the exact item, its proposed command,
and its recommendation to wherever the playbook routes this project's
questions, and journals the pointer (§8). And `approve-a-prompt` stays
absent, nothing restoring it under another name (§2). The record attests
acts only.

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
   with playbook edits carried as superseding deltas in this same
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
   session. Otherwise it goes to the project's hosted desk, ensured live
   at `on` (§9); if the desk has died in the interim, the delivery fails
   with the machine-readable no-live-supervisor result and the failure is
   recorded — recovery is the submitting program's own next move, `on`
   (ensure) then resubmit, which the shipped program does in the same run
   (§9). Every spawn installs the
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
   move is a journal entry or an escalation, never a completion verdict of its
   own.
6. **Act through the daemon, never around it.** `tbd terminal send …` — the
   public send, carrying the desk's ambient identity (§3).
   The daemon performs three steps, and inspects the payload in none of them.
   First, it **appends the actuation row** — the durable request: the payload
   verbatim, the active mode, and the state snapshot that justified the act
   (for `--keys`, that snapshot includes the screen capture the desk read,
   §2). The row exists before any keystroke, so its ID is already durable
   when the delivery envelope quotes it (§12), and no crash window can
   produce a real intervention with no record. Second, it **rechecks the
   actuation preconditions** (§3) against current state; a failure refuses
   the act — nothing is typed, the CLI returns an ordinary error naming the
   condition, and a refusal outcome referencing the row is written.
   Third, it **dispatches** through the adapter — a dispatch that cannot
   succeed fails here, synchronously, as an ordinary error and a
   transport-failed outcome (§12). The claims form a ladder: the actuation row
   asserts the request, the synchronous outcome asserts dispatch or refusal,
   and whether the message *landed* is the re-check's later observation
   (§12). Nothing here verifies what the message claims — that a `--text`
   message rests on facts derived live is the desk's discipline (P0-8), and
   the verbatim row is what makes a stale premise findable afterward. There
   is no content check and no proposal conversion in this path: a desk that
   sends has acted (§3).
7. **Short follow-up.** The act arms a one-minute re-check (daemon timer, in
   memory). The result is recorded as an outcome row referencing the act
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
ceiling overnight — where sharding by project spreads it.

**Parked sessions are absent from this loop.** A compiled "outstanding work"
fact list here — a global any-true verdict making a parked session a wake case,
traded on the argument that "a false wake spends a few supervisor tokens and
ends in a journal entry" — is refused: field measurement falsified both the mechanism and
the price. The reasoning, and what stands in its place, is the
[wake-program sub-document](2026-07-26-fleet-supervision-wake-program.md).

**One case arrives by event rather than by tick: a pending `AskUserQuestion`.**
The `PreToolUse` hook already reports every one of them to the daemon
unconditionally, with no supervision check on the agent side — the daemon knows
each project's coverage and sees every event anyway. The fork is in the
daemon's RPC handler:
with the terminal's repo's project effectively on (§8), a pending
question becomes a case and is **delivered immediately through the compiled
fast path** (§2), bypassing the sweep program entirely: the trigger is a
reported fact that needs no theory of work, and this is the one delivery
TBD composes itself — the question payload verbatim from the
daemon's store, under the compiled header — so the supervisor fetches
nothing and needs no new read
surface. From there it is an ordinary case: judgment, then the send down the
same audited delivery path as every other act. Full mechanics, including the
dismiss-and-reply actuation and what a daemon restart costs, are in §2's
prompt-stalls subsection.

Boundary cases:
- **Supervisor can't decide** → the playbook names where this project's
  questions go — a channel, an issue, a file (§8) — and the desk writes the
  exact item, exact proposed command, and recommendation there, journaling
  the pointer (§6) so the account shows a question is out. The operator
  answers at the route; the sweep program reads the answer and carries it
  into future briefings, so an answered question is not re-asked (P1-5, §8).
- **Supervisor stuck or gone** → it is a session like any other, and the
  same watcher covers it: **the supervisor sits inside the sweep program's
  perimeter** (§9). The facts are one story for both supervisor
  arrangements — the readout's supervisor section carries the desk's
  session state, its last attested act, and the age of any unanswered
  briefing, all TBD-timestamped — and what that silence means, and what to
  do about it, is the program's continuation policy: an authored theory
  with a shipped default (nudge or replace the recreatable hosted desk
  through `on`, never touch the appointed session, page through `tbd
  notify`), overridable like the rest of the program (§9). The daemon
  continues to collect mechanical facts throughout and makes no judgments;
  it never pretends to provide the supervisor's judgment. When a project's
  supervisor stays dark, the darkness covers its own
  project only: other projects' supervisors are separate sessions and keep
  working, and the record shows which project lost its
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
  ensured live at `on`, standing down with its mark, disposed
  only for cause (§9). The alternative is **appointment**: the operator binds an existing
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

**Each desk is addressed to its own project.** The daemon refuses a desk's send
when the target lies outside that project — addressing correctness, not
authority (§3). How the daemon knows the caller's project is deliberately
plain: the desk's terminal environment carries its project's name
(`TBD_PROJECT=<name>`, the same name that keys `supervision.json`, §8),
injected at desk spawn like TBD's other spawn-time env layers — and, for an
appointed supervisor, injected by the appointment operation's relaunch (§9),
which is the same spawn-equivalent moment — and the CLI
sends it ambiently with every call. A desk never types identity flags, so it
cannot mistype them, and the value survives however far the desk `cd`s while
investigating — location is where a desk is looking, never who it is.
Attribution rides the one-supervisor-per-project invariant: the daemon knows
which session currently holds the named project's supervisor role (it spawned
the desk or performed the appointment, and recycling is sequenced), so the
actuation row is attributed from the daemon's
own records, never from the caller's text. All of this is caller declaration, not
authentication — any process could set the variable, and TBD declines to
build stronger (§3): the send is already public surface for every caller
(§3), so impersonating a desk gains a project's attribution and its
preconditions, not reach; if field use ever shows identity-stripped
supervisor traffic, a
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
same position, not a contradiction: the drawer is small because the teller is
trusted with the drawer, not with the vault.

**What stays global.** The project is the unit of judgment and action. It is
deliberately not the unit of everything:

- **One brake**, fleet-wide (§3). P0-2 asks for a single gesture to hand
  the fleet over or take it back, and the brake is that gesture: one bit
  ANDed over the per-project marks (§8), writing none of them. Coverage
  itself is per project — the marks — and mode *selection* is per project
  too; what stays global is the stop.
- **One actuation log, one `ledger.jsonl`, one `account.md`.** Every desk's
  acts and outcomes land in the same attested record as everyone else's, with
  each project's journal and proposals doc (§6) displayed beside it.
  Every row carries the acting project (§6), so every line says which desk
  acted and the account can *group* by project without being *split* by it.

A ledger per project was considered and rejected. It would multiply every
record surface — files, accounts, morning views — to express something the
envelope's project tag already expresses, and an operator's morning does not
decompose by project; it decomposes by what needs an answer. Per-project
*coverage spans* need no per-project files either: every `on` and `off` is a
lifecycle line, so a project's covered windows are a plain query over the
one record (§6, §9).

**Membership changes by `move`, never by add/remove.** Regrouping a repo is one
command — `tbd supervise project move <repo> --to <project|singleton>`, with
`--to singleton` restoring the default. An add/remove pair is deliberately not
offered: with "every repo belongs to exactly one project" as the invariant, a
`remove` leaves a repo belonging to nothing and an `add` can put it in a second
place, so the pair can express states the model forbids and every caller would
have to sequence them correctly. `move` cannot express them at all.

**Project mutations take effect on the next tick.** A definition edited
while its desk is live is legal; it just does not retroactively change a desk that is already
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
  project's whole conduct — every mode it can run — in one place, and it
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
  send carries a redirect exactly as readily as an answer, and the
  playbook is where the choice between them belongs. A second universal covers
  the chat channel: **when an operator answers a question by typing in the
  desk's tab, proceed on that guidance, and write the answer to the project's
  question route (§8) with a journal entry saying so — "acting on this now;
  recorded at <route> so it sticks."** Desk context is disposable by design (§9), so
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
  never lean on a safety net.** Targets genuinely differ in *permission*
  posture — most fleet spawns run with permissions bypassed, yet a repo's
  explicit `ask` rules still prompt even there, the mode can change
  mid-session from the
  keyboard, and an adopted session may ask about everything — so the same
  send is a suggestion behind a checkpoint into one session and the final
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
  injection gets a journal entry the moment it is seen, so the later,
  plausible-looking request lands next to it** — the desk's session memory is
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
the daemon enforces — no overrides for consequential acts, no never-act lists,
no thresholds. The operator's `supervision.json` (§8) holds only the operator's
selections: project topology, the per-project on marks, and per-project mode
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
attention — it never changes what any send is allowed to do.

## 6. The account (P0-9, P1-7)

**The record is written by the machinery that acted; the story is written
by the desk; the account is views over both.** Three surfaces — two
attested, one authored:

- **The actuation log** (`~/tbd/actuations.jsonl`) — TBD's *general*
  append-only record of every state-changing actuation the daemon executes
  through its public surfaces — send, wake, hibernate, spawn, dispose —
  one JSON object per row, written **only by daemon code at the moment it
  acts**, for every caller, whether supervision exists or not (§3). Each
  row carries the declared caller identity, the target, the payload
  verbatim, the synchronous result, and — for a supervisor's act — the
  active mode and the state snapshot that justified it; an **outcome** row
  references the row it confirms when `--verify` or the re-check observed
  one (§12).
- **The supervision ledger** (`~/tbd/supervision/ledger.jsonl`) — the
  supervision-specific kinds, same construction:
  **lifecycle** records a project turned on or off, the brake engaged or
  released, mode changes, desk recycles, and appointment and relief (§9).
  **enrollment** records an agent entering the supervision
  perimeter while its project is on; a project's `on` line carries the same
  fields for every agent already present, as a roster snapshot. **delivery** records a briefing
  delivered to a desk (sweep-program sub-document §3, §9).
  **anomaly** records an unknown state,
  a failed fetch, a dark supervisor, or a silent sweep program (a missed
  contact window, sweep-program sub-document §6).
- **The journal** (`~/tbd/supervision/projects/<name>/journal.md`) — the
  desk's narrative, authored prose in a markdown file: what it saw, what
  it intended, what it did — deliberate inaction narrated as seriously as
  action — the question-route pointers when it raises something (§8), and
  the closing summary at stand-down (§9). Conduct, not code, governs it:
  append, never rewrite; timestamp entries; dated headings per coverage
  span. TBD compiles only the file's location and the app showing it with
  its path — the proposals-doc pattern exactly. Markdown, because its
  readers are the operator and future desks, prose readers both (§1:
  representation follows consumer); a project that wants structured
  narrative ships a helper that writes more. A file needs no verb and no
  preconditions — which is also what lets a stood-down desk write its
  closing summary with nothing legislated (§9).

The attested surfaces prevent false claims about what *happened*: an act
nobody performed cannot appear, because only the daemon writes rows —
appended before the adapter runs, so a crash can delay an outcome but
never hide an act; an outcome nobody observed cannot appear, because
outcomes come from the adapter's synchronous return, `--verify`, or the
re-check; a delivery nobody received cannot be claimed, because the claims
ladder runs from *requested* through *dispatched or refused* to *landed*
(§12) and an act past its deadline with no confirming outcome renders as
unconfirmed, never as done; and certainty the system did not have cannot
appear, because unknowns are anomalies, not values. The journal makes no
claim the log cannot check: a narrated act is verifiable against an
attested row, and the desk can never author a row — it is not the
reporter of its own acts (P1-7, §3).

- Quiet contact writes nothing (sweep-program sub-document §3). Sweep liveness
  is one status field, not forty lines an hour; the lifecycle line that ends
  a project's coverage span — its `off`, or the brake — carries that span's
  coverage summary (§9).
- The record is also readable per project by the sweep program:
  `tbd supervise ledger --project <name> --since <t>` prints a project's
  view — actuations touching its sessions joined with its supervision
  lines (deliveries, lifecycle, enrollment, anomalies) — the loop-closer that lets a
  program see what TBD did since its last evaluation (sweep-program
  sub-document §3). Read-only, schema-versioned, one of the three public
  sweep surfaces. That it reads through to the actuation log means the
  program also sees interventions supervision did not make: a human's
  identified send lands in the same view, so case memory reasons over
  everything that touched the fleet, not only TBD's autonomous half.
- **`account.md`** sits beside the ledger, regenerated by the daemon after
  every append and displayed live in the side panel — the **fact half** of
  the account: acts with their outcomes, unconfirmed acts, anomalies,
  coverage. **The journal is the story half**, displayed beside it as-is.
  TBD weaves nothing and matches nothing — pairing a narrative passage
  with the act rows it describes is reading prose, which compiled code
  never does (§2); whether every act has a story is visible to the
  operator's eye, and a project that wants it *checked* greps act IDs in
  user-land. Nobody but the daemon writes `account.md`; nobody but the
  desk writes the journal. Markdown is the record's presentation; JSONL is
  its source — parsing prose back out of a display format would repeat the
  screen-scraping mistake in a file, which is also why the journal is
  never the fact source.
- **Evening and morning views are queries** over a time window of the
  record. The fact views are done (acts + outcomes), unconfirmed (acts
  past their deadline with no confirming outcome, §12), and went-wrong
  (anomalies); the journal's window is its dated headings, read beside
  them — the question pointers and the closing narrative live there (§8,
  §9) — with each project's proposals doc linked beside both. The story
  adds context; it never authors the facts.

**Proposals are prose, not records.** A proposal is the desk's judgment — "I
think we should do X, and here is why" — not a claim about something that
happened, so it does not belong to the ledger's machinery: the ledger exists
to guard facts against false claims, and a suggestion cannot be a false
claim. When a desk holds back on something consequential (attended mode's
signature move), it writes the suggestion into **that project's proposals
doc** — a markdown file at `~/tbd/supervision/projects/<name>/proposals.md`,
in the project's directory beside its other authored files (§7), outliving
every desk by construction. **How the doc is composed is the project's choice.**
The shipped default playbook describes a sane default entry — what act, on
which target, the exact message or keys, the reasoning, and, for anything
screen-informed, the capture it rests on — and a project that wants its
proposals grouped by risk, written as checklists, or in its own house style
says so in its playbook. TBD compiles only the boring parts: the file's
location, and the app showing it with its path. So the story still points at
everything, filing a proposal comes with a one-line journal entry — "proposal filed:
rebase strategy for acme-web, see the doc" — which is how the morning reader
knows the doc is worth opening. Acting on a proposal is a human act in the
world: the operator does the thing, or tells the desk to — in its tab, or by
an answer on the question route that the sweep program carries into the next
briefing (§8).
There is no approve button, and nothing executes a proposal mechanically.

### Line shapes

Actuation rows share one envelope — `{ "id", "ts", "actor", "kind" }` —
with the target, the payload, and the result in the body, plus, for a
supervisor's act, the active mode and the justifying state snapshot;
**outcome** rows reference the row they confirm, carrying a synchronous
result (*dispatched*; *refused*, naming the failed precondition;
*transport-failed*) or an observed one (the four §12 results, with the
observed-at of that observation) — only an observed outcome may claim a
payload landed. A supervisor's rows keep the evidence rules the desk
verbs carried: a keys payload records **the screen capture the desk read
when choosing those keys** — the evidence requirement every
screen-informed act carries, without which the row is a bug rather than a
thin record (§2) — and when a send answers a pending question, the
justifying snapshot **is** the question payload, verbatim: no separate
line records the question (a pending question is a fact, and facts are
not ledgered), and no separate verb marks the answer — reading the
snapshot is what distinguishes a reply from an unprompted nudge (§2).

Supervision ledger lines share
`{ "id", "ts", "mode", "project", "kind" }`. The envelopes are what make
the views in this section plain queries: filter by kind, window by `ts`,
group by `project` or by actor. The project tag is what lets one shared
record stay honest about
which desk acted: with per-project desks (§5) the account groups by project
without being split into per-project files. Lines the daemon writes on its own
behalf rather than a desk's — the brake's lifecycle lines, sweep-level anomalies —
carry a null project, which is the accurate answer and not a gap; a
project's own `on` and `off` lines carry its name.

What each supervision kind's payload carries:

- **`delivery`** — a briefing delivered to a desk: the project, the delivered
  text's hash, and the conduct hash the desk stands on (sweep-program
  sub-document §3, §9). Written request-first, before the adapter runs; the
  claims ladder (§12) governs what it may assert, and the age of a delivery
  with no answering desk line is a fact any watcher can compute from the
  record — desk-silence judgment is the sweep program's (§9). "What did this desk actually
  receive, under what conduct" is answerable per briefing from this line.
- **`anomaly`** — the category and the detail.
- **`lifecycle`** — a project turned on or off, the brake engaged or
  released, a mode change, a desk recycle, or an appointment or relief; this is
  the kind behind every line §9 describes. An `on` line's payload includes
  the project's roster snapshot: one entry per agent already under supervision, with the
  same fields an enrollment line carries. The line that ends a coverage
  span carries that span's coverage summary (sweep-program sub-document §6).
- **`enrollment`** — the agent's identity (worktree / terminal), its repo's
  resolved project, the spawn source, and the transcript path. Mechanical
  facts only, written by the daemon when a new agent enters a supervised
  project's perimeter; with the `on` line's roster snapshot this makes "what
  was under watch, and since when" a plain query, and "was supervision even
  applying to X at 02:20" answerable after the fact. The transcript path is
  deliberate: its head is the agent's original assignment, so judgment reaches
  "what is this agent for" in one hop, by reference — TBD stores a pointer and
  interprets nothing (§2, §15). The perimeter is the fleet table: a session
  TBD did not spawn is invisible to it, and the account reports that boundary
  honestly rather than implying coverage it does not have.

Two representative actuation rows, a send and the outcome that later
confirms it:

```json
{"id":"a3f1","ts":"2026-07-27T02:41:09Z","actor":{"kind":"supervisor","project":"acme-web"},"kind":"send","target":{"worktree":"1B7E2C90","terminal":"6D40F3A1"},"message":"The rebase conflict is in Package.resolved …","mode":"autonomous","state":{"session":"idle","source":"hook","observedAt":"2026-07-27T02:40:58Z"},"result":"dispatched"}
{"id":"a3f2","ts":"2026-07-27T02:42:11Z","actor":"daemon","kind":"outcome","confirms":"a3f1","result":"landed-and-acting","observedAt":"2026-07-27T02:42:09Z"}
```

Field lists beyond this are implementation detail and will grow. The envelope,
the set of kinds, and the never-claims above are the contract.

## 7. Persistence and storage map

Three categories determine where data belongs. **Live coordination state** is
read to allow or block behavior, affects the system's next action, can be
changed by concurrent actors, and appears live. **Append-only history** is
never used to allow or block behavior; an error there produces an inaccurate
account, not a wrong action. The third category is **human-authored process**.

- **DB: the fleet brake. One config column. Nothing else
  supervision-specific.** The daemon reads it. Both the app and CLI can set it,
  and all surfaces must see the same value immediately after a change — that is
  the purpose of the shared configuration object. Mode selections are *not*
  here; they are per-project operator choices in `supervision.json` (§8), which
  keeps this column a single fleet-wide gesture (P0-2).
- **The actuation log** (`~/tbd/actuations.jsonl`): TBD's general
  append-only actuation record (§3, §6) — deliberately *not* supervision
  storage, because it exists for every caller; supervision's views read
  it. Same housekeeping rules as the ledger below.
- **The supervision record** (`~/tbd/supervision/`): `ledger.jsonl` +
  `account.md`, with each project's `proposals.md` and `journal.md` — the
  desk-authored prose
  of §6 — in its project directory below. Every fact view over the record
  is a
  query of the two attested files, rebuilt at startup, never a second
  store; rotating either file is mechanical housekeeping (date-stamped
  segments), never a record boundary. The record directory contains
  everything needed for debugging or sharing.
- **Durable files**, operator-owned and hand-editable:
  - `~/tbd/supervision/supervision.json` — the project definitions (§5),
    the per-project on marks, the per-project mode
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
  - `~/tbd/supervision/projects/<name>/transition.py` — a project's
    transition hook, run at its coverage edges (§9). Its presence is the
    override — no config key points at it — and it carries the same
    seeded-once, never-rewritten ownership as the sweep program. Absent for
    projects running the shipped default ceremony.
  The playbook tiers (§5) are also durable files — and the playbook is where
  knowledge that must outlive any one session lives, changed by reviewed PR (§8).
- **In-memory, deliberately not durable**: active one-minute re-check timers
  and the brief pipe's liveness bookkeeping. Timers may live in memory *because*
  everything they encode derives from the durable record — an actuation
  row's
  timestamp fixes its observation deadline — so a daemon restart
  costs cadence, never data. For the default tick that is a one-cycle delay.
  For re-checks, the startup replay
  surfaces acts past their deadline with no outcome, and
  the daemon performs those observations then: the envelope is durable in the
  transcript, so a late read can still confirm a landing — though not its
  absence, which a bounded read cannot establish across an unbounded
  interval (§12). Until
  it runs, such actions render as unconfirmed by construction — the
  query-time rule, not a recovery sweep.

Net property: **supervision adds one column to TBD's database** — the fleet
brake. Everything else it knows is in files a human can open: under
`~/tbd/supervision/`, in the general actuation log beside TBD's other
files, and in the playbooks in the repos
themselves.

## 8. Remembered things: advice, selection, and the question route

Two things persist inside TBD's own files, and a third
persists deliberately outside them. All three shape what a desk does — and
none of them is a permission.

1. **Advice** — the playbook: prose, human-curated, travelling with the repo
   (`.agents/supervision.md`, three-tier, resolved per project §5). It carries
   both general guidance and the named **mode** sections a project can run (§3).
   The tool never writes it after seeding.
2. **Selection** — which mode each project runs, which projects are turned on, how repos group into projects, which session supervises a
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

The record's part is deliberately small. The journal is the soft
cross-reference: playbooks may tell desks to journal a pointer — "question
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

**Knowledge that should outlive the desk has exactly one home: the project's
playbook, changed by a reviewed PR.** That path already exists — the capture
flow (below) folds the record's learnings into `.agents/supervision.md` — and an
answer the operator finds themselves giving night after night is precisely
a learning worth capturing; the shipped playbook says so, telling desks that
an answer received two nights running belongs in the capture suggestion.
There is no separate durable decision store, because permanent instructions
kept in a side file are policy nobody reviews — the playbook is where a
project's standing answers live, in the open, with a change history.

### How experience reaches the playbook (P2-1)

**There is no machine-appended learnings tier** — no raw prose the machine
appends to a per-project `learnings.md` via a `learn` verb, carried into every
future briefing and taking effect immediately. It would bridge two different
needs that existing machinery serves better.

**In the near term, a learning is a journal entry.** The record every
replacement desk is briefed from carries the journal file by pointer (§9),
and the account displays the journal beside the facts. A desk that discovers
at 1 a.m. that a repo's test suite needs a
warm cache does not need a new memory tier to tell its 4 a.m. successor — that
was never the hard part.

**Durably, a learning is repo advisory content, and that has a home and a
change process already: the playbook, changed by a reviewed commit.** So at
stand-down — the default transition ceremony's closing request (§9) — and at
every flush step, if learning-shaped journal entries exist, the desk **suggests
spawning a capture worker** — an ordinary worker worktree, briefed to fold the
journal's learnings into that project's `.agents/supervision.md` and open a PR.
The suggestion is an entry in the project's proposals doc (§6); it outlives
the desk as a file on disk, and the
operator acts on it in the morning
alongside the rest. Supervision uses the machinery it supervises — a worktree, an
agent, a PR, a review — rather than inventing a private channel for its own
memory.

This also makes the promotion concrete rather than gestural. "A learning worth
keeping is promoted into the playbook by a human commit" names no mechanism
unless the commit *is* the mechanism — here it is, and the curation step is
ordinary PR review.

**The trade-off, stated plainly.** Durable learning costs PR latency, and it
cannot take effect silently. Both are the point. Nothing becomes standing advice
for a repo without a human reading the diff — the same authority principle as
"repos advise; operators bind," applied to the tool's own output. The gap this
leaves — a lesson learned tonight does not steer tonight's other desks — is
covered by the journal, and is not worth a second file that every future
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
  "supervised": ["acme-checkout"],
  "modes": {
    "acme-checkout": "autonomous",
    "acme-hooks": { "selected": "friday-freeze",
                    "declared": ["attended", "autonomous", "friday-freeze"] }
  },
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

`supervised` is the list of projects turned on — TBD's own attention covers
exactly these, and an absent name is off (below). `modes` holds two things on the default-props chain: the **declared
mode list** — the names a project's operator may select, defaulting to the
built-in pair `attended`/`autonomous` when absent — and the operator's
**selection** per project, defaulting to `attended` (§3). The map's value
carries both, in two shapes: a bare mode name is a selection against the
built-in list (the common case — `acme-checkout` above); an object names the
project's `declared` list and the `selected` name within it
(`acme-hooks` above, a singleton keyed by its implicit repo name like every
per-project map here). A declared list is complete when present — include
the built-in names to keep them selectable. Selection is
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

### Per-project on and off (operator-configurable)

Which projects supervision covers is per-project state, not a design
constant, and its whole model is one sentence: **every project starts off,
and `tbd supervise on <project>` is the standing mark that turns one on.**
There is no default stance and no watch-everything shipping posture — the
house default-off rule applied at the grain where autonomy actually acts —
and `off <project>` clears the mark, so an untouched project and a
turned-off project are the same state. For an off project, TBD's compiled
defaults stand down: no default tick runs, no prompt case is cut, no new
desk is spawned, and nothing is delivered — a desk from an earlier span may
persist, stood down with the mark (§9), but it receives nothing — so a
briefing submitted for the project is refused with the same
machine-readable result the pipe uses
whenever delivery has nowhere to go. **The mark is coverage, never
protection.** It builds no wall: the public actuations stay public
(`terminal.send`, `tbd terminal wake`), so a mark here could never keep
anything's hands off a terminal, and pretending otherwise would be a gate in
everything but name (§16's bet, kept). What the mark does bind is **TBD's
own hand**: the actuation preconditions recheck it at the moment of the act
(§3), so turning a project off beats a send its desk decided a minute
earlier — the same race the fleet switch wins, at per-project grain.
The bare switch (§3) adds exactly one thing the marks cannot express — the atomic
fleet-wide brake, one bit ANDed over every mark, so "nothing acts anywhere,
now" needs no enumeration and disturbs no configuration. What actually keeps supervision away
from work an operator does not want touched sits upstream, in user-land: the
sweep program decides what it briefs about, and its exclusions live in its
own files at whatever grain the project wants — per-terminal, finer than any
project mark. Hard per-session protection, enforced inside the actuation
preconditions, is the deferred never-touch flag (§15).
**Membership sits at the project level because the project is the acting unit**:
a desk works for a project, so "should the daemon be working here" is a question
about a project, and turning half a declared project off would mean a desk
supervising repos it is meant to leave alone. Singletons are marked by their
repo's implicit project name, so per-repo coverage is still exactly one mark
per repo when nothing is declared.

A project that is off gets none of TBD's own attention — no
tick, no prompt cases, no desk. It still appears in the readout and the account —
observability is never withheld, and "project X needed attention but is out of
supervision" is the honest report.

Coverage is also a recorded event, not only a resolved fact. Because
membership derives — agent → repo → project → mark — a new agent spawned
into a covered project is under supervision the moment it exists, with no config edit and
no desk chore; but nothing about that derivation leaves a trace by itself.
The trace is the ledger's: the `on` line's roster snapshot and per-agent
`enrollment` lines (§6) are what let the account answer *what was
under watch, and since when* — enrollment as a first-class event, arrived at
by recording the derivation rather than replacing it.

### Prior art in the current system

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

The merge gate and its clearance and audit stores are gone from the current
system, because whether a PR may merge is the forge's decision: branch
protection enforces approval-bound-to-content from outside the trust boundary
of the machine running the agents, a claim no local gate can make
(`docs/nightwatch.md` §1). Two
of those four defects are worth carrying forward as warnings rather than as
requirements. The `STANDING_RULE` string is why conduct is authored per project
here instead of compiled (§3). The self-report problem is why the daemon writes
every actuation row itself (§6) — the one piece of this design that genuinely
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

## 9. Coverage transitions and supervisor lifecycle (P2-2)

### The record is continuous; coverage spans are the marks' own lines

There is no shift object. The ledger is one append-only record (§6, §7), and
every boundary a shift would have drawn is already drawn by lines the record
carries anyway: `on <project>` writes a lifecycle line with that project's
roster snapshot, `off <project>` writes one carrying the span's coverage
summary, and the brake's engage and release are lifecycle lines of their own
(§3, §6). A project's covered windows are therefore a plain query, evening
and morning views are windowed queries over the same record (§6), and a
night-sized account is what any reader gets by asking for a window —
including an always-on operator, who never performs a boundary gesture at
all. P2-2's deliberate handover survives as the two things it was actually
made of: the coverage gestures themselves, and the ceremony below. Briefings
do not survive a pause — anything still true reappears in a fresh briefing
derived from current state — and a briefing left unanswered across a pause
is the system's doing, not a dead desk, which any continuation policy sees
plainly because the pause is on the record beside it (§6, below).

### The transition ceremony: edges are compiled, ceremony is authored

Every effective-coverage edge — a project's mark turning on or off, or the
brake changing what a standing mark amounts to — runs that project's
**transition hook**: the shipped default, or the project's own at
`~/tbd/supervision/projects/<name>/transition.py`, whose presence is the
override (§7 — no config key points at it, and it carries the sweep
program's seeded-once, never-rewritten ownership). The daemon invokes it
with the event (`on`/`off`), the cause (`mark`/`brake`), and the timestamp
of the previous edge — so an off-hook can read the whole span it is closing
with one `tbd supervise ledger --project <name> --since <t>` call. What the
hook prints to stdout is delivered to the project's supervisor as a
**transition delivery**: opaque bytes, bounded (§13), hashed into the
delivery line, never parsed — and its answer is ceremony, so silence about
it claims nothing. Empty stdout delivers
nothing.

The hook runs **after** the edge has taken effect, asynchronously, and is
best-effort: no transition ever waits on a user script, `off` in particular
succeeds no matter what the script does, and a hook that fails or times out
(§13) is an anomaly line, never a refusal. A daemon crash between the
lifecycle line and the hook costs the ceremony, never the record. The brake
fires each effectively-on project's hook with `brake` as the cause; a mark
flipped while the brake is engaged fires nothing, because nothing
effectively changed — though its lifecycle line is still written, so the
record never depends on hooks.

The shipped defaults: the off-hook composes a short stand-down request asking
the desk to append its closing summary of the span to the journal — the
handover ritual, and
where learning-shaped journal entries become a capture suggestion (§8) — and
the on-hook prints nothing, because an idle desk costs nothing until a message
arrives and the next briefing already carries what is new. The stood-down
desk can answer: a file needs no verb and no preconditions (§6), so the
closing summary lands after the mark clears with nothing legislated. This hook governs transition
messages only — briefing composition stays the sweep program's, standing
conduct stays the session layer's (sub-document §8), and `brief` remains
the one way to send a desk substance.

### Hosted desk lifecycle: ensured by `on`, standing down with the mark

- **`on <project>` is ensure-desk.** Deliveries need a live supervisor, so
  the gesture that opens coverage verifies one exists. Where an appointed
  binding stands (below), the binding is untouched — a mark is coverage, a
  binding is selection — and a dangling binding is reported loudly, never
  silently replaced by the hosted default. Otherwise: a live stood-down
  desk resumes as it stands, with the conduct reload folding in any playbook
  edits at the same moment (sub-document §8); a desk that died while stood
  down — a death nothing was watching for, since a stood-down project's
  sweep is not running — is detected
  here and replaced, a lifecycle line linking successor to predecessor; and
  a project that never had a desk gets one spawned. Spawn is cheap by
  construction: it installs the project's playbook as the standing conduct
  layer (sub-document §8) and delivers nothing — the opening material (the
  active mode, a pointer to the project's recent record window, derived by
  replaying the ledger filtered on the project tag, §6) rides the first
  briefing — so a quiet project's desk idles at zero token cost. Each
  hosted desk is a scratch space tracked by ID rather than by its display
  string, receives the supervision skill through the plugin mechanism, and
  is bound to its project for its whole life (§5). Open questions never
  depend on any desk's survival: they live on the project's question route
  and in the sweep program's files (§8), which outlive every desk by
  construction — which is why the route and not the desk is the durable
  home for anything needing a human.
- **`off <project>` stands the desk down; it does not dispose of it.** The
  mark is a delivery precondition rechecked at act time (§3, §8), so a
  stood-down desk simply receives nothing — an idle session holding its
  context at no token cost. Nothing watches it while stood down — the
  sweep is not running for an off project, and its idle silence would mean
  nothing anyway; liveness is re-verified at the next `on`. Context that
  cost real tokens to build is kept, not
  burned — and the durable guarantees never rest on it, because everything
  that matters is externalized as it happens (the record, the journal,
  proposals, routed questions), so persistence is an economy, never a
  dependency.
  Continuity still lives in artifacts; the desk's memory is a bonus the
  next `on` gets for free.
- **Disposal happens only for cause.** The recycle path (below) replaces a
  full desk; a continuation policy replaces a dark one — the sweep
  program's judgment, actuated through `on` (below); an operator may end
  the session like any other session they own. No coverage gesture disposes
  a desk — which is what makes toggling cheap in both directions, the same
  property the brake has (§3). **An appointed supervisor outlives
  everything here**: it is the operator's own conversation, and disposal is
  never TBD's to perform; the binding and the installed conduct layer
  persist until the operator relieves them (below).
- **A daemon restart resumes coverage, never forks it.** The marks and the
  brake are state, not history — `supervision.json` and the config column
  persist them (§7) — so recovery is a read of two files, not a replay
  decision. Desks are ordinary sessions and survive the daemon; the startup
  record replay runs the overdue-observation scan (§7, §12).

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
relaunch. **Relieving is the symmetric operation**: the same idle-waiting
resume, without the layer and without `TBD_PROJECT`, returning the session to
ordinary life with its conversation intact.

**One mechanism serves every conduct moment.** Resuming a session's process
in place with a changed standing layer and environment is the same mechanism
as the conduct reload that re-baselines a desk after a playbook
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
- **CLI reachability for the public send and the supervise surfaces** — the
  session can call `tbd terminal send` and the `tbd supervise` surfaces
  (§3, §10).

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
desk-liveness section below carries the same line); its context is
managed the way the operator manages any of their sessions, with
auto-compaction bearing survival there as everywhere. Two mechanisms manage
a hosted desk's context, and their
relationship is deliberate: **auto-compaction bears survival; deliberate
recycling is an optimization.** Inverting that — treating auto-compaction as
the expensive path and making the recycle machinery the thing standing between
a desk and its context ceiling — would make recycling load-bearing: if it
failed to fire, the desk would die at the ceiling, which is exactly how the
desk that reviewed this design came to exist, spawned by hand from a
predecessor that hit 200k overnight. So auto-compaction stays on for desks and
is the guarantee: a desk
can never hard-die from context alone, and what compaction loses is
acceptable by this design's own doctrine, because everything durable is
externalized as it happens (the record, the journal, the account, routed
questions). **A desk's
handoff document already exists — it is the record.** Recycling is
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
facts a continuation policy needs — deliveries, acts, and their ages — are
in the record, and hosted-desk
replacement
briefs from the record, so both hold unchanged. Such a desk simply runs
until it is stood down, recycled, or a continuation policy replaces it
(below) —
and the account
shows its context as unknown rather than guessed.

Thresholds are **fractions of the session's effective window**, never absolute
token counts. The denominator comes from the statusline tee (§2); absolute
numbers would be wrong on the next model, and the effective window is a
session fact TBD receives rather than knows. As context grows the daemon
sends staged **flush nudges** — bounded requests, same shape as the stand-down
closing request (§9): "anything in your head not yet in artifacts, write it
now — journal entries, proposals" — at rising fullness (§13), so that whenever
a recycle or a compaction
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
4. **Recycle** — tear down that desk's session, spawn fresh into the same
   project (spawning installs its one playbook as standing
   conduct), and deliver the standard replacement briefing (the
   active mode, that project's account so far) **plus the predecessor's
   transcript path**. Anything that lived
   only in the old context — a hunch
   mid-investigation, steering the operator typed earlier — is not lost; it is
   demoted from context to disk, and the new supervisor can search its
   predecessor's transcript on demand without paying for that history on every
   future turn. A ledger line links the old session ID to the new one.

**This runs automatically, in both modes, with no proposal.** Everything else
consequential in this design either takes an operator gesture or is an act on
the fleet someone will read in the record; this is deliberately neither. Recycling a desk
touches no fleet agent and destroys no work state, because desks were built
disposable — it is self-maintenance of the
supervision machinery, not an act on the fleet. It appears in the account
("3:12 a.m. — acme-web desk recycled at 261k context, 4 journal entries flushed"),
never as a question to anyone. If a recycle ever loses something that mattered, that
is an artifact-externalization bug to fix — the answer is "that should have
been in the record," never "a human should have approved the recycle."

### Desk liveness: the supervisor is in the sweep's perimeter

Context is not the only way a desk fails, and field experience supplied the
receipt: a desk can stall on its own question, wedge mid-turn, or sit silent
with a briefing unanswered — failing exactly like the agents it exists to
catch. The design's answer is that it is watched exactly like them too:
**the supervisor is a session inside the sweep program's perimeter**, and
desk liveness is the continuation half of the program's authored theory —
what silence means, when it becomes failure, whether to nudge, replace,
fail over, or page. TBD's part is the same as everywhere else in this
design: it keeps the facts, executes the actuations, and holds the one
compiled clock.

**The facts are compiled; the deadline is not.** The readout's supervisor
section carries the desk's session state, its last attested act, its
context fullness where known, and the age of any delivered briefing with no
answering desk act — every supervisor act is already an attested actuation
row, so record silence *is* unresponsiveness, computable by any reader
with no new observation channel. "Briefing unanswered for an hour" is the
same kind of statement as "idle for forty minutes": an authored threshold
over TBD-timestamped facts, a shipped-program constant (sub-document §7)
rather than compiled law. The shipped conduct triggers on an unanswered
briefing or a desk `working` past the threshold with no attested act —
never on idleness, because a desk is *supposed* to be idle most of the
night, and replacing quiet healthy desks would churn for nothing. A
transition delivery is ceremony and counts for nothing here; a stood-down
project's desk is dormant, not dark (above).

**Continuation is authored, and the actuations are public.** The shipped
program's policy: for a hosted desk — recreatable from playbook and record
by construction — run `on` (ensure), which verifies the desk really is
dead or wedged-beyond-use, replaces it with a lifecycle line linking
successor to predecessor, and costs a briefing, not work state; then
resubmit from current state (never replay the possibly-poisoned briefing —
anything still true reappears in a fresh composition). After two
consecutive replacements for the same project with no attested act between
them (sub-document §7), stop and page through `tbd notify` — repeated
futile acts go unnoticed precisely when nobody is watching, the five-nights
shape. For an appointed supervisor the shipped policy never disposes,
restarts, or spawns over the operator's own conversation: it pages, and
nothing more — the binding stands, and the hosted default does not step in
(a dark supervisor is not a relieved one — the dangling-binding rule
above). A project's own copy may do what the shipped one declines to:
nudge first through the public send, replace on a different model or agent
kind by spawning a session and appointing it (replacement briefs from the
record, so a cross-harness successor loses nothing durable), fail over on
provider health, or bind its own budgets. Its correctness is its author's,
like the wake program's — sufficiency, not guardrails.

**What stays compiled is the floor, and it is fact-shaped.** The contact
window (sub-document §6) is the clock that rings when the watcher itself
stops — the desk's watcher is the sweep, and the sweep's watcher is
compiled, so the regress terminates: sweep watches fleet and desk, contact
window watches sweep, heartbeat watches daemon (§14). TBD's own acts and
failures stay loud without judgment: a replacement performed at ensure, a
spawn failure, a failed delivery, a dangling binding — each is an anomaly
or lifecycle line and, where it is TBD's own machinery failing, a compiled
notification. And the unanswered-briefing age is a displayed fact in
status and the account, so a desk dark under a broken continuation policy
is visible in the record even when nothing acted — the record never
implies watchfulness nobody provided, which is the honest form of the
guarantee the compiled switch used to make. The compiled dead-man's switch
this replaces is recorded as a rejected alternative in §15.

**Fleet agents are explicitly excluded from all of this.** Auto-compaction is
fine for them too; no handoff templates, recycle flags, or compaction counters
exist for fleet sessions. The per-agent context fact is available for free
(§2), and its only fleet-facing use is informational: an account line or a
briefing may mention a parked session's context load, as input to judgment. And a
desk never runs its own succession: the primitives to self-replace exist in
the CLI, and the design's answer is that hosted-desk lifecycle — spawn, brief,
recycle, dispose — belongs to the daemon, and the supervisor binding to the
operator (§9's appoint and relieve gestures), full stop. The desk's whole
contribution to its own replacement is writing journal entries when asked.

## 10. Operator surfaces (intent, not screens)

Principle: **you take action where you already read the relevant information.**

- **The account panel shows the live account — one record, all projects.**
  The `account.md` renders beside the operator's work as things happen: acts
  with their outcomes, anomalies, and each project's journal and proposals
  doc beside them (§6). A desk's questions are not in it as a queue,
  because TBD holds no queue: questions go where the playbook routes them —
  a channel, an issue, a file the operator already reads (§8) — and the
  journal carries the pointers, so the panel tells the operator *that*
  a question is out and *where*, and the answer happens at the route, in the
  place their attention already lives.
- **A supervisor's tab stays a plain conversation.** Typed instructions are
  conversation. They steer the session but do not set policy. The two durable
  channels for rules are
  the playbook and its mode sections (§3); the chat is neither. If you type
  something conduct-shaped that should outlast the conversation, it belongs in the
  playbook, and the desk may propose a capture PR that puts it there (§8).
- **Chat steers; the route remembers.** These are not two homes for the same
  answer, and the difference is worth being exact about. An answer written on
  the project's question route is durable and legible to the whole loop: the
  sweep program reads it and carries it into future briefings (§8), and it
  survives every desk recycle and stand-down. Typing the same words into a
  desk's tab does neither: a hosted desk's context is disposable *by design*
  (it recycles on fullness and is replaced when it goes dark, §9), and even an
  appointed supervisor's compacts on a schedule nobody chose, so a chat-only
  answer evaporates on a schedule the operator cannot see — and the desk may
  not exist when the answer is given at all, since questions are often
  answered in the morning, when the desk that raised them may already have
  been recycled or replaced. The shipped
  playbook closes the loop from the desk's side (§5): a desk told something
  in chat acts on it, writes the answer to the route, and says so with a
  journal entry. One honesty boundary rides with this: a desk's transcription of a
  chat answer is the desk's report, and the compiled record attests acts
  only (§8) — consent never becomes a record claim, because there is no
  record kind that could carry one.
- **Attending the desk live is trivial, and no gate is missed in making it
  so.** With no proposal conversion, watching a desk work is just
  reading its tab and its account: you see what it did the instant the
  actuation row lands, and if you want it to do something you type it. There is no
  double-consent problem — no state where an operator has told a desk one thing
  in chat while a queued proposal says another — because chat steers and the
  record is written by the daemon either way (above).
- **The operator surface for v1 is `supervision.json` itself, plus the CLI.**
  The file is hand-editable by design (§8) — project topology, the
  per-project on marks, mode selections, sweep selections — atomically rewritten after
  each CLI action and reloaded after a manual edit, and every control is a
  CLI command (`tbd supervise project ...`, `tbd supervise mode ...`,
  `tbd supervise on|off <project>`, `tbd supervise sweep ...`). App
  presentation of these selections is deliberately deferred to its own
  design pass; this document specs no screens for them. The account panel
  above is the one app surface this design leans on, and it is being built
  separately (P0-9).

  There is deliberately **no rules-inspection surface**, because there are no
  rules to inspect (§3). The question it existed to answer — "why did the daemon
  do that on its own?" — is answered better by the account: every actuation row
  carries the mode it ran under and the state snapshot that justified it.
- **Morning flow**: open TBD → open the account panel's morning view — a
  windowed query over the record since you last read it (§6) → follow the
  journal's question pointers to the route and answer them in minutes (P0-10), with
  the desk's exact item, proposed command, and recommendation already there.
  An answer worth keeping is playbook material, and the
  capture flow is how it gets there (§8).

### The CLI surface (normative)

This is the complete `tbd supervise` surface. It is **normative for names
and shapes**: exact flag spellings may grow, command and subcommand names may
not drift. Everything the app can do appears here, because nothing exists only
as a button.

**Sweep-program surfaces — detection** (a desk never sweeps,
§1). The sweep program's three commands, specified in the
[sweep-program sub-document](2026-08-01-fleet-supervision-sweep-program-design.md)
§3:

```
tbd supervise readout --project <name>               # read-only: live-agent + supervisor facts, machinery state
tbd supervise brief   --project <name>               # briefing text on stdin; empty = quiet contact
tbd supervise ledger  --project <name> --since <t>   # read-only: the project's joined record (actuations + supervision lines)
```

`readout` and `ledger` print and change nothing; the readout includes the
**supervisor section** — the desk's session state, last attested act, and
unanswered-briefing age — because the supervisor sits inside the sweep's
perimeter (§9). `brief` is how cases reach a
desk: composed briefing text on stdin, delivered under the compiled header
after the per-project rate limit, refused with a pinned exit code while
the brake is engaged and with the `refused-off` result for a project that
is off (§8), and counted as liveness contact
either way (an empty submission is the attested "looked, found nothing").
Its synchronous result is machine-readable and pinned as contract —
delivered; refused-paused (exit 75); refused-off; refused-rate-limit;
refused-size; transport-failed; no-live-supervisor — because TBD makes one
full delivery attempt and never retries a briefing: persistence is the
program's, branching on the result and the ledger (§9, §12).

One general surface completes the program's toolkit without joining this
namespace: **`tbd notify --title … --body …`** raises an operator
notification through TBD's own notification path — the same machinery
TBD's compiled alerts ride — attributed to the calling script. It is
`tbd notify`, not `tbd supervise notify`, because nothing about it is
supervision-specific: the wake program's external watchdog has the same
need. TBD's compiled notifications narrow correspondingly to facts TBD
itself observed — its own failures and its own acts — while judgment-driven
pages are user-land's, through this verb.

**Acting and narrative — deliberately not here.** Acting on a session is the
public **`tbd terminal send`** (§3): one verb for every caller, logged in the
actuation log and attributed from the caller's ambient identity — a
supervisor's project rides from its spawn environment (`TBD_PROJECT`, §5),
never from a typed flag, and an identified send is preconditioned and
confined to its own project. So no supervise-tier acting verb exists.
Narrative is the project's journal file (§6), authored prose that needs no
verb, so no recording verb exists either. The sweep-program surfaces above
still take an explicit `--project` because their caller runs outside TBD's
management and has no spawn-injected identity.

**Operator — on, off, and the modes.** Coverage is per project: every
project starts off, `on <project>` is the standing mark that turns one on
(and ensures its supervisor is live, §9), and `off <project>` clears it,
each transition running the project's transition ceremony (§9). The bare
forms are the fleet brake — one bit ANDed over every mark, writing none of
them (§3, §8). Mode selection is per project and takes effect on the next
briefing (§3).

```
tbd supervise on  [<project>]
tbd supervise off [<project>]
tbd supervise status [--json]
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

**Operator — the sweep** (sub-document §4, §7).

```
tbd supervise sweep customize <project>   # copy the shipped program, write the pointer — once
```

**Deliberately absent**, each with its argument elsewhere in this document:

- **`shift open`, `shift close`** — there is no shift object and no record
  boundary gesture. The ledger is continuous; evening and morning views are
  windowed queries (§6); coverage spans are the marks' own lifecycle lines;
  and the handover ritual — the closing summary, the capture suggestion —
  is the stand-down ceremony of `off <project>` (§9). A close verb would
  re-reify as lifecycle what windows and marks already express.
- **`drive`** — it was the send plus the record, and the record now rides
  every send in the actuation log (§3, §6), so a supervise-tier wrapper would
  duplicate a public capability — the argument that deleted `wake`, carried
  to completion.
- **`pause`** — interrupt is a keys payload of the one send (§3), a
  convenience spelling the payload covers; the reason a desk halted something
  belongs in the journal (§6).
- **`note`** — narrative is a file: the project's journal (§6), appended
  under conduct, needing no verb and no precondition carve-outs (§9).
- **`learn`** — no machine-appended memory tier; near-term memory is a
  journal entry,
  durable memory is a reviewed playbook PR (§8).
- **`wake`** — no supervise-tier unpark verb. Parked sessions are the wake
  program's half outright (§4, the
  [wake-program sub-document](2026-07-26-fleet-supervision-wake-program.md)),
  the actuation already exists as public surface (`tbd terminal wake`), and
  every path that could put a parked session in front of a desk is authored
  away — a duplicate verb would be machinery whose consumer path was cut,
  the same argument that declined `approve` (§8). A desk that believes a
  parked session should wake says so on the project's question route; the
  shipped playbook's conduct is to raise it there rather than waking on its
  own judgment, because parked sessions sit outside the desk's remit.
- **`escalate`, `queue`, `resolve`** — the compiled record attests acts only
  (§8). A desk that needs a human writes to the playbook-named question route
  and journals the pointer; the operator answers there; the sweep program
  carries answers into future briefings. There is no compiled queue to read
  or resolve, and the why-not — with the conditions for revisiting — is §8's
  rejected-alternatives pair.
- **`approve`** — the approval-stamp variant of the same descope: a verb
  writing operator-gesture consent into the ledger. Machinery with no
  consumer today; revisit on evidence (§8).
- **`intervene`, `send`, `answer --terminal`** — there is one send verb,
  the public send (§3). Answering is the send path rather than a verb of its
  own (§2), and
  text and keys are payload variants rather than two verbs, since a message is
  not the lighter act (§3).
- **`approve-a-prompt`** — no blanket auto-grant of permission prompts exists,
  and nothing restores one under another name (§2).
- **Per-desk lifecycle commands** (spawn, recycle, dispose) — hosted desks are
  daemon self-maintenance, ensured live by `on`, standing down with the
  mark, and disposed only for cause; there is nothing for an operator to
  drive (§9). `appoint` and
  `relieve` are not the exception: they select *who* supervises — a binding
  gesture, like `mode` — and drive no hosted desk's lifecycle.
- **Rules of any kind — allow, deny, approve-lists, prompt-approvals.** Nothing
  is rule-gated (§3), so there is nothing to permit or forbid. The operator's controls are
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
  each profile. Holds bind identified supervisor sends — the actuation
  preconditions (§3). The
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
actuation row is appended durably before the adapter runs, so it asserts
exactly one thing: the daemon accepted this send and was about to dispatch
this payload at this moment. The adapter's synchronous return writes the
second rung as an outcome — *dispatched*; *refused*, a failed precondition
(§3); or *transport-failed* — and delivery is the third rung, a separate
observation recorded later by the re-check. Request-first ordering means no
crash window can produce a real intervention with no record: an act the
daemon performed is always preceded by its row, and a row whose act never
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
A dispatched text payload bound for an agent opens with a one-line envelope carrying the
actuation row's ID and the identity the row was attributed to —
`<tbd-dispatch id="a3f1" from="supervisor:acme-web"/>`, then the message
verbatim — which doubles as honest attribution: the receiving agent sees who
is addressing it, down to `from="anonymous"` when the caller declared no
identity. The envelope rides every text send the public verb makes to an agent,
`--verify` or not, because a prefix that appears only sometimes is one no
reader can rely on. Two targets get none. A keys payload carries no
envelope: a key sequence has
nowhere to put a line of text, and typing one ahead of an interrupt would
itself be an intervention. And a **shell** session receives the text alone —
`tbd terminal send` into a plain shell pane is a supported thing to do, and
every property that makes the envelope worth having is a property of an
agent: nothing in a shell reads the tag, no transcript records it, there is
nothing to join back to, and a submitted line would simply be executed. The
envelope is unconditional along the axis that matters — whether delivery is
being verified — and conditional only on the target being something it means
anything to. That is
why `--verify` and `--keys` are refused together (§3) — keys reach no
transcript, so there is no observation to be made.
No second ID namespace exists; the row ID is the identifier, so dispatch,
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
no machinery. During the re-check the daemon reads two machine facts — whether
the transcript contains the envelope, and the session's current state — plus
one identity check: that the terminal still holds the conversation the
payload was addressed to. `/clear`, `/compact` and an account swap all
rebind a session while leaving its pane untouched, so the transport's
identity check cannot see them, and reading on would mean judging one
conversation by another's transcript. The transcript read is a bounded
tail, never a parse: a cheap 64 KiB window first, and — only where the
envelope is absent and the next word would be an accusation — a second,
far wider 8 MiB read that must provably have covered the whole file before
non-delivery is claimed (§13). It
records one of four results as an outcome row referencing the act:

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
  session state unknown, adapter result ambiguous, the terminal rebound to a
  different conversation since dispatch, or the envelope simply absent from a
  bounded read that cannot prove it covered everything written since. That
  last case is why absence escalates before it accuses: a session can act on a
  payload, write past the cheap window, and be idle again inside the deadline,
  which is indistinguishable from non-delivery until a wider read settles it.
  **Never retried.** Written
  as an outcome and an anomaly, loud in the account. Retry proceeds only from
  *not landed*, because retrying into uncertainty risks double-instructing an
  agent that did receive the first copy — and a message to an agent running
  with permissions bypassed is arbitrary instruction injection (§3), so
  delivering it twice is not a neutral event.

**The machinery carries its own flag, and refuses rather than pretends.**
The re-check acts on no user gesture and its retry types into a live
session, so the whole path — arming the timer, the retry, and the startup
replay below — stands behind a daemon config column,
`delivery_verification_enabled`, shipped off. While it is off, `--verify` is
*refused*, with the flag named: nothing is typed, and the caller learns its
request went unhonored rather than receiving a quiet unverified send. A
caller that asked for confirmation must never be answered with a silence
that reads like one. The envelope is deliberately outside the flag —
attribution belongs on every dispatch that carries one, and a prefix that
comes and goes with a config column is worse than one that is always there.

Verification is narrower than the envelope, and narrower still than the
fleet. It is available where an adapter exists that can actually answer:
today that is a Claude session, whose harness writes the submitted message
into its transcript JSONL. A shell keeps no transcript, and the Codex
adapter's answer comes from the app-server protocol's in-protocol
acknowledgement rather than from an envelope — a different mechanism, and
one that is not built. Asking to verify either is refused rather than
accepted and quietly answered *undetermined* forever, for the reason the
whole section exists: promising evidence a target cannot produce rebuilds
the silent-failure class one layer up. It is narrower than the send path
too: the two in-daemon rails that paste directly rather than through the
public verb (§3) write no envelope, so there is nothing for an observation
to find, and bringing them onto the public actuation is what extends this
section's guarantees to them.

That one full attempt — adapter fallback and the evidence-bounded single
retry included — is the whole of TBD-side persistence for any send. Beyond
it the outcome stands as recorded, and whether to try again belongs to the
caller: a sweep program branches on its synchronous result and the ledger
and resubmits under its own continuation policy (§9), and a desk reads its
send's error and judges (§3). TBD attempts once, honestly, and remembers;
persistence is policy, and policy is authored.

**No confirming outcome means not-delivered, at query time.** The account
computes delivery status as the join of act and outcome: an act past its
acknowledgement deadline with no confirming outcome renders as unconfirmed,
as loudly as an anomaly. This is the fail-closed rule applied to delivery —
never default to "landed," the way the wake verifier never defaulted to
DONE — and it keeps every rung of the ladder honest: *requested* on the
daemon's word, *dispatched* on the adapter's return, *landed* only on a
machine observation. Because the rule lives in the query rather than in an
appended repair, a daemon restart cannot corrupt the record: an
act whose observation never ran renders as unconfirmed by construction
(§7). The observation itself is recoverable from the record alone — the
actuation row's timestamp fixes the deadline, and the envelope is durable in
the transcript — so at startup the daemon replays the record, finds acts
past their deadline with no outcome, and performs the same observation late
(§7). Late, it can confirm a landing but never assert the opposite: a bounded
tail read cannot span an interval of unknown length, so an absent envelope
there is *undetermined*. It re-delivers nothing either way, because the retry
exists to close a sixty-second gap, and a payload whose premise is an
unbounded interval old is exactly the stale-premise send this design refuses
to issue (§3). The late observation records what it could establish, writes
the anomaly, and stops. What a
restart costs is cadence, stated plainly: P1-6's sixty-second window degrades
to the startup scan or the next evaluation. What to *do* about a late-confirmed or
unconfirmed act — re-send, journal, shrug — stays playbook judgment, never
compiled repair.

### Delivery adapters: parity for the fleet, a channel for the desks

Which adapter a session can be reached by is itself a per-session fact, with
the same source-and-freshness treatment as any other fact.

**Fleet agents: `terminal.send` (paste + submit), the mechanism that exists
today.** This is the parity choice, and for much of the fleet it is
permanent: older agent versions and future agent kinds may never offer a
message channel, so typing is the floor that delivery stands on when nothing
better exists. Claude Code's per-session inbox socket was validated as a
draft-safe path
(`docs/research/2026-07-26-claude-code-channels/findings.md`, landed on
`main` separately): it delivers a message without touching the composer and
needs no agent-side setup, but it exists only on recent Claude Code versions
on supported platforms, and whether a message is delivered or held is decided
by the receiving session's inbound settings. Reachability is therefore a
per-session fact to be measured, not something fleet sessions can be assumed
to have.

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
delivery. The handshake is per desk because desks are
born and recycled independently (§9): the adapter is a property of a session,
so each new session earns it, and one degraded desk says nothing about the
others.
Thereafter, the acknowledgement path above extends naturally: a channel send
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
exercise judgment about it. §2's `--keys` send is not a loophole back in — a
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
interrupts it — a keys payload of the send (§3) — and what it does with that
judgment is its mode's conduct to say —
a cautious mode tells it to propose and escalate, a bolder one tells it to act
(§3). Either way the daemon records the act, never arbitrates it.
If the agent is making legitimate progress on a hard problem, the supervisor
writes a journal entry and leaves it alone.

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
| Delivery observation tail read | 64 KiB | §12 |
| Escalated read before claiming non-delivery | 8 MiB | §12 |
| Pause between keys in a `--keys` payload | 150 ms | §2, §3 |
| Keys accepted in one `--keys` payload | 32 | §2, §3 |
| Supervisor recycle preference | 50% of the effective window, per desk | §9 |
| Flush nudges | 50% / 60% / 70% fullness | §9 |
| Unknown-denominator assumption | 200k, labeled | §2, §9 |
| Desk-overdue threshold (briefing unanswered) | 60 min | shipped sweep program (sub-doc §7) |
| Desk replacement budget | 2 consecutive per project | shipped sweep program (sub-doc §7) |
| Per-project briefing rate limit | 1 briefing / 2 min | sub-doc §3, §10 |
| Briefing size bound (`brief` stdin) | 256 KiB | sub-doc §3, §10 |
| Paused-refusal exit code (`brief`) | 75 | sub-doc §3, §10 |
| Transition-hook run timeout | 5 min | §9 |
| Transition-hook output bound | 256 KiB | §9 |
| Runaway: turns in window | 30 turns | shipped sweep program (sub-doc §7) |
| Runaway: no-progress window | 90 min with no commits | shipped sweep program (sub-doc §7) |
| Heartbeat staleness | 10 min | §14 |

**All of these are compiled constants at parity — except the rows marked as
shipped-program constants, which ship in the reference sweep program — and none
is a config column.** That
preserves §7's one-column property, which is a real property of the design and
not an accounting convenience: the moment numbers become columns, "where is this
system's state?" stops having a one-line answer. If field use proves a number
wrong, promoting that one number to a config column is a conscious change to
§7, argued on its own merits — the same stance taken toward per-repo threshold
overrides (§15).

## 14. Out-of-band heartbeat (P3-1)

On a fixed cadence of its own, the daemon writes a small `status.json` file
under `~/tbd/supervision/`. It contains the brake, each project's mark and
active mode, and each project's last sweep contact. The watchdog is an
optional `launchd` job with one rule: *if any project claims to be
effectively on and the
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
  and CLI reachability for the public send and the supervise surfaces — and
  each of them presumes a harness
  TBD can relaunch. An endpoint that cannot be relaunched could only be
  supported through a weaker registry-declaration mode — a binding with no
  installed conduct and no injected identity — and this design refuses to
  have one: a supervisor that merely *received* briefings, on unknown
  conduct, with unattributable acts, would hollow out every property §5, §8,
  and §9 establish.
- **A compiled resume-nudge for dark appointed supervisors** — TBD resuming
  or nudging an appointed supervisor its project's continuation policy
  judged dark. Not built as compiled behavior: the session is the
  operator's own conversation, and TBD itself never restarts it uninvited
  (§9). A project that wants a nudge authors one — the send surface is
  public, and its own sweep copy is the place (§9); what stays absent is
  TBD doing it on its own initiative.
- **A compiled desk dead-man's switch** — a daemon-owned deadline armed by
  every briefing delivery, firing hosted-desk replacement or the appointed
  notification at T plus sixty minutes. Superseded by the sweep perimeter
  (§9): desk silence is judgment over TBD-timestamped facts (the readout's
  supervisor section), the deadline is an authored threshold like idle-40,
  and continuation is the program's policy actuated through public
  surfaces (`on`, the send, `appoint`, `tbd notify`). What the compiled
  switch uniquely guaranteed — a page at the deadline no matter what
  user-land does — is traded for consistency, and the floor that remains
  is fact-shaped: the contact window, TBD's notifications for its own
  failures, and the unanswered-briefing age displayed in status and the
  account. Revisit on evidence — the failure signature is desks dark for
  hours under live sweeps whose desk conduct silently rotted, in the
  record, more than once.
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
  the real difference: the same text send is a suggestion behind a
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
  consulted per call, consequential sends converted into proposals. Refused in
  full as over-engineering: it is machinery for a failure mode these models are
  not expected to exhibit, and TBD declines to build a second anti-injection
  layer on top of models already resistant to injection. What TBD does build
  around an act — the daemon-written actuation row, the one-minute re-check — is
  accounting, and earns its place in a system with no rules at all. Send-time
  re-verification is refused on its own grounds too (next bullet). The bet this
  rests on is named in §3 and revisited in §16.
- **Compiled send-time re-verification for desk messages** — the daemon
  checking every external claim in a text send against live sources, with a
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
  verbatim actuation row, §6), and one small compiled obligation — display-tier
  honesty for the persisted `PRStatus` (§2). The full argument, the field
  evidence that a faithful re-verification can still be lied to by its source,
  and the failure signature that would justify building it are in P0-8
  (requirements doc); the transient per-source reliability findings live as a
  dated note in the reference wake script, where they can rot without touching
  this document
  ([wake-program sub-document](2026-07-26-fleet-supervision-wake-program.md)).
- **Per-mode playbook files** — a project's modes are described in its one
  playbook (§3, §5), so a reader sees every mode a project can run in one
  place. Splitting them across files would also invite the reader to imagine the
  daemon choosing between them; it chooses nothing.
- **The act-with-veto-window human-in-the-loop (HITL) variant** — rejected on
  the grounds that a missed veto allows an action nobody approved. It has
  nothing to attach to here in any case: no act is converted into a proposal
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
  actuation preconditions (§3). The intermediate shapes — a daemon-invoked
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
  holds, in-flight dedup, send-time freshness)
  that every wake would pass through. Not built: TBD does not guarantee
  or guardrail a program it does not run and cannot repair. The program's
  inputs and actuation are public surfaces (Built/Enabled split, requirements
  doc), and the actuation log already records every wake the daemon executes
  (§3, §6); the rails are the program's to honor, and the reference script
  honors all of them.
- **A machine-appended learnings file** (and the `learn` verb and `learning`
  ledger kind that fed it) — a per-project `learnings.md` the desk could append
  to, carried into every future briefing, taking effect with no review. Not
  built, because it bridges two needs that existing machinery serves better:
  in the near term a learning is a journal entry, and the record every
  replacement desk is
  briefed from carries the journal by pointer; durably it is repo advisory content, which already has
  a home (the playbook) and a change process (a reviewed commit). Stand-down
  and the flush steps propose a capture worker that opens that PR instead. The cost — PR latency,
  and no silent adoption — is the feature. See §8.
- **Separate verbs for answering, messaging, and key-sending** — all three are
  the one public send with payload variants. Replying to a question is the send
  path (the dismissal is delivery-adapter behavior, the "this is a response"
  quality rides in the act's state snapshot); and text is not a lighter act
  than keys, since a message to a permissions-bypassed agent is arbitrary
  instruction injection (§3). Identical semantics, one verb. The collapse costs
  nothing: with no rules to scope, a mode's
  conduct prose draws whatever distinction a project wants — "answer questions
  freely, nudge sparingly" is one sentence. See §2, §3.
- **A per-project prompt-approval layer** — no matcher, no allowlist, no
  auto-grant, no table of prompts TBD says yes to. Answering a permission prompt
  is an ad hoc judgment act through the send, and nothing about it accumulates.
  Recurrence is a signal to fix the repo's own permission config, not a workload
  to automate. See §2.
- **Per-project ledgers** — the project is the unit of judgment,
  conduct, and coverage (§8), not of the record: one ledger and one
  account keep every record surface single, the envelope's project tag lets
  views group without splitting (§6), and a project's coverage spans are
  already its marks' lifecycle lines (§9). "Not this project tonight" is
  `off <project>` (§8). See §5.
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
- **DB tables for the ledger or its views** — every fact view over the record
  is a query of the two attested JSONL files (§7), rebuilt at startup.
  Supervision adds one column to the database.
- **A supervisor-authored account** — the record produces the fact summary. The
  supervisor adds context through the journal, displayed beside it, and cannot
  author the account.
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
project's policy because it is not deciding any project's action, and it
carries no supervisor identity — it reads, reports, and exits.
That keeps "one supervisor per policy" intact while restoring the view.
This document deliberately does not design that feature. It should be built
only when the need is real.

### The trust bet

The second criticism is newer and larger, and it deserves to sit beside the
first rather than under it. **This design has no enforcement.** No send is
rule-gated; no rule can forbid an act; "attended" instructs but does not restrain.
Everything that stops a desk from doing the wrong thing is either authored
conduct it chooses to follow, or an operator noticing afterward in an account
that is, admittedly, written the instant anything happens.

That is a deliberate bet on model quality (§3), and it should be stated at its
strongest against itself. If a desk misreads its mode, or reasons its way past
conduct prose, or is talked into something by text in a transcript it was asked
to read, there is no second line. The action lands, the record shows it
faithfully, and the operator finds out — with a send that may mean an
instruction already delivered to an agent running with permissions bypassed. The
verb gate would not have caught most of that either (it could forbid
acts by scope, not judge intentions), but it would have caught the blunt cases,
and blunt cases are the ones that actually happen at 3 a.m.

What makes the bet reasonable rather than reckless: the models are trusted to
follow instructions and are already injection-resistant, so a second mechanism
inside TBD would duplicate a defense that exists upstream and be weaker than it;
the blast radius is bounded by project (§5) and by the per-project marks (§8),
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
