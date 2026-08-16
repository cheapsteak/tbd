# Fleet supervision — the sweep program and desk briefing

Status: **normative sub-document of the fleet-supervision design.** Sibling of
the [wake-program sub-document](2026-07-26-fleet-supervision-wake-program.md),
with the same authority as the design sections it details; `design §N` below
refers to
[`2026-07-26-fleet-supervision-design.md`](2026-07-26-fleet-supervision-design.md).
It specifies two things that arrive from one placement argument: the **sweep
program** — one project-authored program owning live-agent case detection, its
own case memory, and the composition of the briefings that reach a desk — and
the compiled machinery that program runs against: three public surfaces (the
readout, the brief pipe, the ledger query), the delivery path with its
standing-conduct mechanics, and the liveness contract that makes a dead
program detectable. Compiled TBD's remit here is exactly five things: facts
out, briefings delivered, actuations executed, record kept, liveness attested. The
requirements doc carries the Built/Enabled classification and the
outside-first ratchet this document applies
([`2026-07-26-fleet-supervision-requirements.md`](2026-07-26-fleet-supervision-requirements.md)).

## 1. What TBD does not decide: theory of work, theory of attention

The design states that TBD has no **theory of work** — what done, stuck, or
abandoned mean is a project's convention, authored, never compiled (design §2).
This document names the sibling refusal: TBD has no **theory of attention** —
*when the fleet deserves evaluation* is equally a convention. One project
thinks in durations: look every few minutes, worry at forty idle. Another
thinks in forge events: look when a pull request becomes mergeable, when a
review lands, when checks go green. A third looks only during working hours.
A compiled tick as the sole trigger would quietly enshrine the first theory as
the only one.

Both theories are authored in the same artifact. The **sweep program** holds a
project's theory of attention (its triggers) and its theory of work for the
live half of the fleet (what the facts mean once it looks) — the exact
counterpart of the wake program, which holds both theories for the parked
half. It also holds the project's case memory (§7) and the briefings' own
voice: the text a desk reads is the program's prose. Compiled TBD keeps what
remains when the theories, the memory, and the voice are all subtracted: how
to look (the fact snapshot), how to act (the public send), what happened (the
record), and whether anyone is actually looking (the liveness contract, §6).

A rule of thumb runs through every artifact in this document, stated once:
**representation follows consumer.** Content read by judgment is prose (the
playbook, the briefing). Content read by lookup is structured data
(`supervision.json`, the readout, the ledger query's output). Content that
decides is code (the sweep program). Schemas exist only where a parser is the
reader — the readout and the ledger query carry them because a program parses
their output; the brief pipe carries none because its only reader is a desk.
The corollary is a hard rule: **TBD never parses the playbook — and never
parses the briefing.** Compiled code resolves paths, hashes bytes, and
delivers text verbatim; the only structure-aware reader of either is a model.
Structure a machine needs — the declared mode names — lives in
`supervision.json` (design §8), never in the prose.

## 2. The placement split

Authored, per project — one program plus one playbook:

- **When to look** — the sweep program's triggers (§4).
- **What the facts mean** — the program's case-cutting logic, including every
  threshold number (§7).
- **What has already been raised** — the program's case memory: which
  situations it has briefed, which operator answers it has read, kept in its
  own files, with the ledger query as TBD's half of the loop (§3, §7).
- **How the briefing reads** — the briefing is the program's prose start to
  finish. How a briefing lands is voice and emphasis, which is conduct's
  territory, and the program is where the project authors it.
- **What conduct governs** — the playbook, standing in the desk's session
  layer (§8).
- **What to do** — the desk's judgment, under that conduct (design §4).

Compiled, always — the integrity-facing remit:

- **The fact snapshot** — state with source and observed-at, work facts,
  runaway counters (design §2, §13). Fact: a wrong answer poisons everything
  downstream.
- **The event path for prompt cases** — a pending `AskUserQuestion` or
  permission prompt is a *reported fact*, not an inference: the hook payload
  states that a question is on screen and the agent is waiting. There is no
  detection heuristic in it for a project to iterate on, it is the case kind
  where the agent is provably blocked right now, and the hook event is the
  only live signal — the transcript is blind while a picker is open
  (`docs/research/2026-07-31-askuserquestion-dismissal/findings.md`). It
  bypasses the sweep program entirely. A project that wants routine prompts
  handled without a desk fixes them at the source (design §2, prong 1).
- **The pipe, delivery, and the record** — pacing at the brief pipe, the
  compiled header, delivery through the agent-kind adapter, the ledger and
  its query (§3, design §4–§6, §12).
- **The mechanical reasons not to act** — a rate-limited or capacity-held
  target is checked inside the identified supervisor send, at the moment of
  the act, where the target is explicit in the call (design §3); an
  intervention already mid-flight to the same target is transport
  serialization, held for every caller alike. Never double-treat before the
  first treatment is assessed is conduct, not a gate: the pending re-check
  and the in-flight intervention are not-to-act facts in the readout, and
  the desk decides with them and the act log in hand. Together these protect
  the record's integrity and the wake count (design §5's honestly priced
  resource); a program can reason with the same readout facts and decline to
  brief, and the compiled checks hold at the act regardless of whether it
  did.
- **Every compiled liveness contract** — the act re-check (design §12) and
  the sweep watchdog (§6). Desk liveness is deliberately not among them:
  the supervisor sits inside this program's perimeter, its silence judged
  by authored thresholds over TBD-timestamped facts (§5, design §9).

**The briefing, decomposed by author**, is the worked example of this split.
The playbook and mode conduct are the project's file; the briefing's prose is
the sweep program's voice; a question payload is the agent's words, verbatim
(the prompt fast path, design §2). The compiled **header** is the only text
TBD adds — the active mode's name and any pending conduct delta (§8) — TBD
prepending its own information, never demanding structure from the program.
What stays compiled is the guarantee around the text, not the text: each
delivery is recorded with the delivered text's hash and the conduct hash it
stood on, the header's contents are TBD's own facts, and the record shows
exactly what each desk received (§3, design §6).

