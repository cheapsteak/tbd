# tbd supervise

Operate fleet supervision's surfaces: per-project coverage and the fleet
brake, supervisors, and the sweep program's contract surfaces. Acting on a
session is the public `tbd terminal send`, identity-attributed and always
logged; a supervisor's narrative is its project's journal file (see "Acting
and narrative" below).

Status: documents the `tbd supervise` surface specified by
[`docs/specs/2026-07-26-fleet-supervision-design.md`](specs/2026-07-26-fleet-supervision-design.md)
(§10 is normative for names and shapes) and the
[sweep-program sub-document](specs/2026-08-01-fleet-supervision-sweep-program-design.md);
the migration from the current implementation is planned separately. JSON output
shown here is illustrative of the schema family until the schemas ship.

## Synopsis

```
tbd supervise on | off [<project>]
tbd supervise status [--json]
tbd supervise mode <project> [<mode-name>]
tbd supervise project <list|create|delete|move> …
tbd supervise appoint <project> --terminal <id>
tbd supervise relieve <project>
tbd supervise sweep customize <project>

tbd supervise readout --project <name>
tbd supervise brief   --project <name>            # briefing text on stdin
tbd supervise ledger  --project <name> --since <t>
```

## Description

Supervision watches a fleet of agent sessions and intervenes through a
**supervisor** — itself an agent session — one per **project** (a repo, or a
declared group of repos). It is turned on per project — every project
starts off — and the bare `on`/`off` is the fleet-wide brake. Every act
lands in TBD's general append-only **actuation log** the moment the daemon
executes it, and supervision's own events — coverage, deliveries,
anomalies — land in a continuous **ledger** beside it; evening and morning
views are windowed queries over the two, and each `on`/`off` is itself a
ledger line, so a project's covered spans are always on record.

Each project's supervisor is either the **hosted desk** — a session TBD
spawns and keeps for the project (the default; zero setup) — or an
existing session the operator **appoints** into the role. Both stand on the
project's **playbook** (`supervision.md`, installed as a standing prompt
layer) and run under an operator-selected **mode**, which is conduct prose in
that playbook.

What the supervisor sees comes from the project's **sweep program**: a
script — the shipped one by default, the project's own by configuration —
that reads the `readout`, checks the `ledger` for what TBD already did, and
submits composed briefings to `brief`. Those three commands are the program's
entire contract with TBD.

Conventions: data goes to stdout, messages to stderr. JSON output carries a
top-level `schemaVersion`; changes within a version are additive only.
Commands exit 0 on success and nonzero with the refusing condition named on
stderr; exit codes called out below as stable are a contract scripts may
branch on.

## Subcommands

Operating (human operators):

- **on / off** – with a project: turn its supervision on or off (all start
  off), running its transition hook; bare: the fleet brake — pause
  everything, marks untouched
- **status** – the brake and per-project supervision state
- **mode** – show or select a project's active mode
- **project** – declare and edit multi-repo projects
- **appoint / relieve** – bind or unbind an operator-chosen supervisor
- **sweep customize** – take ownership of a project's sweep program

Detection (the sweep program; stable JSON and exit codes):

- **readout** – the project's live-agent facts, supervisor state, and
  machinery state
- **brief** – submit a composed briefing; empty input is a liveness heartbeat
- **ledger** – the joined per-project record: actuations with outcomes,
  deliveries, lifecycle, enrollment, anomalies

Acting and narrative have no `supervise` commands, deliberately. Acting on a
session is the public **`tbd terminal send`** — one verb for every caller,
identity-attributed and always recorded in TBD's actuation log, with
act-time preconditions binding supervisor-identified sends only. Narrative
is the project's **journal** —
`~/tbd/supervision/projects/<name>/journal.md`, appended by the supervisor
under its conduct, never through a command. Both are covered in "Acting and
narrative" below.

## Common examples

