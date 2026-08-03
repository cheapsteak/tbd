# tbd supervise

Operate fleet supervision: per-project coverage and the fleet brake,
supervisors,
the sweep program's contract surfaces, and the verbs a supervisor acts with.

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

tbd supervise drive --terminal <id> --text "…" | --keys "…"
tbd supervise pause --terminal <id> [--reason "…"]
tbd supervise note  --text "…" [--ref <line-id>]
```

## Description

Supervision watches a fleet of agent sessions and intervenes through a
**supervisor** — itself an agent session — one per **project** (a repo, or a
declared group of repos). It is turned on per project — every project
starts off — and the bare `on`/`off` is the fleet-wide brake. Every act
lands in one continuous append-only **ledger** the daemon writes; evening
and morning views are windowed queries over it, and each `on`/`off` is
itself a ledger line, so a project's covered spans are always on record.

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

- **readout** – the project's live-agent facts and machinery state
- **brief** – submit a composed briefing; empty input is a liveness heartbeat
- **ledger** – TBD's own record of acts, outcomes, and deliveries

Acting (supervisor sessions; each writes a ledger line and schedules a
60-second re-check):

- **drive** – deliver a message or named keys into an agent's session
- **pause** – halt a runaway session

Recording:

- **note** – attributed prose into the ledger; the only supervisor-authored
  line kind

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
The acting verbs recheck the mark at the moment of the act, so turning a
project off stops even a drive its supervisor already decided. `off`
stands the hosted desk down but keeps its session — deliveries stop, the
context is kept, and the next `on` resumes it rather than paying to rebuild
it.
Coverage, never protection: public commands stay public; keeping supervision
away from specific terminals is the sweep program's concern (its exclusions
can be per-terminal, in its own files), and hard per-session protection at
the acting verbs is a deferred design. An off project's facts still appear
in the readout and the account — observability is never withheld.

Each transition also runs the project's **transition hook**, after the
switch has taken effect and without ever blocking it: the shipped default —
on `off`, a stand-down note asking the supervisor to ledger a closing
summary of the span; on `on`, nothing — or the project's own script at
`~/tbd/supervision/projects/<name>/transition.py`, whose stdout (if any) is
delivered to the supervisor verbatim. A failing hook is recorded as an
anomaly and never blocks the transition.

Bare: the fleet brake. `off` pauses TBD's authority to act everywhere —
briefings refused, acting verbs refuse from that instant — without
disposing any supervisor or touching the per-project marks, so
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
recycled, or restarted by TBD; if it goes dark or its session disappears,
TBD notifies the operator and does not silently substitute the hosted desk.

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
pin state, the not-to-act facts — plus machinery state: the brake, the
project's mark, the active mode.

### Output

JSON on stdout, `schemaVersion` at top level. Illustrative:

```
$ tbd supervise readout --project acme-platform
{
  "schemaVersion": 1,
  "supervision": { "on": true, "brakeEngaged": false, "mode": "autonomous" },
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
the ledger with the delivered text's hash and arms the unanswered-briefing
deadline. An **empty submission is meaningful**: it is the attested "looked,
found nothing" that keeps the project's liveness contact fresh without
delivering anything.

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

Read-only. TBD's own record for the project since `<t>`: acts (drive and
pause) with payload hashes, their observed outcomes, briefing deliveries,
lifecycle events, notes, anomalies. This is how a sweep program closes its
loop — seeing what TBD did since its last evaluation — and how anything else
audits the night. JSON on stdout, `schemaVersion` at top level.

### Examples

```
# What happened since my last evaluation?
$ tbd supervise ledger --project acme-platform --since 02:10

# Morning audit, human-shaped: prefer the account file, but this is the raw truth
$ tbd supervise ledger --project tbd --since 22:00 | jq '.lines[] | select(.kind=="action")'
```

## tbd supervise drive

```
tbd supervise drive --terminal <id> --text "…"
tbd supervise drive --terminal <id> --keys "…"
```