The old system is the cautionary precedent for collapsing this split. Its
recurring desk briefing was a prompt template compiled into the binary
(`NightwatchDeskPrompts.judgePrompt`,
`Sources/TBDShared/NightwatchDeskPrompts.swift:172`; `docs/nightwatch.md` §5),
mixing mechanism, policy, and a section literally titled "Field learnings —
apply these rules" — conduct learned on real nights that could only be taught
by editing Swift and rebuilding. Every sentence of that content has an
authored home; only the header and the record remain compiled.

## 3. The three public surfaces

The sweep program runs against exactly three public surfaces, and the shipped
reference program is the conformance artifact for all three (§7): a fact it
cannot obtain from them is a failed conformance check and a concrete, scoped
API request — the mechanism by which TBD's surface grows, pulled by a real
consumer.

```
tbd supervise readout --project <name>               # JSON on stdout, schema-versioned
tbd supervise brief   --project <name>               # briefing text on stdin
tbd supervise ledger  --project <name> --since <t>   # JSON on stdout, schema-versioned
```

**The schema-version contract, stated once for all three.** The readout and
the ledger query each print a JSON object carrying a top-level
`schemaVersion`, value `1`. The brief pipe carries no schema on the way *in* —
its reader is a desk, and representation follows consumer (§1) — but its
synchronous *result* is machine-readable, and it is versioned on the same
terms. Those terms are the ones `tbd profile list --json` already states
([`2026-08-14-capacity-facts-contract-design.md`](2026-08-14-capacity-facts-contract-design.md)),
and they are three:

- **Additive within a version.** Fields may be added at any level, and a
  consumer must tolerate keys it does not recognize. A ledger kind a later
  build writes, or a fact the readout grows, is not a breaking change and
  arrives without a version bump.
- **Meanings are fixed within a version.** A field TBD computes keeps
  computing the same thing, timestamps stay ISO 8601, and an enum value
  already emitted keeps its sense.
- **Removal, or a change of meaning, requires a bump.** So a program
  branching on `schemaVersion == 1` is never silently surprised.

The version sits on the **envelope**, never per line or per agent entry. One
binary emits one shape: every entry in one printed object came from the same
build, so a per-entry version could never legitimately differ — it would be
either always redundant or always a bug. And the rules being versioned have
the whole object as their subject: the ledger's projection rule (below) is a
statement about which lines the array contains, and the readout's
absence-means-unestablished rule is a statement about every fact in it, so a
version scoped to one entry could not carry either. The stamp goes where a
program reads bytes — the CLI's stdout — rather than on the daemon's RPC
result, which is an internal seam between two binaries shipped together and
observed by no external consumer. Saying all of this is the point: **a version
whose guarantees nobody stated is decoration.**

**The readout** is the fact surface. An instrument readout: read-only, the
current values printed for whoever is consuming them, implying no action. It
prints the project's live-agent facts — session state with source and
observed-at, the work facts named below, runaway counters, worktree pin state,
and the per-target not-to-act facts (an intervention in flight, a pending
re-check, a rate limit) — plus the supervision machinery's own state: the brake, the
project's mark (design §3, §8), and the project's active mode. It also
carries the **supervisor section**, because the supervisor is a session in
this program's perimeter (design §9): the desk's session state, its last
attested act, its context fullness where known, and the age of any
delivered briefing with no answering desk line — the facts the program's
continuation policy judges (§7). A program can
therefore see for itself when a submission would be refused (§4). There is no
open-cases section: what has already been briefed is the program's own memory
(§7), not TBD's. An operator or any other script may read the readout freely
at any time.

**The work facts are the ones the sweep already resolves**, and no others:
each agent carries its branch, whether that branch has conflicts, since when
its commits stopped moving, and the PR observation and status TBD already
keeps beside the worktree. All of it falls out of the single
`git for-each-ref` per repo the conflict sweep runs regardless. A
working-tree fact — a count of uncommitted files, a diff summary — is
deliberately absent: the sweep resolves refs, not worktree status, and
answering the working-tree half would mean a `git status` subprocess per
worktree per cycle, which is exactly the per-agent cost the readout exists to
avoid. That is the same refusal `BranchTipTracker` states one layer down
(`Sources/TBDDaemon/Supervision/BranchTipTracker.swift`). A project whose
theory of work needs the working tree runs `git status` itself, over the
worktrees its own judgment cares about — the placement split (§2) working as
intended, with the cost borne where the interest is.

**An unestablished fact is `null`, never a fabricated zero.** "Commits
unchanged since" is null until the sweep has seen the same branch tip twice,
because one sample measures no duration; a zero or a stamp taken at first
sighting would be a claim of stillness TBD never observed, and it would read
as freshly-still every branch in the fleet after each daemon restart. The rule
generalizes across the readout: it reports what it established, and says null
where it established nothing, so a program can tell ignorance from a
measurement.

**The brief pipe** takes a composed briefing as text on stdin. There is no
schema — representation follows consumer (§1): the briefing's only reader is
a desk, a model reading prose, so no parser exists for a schema to serve. The
daemon takes the text as given; it never parses, edits, or ranks it. What it
does, synchronously, in this order — no step of which reads the briefing
text:

1. **Refuse for a standing state**, before anything is recorded. A project
   whose mark is off gets the `refused-off` result (design §8) — the "not
   covered" answer rather than the "not now" one; with the brake engaged the
   pipe refuses with a distinct machine-readable paused result and its pinned
   exit code (§10), so a program can tell "not now" from "broken". **When both
   stand, `refused-off` wins.** Off is a standing state: releasing the brake
   would change nothing while the mark is off, so "retry when supervision
   resumes" would send the program back forever, and `refused-off` — stop
   submitting — is the advice that holds. Neither refusal feeds the watchdog
   (§6), neither records contact (the contact window is disarmed while
   coverage is closed, so no contact is owed and none is counted), and nothing
   is delivered.
2. **Timestamp and attribute.** Every submission that gets past step 1 updates
   the project's liveness record — last contact, evaluation count (§6) —
   empty or not, and ahead of the two refusals below. That ordering is the
   point: a sweep program whose composer has a runaway bug and submits 300 KiB
   every tick must read as *broken*, not as *silent*. Silence is the one
   signal reserved for "nobody looked".
3. **Bound the size.** A submission over the §10 bound is refused
   `refused-size`, counted in bytes. Its contact is already recorded by then,
   which is the whole reason step 2 precedes this.
