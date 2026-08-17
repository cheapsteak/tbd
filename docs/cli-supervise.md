# tbd supervise

Operate fleet supervision's surfaces: per-project coverage and the fleet
brake, supervisors, and the sweep program's contract surfaces. Acting on a
session is the public `tbd terminal send`, identity-attributed and always
logged; a supervisor's narrative is its project's journal file (see "Acting
and narrative" below).

Status: documents the `tbd supervise` surface specified by
[`docs/specs/2026-07-26-fleet-supervision-design.md`](specs/2026-07-26-fleet-supervision-design.md)
(§10 is normative for names and shapes) and the
[sweep-program sub-document](specs/2026-08-01-fleet-supervision-sweep-program-design.md).
Part of that surface exists and part of it is specification the rest of this
document describes ahead of the code:

- **Built** – `on`, `off`, `status`, `mode`, `project`, `playbook`, and the
  sweep program's three surfaces: `readout`, `brief`, `ledger`. These are what
  `tbd supervise --help` lists, and their output is quoted here as it prints,
  with long JSON values elided for the page.
- **Specified, not yet built** – `appoint`, `relieve`, `sweep customize`.
  Their sections below carry the same marker, and any output they show is the
  specified shape rather than a transcript.

Briefing *delivery* is a separate half from the `brief` surface itself, and it
is the half that has not landed: `brief` accepts, attributes, paces, and
refuses where it should today, and answers `no-live-supervisor` because no
supervisor is ever resolved. Its section below says so plainly. The migration
from the current implementation is planned separately.

## Synopsis

```
tbd supervise on | off [<project>]
tbd supervise status [--json]
tbd supervise mode <project> [<mode-name>]
tbd supervise project <list|create|delete|move> …
tbd supervise playbook show      --project <name> [--content] [--json]
tbd supervise playbook customize --project <name> [--repo-level] [--json]
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

Conventions: data goes to stdout, messages to stderr. **Project names are
taken verbatim** — a `<project>` argument reaches the daemon exactly as typed,
surrounding spaces included, because a singleton's name is its repo's display
name and TBD lets a repo be called ` api `. A name of nothing but whitespace
is refused: that is the empty case, and it would otherwise read as the bare
fleet-brake form of `on`/`off`.
Commands exit 0 on success and nonzero with the refusing condition named on
stderr; exit codes called out below as stable are a contract scripts may
branch on.

**Schema versions.** JSON output carries a top-level `schemaVersion` — `1` for
`readout` and `ledger`, and `brief`'s result is versioned on the same terms
even though its input has no schema at all (the briefing is prose for a desk,
and TBD parses none of it). Within a version, fields may be added at any
level and a consumer must tolerate keys it does not recognize; a field never
changes what it computes, timestamps stay ISO-8601, and an enum value already
emitted keeps its sense. Removing a field, or changing what one means,
requires a version bump — so a program branching on `schemaVersion == 1` is
never silently surprised. The version sits on the printed envelope rather than
on each line or each agent entry: one binary emits one shape, so a per-entry
version could never legitimately differ, and the rules being versioned — the
ledger's projection rule, the readout's absence-means-unestablished rule —
have the whole object as their subject. It is stamped where a program reads
bytes, which is this CLI's stdout, not the daemon's internal RPC seam. TBD's
older JSON output predates the convention and carries no version, so expect
one only from a command documented as having it.

## Subcommands

Operating (human operators):

- **on / off** – with a project: turn its supervision on or off (all start
  off), running its transition hook; bare: the fleet brake — pause
  everything, marks untouched
- **status** – the brake and per-project supervision state
- **mode** – show or select a project's active mode
- **project** – declare and edit multi-repo projects
- **playbook** – show the standing conduct a project's supervisor stands on,
  or take ownership of a level of it
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
on: acme-platform

# What is supervision doing right now?
$ tbd supervise status
brake: released
acme-platform  on since 22:04  mode autonomous  supervisor: hosted desk      last sweep contact: never  coverage unknown
acme-hooks     on since 21:40  mode attended    supervisor: appointed (t42)  last sweep contact: never  coverage unknown

# Read the facts the way the sweep program does
$ tbd supervise readout --project acme-platform

# Answer "what did supervision actually do overnight?"
$ tbd supervise ledger --project acme-platform --since 22:00

# Make your current pairing session the project's supervisor for the day (not yet built)
$ tbd supervise appoint acme-hooks --terminal t42
appointed: session t42 supervises "acme-hooks" (relaunched with playbook layer)
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

A per-project call prints the resulting state and whether it changed anything
— `on: acme-platform`, or `on: acme-platform (already on)` when the mark
already stood. A gesture that changes nothing is not a decision: it writes no
ledger line, and the parenthetical is how you can tell. The bare form prints
the brake instead, `brake: engaged` or `brake: released`. The result carries
the mark and nothing more: no mode, no supervisor state, nothing about a desk
— reporting a fact the command did not establish is exactly the invented
measurement this design refuses.

**`on` warns; `off` deliberately does not.** After the switch has taken
effect, both forms of `on` — releasing the brake, and marking a project —
print the same warning composition `status` renders, unfiltered. The gesture
is where an operator forms the belief that supervision is running, and each
of the two is the only gesture that can create the state its warning
describes: release the brake over an unmarked fleet and you get
`noProjectsOn`; mark a project while the brake is engaged and you get
`brakeEngagedWithProjectsOn`, having just been told `on: acme-platform`.
Turning something off is a deliberate reduction of coverage rather than a
mistaken belief, so it says nothing extra.

**The streams split, so the command stays scriptable.** The one result line —
`on: acme-platform`, or `brake: released` — is stdout; the warnings are
stderr; the exit code is unchanged by either. `$(tbd supervise on acme-web)`
captures the result and nothing else, and a terminal shows both. The check is
best-effort in one direction only: it runs after the switch, so a readout it
cannot take never turns a gesture that succeeded into a nonzero exit — but it
says on stderr that it could not read the state, rather than falling silent
and letting silence read as a calm night.

What these gestures do today is the mark, the ledger line, the result and
that warning. The supervisor half described above — ensuring a hosted desk
live, standing one down — and the transition hook belong with the
not-yet-built commands, and arrive with them.

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

One line of global state (the brake), then any warning lines, then one line
per project. A project's line carries its name, its state — `on since HH:mm`,
or bare `on` where the record holds no opening line, or `off` — then
`mode <name>`, the supervisor arrangement (`supervisor: hosted desk`, or
`supervisor: appointed (<terminal>)`, which names the bound terminal rather
than its display string), `last sweep contact: <age>` or
`last sweep contact: never`, and coverage: the project's declared contact
window, or `coverage unknown` where it declares none. Unknown is the honest
not-yet value; nothing here invents a coverage claim. A fleet with no
projects at all prints `(no projects)` where the rows would be.

An off project renders exactly `off`, never a span and never a "was on
until" — an untouched project and a turned-off one are the same state, and a
third rendering would imply a third state that does not exist.

**Here warnings are stdout, and they are not errors.** A fleet state that
would otherwise render as a calm night gets its own `warning:` line, between
the brake and the project rows. Under `status` the lines are part of the
readout, so they go to stdout; the exit code stays 0 either way, because a
state worth saying out loud is not a failure of the command that reported it.
(The same lines appear under `on`, where they go to stderr instead — see that
section.) Four conditions warn:

- **`noProjectsOn`** – the brake is released and no project is on, so nothing
  is being supervised. The quiet failure the whole surface exists to prevent,
  so the line is composed from the facts the status carries — a released brake
  with nothing effectively supervised — and appears whether or not the daemon
  named it.
- **`brakeEngagedWithProjectsOn`** – the mirror: the brake is engaged while
  projects are marked on, so nothing is watching projects you believe are
  covered. Release it with `tbd supervise on`. It appears only while a mark
  actually stands — an engaged brake over an unmarked fleet is a deliberately
  quiet system, and a line there would teach you to stop reading the line.
- **`ambiguousRepoName`** – two or more repos share a display name, so none of
  them resolves to a project and none is supervised: a name with two
  candidates identifies nothing. Rename one, or declare a project naming them.
  The message names the repos, and the rest of the fleet is unaffected. Those
  repos have **no rows at all** below, so if you marked one on and cannot find
  its row, this line is the explanation — the repo is still in TBD, it is the
  project that has stopped resolving.
- **`unusableProjectName`** – one or more projects have a name that cannot be
  a directory name, so nothing can be written beside them: no playbook,
  journal, proposals or programs. They are supervised like any other project,
  and the message names which ones; renaming the repo gives them a directory.

`--json` carries the same facts for a program. `warnings` is an array whose
entries pair a stable `code` — the four above — with the sentence a human
would have read. `effectivelySupervising` (the brake released *and* at least
one project on) is a useful bit but not a diagnosis: it is false for
`noProjectsOn` and `brakeEngagedWithProjectsOn` alike, and those call for
opposite gestures, so branch on `code`. Never branch on the rendered line.
Each project entry carries `spanStartedAt`, `lastSweepContactAt` and
`coverageWindow` as explicit nulls when unknown, so a missing value is
readable as one rather than as an absent key.

```
$ tbd supervise status
brake: released
warning: the brake is released but no project is on — nothing is being supervised.
(no projects)
```

## tbd supervise mode

```
tbd supervise mode <project> <mode-name>
tbd supervise mode <project>
```

Selects the project's active mode, or with no mode name, shows the active
mode and the declared choices. Names are validated against the declared mode
list in `supervision.json`; the conduct a name stands for is the playbook's
prose. Selection takes effect on the next briefing — no restart.

Every form prints the choices beside the answer, so an operator never has to
go looking for what would have worked — including the refusal, which names
the condition on stderr and exits nonzero.

```
$ tbd supervise mode acme-platform
mode: acme-platform is autonomous   choices: attended, autonomous

$ tbd supervise mode acme-platform attended
mode: acme-platform is now attended   choices: attended, autonomous

$ tbd supervise mode acme-platform attended
mode: acme-platform was already attended   choices: attended, autonomous

$ tbd supervise mode acme-platform friday-freeze
mode "friday-freeze" is not declared for project "acme-platform" — choices: attended, autonomous
```

`was already` is the same distinction the `on`/`off` parenthetical draws: a
selection that changes nothing is not a decision and writes no ledger line. A
project whose declared list is somehow empty renders `choices: (none
declared)` rather than an empty space.

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

`list` prints one row per project: its name, its member repos, the playbook
source it designates (`policy: repo:<repo>` or `policy: operator`), and its
sweep program (`sweep: shipped`, or the path of the copy `sweep customize`
wrote). An installation that has declared nothing prints `(no projects)`.
There is no `--json` here; `status` is the machine surface.

```
$ tbd supervise project list
acme-checkout  acme-web, acme-api  policy: repo:acme-web  sweep: shipped
```

`move --to singleton` takes a repo back to being its own project, and where
that empties a declaration it deletes the declaration outright, along with
that project's mark, its mode selection and any supervisor binding — a mark
outliving its project would silently turn a later project of the same name
on. A move that would take a surviving project's designated policy repo away
is refused, naming the condition: designate another member's policy first.

`singleton` is a reserved name: `create` refuses it, because it is the word
`--to` takes to mean "back to being its own project" and a project holding it
could never be a move destination. `--to` is otherwise verbatim like every
other project name, so the sentinel is the exact word — `--to " singleton "`
names a project whose name has spaces around it, on the reading that whoever
quoted those spaces typed them deliberately. `--repos` is the one place that
still trims: it splits on commas and trims each element, so a repo whose
display name carries surrounding spaces cannot be named there. `project move`
reaches it.

## tbd supervise playbook

```
tbd supervise playbook show      --project <name> [--content] [--json]
tbd supervise playbook customize --project <name> [--repo-level] [--json]
```

The **playbook** is the project's conduct as prose — `supervision.md`,
installed whole as the supervisor's standing instruction layer when its
session launches. Every desk stands on exactly one, because a desk supervises
exactly one project.

Resolution runs **per project**, three levels, first existing non-empty file
wins, and the whole file is used — **levels are never merged**:

- the operator's copy, beside a declared project's definition at
  `~/tbd/supervision/projects/<name>/supervision.md`, or for a singleton in
  its per-repo config directory at `~/tbd/repos/<repo-id>/supervision.md`
- the project's designated policy source — `.agents/supervision.md` in the
  member repo named by `policy: repo:<id>`, and nothing at all when the
  project designated `policy: operator`, which *is* the statement that it has
  no repo level
- the shipped default

An empty or unreadable file at a level falls through to the next one — an
empty copy is not conduct — and `show` says so on stderr, so a file being
ignored is never silent.

**TBD never parses a playbook.** It resolves the path, hashes the bytes, and
installs them verbatim; the desk is the only structure-aware reader. Mode
names come from `supervision.json`, never from the prose, which is why
selecting a mode changes nothing about which file resolves. By convention a
playbook describes each mode in a section named for it, and the shipped
default carries `attended` and `autonomous`, so every project has both without
authoring anything.

`show` prints which level stands, its path and the conduct hash — the value a
delivery records as the conduct it ran under, and what "is this desk still on
the current text" is answered by comparing. `--content` appends the bytes;
`--json` prints the same facts as an object, which always carries the content.

```
$ tbd supervise playbook show --project acme-platform
playbook: acme-platform   tier: shipped   (shipped default)
hash: 4f1a…

$ tbd supervise playbook show --project acme-checkout
playbook: acme-checkout   tier: repo   /Users/me/src/acme-web/.agents/supervision.md
hash: 9c02…
```

`customize` is the "Customize playbook…" action: it copies the **current
shipped default** into the operator level, or with `--repo-level` into the
project's designated repo file, and prints the path it wrote. The flag is named
for the level rather than the repo because `--repo` names *which repo*
everywhere else in this CLI. Two properties matter more than the gesture
itself.

**Write-once.** Tool-provided content lives only in the level the tool owns —
the shipped default, which updates may freely replace. The operator and
repository levels are written exactly once and TBD never writes them again: it
does not overwrite them, merge into them, or reconcile them at startup. A
second `customize` against a level that exists is refused, naming the path,
and the file it refuses to touch is byte-for-byte unchanged.

**It copies the default, not what currently resolves.** Customizing the repo
level of a project that already has an operator copy gives you the tool's
default to edit, never a duplicate of the level above.

```
$ tbd supervise playbook customize --project acme-platform
playbook: wrote the shipped default to /Users/me/tbd/repos/6f3…/supervision.md
hash: 4f1a…
It is yours now — TBD writes the operator level exactly once and never again.

$ tbd supervise playbook customize --project acme-platform
The operator-level playbook for project "acme-platform" already exists at
/Users/me/tbd/repos/6f3…/supervision.md, and TBD writes that level exactly once.
Edit the file directly; nothing here will overwrite it.
```

Two conditions refuse `--repo-level`, each naming itself: a project that
designated `policy: operator` has no repo level at all, and a project whose
designated repo has a checkout that is no longer on disk has no tree to write
into — writing there would materialize a `.agents/` directory outside any
repository and then refuse forever, so the gesture waits for the checkout to
come back.

**Resolution follows the project, so moving a repo between projects moves which
operator copy is read.** A singleton's operator level lives at
`~/tbd/repos/<repo-id>/supervision.md`; once that repo is declared into a
project, the project's own `~/tbd/supervision/projects/<name>/supervision.md`
is the operator level, and the per-repo copy is no longer that project's
conduct. Nothing deletes it — it is read again if the repo goes back to being
its own project — but `playbook show` reports the project's levels, not the
repo's former ones, so check `show` after a `project create` or
`project move`.

## tbd supervise appoint / relieve

*Specified, not yet built.*

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

*Specified, not yet built.*

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
session state with its source and observed-at, the work facts below, runaway
counters, pin state, the not-to-act facts — plus machinery state (the brake,
the project's mark, the active mode) and the **supervisor section**: the
supervisor's session state, last attested act, context fullness where
known, and the age of any delivered briefing with no answering act from
the desk. The supervisor is in the sweep program's perimeter — whether its
silence is failure, and what to do about it, is the program's judgment
over these facts.

### The work facts, and the one that is deliberately missing

Each agent's `work` object carries what the supervision sweep already
resolves: the branch, whether that branch has conflicts, since when its
commits stopped moving, and the PR observation and status TBD keeps beside
the worktree. All of that comes out of the one `git for-each-ref` per repo
the sweep runs anyway, so the readout costs no extra subprocess per agent.

There is no working-tree fact — no uncommitted-file count, no diff summary —
and there is not going to be one at this layer. The sweep resolves refs, not
worktree status; answering the working-tree half would mean a `git status`
subprocess per worktree per cycle, which is the per-agent cost the readout
exists to avoid. A program whose theory of work needs the working tree runs
`git status` itself, over the worktrees it actually cares about.

**An unestablished fact is `null`, never a fabricated zero.**
`commitsUnchangedSince` is null until the sweep has seen the same branch tip
twice, because one sample measures no duration — a zero there would be a claim
of stillness TBD never observed. Read a null as *unknown*, which is neither
"moving" nor "still", and decide which way to fail from your own conduct.

### Output

JSON on stdout, `schemaVersion` at top level. A fact that is unknown is
present and `null` rather than an absent key, so a reader never has to guess
whether a value was unknown or the writer was an older build:

```
$ tbd supervise readout --project acme-platform
{
  "schemaVersion": 1,
  "project": "acme-platform",
  "generatedAt": "2026-08-15T02:13:41.204Z",
  "supervision": { "brake": "released", "on": true, "mode": "autonomous",
                   "declaredModes": ["attended", "autonomous"],
                   "spanStartedAt": "2026-08-14T22:04:11.000Z",
                   "lastSweepContactAt": "2026-08-15T02:08:40.000Z" },
  "supervisor": { "arrangement": { "kind": "hostedDesk", "terminal": null },
                  "live": false, "state": null, "lastAttestedAct": null,
                  "contextLoad": null, "unansweredBriefingSince": null },
  "agents": [
    { "terminal": "6D40F3A1-…", "worktree": "1B7E2C90-…", "repo": "9A11C0DE-…",
      "spawnSource": "claude", "transcriptPath": "…",
      "state": { "value": { "state": "idle" },
                 "source": { "kind": "hook", "detail": "Stop" },
                 "observedAt": "2026-08-15T02:13:40.000Z" },
      "work": { "branch": "tbd/public-surfaces",
                "hasConflicts": false,
                "commitsUnchangedSince": "2026-08-15T01:14:02.000Z",
                "pr": { "outcome": "observed", "observedAt": "2026-08-15T02:09:30.000Z" },
                "prStatus": { … } },
      "counters": { "turnsInWindow": 12, "hookEventsInWindow": 31,
                    "windowStart": "2026-08-15T01:13:40.000Z",
                    "observedAt": "2026-08-15T02:13:41.000Z" },
      "pinned": false,
      "notToAct": { "interventionInFlight": false, "recheckPending": false,
                    "rateLimitedUntil": null } }
  ]
}
```

**Read `supervisor.live`, never `supervisor.arrangement`, to learn whether
anything is standing in the role.** `arrangement` says what *would* supervise
this project — the operator's appointed session where a binding stands,
otherwise the hosted desk — and it is always present. It is never a claim that
a supervisor exists right now. Until briefing delivery ships, `live` is false
on every readout and the four facts beside it are null.

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
any pending playbook update); TBD never parses it. Delivery — the half that has
not landed, as the paragraph on it below says — will be recorded in the ledger
with the delivered text's hash.

**The pipeline runs in this order, and no step reads your text:** refuse for a
standing state (the project off, or the fleet brake engaged),
timestamp-and-attribute (the submission updates the project's liveness
record), size, pace, deliver. Attribution sits ahead of the size and pacing
refusals deliberately: a composer with a runaway bug submitting 300 KiB every
tick must read as broken, not as silent.

**Pacing is identity-blind.** One briefing per project per 2 minutes, decided
on timestamps alone. It does not consult who is submitting, and it must not:
the moment pacing reads an identity it stops being a mechanism and becomes a
policy — some submitters worth more of the window than others — and policy
belongs to the project's own program, not to the pipe.

**One attempt, honest result, your policy.** TBD makes one full delivery
attempt (internal transport fallback included) and never retries a
briefing. The synchronous result is machine-readable, and these seven values
are the contract: `delivered`, `refused-paused` (exit 75), `refused-off`,
`refused-rate-limit`, `refused-size`, `transport-failed`,
`no-live-supervisor`. What happens next — resubmit, replace the desk with
`on` and resubmit, page with `tbd notify`, or wait for the next
evaluation — is the submitting program's continuation policy; the shipped
program handles `no-live-supervisor` by running `on` (ensure) and
resubmitting in the same run.

**Delivery has not shipped, so today every submission carrying text answers
`no-live-supervisor`.** Nothing else about the surface is a stub: the
submission is timestamped, attributed, paced, refused where it should be
refused, and counted as liveness contact exactly as described here. It is an
honest answer to "did a supervisor receive this" — no — rather than a
placeholder, and it is enough to write and test a whole sweep program against,
minus the delivery leg.

**An empty submission is still a submission.** It is the attested "looked,
found nothing": it updates the liveness record, delivers nothing, writes no
ledger line, and pacing never applies to it. Its durable trace is the coverage
summary on the lifecycle line that ends the project's coverage span, which is
what lets the account say "checked 14 times, nothing found" — an attested calm
night rather than an absence of evidence. It answers `delivered`, in that
value's wider sense: the submission was accepted and everything it required
happened, which for a quiet contact is the liveness update alone. A refusal
there would tell a program something went wrong when nothing did; `detail`
says plainly which of the two happened. Empty means **zero bytes** and nothing
else — a briefing of three newlines takes the ordinary path, because deciding
that it "says nothing" would mean reading it.

Refusals: while the fleet brake is engaged, exits **75**
(temporary; retry when supervision resumes). A project whose mark is off is
refused with an ordinary nonzero result naming the condition — off is a
standing state, not a pause, and a program should stop submitting rather
than retry. **When both stand, the answer is `refused-off`**: releasing the
brake would change nothing while the mark is off, so "retry when supervision
resumes" would send the program back forever, and "stop submitting" is the
advice that holds. The contact window is disarmed in both cases, so a refused
submission neither counts as
liveness contact nor needs to — no contact is owed while coverage is closed.
Submissions beyond the per-project rate limit (one briefing per 2
minutes) or the size bound (256 KiB) are refused with the condition named,
and both are counted as contact — the program looked.

**The pacing slot is spent by a briefing that reached a supervisor, not by one
that was merely attempted.** The limit paces *delivered* briefings, so a
submission refused as paused, off or oversize never burns it, and neither does
one answered `no-live-supervisor` or `transport-failed` — the next submission
is free to go. That is what makes the documented continuation work: a program
handling `no-live-supervisor` by running `on` and resubmitting in the same run
would otherwise meet `refused-rate-limit` on the resubmission. A program is not
penalised for a refusal it did not cause, nor for a delivery that did not
happen.

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

### How the join is computed

- **Lines pass through verbatim.** Each entry carries the original JSON object
  untouched under `line` — every key it had, including the ones this build
  does not model — beside `source` (`actuation` or `supervision`), the two
  envelope fields lifted out for filtering and ordering (`kind`, `ts`), and a
  computed `delivery` status where a verified send is owed one. Neither record
  is re-modelled. The actuation record's field list is documented as growing,
  and the supervision ledger carries kinds a given build does not write — so
  re-modelling would make a later build's line, or any field added within a
  schema version, vanish from a query whose entire job is showing you
  everything that touched the fleet.
- **One merged `lines` array, ascending by `ts`.** The two kind vocabularies
  are disjoint, so a single array reads correctly and you filter by `kind`.
  `source` rides every entry regardless, so provenance never depends on
  remembering which vocabulary a kind belongs to.
- **An actuation row appears only when it resolves into this project.** Its
  target is matched by worktree, terminal, or repo, each resolved
  through TBD's own tables to a project. A row that resolves to nothing — a
  target whose row has since been deleted, a remote-provider act with no local
  coordinates — is excluded rather than included on a guess. The failure worth
  preventing is one project's query showing another project's lines.
- **A supervision line appears when it names this project, or names none at
  all.** A line carrying a different project's name is excluded exactly as an
  actuation row would be, but a line with no `project` is fleet-wide and
  belongs in every project's view. The brake's lifecycle lines are the reason:
  they name no project by construction, and a brake engaged at 02:00 is
  precisely what explains a project's silence for the rest of the night. A view
  that hid it would leave a program reading a quiet fleet as a broken one.
- **Unparseable lines are counted, not swallowed.** Both records are
  append-only files a human may hand-edit and a crash may truncate mid-write.
  A line that cannot be read at all is dropped from `lines` and counted in
  `skipped`, per record, so damage reads as damage rather than as a quiet
  absence — a shorter list with no count would read as "the fleet was quiet",
  which calls for the opposite response. A line whose envelope parses but
  whose body this build does not model is *not* skipped: it rides in `lines`
  verbatim.

### Output

```
$ tbd supervise ledger --project acme-platform --since 2026-08-15T02:10:00Z
{
  "schemaVersion": 1,
  "project": "acme-platform",
  "since": "2026-08-15T02:10:00.000Z",
  "generatedAt": "2026-08-15T02:41:12.008Z",
  "lines": [
    { "source": "actuation", "kind": "send", "ts": "2026-08-15T02:11:09.412Z",
      "delivery": "observed:landed-and-acting",
      "line": { … the row exactly as written … } },
    { "source": "supervision", "kind": "lifecycle", "ts": "2026-08-15T02:20:00.100Z",
      "delivery": null,
      "line": { … } }
  ],
  "skipped": { "actuationLines": 0, "supervisionLines": 0 }
}
```

`since` is echoed back so a program can confirm the window it got rather than
assume it. `delivery` is computed at query time and is null for every line
owed no observation, which is most of them — no row is ever *written* saying
`unconfirmed`, because that would make the record's claims depend on a sweep
having run.

### `--since`

Three shapes are accepted, and anything else is refused naming all three:

- **A full ISO-8601 timestamp**, with an offset or `Z`. The form a program
  computing "since my last evaluation" should use — unambiguous across time
  zones and daylight-saving edges.
- **Bare `HH:MM`**, resolved to the **most recent past** occurrence in the
  machine's local time zone. The operator's shape: at 02:40, `--since 22:00`
  means last night's 22:00.
- **A bare relative duration** — `30m`, `2h`, `90s` — meaning that long ago.

All three are resolved to an absolute instant by the CLI before the query
runs, and that instant is what `since` echoes back. The window's lower bound
is therefore fixed at the moment you invoked the command, not re-derived while
it executes.

### Examples

```
# What happened since my last evaluation? (a program: exact instant)
$ tbd supervise ledger --project acme-platform --since 2026-08-15T02:10:00Z

# Morning audit, human-shaped: prefer the account file, but this is the raw truth
$ tbd supervise ledger --project tbd --since 22:00 | jq '.lines[] | select(.kind=="send")'

# The last half hour, whatever the clock says
$ tbd supervise ledger --project acme-platform --since 30m
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

- **0** – success. `readout` and `ledger` are read-only and exit 0 whenever
  they printed their JSON; a `brief` that was `delivered` exits 0 too.
- **75** – `brief`'s `refused-paused`, and only that: the fleet brake is
  engaged. It is sysexits' `EX_TEMPFAIL` — "not now, retry later" — which is
  exactly what a brake refusal means, and it is stable, so scripts may branch
  on it.
- **other nonzero** – every other refusal or failure, with the condition
  named on stderr: `refused-off`, `refused-rate-limit`, `refused-size`,
  `transport-failed` and `no-live-supervisor` at `brief`, usage errors
  anywhere, an unsupported agent kind at `appoint`. `refused-off` is
  deliberately not 75: an off project is a standing state, so a program
  should stop submitting against it rather than retry on a timer. Codes other
  than 0 and 75 are not pinned as contract; branch on 0 / 75 / nonzero and
  read the result value for the rest. (The public send's precondition
  refusals are `tbd terminal send`'s own, ordinary nonzero errors naming the
  condition.)

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
- `~/tbd/supervision/projects/<name>/supervision.md` – a declared project's
  operator-level playbook, written once by `playbook customize` and never
  touched by TBD again.
- `~/tbd/repos/<repo-id>/supervision.md` – a singleton project's
  operator-level playbook, on the same write-once terms.
- `.agents/supervision.md` (in each repo) – the playbook's repository level,
  consulted for the member repo a project designates as its policy source;
  resolved per project through the standard tiers.

## Environment

- `TBD_PROJECT` – injected by TBD into supervisor sessions at spawn or
  appointment; carries the supervisor's ambient identity for identified
  sends and attribution. Not set by hand.

## See also

- [`specs/2026-07-26-fleet-supervision-design.md`](specs/2026-07-26-fleet-supervision-design.md) — the design; §10 is the normative command inventory
- [`specs/2026-08-01-fleet-supervision-sweep-program-design.md`](specs/2026-08-01-fleet-supervision-sweep-program-design.md) — the sweep program's contracts in full
- [`specs/2026-07-26-fleet-supervision-wake-program.md`](specs/2026-07-26-fleet-supervision-wake-program.md) — waking parked sessions