Delivers a message (`--text`) or named keys (`--keys`) into an agent's
session. Exactly one payload flag per call. The daemon does not read the
payload; it records it verbatim and schedules the 60-second re-check.

Preconditions, checked at the moment of the act — a refusal names the
condition and is recorded: the brake released, the target inside the
calling supervisor's project and that project turned on, target not
rate-limited, no intervention
already in flight for the target, no pending re-check. The transport then
verifies the pane is alive and is the session it claims to be; a dead or
wrong pane fails as a recorded delivery error. If the target is showing a
dialog TBD machine-knows, the adapter clears it first; an unidentified
dialog refuses the delivery and writes an anomaly.

For a supervisor deciding how to act on failure: precondition and transport
refusals are safe to re-evaluate on the next briefing — never retry in a
loop, and never assert a fact in the message older than this call.

### Examples

```
# A specific next step, decided after reading the transcript
$ tbd supervise drive --terminal t17 --text "PR #522 review comments are in; address the two blocking ones, then re-request review."

# Answer a question TBD machine-knows is on screen
$ tbd supervise drive --terminal t23 --text "Option 2. The migration must stay append-only."
```

## tbd supervise pause

```
tbd supervise pause --terminal <id> [--reason "…"]
```

Halts a runaway session. Counters (turns in window, no-progress time) arrive
in briefings as facts; whether to pause is the supervisor's judgment under
its mode's conduct. Same preconditions and recording as `drive`.

## tbd supervise note

```
tbd supervise note --text "…" [--ref <line-id>]
```

Appends attributed prose to the ledger — the one supervisor-authored line
kind. A note can reference another line but can never change one. Use it for
deliberate inaction ("agent t17 progressing, left alone") and for pointers
that keep the record one hop from off-record threads ("question posted to
#fleet-questions, answered 09:14"). A note is accepted even for a project
just turned off — which is how the closing summary a stand-down requests
lands after the mark clears.

## Exit codes

- **0** – success.
- **75** – the fleet brake is engaged (`brief` only). Temporary by
  contract: retry when supervision resumes. Stable; scripts may branch on
  it. A project turned off is an ordinary nonzero refusal, not 75 — off is
  standing, not temporary.
- **other nonzero** – refusal or failure, with the condition named on
  stderr: usage errors, unmet preconditions, rate or size bounds, an
  unsupported agent kind at `appoint`. Codes other than 0 and 75 are not yet
  pinned as contract; branch on 0 / 75 / nonzero, not on specific values.

## Files

- `~/tbd/supervision/supervision.json` – projects, mode declarations and
  selections, the per-project on marks, supervisor bindings, sweep configuration.
  Hand-editable; the entire operator surface beyond this CLI.
- `~/tbd/supervision/projects/<name>/sweep.py` – the project's own sweep
  program, if customized.
- `~/tbd/supervision/projects/<name>/transition.py` – the project's own
  transition hook, if present; its stdout is delivered to the supervisor at
  each on/off edge.
- `~/tbd/supervision/ledger.jsonl` – the continuous supervision record, with
  the generated `account.md` beside it and each project's `proposals.md`
  under its project directory.
- `.agents/supervision.md` (in each repo) – the playbook; resolved per
  project through the standard tiers.

## Environment

- `TBD_PROJECT` – injected by TBD into supervisor sessions at spawn or
  appointment; carries the acting verbs' ambient identity. Not set by hand.

## See also

- [`specs/2026-07-26-fleet-supervision-design.md`](specs/2026-07-26-fleet-supervision-design.md) — the design; §10 is the normative command inventory
- [`specs/2026-08-01-fleet-supervision-sweep-program-design.md`](specs/2026-08-01-fleet-supervision-sweep-program-design.md) — the sweep program's contracts in full
- [`specs/2026-07-26-fleet-supervision-wake-program.md`](specs/2026-07-26-fleet-supervision-wake-program.md) — waking parked sessions