4. **Pace.** One identity-blind check: the per-project briefing rate limit
   (§10) — at most one briefing delivered per project per interval, enforced
   on timestamps alone. A submission inside the window is refused with a
   machine-readable result; the refusal still counts as contact. **Pacing must
   not consult who is submitting.** The moment it reads an identity it stops
   being a mechanism and becomes a policy — some submitters worth more of the
   window than others — and policy is the project's, authored in its own
   program. Timestamps are all a floor needs. This is also the whole of the
   pipe's not-to-act checking, because pacing is the one check
   that needs no identity. The per-target reasons not to act live inside the
   identified send's preconditions (design §3), where the target is explicit
   in the call (`--terminal <id>`) — the same check-at-the-act pattern that
   makes the off switch bind. **The slot is committed when a submission
   reaches the delivery attempt, not at the moment of the check** — ordinary
   rate-limiter shape, test the window and spend the token when the action
   proceeds — so a submission refused as paused, off or oversize never burns
   it, and a program is not silently penalised for a refusal it did not cause.
5. **Deliver.** A surviving briefing goes to the project's supervisor: the
   daemon
   prepends the compiled **header** — the active mode's name and any pending
   conduct delta (§8) — resolves the supervisor (the operator's appointed
   session where a binding stands, otherwise the hosted desk, ensured live
   since the project's `on` — design §5, §9),
   delivers through the agent-kind adapter, and writes the ledger's
   delivery line request-first, carrying the delivered text's hash and the
   conduct hash (design §4 steps 3–4, §6, §12). The synchronous result is
   machine-readable and its **seven values are contract** (§10): delivered,
   refused-paused, refused-off, refused-rate-limit, refused-size,
   transport-failed, no-live-supervisor. TBD makes **one full attempt and
   never retries** — adapter fallback included (design §12) — so continuation
   is the submitting program's policy, closing the loop through the result and
   the ledger (§7, design §9).

**An empty submission is still a submission.** A `brief` call with nothing on
stdin is the attested "looked, found nothing": it updates the liveness
record, delivers nothing, and writes no ledger line — the design's noise rule
holds (design §6: quiet contact is one status field, not forty lines an
hour); its durable trace is the coverage summary on the lifecycle line that
ends the project's coverage span (§6, design §9). It
is not a courtesy: it is what makes a quiet fleet distinguishable from a dead
sensor. Pacing applies only to delivered briefings, never to quiet contact.

**Its result is `delivered`**, in that value's wider sense: the submission was
accepted and everything it required happened, which for a quiet contact is the
liveness update alone. Any refusal there would tell a program that something
went wrong when nothing did, and the result's `detail` sentence says plainly
which of the two happened. **Empty means zero bytes**, and nothing else: a
briefing of three newlines takes the ordinary path, because deciding that it
"says nothing" would mean reading it — which no step of this pipe does.

The pipe takes **pure text and nothing else**, bounded in size (§10). A
structured evaluation report
and the thinner variant — a small agent-list manifest riding beside the
text — are both rejected alternatives (§11): every piece of structure demanded
from the program becomes vocabulary TBD must version, and the compiled
consumers such structure would feed are checks this design deliberately
places elsewhere.

**The ledger query** closes the loop. It prints the joined per-project view
of TBD's own record since a timestamp: the actuation-log rows touching the
project's sessions — every identified caller's, so a human's identified send
appears beside the desk's — with the outcome rows that join them, plus the
supervision lines: briefing deliveries, lifecycle, enrollment, anomalies (design §6). It
is how the program sees everything that touched the fleet since its last
evaluation — which briefings were delivered, whether the desk acted, what
came of the acts, and interventions supervision did not make. It is TBD's
half of the program's case memory (§7): the program's files say what it has
raised; the record says what the machinery did about it, whoever asked.
Read-only, schema-versioned, free to call.

**How the join is computed, and what it refuses to do.** Four rules, and each
one is a refusal to be clever with somebody else's record:

- **Lines pass through verbatim.** An actuation row's field list is documented
  as growing — the envelope, the kind set and the never-claims are the
  contract and the rest is implementation detail (design §6) — and the
  supervision ledger is append-only, with kinds a given build does not write.
  So the query carries each line's original JSON object untouched under
  `line`, beside `source` (`actuation` or `supervision`), the two envelope
  fields lifted for filtering and ordering (`kind`, `ts`), and a computed
  `delivery` status where a verified send is owed one. It re-models neither
  record. Re-modelling would
  make a later build's line, or any field added within a version, vanish from
  a query whose entire job is showing a program everything that touched the
  fleet.
- **One merged, timestamp-ascending `lines` array.** The two kind vocabularies
  are disjoint, so one array reads correctly and a consumer filters by `kind`
  the way the design's views do. `source` rides every line regardless, so
  provenance never rests on remembering which kind set a name belongs to.
- **A row is in the project's view only when it resolves into the project.**
  An actuation row's target is matched by worktree, terminal, or repo, each
  resolved through TBD's own tables to a project. A row that resolves to
  nothing — a target whose row has since been deleted, a remote-provider act
  with no local coordinates — is **excluded**, not included by default. The
  failure that matters here is one project's query showing another project's
  lines, so an unresolvable row is dropped rather than passed through on a
  guess.
- **Unparseable lines are counted, not swallowed.** A hand-edit or a crash
  fragment is reported as a count alongside the array, so damage reads as
  damage rather than as a quiet absence.

`--since` accepts three shapes and refuses anything else naming all three: a
full ISO-8601 timestamp with offset or `Z` (the form a program computing
"since my last evaluation" uses), a bare `HH:MM` resolved to the most recent
past occurrence in the machine's local time zone (the operator's shape), or a
bare relative duration — `30m`, `2h`, `90s` — meaning that long ago.

## 4. Triggers and the default tick

Triggers are the project's. Cron, launchd, a webhook receiver listening for
forge events, a manual run while debugging — all equivalent at the pipe,
which neither knows nor asks what prompted a submission.

TBD ships scheduling as a **default, not a monopoly** — the same shape as a
component's default props. The daemon runs the shipped reference program (§7)
on a timer, per project, until the project overrides:

- **Keep the tick, keep the shipped program** — the zero-setup case, and the
  common one. The shipped program improves with releases and the project
  authors nothing.