```
# Hand a project over for the night
$ tbd supervise on acme-platform
on: acme-platform (mode autonomous, hosted desk ready)

# What is supervision doing right now?
$ tbd supervise status
brake: released
acme-platform   on since 22:04   mode autonomous   supervisor: hosted desk   last sweep report 2m ago
tbd             on since 21:40   mode attended     supervisor: appointed (⌁ main session)   last sweep report 4m ago

# Read the facts the way the sweep program does
$ tbd supervise readout --project acme-platform

# Answer "what did supervision actually do overnight?"
$ tbd supervise ledger --project acme-platform --since 22:00

# Make your current pairing session the project's supervisor for the day
$ tbd supervise appoint tbd --terminal t42
appointed: session t42 supervises "tbd" (relaunched with playbook layer)
```

## tbd supervise on / off

```
tbd supervise on  [<project>]
tbd supervise off [<project>]
```

With a project: the standing per-project mark. Every project starts off;
`on <project>` brings it under supervision — the tick runs for it, prompt
cases reach its supervisor, and its supervisor is ensured live (a hosted
desk is spawned if the project has none, or resumed where one stands idle
from an earlier span) — and `off <project>` clears
the mark (an untouched project and a turned-off one are the same state).
An identified supervisor send rechecks the mark at the moment of the act,
so turning a project off stops even a send its supervisor already decided.
`off` stands the hosted desk down but keeps its session — deliveries stop,
the context is kept, and the next `on` resumes it rather than paying to
rebuild it.
Coverage, never protection: public commands stay public; keeping supervision
away from specific terminals is the sweep program's concern (its exclusions
can be per-terminal, in its own files), and hard per-session protection at
the send is a deferred design. An off project's facts still appear
in the readout and the account — observability is never withheld.

Each transition also runs the project's **transition hook**, after the
switch has taken effect and without ever blocking it: the shipped default —
on `off`, a stand-down message asking the supervisor to journal a closing
summary of the span; on `on`, nothing — or the project's own script at
`~/tbd/supervision/projects/<name>/transition.py`, whose stdout (if any) is
delivered to the supervisor verbatim. A failing hook is recorded as an
anomaly and never blocks the transition.

Bare: the fleet brake. `off` pauses TBD's authority to act everywhere —
briefings refused, identified supervisor sends refused from that instant —
without disposing any supervisor or touching the per-project marks, so
releasing the brake with `on` restores exactly the coverage that stood. The
switch is
a daemon config column shipped default-off. Toggling is cheap in both
directions; the record has no boundary to manage — the ledger is
continuous, and views over it are windowed.

## tbd supervise status

```
tbd supervise status [--json]
```

One line of global state (the brake), then one line per project: on/off
with the span's start, active
mode, supervisor arrangement, last sweep contact age, and coverage — a
project with no declared contact window and no tick shows `coverage unknown`.

## tbd supervise mode

```
tbd supervise mode <project> <mode-name>
tbd supervise mode <project>
```

Selects the project's active mode, or with no mode name, shows the active
mode and the declared choices. Names are validated against the declared mode
list in `supervision.json`; the conduct a name stands for is the playbook's
prose. Selection takes effect on the next briefing — no restart.

## tbd supervise project

```
tbd supervise project list
tbd supervise project create <name> --repos <id,…> --policy repo:<id>|operator
tbd supervise project delete <name>
tbd supervise project move   <repo> --to <project|singleton>
```

Declares multi-repo projects and moves repos between them. A repo in no
declared project is its own singleton project with its repo name — most
fleets never need these commands.

## tbd supervise appoint / relieve

```
tbd supervise appoint  <project> --terminal <id>
tbd supervise relieve <project>
```

`appoint` binds an existing TBD-managed session as the project's supervisor,
replacing the hosted desk. It is an operation, not a registry write: it is
refused with the reason unless the session's agent kind is
supervisor-capable (Claude Code today), waits for the session to be idle,
then relaunches it — same conversation, nothing lost — with the playbook
layer installed and its supervisor identity injected. The pane visibly
restarts for a moment.

`relieve` is the symmetric relaunch without either, returning the session to
ordinary life; the hosted desk resumes lazily on the next briefing need.
Both write the binding into `supervision.json` and a lifecycle line into the
ledger. An appointed supervisor outlives every coverage toggle and is never disposed,
recycled, or restarted by TBD; if its session disappears,
TBD notifies the operator and does not silently substitute the hosted
desk. Whether a live-but-silent appointed supervisor needs action is the
sweep program's continuation policy — the shipped program pages rather
than touching your session.