- **Keep the tick, bring your own program** — `"sweep": { "script": "<path>" }`
  in the project's `supervision.json` entry points the tick at the project's
  own program (§7). Anything **time-shaped** — custom logic, custom
  thresholds, custom cadence — takes this route: TBD's schedule plus a custom
  script, with an `interval` value overriding the cadence when the default
  tick is too fast or too slow.
- **Go external** — `"schedule": "external"` stands TBD's scheduler down. It
  exists for exactly one shape: an **event-driven resident process** — a
  webhook receiver, a forge-event listener — whose triggers TBD cannot see.
  It is not for custom logic or custom cadence; those are the `script` and
  `interval` overrides above. The project then owns its theory of attention
  outright, and declares a contact window in exchange (§6).
- **Keep the tick alongside your own triggers** — legitimate and cheap: the
  tick becomes a reporting floor under an event-driven program.

The selection is the `sweep` object inside the project's entry in
`~/tbd/supervision/supervision.json` (design §8), on the default-props
chain: no object means TBD's schedule, at the default interval, running the
shipped program.

```jsonc
// ~/tbd/supervision/supervision.json
{
  "projects": {
    "acme-platform": {
      "repos": ["<repoID-a>", "<repoID-b>"],
      "sweep": { "script": "~/tbd/supervision/projects/acme-platform/sweep.py",
                 "interval": "10m" }
    },
    "acme-hooks": {
      "repos": ["<repoID-c>"],
      "sweep": { "schedule": "external", "contactWindow": "30m" }
    }
  }
}
```

(Mode selection is not part of the `sweep` object — it lives in the file's
top-level `modes` map; design §8 shows the whole file.)

When the daemon itself runs the program, failure detection is direct — a
crash or timeout is observed as an exit condition and recorded (§6). When the
project owns the triggers, failure detection is the watchdog's, by silence.
Either way the shipped default means "turn the project on and supervision
works": no project starts with a scheduling chore, and the
never-installed-schedule failure class does not exist for the default path.

**Paused and off.** The brake's writ runs exactly as far as TBD's own
processes (design §3). While a project's mark is off or the brake is
engaged, the default tick
launches no new runs for it; a run already in flight finishes inside its timeout
bound (§10) and its submission is refused at the pipe with the paused result
(§3). External programs are **never signaled or killed** — TBD stops only
what TBD starts. Toward everything it does not run, TBD refuses at the
boundary and advertises state: the readout carries the brake and the
project's mark (§3), so a courteous program can decline to run at all, and a program
that submits anyway gets the machine-readable refusal. Refusals while paused
do not feed the watchdog, whose contact window is armed only while
the project is effectively on — mark set, brake released (§6).

## 5. Liveness contracts: which durations are whose

"Idle 40 minutes" does double duty in supervision conversations, and the two
duties land on opposite sides of the compiled/authored line:

- **Durations about the supervised work are authored hypotheses.** An agent
  idle 40 minutes is a *guess* that something is wrong — project-variable
  (one team's stall is another's long build), owned by the sweep program,
  evaluated on whatever cadence its theory of attention supplies. TBD never
  evaluates these durations; it timestamps the facts so any evaluator can.
- **Durations about the supervision machinery are compiled contracts.** Each
  measures silence against an expectation *the system itself created*, and
  none involves judgment:
  - an **act** performed at T, verified about a minute later — the re-check
    (design §12);
  - a **declared contact window** with no submission inside it — the sweep
    watchdog (§6).

The desk's own silence sits deliberately on the *authored* side of this
line: a briefing unanswered past a threshold is the same kind of hypothesis
as an agent idle past one, evaluated by this program over TBD-timestamped
facts (the readout's supervisor section, §3) with continuation policy to
match (§7, design §9). The compiled clocks never point outward at the
fleet, and only one points at user-land at all — the contact window, the
clock that rings when the watcher itself stops. The fleet's idleness is
judgment; the machinery's idleness is integrity — if it went unmeasured,
the record would lie by omission.

## 6. Detecting a dead sweep program

The rule that makes detection possible: **"nothing going on" is never
expressed as silence.** A healthy sweep program that finds nothing still
submits — an empty submission, the attested quiet contact (§3). The shipped
program honors that obligation out of the box, and it makes three states
cleanly distinguishable at the pipe:

- **Briefings arriving** — the program ran and found work.
- **Empty submissions arriving within the window** — the program ran and the
  fleet is genuinely quiet. Quiet contact updates the liveness record, never
  the ledger (noise rule, §3); the lifecycle line that ends the coverage
  span carries the coverage
  summary (design §9), so the account can still say "checked 14 times, nothing found":
  an *attested* calm night, durably.
- **No contact past the declared window** — nobody looked. Dead cron, crashed
  script, uninstalled schedule — the daemon cannot tell which and does not
  need to: it responds by tier (below). Silence means exactly one thing.

**What the watchdog does, by tier — and what it never does.** The
last-contact age is a plain displayed fact wherever supervision status
appears: an operator glancing at the app sees "last sweep contact 4 min
ago," no alarm involved. The watchdog proper begins where display ends,
because a status surface nobody is watching protects nobody overnight — that
is the subsystem's founding premise. A missed window writes an **anomaly
line into the ledger**, so the coverage gap is part of the durable account
whether or not anyone was looking; persistent silence (§10) raises an
**operator notification** through the notification channel the requirements
doc assumes exists (designing it is out of scope there), and the anomaly
lines stand in the record either way as the loudest thing in the account.
The desk is deliberately never prompted: a broken sensor is an operator's
problem, not a judgment call, and a desk told "your own sweep is dead" could
do nothing but relay the message. Nor is this new timer machinery — the
daemon already runs compiled cadences (the fact maintenance, design §14's
status write); the watchdog is one more deadline on the clock TBD already
holds. It complements design §14 rather than duplicating it: that
out-of-band watchdog asks
whether the *daemon* is alive; this one asks whether anyone is *feeding* it.

**Daemon-run failures are observed, not inferred.** Silence is the detection
path for schedules TBD does not run; when the default tick runs the program,
TBD watches the process itself, and a crash, hang past the timeout bound
(§10), or nonzero exit writes an **immediate anomaly line** — naming the
program, the exit condition, and the tick — with no window latency. The two
paths share one escalation ledger: a **failed contact** is a missed window
(external schedules) or a failed daemon run (the tick), and the notification
threshold (§10) counts consecutive failed contacts of either kind — so a
customized script crashing on every tick reaches the operator in three tick
intervals, not three contact windows. What counts as contact is precise:
**an accepted submission to the brief pipe.** A run that submits and then
exits badly has made contact — it looked and reported; the bad exit is still
an anomaly. A run that dies before submitting makes none. And contact
attests aliveness, never sense: a program that runs and submits nonsense
prose is delivered like any briefing — TBD never parses the text — and is
caught where prose is read, by the desk's judgment and the operator's
account, not by a liveness clock that is deliberately measuring only whether
anyone looked.

**The contact window** is the declared expectation silence is measured
against. It is armed only while the project is effectively on — mark set,
brake released (§4):
a pause disarms it, because silence the system itself requested is not a
coverage gap. Each window is measured from the later of the last accepted
contact and the moment the watchdog armed — a project owes no contact
for time before its coverage opened. While the default tick runs, the window defaults to a multiple
of the tick interval (§10) and the operator declares nothing. A project on
an external schedule declares its own window in `supervision.json`. A
project that declines even that — a purely event-driven program with no
periodic submission has no honest cadence to declare — gets the degraded
account in so many words: its coverage renders as **unknown**, in the
morning account and on the status surfaces. Every position is available; the
one eliminated is the accidental version, where the account implies
watchfulness nobody was providing. The old system ran the accidental version
for five nights: a component reported missing at every tick had never been
installed at all, and judge sessions raised restart questions for software
that was never built (design §9). The watchdog exists so that failure shape
cannot recur quietly.

**Why the watchdog's clock is TBD's.** Any user-land watchdog is itself a
process that can die unnoticed; adding layers moves the silent-death point
without removing it. The chain terminates only at a process whose failure is
already visible — one that cannot be dead while everything seems fine. The
daemon is that process: if it is down, sessions are unmanaged, the app shows
it, the product is visibly broken. The alarm must also be written into the
ledger — the compiled, append-only record the operator trusts — by something
other than the thing being measured, and the daemon owns that record. This is
the placement rule's own exception pair (liveness attestation, integrity of
the record) applied, not overridden. The guarantee is stated as the
conditional it is: **while TBD runs, silence in the record is meaningful.**
Daemon liveness itself belongs to the layer that already owns it (launchd,
and an operator's eyes on a visibly broken app). Projects may stack further
watchdogs above TBD's; the compiled one is the floor, not the ceiling. And
the window carries one more weight than fleet coverage: the desk's watcher
is this program (design §9), so the clock that rings when the program stops
is also what terminates the desk-watching regress.

## 7. The reference sweep program

The reference program ships **inside TBD's install, tool-owned**: the default
tick runs the shipped copy directly, so every project has working supervision
from its first `on` with nothing authored, nothing configured, and nothing
written into project files — and the program improves with releases, because
the tool still owns it. A project takes ownership only when it wants to:

- **The override is a pointer**: `"sweep": { "script": "<path>" }` in the
  project's `supervision.json` entry (§4) points the tick at the project's
  own program.
- **The "Customize sweep…" gesture makes that concrete** — the exact analog
  of the playbook's "Customize playbook…" gesture (design §5): it copies the
  *currently shipped* program to
  `~/tbd/supervision/projects/<name>/sweep.py` and writes the pointer,
  exactly once. The tool never touches the copy again; after the gesture,
  the file is the project's, and divergence from the shipped copy is
  deliberate. Until the gesture, release improvements arrive for free.

What the program is, wherever it runs from:

- **It carries the threshold numbers as named constants** — the
  idle-intervention threshold, the runaway turn and no-progress windows,
  the desk-overdue threshold, and the desk replacement budget
  (§10). Tuning is taking the customize copy and editing a constant in a
  file the project then owns. There is no per-repo threshold configuration
  surface in TBD and none deferred: numbers live in the program, which also
  preserves the design's one-column property (design §7) permanently — a
  number never becomes a config column.
- **It is the conformance artifact** for all three public surfaces (§3),
  alongside the reference wake script for its own: it may use only public,
  documented surfaces — `tbd supervise readout`, `tbd supervise brief`,
  and `tbd supervise ledger` for its contract, plus the public actuations
  its continuation policy composes with (`tbd supervise on`,
  `tbd terminal send`, `tbd notify`; design §3, §9, §10). A fact it cannot
  obtain that way is a failed
  conformance check and a scoped API request — the mechanism by which TBD's
  surface grows, pulled by a real consumer.
- **It submits on every evaluation**, findings or none — an empty submission
  when quiet — satisfying §6's contact obligation.
- **It supervises the supervisor** (design §9): each run checks the
  readout's supervisor section, and its continuation policy is the shipped
  default — a hosted desk with a briefing unanswered past the desk-overdue
  threshold, or found dead at a delivery attempt (the no-live-supervisor
  result), is replaced through `tbd supervise on` (ensure) and the case
  resubmitted from current state; after the replacement budget's
  consecutive replacements with no attested act between them, it stops and
  pages through `tbd notify`; an appointed supervisor is never touched —
  overdue there means a page, nothing more. A project's copy may nudge
  first through the public send, fail over to another model or agent kind
  by spawning and appointing, or rebind its budgets — continuation is
  authored like the rest of the file.
- **It demonstrates case memory as authored discipline.** Its own files
  record what it has briefed; before briefing an agent's situation it
  consults the ledger query for TBD-side activity since — a situation it
  already briefed, with the ledger showing the desk has not yet acted, is
  skipped rather than re-briefed, and an operator answer it has read is
  carried into the briefings it composes rather than re-asked. Open-case
  dedup and never-re-ask (P1-5) are this discipline, demonstrated by the
  shipped program rather than compiled into the daemon (§11, design §8).
- Its case-cutting defaults are deliberately modest: idle past the threshold
  with uncommitted work briefs a case; runaway counters past their windows
  brief a case; the worktree pin state orders the briefing pinned-first,
  then by case age (design §5, P1-3); facts it cannot interpret brief
  nothing. Sophistication is the project's to add; the shipped copy is a
  floor, not a ceiling.

## 8. Standing conduct: how the playbook reaches the desk

The playbook — every mode description included — is installed as a
standing instruction layer when the desk session is launched, through the
agent-kind adapter: at spawn for a hosted desk, at the appointment relaunch
for an operator-appointed supervisor (design §9) — the same layer, installed
at the same kind of moment. Each delivered briefing then carries the **active
mode's
name** in its compiled header (§3) — a name from `supervision.json`'s
declared list (design §8), never text extracted from the file. The desk
holds the project's whole conduct for the life of its session; the header
tells it which posture is selected right now. For an appointed supervisor the
layer is present, never alone: the session also carries whatever context and
instructions the operator chose it for (design §9).

What this buys, in order of importance:

- **Compaction cannot eat the conduct.** A long night summarizes old turns;
  a playbook embedded in an early message can be compacted into mush by
  briefing fifteen. Standing layers are re-included by construction —
  verified for both shipped desk kinds (dated note, §13). Since deliberate
  recycling is an optimization and auto-compaction bears desk survival
  (design §9), conduct must live where compaction cannot reach it.
- **A mode switch is zero-delta.** The next briefing's header names a
  different mode whose description the desk already holds — mode selection
  takes effect on the next briefing (design §3) with no conduct re-delivery
  and no desk restart. The daemon extracts nothing and delivers no conduct;
  it delivers the selection.
- **Standing weight.** Conduct in the session's instruction layer reads as
  *who you are*; conduct in message one of forty reads as something someone
  said earlier.
- **One copy per session**, prompt-cached, instead of one per briefing — on
  a busy night, tens of thousands of tokens of duplication removed from the
  context window that the fullness ceiling already threatens.

**Playbook edits under a live desk** are the one thing a launch-time layer cannot
carry, and the file cannot be re-read into a live session by either shipped
agent kind (dated note, §13) — so the delta travels in the compiled header
of the next delivered briefing: the changed text, marked as superseding the
standing conduct. The daemon tracks, per desk session, the hash of the
conduct that session stands on; headers carry deltas only while the hashes
differ. Re-baselining does not wait for a full replacement: every
supervisor-capable adapter has a **conduct reload** — relaunch the desk's
session
process *resuming the same conversation*, with the refreshed playbook as its
standing layer (dated note, §13) — so the daemon schedules exactly that at
the desk's next idle moment, and nothing of the session's context is lost.
A replacement or reloaded desk launches with the current playbook,
which is also why a replacement desk needs no special briefing path. The
ledger records the conduct hash per delivery either way, so "what conduct
governed this act" is answerable per action against a versioned file.

**One mechanism serves every conduct moment.** Launching a session's process
with a chosen standing layer and environment — fresh at spawn, resuming the
same conversation every time after — is the whole of the mechanism, and it
is exercised four ways: the install at desk spawn, the
appointment relaunch that adds the layer and the injected identity, the
relieving relaunch that removes both, and the conduct reload above that
refreshes the layer's value after a playbook edit (design §9). Nothing
conduct-shaped travels any other way.

**Installation is a supervisor-capability requirement, not an optional
adapter nicety.** Standing-layer install at (re)launch is one of the four
requirements of the supervisor-capability qualification (design §9, the
normative home; resume without conversation loss, briefing delivery, and CLI
reachability for the public send are the others). An agent kind without the
mechanism cannot run a supervisor at all — hosted or appointed; appointing a
session of such a kind is refused at the gesture with the reason — so there
is exactly one conduct-delivery story, this section's. The Claude adapter
delivers the playbook as a named layer in
the `SystemPromptBuilder` stack TBD already applies at spawn
(`Sources/TBDDaemon/Lifecycle/SystemPromptBuilder.swift`) — the same
mechanism as the existing `TBD_PROMPT_CONTEXT` layer; the Codex adapter
passes it as `developerInstructions` at thread start (dated note, §13, which
carries the per-harness mechanics and, where one is established, the
version floor).

## 9. The delivered briefing

What lands on a desk is the program's text under a short compiled header,
and the whole delivery story states as one rule: **the briefing embeds what
is new, the session layer holds what is standing, and the ledger points at
what is durable** — case prose in the briefing, conduct in the session
layer, transcripts and playbooks by path with hashes in the ledger.

- **The header is TBD's only text**, and it carries only TBD's own facts:
  the active mode's name and any pending conduct delta (§8). TBD adds its
  own information; it never demands structure from the program, and it
  never edits the program's text (§3).
- **Every delivery is recorded** with the delivered text's hash and the
  conduct hash the desk stands on (§3, design §6). "What did this desk
  actually receive, and under what conduct" is answerable per briefing —
  which is what makes a desk that ignores its briefing *diagnosable*: the
  record shows exactly what the briefing carried, so a re-asked question or
  a missed case traces to the program's text or the desk's judgment, never
  to an unrecorded transform in between.
- **Delivery is never held hostage.** The header is compiled and cannot
  fail apart from the daemon itself; there is no authored formatter in the
  delivery path to crash, time out, or drop content (§11, the renderer-hook
  rejection).

## 10. Defaults

| Number | Default | Where it acts |
| --- | --- | --- |
| Default tick interval | 5 min | §4 |
| Contact window, TBD schedule | 3 × tick interval | §6 |
| Contact window, external schedule | declared, or coverage unknown | §6 |
| Watchdog notification | 3 consecutive failed contacts (missed windows or failed runs) | §6 |
| Sweep program timeout (daemon-run tick) | 60 s | §4 |
| Per-project briefing rate limit | 1 briefing / 2 min | §3 |
| Briefing size bound (`brief` stdin) | 256 KiB | §3 |
| Paused-refusal exit code (`brief`) | 75 | §3 |
| Idle-intervention threshold | 40 min | §7 (shipped program constant) |
| Runaway: turns in window | 30 turns | §7 (shipped program constant) |
| Runaway: no-progress window | 90 min | §7 (shipped program constant) |
| Desk-overdue threshold (briefing unanswered) | 60 min | §7 (shipped program constant) |
| Desk replacement budget | 2 consecutive per project | §7 (shipped program constant) |

The first eight are compiled constants; the rest ship as named
constants in the reference sweep program and are listed here as its
documented defaults, not as TBD's. The paused exit code follows sysexits'
`EX_TEMPFAIL` (75): "not now, retry later," which is exactly what the
refusal means.

## 11. Rejected alternatives

- **A compiled case-cutting sweep** — the daemon evaluating thresholds and
  cutting cases itself. Rejected by the placement tie-breaker (design §1):
  the heuristic passes no compiled test decisively — it is project-variable
  judgment about what facts mean, the definition of authored territory — and
  compiling it freezes exactly the logic projects most need to iterate on.
  It would also compile a theory of attention: a tick as the only trigger
  forces duration-thinking on event-shaped projects.
- **A daemon-invoked decision script** — the daemon keeps the tick and pipes
  facts to an authored script on stdin, stdout returning cases through a
  private contract. Attractive because liveness attestation comes free ("I
  called and nobody answered"), but it buys attestation by making the
  daemon's invocation the only trigger and its stdin/stdout the only
  interface, which compiles the theory of attention anyway. The
  pipe-plus-watchdog shape buys the same attestation directly and leaves
  triggers authored. The daemon-run default tick (§4) preserves this shape's
  out-of-box convenience without its monopoly: the program the tick runs
  speaks the same three public surfaces any externally triggered program
  would.
- **A fully external sweep with no liveness contract** — maximum symmetry
  with the wake program: TBD exposes surfaces and neither runs nor monitors
  anything. Rejected on failure asymmetry: a dead wake program leaves parked
  sessions parked — a safe state, deferred work — while a dead sweep leaves
  stuck agents unnoticed all night, the product's core promise silently off,
  indistinguishable from calm. The parked half accepts that ambiguity
  deliberately; the live half measured its cost at five nights once and does
  not accept it again (§6).
- **A compiled baseline with an authored overlay** — a compiled sweep stays
  and a script may add or suppress cases. Fails toward stock behavior
  instead of silence, which is its one virtue, but creates two concurrent
  decision layers to reason about, and delivers tuning as *suppressing the
  output of logic the project cannot edit* — backwards. The shipped
  reference program provides stock-behavior-by-default without a second
  layer, and the customize gesture makes every line of it editable (§7).
- **Routing prompt cases through the sweep program** — uniformity at the
  cost of putting script latency and script bugs on the one path where the
  agent is provably blocked and the hook event is the only live signal.
  There is no authored detection logic in a reported fact, so the descope's
  motivation does not apply. Script-level prompt handling can migrate in
  later on field evidence, as any capability can.
- **A single fleet-global sweep evaluation** — one run seeing all projects
  at once. The project is the policy unit everywhere else (desk, playbook,
  wake program, mode); a global run would reimplement project-membership
  dispatch inside user code and let one project's error silence every
  project's briefings. The tick invokes the program once per project, and a
  custom program is selected per project (§4, §7), so an edit's blast
  radius is the project that edited.
- **A structured evaluation report at the pipe** — per-agent proposals with
  condition and evidence fields, submitted as JSON to a compiled intake that
  assembles them into deliveries. Rejected by representation-follows-consumer
  (§1): no parser ever reads a proposal — the only downstream reader is the
  desk, which reads prose — so the schema would exist solely for TBD to
  disassemble and reassemble text on its way to a model, putting TBD in the
  composition business the placement split assigns to the project. A
  condition vocabulary also rebuilds the old system's rules vocabulary (the
  `clearance` table's verdict kinds, shipped with zero production readers —
  `docs/nightwatch.md` §1) one layer down.
- **An agent-list manifest on the pipe** — briefing text plus a minimal
  structured list of the agents it concerns, so the daemon could dedup or
  track per-agent state. Rejected as the report schema's thin end: any
  structure demanded from the program becomes vocabulary TBD must version
  and the program must satisfy, and the compiled consumers a manifest would
  feed — per-agent cooldowns, open-case tracking — are checks this design
  deliberately places elsewhere: at the identified send, where the target is
  already explicit, and in the program's own memory (§7). The pipe takes
  pure text because its reader is a desk.
- **A separate renderer hook** — a per-project program between compiled
  assembly and delivery, receiving an assembled order structure on stdin,
  its stdout becoming the delivered text. Rejected as the two-author
  artifact: it splits one briefing between a compiled assembler guaranteeing
  structure and an authored formatter free to drop it, forcing a schema into
  existence solely to bridge the two halves of what is naturally one
  authored act — and every guarantee about the assembled contents has to be
  re-litigated against what the formatter kept. With the program composing
  the briefing outright, the split collapses: voice, emphasis, and content
  have one author, and TBD's only text is the compiled header — its own
  information, prepended, never structure demanded (§2, §3).
- **Compiled open-case tracking at the pipe** — the daemon remembering which
  situations have been briefed and dropping repeats. Rejected because dedup
  requires identity, identity requires structure (the manifest above), and
  "the same situation" is a judgment no daemon can make from text. The
  program owns its case memory in its own files, with the ledger query
  supplying TBD's half of the loop — what was delivered, what was acted on,
  what came of it — and the shipped program demonstrates the discipline
  (§7). The identity-blind rate limit is the compiled floor: pacing needs
  no identity, only timestamps (§3).
- **A compiled escalation queue** — see design §8 for the full argument. One
  guaranteed inbox plus forgery-proof consent is a real property, and it is
  still rejected: it freezes question routing into the daemon and builds a
  question data model — the hardest kind of surface to change. Starting
  outside is the reversible direction.
- **An approval-stamp verb** — see design §8. Forgery-proof consent for
  irreversible acts at the cost of one verb, rejected for now as machinery
  with no consumer; revisit on field evidence.
- **Re-delivering the playbook in every briefing** — robust and simple,
  and what the old system's nudge loop did with its whole compiled briefing,
  but it funds the desk's most likely failure (the context
  ceiling) with pure duplication, and re-delivery is the anomaly against the
  design's own transcript-by-path rule. The standing layer plus header
  deltas (§8) keeps every property re-delivery had — mode switches on the
  next briefing, replacement desks briefed on arrival — without the copies.