## tbd supervise sweep customize

```
tbd supervise sweep customize <project>
```

Copies the current shipped sweep program to
`~/tbd/supervision/projects/<project>/sweep.py` and points the project's
`supervision.json` entry at it. Write-once: the copy is yours and is never
touched by TBD again. Until then, the shipped program runs on the default
tick with no setup.

## tbd supervise readout

```
tbd supervise readout --project <name>
```

Read-only; prints and changes nothing else. The project's live-agent facts —
session state with its source and observed-at, work facts, runaway counters,
pin state, the not-to-act facts — plus machinery state (the brake, the
project's mark, the active mode) and the **supervisor section**: the
supervisor's session state, last attested act, context fullness where
known, and the age of any delivered briefing with no answering act from
the desk. The supervisor is in the sweep program's perimeter — whether its
silence is failure, and what to do about it, is the program's judgment
over these facts.

### Output

JSON on stdout, `schemaVersion` at top level. Illustrative:

```
$ tbd supervise readout --project acme-platform
{
  "schemaVersion": 1,
  "supervision": { "on": true, "brakeEngaged": false, "mode": "autonomous" },
  "supervisor": { "arrangement": "hostedDesk", "terminal": "t81",
                  "state": { "value": "idle", "source": "hook", "observedAt": "02:13:12Z" },
                  "lastAttestedAct": "02:04:51Z", "unansweredBriefingSince": null },
  "agents": [
    { "terminal": "t17",
      "state": { "value": "idle", "source": "hook", "observedAt": "02:13:40Z" },
      "work": { "uncommittedFiles": 2, "branchAheadBy": 3 },
      "counters": { "turnsInWindow": 12, "minutesSinceCommit": 47 },
      "pinned": false,
      "notToAct": { "interventionInFlight": false, "recheckPending": false,
                    "rateLimitedUntil": null } }
  ]
}
```

### Examples

```
# A sweep program's opening move
$ tbd supervise readout --project acme-platform

# Operator, checking one fact quickly
$ tbd supervise readout --project tbd | jq '.agents[] | {terminal, state}'
```

## tbd supervise brief

```
tbd supervise brief --project <name>    # briefing text on stdin
```

Submits a composed briefing for delivery to the project's supervisor. The
text is delivered verbatim under a short compiled header (active mode name,
any pending playbook update); TBD never parses it. Delivery is recorded in
the ledger with the delivered text's hash. An **empty submission is
meaningful**: it is the attested "looked,
found nothing" that keeps the project's liveness contact fresh without
delivering anything.

**One attempt, honest result, your policy.** TBD makes one full delivery
attempt (internal transport fallback included) and never retries a
briefing. The synchronous result is machine-readable and stable:
`delivered`, `refused-paused` (exit 75), `refused-off`,
`refused-rate-limit`, `refused-size`, `transport-failed`, or
`no-live-supervisor`. What happens next — resubmit, replace the desk with
`on` and resubmit, page with `tbd notify`, or wait for the next
evaluation — is the submitting program's continuation policy; the shipped
program handles `no-live-supervisor` by running `on` (ensure) and
resubmitting in the same run.

Refusals: while the fleet brake is engaged, exits **75**
(temporary; retry when supervision resumes). A project whose mark is off is
refused with an ordinary nonzero result naming the condition — off is a
standing state, not a pause, and a program should stop submitting rather
than retry. The contact window is disarmed in both cases, so a refused
submission neither counts as
liveness contact nor needs to — no contact is owed while coverage is closed.
Submissions beyond the per-project rate limit (one briefing per 2
minutes) or the size bound (256 KiB) are refused with the condition named.

### Examples

```
# The sweep program submitting its findings
$ compose_briefing | tbd supervise brief --project acme-platform

# A quiet evaluation: heartbeat only
$ tbd supervise brief --project acme-platform < /dev/null
```

## tbd supervise ledger

```
tbd supervise ledger --project <name> --since <t>
```

Read-only. The joined per-project view of TBD's record since `<t>`: the
actuation-log rows touching the project's sessions — any identified
caller's, a human's identified send included — with their observed
outcomes, plus supervision's own lines: briefing deliveries, lifecycle
and enrollment events, anomalies. This is how a sweep program closes its loop — seeing
everything that touched the fleet since its last evaluation, not only
supervision's half — and how anything else audits the night. JSON on
stdout, `schemaVersion` at top level.

### Examples

```
# What happened since my last evaluation?
$ tbd supervise ledger --project acme-platform --since 02:10

# Morning audit, human-shaped: prefer the account file, but this is the raw truth
$ tbd supervise ledger --project tbd --since 22:00 | jq '.lines[] | select(.kind=="send")'
```

## Acting and narrative

Supervision deliberately owns no acting or recording commands. A supervisor
acts through the same public actuation as every other caller and narrates
in a file of its own; TBD's compiled part is the send's execution, the
record, and the display.

**Acting is `tbd terminal send`** — one verb for every caller: a human's
script, a wake program, a sweep program's continuation policy, the
supervisor itself.

```
tbd terminal send --terminal <id> --text "…" [--submit] [--verify]
tbd terminal send --terminal <id> --keys "…"
```

Payloads, not verbs: `--text` carries a message and `--submit` sends it —
without `--submit` the text is typed into the composer and left there for a
human to send, so a message meant to be acted on passes both (that pair is
also how a pending question is answered — the adapter clears a machine-known
dialog first); `--keys` sends named keys chosen after reading the screen; an
interrupt is a keys payload. Exactly one payload flag per call, and
`--submit` belongs only to a text payload — Enter is itself a key, so a keys
sequence that means to submit spells it out (`--keys "Escape Enter"`). The daemon
does not read a text payload; it records it verbatim — every send lands in
TBD's actuation log (`~/tbd/actuations.jsonl`) with the caller identity as
declared, and a caller with no identity is logged as anonymous.

A text payload sent to an agent is delivered under a one-line envelope naming the
actuation row and that caller —
`<tbd-dispatch id="a3f1b2c3d4e5" from="supervisor:acme-platform"/>` on its
own line, then your text verbatim — so the receiving agent sees who is
addressing it and the transcript carries an identifier the record can join
on. It rides every text send this verb makes to an agent, verified or not: a
script of your own that declares no identity still delivers one, reading
`from="anonymous"`.
A keys payload carries no envelope, and neither does a send to a plain shell
pane — nothing there reads the tag, and `--submit` would run it as a command
line of its own, so a shell receives your text alone. Two of TBD's own
in-daemon rails — the watch desk's nudges and the rate-limit auto-continue —
type into a session without going through this verb; their sends are in the
actuation log like any other, but they carry no envelope and cannot be
verified.

`--verify` opts into landing confirmation — a tail read of the target
transcript's JSONL for that envelope, with the re-check deadline as its
default timeout. It is available for **Claude sessions only** — a shell keeps
no transcript to observe, and a Codex session's acknowledgement arrives by a
different mechanism that is not built yet, so asking to verify either is
refused rather than accepted and answered *undetermined* forever. It
requires `--submit`, since text left standing in a
composer never enters the conversation and so can never reach a transcript,
and it is refused with `--keys`, which leaves no transcript trace to read,
and with an empty `--text`, which pastes nothing and so writes no envelope
to look for. It is also gated on the daemon's `delivery_verification_enabled`
config, shipped off and flipped with the `config.setDeliveryVerification`
RPC (`daemon.capabilities` reads it back). **Enabling it means enabling it
and then restarting the daemon**, which wires the observation machinery at
startup; until that restart `--verify` is refused with a message saying so.
While the flag is off a `--verify` send is likewise refused outright, with
the flag named, rather than quietly delivered as an unverified one — a
caller that asked for confirmation is never answered with silence. TBD makes
one full attempt — including the single re-delivery it will make on positive
evidence that the first never landed — and nothing beyond it; the
synchronous result is honest and machine-readable, and what happens next is
the caller's policy.

**Supervisor-identified sends carry act-time preconditions.** When the
ambient supervisor identity (`TBD_PROJECT`) is present, the daemon rechecks
current state at the moment of the act — a refusal names the condition and
is logged: the brake released, the target inside the calling supervisor's
project and that project turned on, the target not rate-limited or under a
capacity hold. A send without that identity passes none of these gates —
the marks bind TBD's own autonomous hand, never a human's. For every caller
alike, the transport verifies the pane is alive and is the session it
claims to be, and a send to a target with one already mid-flight queues
behind it. For a supervisor deciding how to act on failure: precondition
and transport refusals are safe to re-evaluate on the next briefing — never
retry in a loop, and never assert a fact in the message older than this
call.

**Narrative is the journal.** A supervisor's story lands in
`~/tbd/supervision/projects/<name>/journal.md` — authored markdown, no
command in the path. Conduct governs it: append, never rewrite; timestamp
entries; a dated heading per coverage span. What goes there: narration of
what the desk saw and did, deliberate inaction ("agent t17 progressing,
left alone"), pointers that keep the record one hop from off-record threads
("question posted to #fleet-questions, answered 09:14"), and the closing
summary a stand-down requests — a file needs no precondition carve-outs, so
the summary lands after the mark clears. TBD compiles only the file's
location and the app displaying it beside the account; it never parses the
prose or matches it to acts. Held-back suggestions still go to the
project's `proposals.md`, unchanged.

### Example

```
# A specific next step, decided after reading the transcript
$ tbd terminal send --terminal t17 --text "PR #522 review comments are in; address the two blocking ones, then re-request review." --submit
```

## Related: tbd notify

```
tbd notify --title "…" --body "…"
```

Raises an operator notification through TBD's own notification path — the
same machinery TBD's built-in alerts use — attributed to the calling
script. Not part of the `supervise` namespace because nothing about it is
supervision-specific: sweep programs use it to page on their own judgment
(a silent supervisor, an exhausted replacement budget), and any user-land
watchdog may use it the same way. TBD's built-in notifications cover only
facts TBD itself observed.

## Exit codes

- **0** – success.
- **75** – the fleet brake is engaged (`brief` only). Temporary by
  contract: retry when supervision resumes. Stable; scripts may branch on
  it. A project turned off is an ordinary nonzero refusal, not 75 — off is
  standing, not temporary.
- **other nonzero** – refusal or failure, with the condition named on
  stderr: usage errors, rate or size bounds at `brief`, an unsupported
  agent kind at `appoint`. Codes other than 0 and 75 are not yet pinned as
  contract; branch on 0 / 75 / nonzero, not on specific values. (The
  public send's precondition refusals are `tbd terminal send`'s own,
  ordinary nonzero errors naming the condition.)

## Files

- `~/tbd/supervision/supervision.json` – projects, mode declarations and
  selections, the per-project on marks, supervisor bindings, sweep configuration.
  Hand-editable; the entire operator surface beyond this CLI.
- `~/tbd/supervision/projects/<name>/sweep.py` – the project's own sweep
  program, if customized.
- `~/tbd/supervision/projects/<name>/transition.py` – the project's own
  transition hook, if present; its stdout is delivered to the supervisor at
  each on/off edge.
- `~/tbd/actuations.jsonl` – TBD's general actuation log: every
  state-changing actuation the daemon executes, for every caller,
  supervision or not; the `ledger` view joins it per project.
- `~/tbd/supervision/ledger.jsonl` – the continuous supervision record
  (lifecycle, enrollment, deliveries, anomalies), with the generated
  `account.md` beside it and each project's `proposals.md` under its
  project directory.
- `~/tbd/supervision/projects/<name>/journal.md` – the supervisor's
  narrative, appended by conduct; displayed by TBD as-is, beside the
  account.
- `.agents/supervision.md` (in each repo) – the playbook; resolved per
  project through the standard tiers.

## Environment

- `TBD_PROJECT` – injected by TBD into supervisor sessions at spawn or
  appointment; carries the supervisor's ambient identity for identified
  sends and attribution. Not set by hand.

## See also

- [`specs/2026-07-26-fleet-supervision-design.md`](specs/2026-07-26-fleet-supervision-design.md) — the design; §10 is the normative command inventory
- [`specs/2026-08-01-fleet-supervision-sweep-program-design.md`](specs/2026-08-01-fleet-supervision-sweep-program-design.md) — the sweep program's contracts in full
- [`specs/2026-07-26-fleet-supervision-wake-program.md`](specs/2026-07-26-fleet-supervision-wake-program.md) — waking parked sessions