## 12. Testing

- **Brief round-trip** — briefing text submitted for an effectively-on
  project is
  delivered verbatim under the compiled header; the delivery line carries
  the delivered text's hash and the conduct hash; the synchronous result
  is `delivered`.
- **Result vocabulary** — every refusal and failure returns its pinned
  machine-readable result (refused-paused, refused-off, refused-rate-limit,
  refused-size, transport-failed, no-live-supervisor); a submission for a
  project whose desk has died returns no-live-supervisor with the failure
  recorded, and TBD performs no replacement and no retry of its own.
- **Desk supervision** — the readout's supervisor section reports session
  state, last attested act, and unanswered-briefing age; the shipped
  program replaces a dead hosted desk via ensure and resubmits; past the
  replacement budget it pages and stops; an appointed supervisor is paged
  about, never replaced.
- **Quiet contact** — an empty submission updates the liveness record,
  delivers nothing, writes no ledger line, and is counted in the coverage
  summary on the lifecycle line that ends the span.
- **Pacing** — a second briefing for the same project inside the rate-limit
  window is refused with the machine-readable result and still counts as
  contact; a briefing for a different project inside the same window is
  delivered (the limit is per project and blind to everything else); an
  empty submission is never paced.
- **Paused and off** — with the brake engaged, `brief` exits with the
  pinned paused code; for a project whose mark is off it returns the
  `refused-off` result; either way it delivers nothing and does not feed
  the watchdog; the
  default tick launches no runs while paused; a run in flight at the flip
  finishes within its timeout bound and its submission is refused; no
  external process is signaled. Both branches of the brake and of the mark
  behave (per the
  flag-branch rule).
- **Send preconditions** — an identified supervisor send targeting a
  rate-limited or capacity-held terminal, a target outside the caller's
  project, or issued while the brake is engaged or the project off, is
  refused at the act with an ordinary error naming the condition, and the
  refusal is logged (design §3); an unidentified send passes none of these
  gates and is logged as anonymous; a send to a target with one mid-flight
  queues behind it (transport serialization).
- **Readout facts** — each agent carries the branch, the conflict flag, the
  commits-unchanged-since stamp, and the PR observation and status; the stamp
  is null on a first sighting of a tip and set on the second unchanged one, so
  ignorance never renders as stillness; no per-worktree `git status` runs.
  Both the readout and the ledger query print `schemaVersion` at the top level
  of their object.
- **Ledger query** — returns exactly the joined per-project view since the
  timestamp: the actuation rows touching the project's sessions — any
  identified caller's included — with their outcomes, plus its deliveries,
  lifecycle and enrollment lines, and anomalies; other projects' lines never appear.
  A line the query does not model — an unfamiliar kind, an unrecognized field —
  still appears verbatim with its `source` added; a row that resolves to no
  project is excluded rather than passed through; unparseable lines are
  reported as a count. `--since` accepts all three shapes (ISO-8601 instant,
  bare `HH:MM` resolved backwards in local time, bare relative duration) and
  refuses a fourth naming them.
- **Watchdog** — a missed window writes the anomaly line; the configured
  consecutive count raises the operator notification; contact resets the
  count; the window is disarmed while the project's mark is off or the
  brake is engaged; a project with `schedule: external` and no declared window renders
  coverage unknown, and both branches of the schedule setting behave. On the
  daemon-run path: a crash, timeout, or nonzero exit of a tick run writes an
  immediate anomaly line without waiting for a window; consecutive failed
  runs reach the notification threshold on their own; a run that submits an
  accepted brief and then exits nonzero counts as contact *and* writes the
  anomaly.
- **Dead-vs-quiet** — a quiet-contact night and a no-contact night produce
  distinguishable accounts.
- **Selection** — with nothing configured the tick runs the shipped program;
  a `sweep.script` pointer runs the project's file; the customize gesture
  copies the currently shipped program, writes the pointer, and refuses to
  overwrite an existing copy; playbook seeding is unchanged by any of it.
- **Standing layer** — spawn installs the full playbook via the adapter; a
  mode switch changes only the name in the next delivery's header; a
  playbook edit produces a superseding delta in the next header; a conduct
  reload resumes the same session with the refreshed layer and clears the
  delta; appointment resumes the same conversation with the layer added and
  `TBD_PROJECT` injected, and relief resumes it with both removed (design
  §9); appointing a session whose agent kind lacks the supervisor-capability
  qualification is refused at the gesture with the reason.

## 13. Dated source note: standing-instruction mechanics per agent kind

Facts below are point-in-time observations of external tools, recorded here
so they can rot without touching the design (the wake program's dated-note
discipline). They are also the per-harness evidence behind the
supervisor-capability qualification (design §9): the standing-layer and
resume mechanics each adapter's qualification rests on live here, and so do
its version floors — qualification facts belong with the adapter, not in the
design's prose. Verified 2026-08-01.

- **Claude Code** — `--append-system-prompt` appends to the system prompt at
  launch; TBD already delivers named prompt layers through it via
  `SystemPromptBuilder`, and the desk's playbook layer rides that same
  stack. (`CLAUDE.md` in the desk worktree would also load as project
  instructions, but a materialized copy on disk can diverge from the
  resolved playbook, so it is not used.) Resuming a session
  (`claude --resume <id>`) launches a fresh process that rebuilds its launch
  flags, which is what makes the conduct reload (§8) a resume with a
  refreshed layer value — expected to behave as at spawn; verify at
  implementation.
- **Codex** (codex-cli 0.146.0; flags verified from the binary, behavior
  from `openai/codex` source) — the additive standing mechanism is
  `developer_instructions`: per-invocation via
  `codex exec -c developer_instructions="..."`, or per-thread via the
  app-server protocol's `developerInstructions` field on `thread/start` —
  one field in the same call that spawns the desk. `thread/resume` and
  `thread/fork` accept the same field (schema-verified), which is what makes
  the conduct reload (§8) a resume with a refreshed value. It lands as the
  first developer-role message, above `AGENTS.md`. Compaction re-injects both
  developer instructions and `AGENTS.md` into rebuilt history
  (`codex-rs/core/src/compact.rs`), so the layer survives by design.
  `AGENTS.md` in the desk worktree is the file-based alternative (loaded
  root-down, 32 KiB combined budget) but arrives as a user-role message.
  Caveats: the app-server is flagged experimental; `AGENTS.md` is cached per
  session and **not re-read on file edits** — which is why live-desk
  playbook edits travel as briefing-header deltas (§8) rather than file
  writes; the former `experimental_instructions_file` key is renamed
  `model_instructions_file` and *replaces* base instructions — not the
  mechanism to use here.
