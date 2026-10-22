# Start admission and background priority for agent sessions

TBD starts and wakes Claude Code and Codex sessions on request from other programs: a
command typed in one TBD terminal that opens another, a script that runs `tbd terminal
create` or `tbd terminal wake`, a supervisor that wakes sleeping tabs to deliver work. On a
laptop that also carries its owner's video calls, those starts are the moments that can push
memory and CPU past what the call needs. One case measured on a 12-core, 24 GiB machine:
five agent sessions started in ten minutes took the one-minute load from 32 to 168 with swap
full, and the camera stopped mid-call because its driver could not allocate frame buffers.

This design adds two features, both off by default:

1. **Start admission.** Before TBD starts or wakes an agent session that a program asked
   for, it runs a command the user wrote. The command says yes or no; TBD holds a "no" and
   says why. Starts the user makes in the TBD app are never held.
2. **Background priority.** A command that moves every agent process tree TBD owns to
   macOS background priority, and back, on a lease that ends by itself.

TBD decides neither when the machine is full nor when a call is on. Those thresholds differ
by machine and by person, which makes them a theory two reasonable projects would answer
differently (`docs/theory-placement.md`). So the policy is the user's command, and the
caller that turns background priority on owns the "when". TBD compiles only what it alone
can do: the gate at its own start boundary, the classification of who asked, the timeout
brake, the priority change on processes only it can identify, and the clock that restores
them when nobody renews.

## Start admission

### Which starts

An agent start is a request that would launch a Claude Code or Codex process on this machine:

- `terminal.create` with type `claude` or `codex` (fresh, resumed or forked), and any
  `terminal.create` that resumes a session, whatever its type: that spawns Claude
- `worktree.create` and `scratch.create`, whose primary terminal is an agent
- `worktree.revive` and `worktree.reviveConversationFresh`
- `terminal.wake`, `terminal.resume` and `worktree.resume`, for a terminal that is parked and
  whose kind is `claude` or `codex`
- `terminal.continueInCodex`, `terminal.continueInClaude` and `terminal.swapProfile` when
  it starts a new session; `terminalHistory.revive` when it resumes a Claude session (every
  other kind of history entry reopens as a shell)
- `terminal.recreateWindow` for a Codex tab, which starts Codex again in a new window
- `terminal.migrateTransport` for each running Claude session with a conversation, which it
  parks and wakes on the pty holder. With no terminal id it moves every session, so it can
  start many agents in one call.

Not checked:

- Shell terminals, hook terminals and dev-server tabs (`server.start`).
- A wake of a terminal that is not parked. It starts nothing, and the wake path already
  answers it as a no-op.
- `terminal.recreateWindow` for a Claude tab, which only parks it, and for a shell.
- The moves in `terminal.migrateTransport` that start no agent: a parked row is only
  rewritten, and a running shell restarts as a shell.
- Remote sessions. They run on another machine.

### Who is checked

Each request carries its `ActuationActor`. The gate checks every actor except two:

- `app` is never checked. Everything the app sends follows something the person did in
  it, including the wake that selecting a parked tab performs.
- `daemon` is never checked. TBD's own rails (startup recovery of a half-created
  worktree, and any transport migration TBD starts itself) are out of scope for this
  version.

So `session` (a `tbd` command run inside a TBD terminal, usually an agent), `anonymous` (a
`tbd` command run outside TBD, usually a script or another tool's timer), the reserved
`supervisor` kind, and any kind a newer client declares are all checked. The actor is
self-declared, not authenticated (`ActuationActor.swift`). This is a resource policy, not a
security boundary: a caller that claims to be the app defeats only its own user's policy.

### The command

`~/tbd/hooks/start-admission`, resolved through `TBDConstants` so it honors `TBD_HOME`. One
file per machine, not per repo, because the question is about the machine.

- The flag is off, or the file is absent: every start proceeds as before.
- The file is present: TBD runs it through `runBoundedProcess` with a 10-second limit, its
  own environment, and these variables added:
  - `TBD_START_KIND` – `create` or `wake`
  - `TBD_AGENT` – `claude` or `codex`
  - `TBD_ACTOR` – the actor's kind
  - `TBD_WORKTREE_ID` – the worktree the start belongs to
  - `TBD_TERMINAL_ID` – the terminal, when the start names one
- Exit 0: the start proceeds.
- Any other exit: the start is held. The reason is the first non-empty line of stdout,
  cut to 200 characters, or `start-admission exited N` when stdout has none.
- No answer in 10 seconds, a signal, or a file that cannot run: the start is held with a
  reason naming that. A user who installed a gate wants it to hold when it cannot decide.
- TBD cannot read its own settings, or cannot read the terminal row a wake names: the start
  proceeds unchecked. The flag is off by default, so a start is never held on the strength of
  a flag TBD cannot show the user turned on.

### What a hold does

TBD keeps no queue of held starts. The caller already holds the request and decides when to
ask again, which is exactly the "when" this design keeps out of the daemon.

- The gate runs after the request's actuation row is written and before the first step that
  reaches git, tmux or a process, so a held create makes no terminal row, branch, worktree
  or window. `worktree.create` and `scratch.create` write a `.creating` row (and, for a
  scratch space, its folder) before their actuation row exists; a hold deletes them, the
  same cleanup those handlers already do when the actuation row cannot be written. The
  parent's auto-archive-on-merge setting is not changed until the gate has passed.
  `terminal.continueInCodex` asks before it imports the Claude session into Codex, so a
  held continuation leaves no Codex thread.
- If that cleanup fails, TBD logs it and still answers `startHeld`. The message then names
  what remains (the worktree row id, the scratch folder path) so the caller can remove it.
- The actuation record gets a `refused` outcome with the new reason `held`, carrying the
  hook's reason. The record can then answer "which starts did the gate stop?" without
  reading prose.
- The RPC fails with the new error code `startHeld`, and its message is the reason.
- `tbd` prints `held: <reason>` on stderr and exits 75 (`EX_TEMPFAIL`, try again later), for
  every command whose RPC came back `startHeld`.
- A held wake also records the reason and the time on the terminal row
  (`start_held_reason`, `start_held_at`). The parked pane's notice then reads, for example,
  "Automatic wake held at 9:12: <reason>". The next successful wake clears both. A held
  create has no row to mark; its caller reports it. The note is written only if the row is
  still parked under the same session incarnation as when the command started; a row woken
  or parked again while the command ran gets no note.
- A call that starts several agents (`worktree.resume`, `terminal.migrateTransport`) asks
  before each start until the first hold. Every start after that in the same call is held
  for the same reason without running the command again, so a slow command delays the call
  once, not once per agent.
- `worktree.resume` wakes the admitted terminals, leaves the held ones parked with their
  reasons, and then fails with the first hold, so a caller is never told a resume succeeded
  when part of it did not happen.
- `terminal.migrateTransport` leaves a held session running where it is and lists it under
  `skipped` with the reason `held: <reason>`. The call's report is its answer, so it does
  not fail with `startHeld`.
- A held `terminal.recreateWindow` leaves the Codex tab as it was. The app's own recreate is
  never checked, so the person can always repair the tab.

### The flag

`start_admission_enabled`, a `config` column with no SQL default, so NULL means nobody
chose. `Config.startAdmissionDefault = false`. Set with `tbd config set start-admission
on|off`, shown by `tbd config get`.

## Background priority

### What macOS does

Measured on macOS 26:

- `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)` (what `taskpolicy -b -p PID`
  does) moves that one process to background priority: its base priority drops to 4, its
  disk I/O is throttled, and so are sockets it opens afterwards. Children it already has
  keep their priority. The `getpriority(2)` page says only the calling process may be
  named; on macOS 26 another process of the same user can be, as `taskpolicy -p` relies on.
- A child started after the change inherits background priority, unless it sets its own: a
  lowered Claude Code process's `caffeinate` child read 31 while another child it started in
  the same turn read 4. The sweep below lowers such a process at its next pass.
- `setpriority(PRIO_DARWIN_PROCESS, pid, 0)` (what `taskpolicy -B -p PID` does) restores
  that one process. Its children keep whatever they have.
- The state reads back from the process's base priority (`proc_pidinfo`,
  `PROC_PIDTASKINFO`, `pti_priority`): 4 while in the background. `getpriority` cannot
  read it for another process; it answers 0 either way.

TBD calls `setpriority` and reads `proc_pidinfo` directly, without starting a process per
PID.

### The command

- `tbd agents background on --for <duration>` – required duration, at most 2 hours, written
  as `90s`, `10m` or `1h`. Calling it again renews the lease.
- `tbd agents background off` – restores now.
- `tbd agents background status [--json]` – whether a lease is active, when it ends, and how
  many processes TBD lowered.

One RPC, `agents.background`, carries all three. It is not an actuation row: it changes no
session's input, pty or lifecycle, and its effect is recorded in its own state file instead.

**On:** for each agent terminal that is not parked, TBD finds the root of the agent's
process tree (the holder's child for a holder session, `#{pane_pid}` for a tmux pane) and
walks its descendants. Each process not already in the background is lowered and recorded
as (PID, start time). A process already in the background is left alone and not recorded,
so TBD never restores what someone else lowered. The holder and the tmux server are never
lowered: they carry the terminal's input and output.

**While on:** a sweep every 60 seconds, on an injected clock, repeats the walk. It lowers
any agent process that appeared since the last one, including the trees of agents started
or woken during the lease. With start admission on and a policy that holds starts during a
call, few such agents appear.

Each sweep also drops records whose process has exited or whose PID now names a process with
another start time, so the record stays as long as the set of live lowered processes.

**Off, or the lease ends without renewal:** TBD restores each recorded process whose start
time still matches, then clears the record. A process that started during the lease and
inherited background priority keeps it until it exits: a build an agent started during a
call finishes at background priority, which is what the call wanted.

A terminal at background priority still takes input and shows output; it is slower to
compute, not stopped. Checked once by hand: a real Claude Code TUI against the fake model API
(`scripts/claude-stub.py`), its whole tree lowered to 4, took a typed prompt, rendered the full
answer, and returned to its old priority on restore.

### Restarts

The lease's end and the record live in one file, `~/tbd/agent-background.json`, rewritten
in place. At daemon start an expired lease restores its recorded processes and deletes the
file; a live one is kept and swept. A daemon that shuts down leaves the file and restores
nothing, so the lease outlives a restart. One file, overwritten, cannot accumulate. If the
daemon never comes back, the lowered processes stay lowered until they exit.

### The flag

`agent_background_enabled`, the same three-state pattern. While it is off, `on` fails with
a message naming the flag; `off` and `status` always work, so a user can restore after
turning the flag off.

## Testing

- **The actor table** – each actor kind against each start kind, with the flag on and off.
- **The command runner** – exit 0; exit 1 with a reason; exit 1 with no output; a timeout on
  a test clock; a file that cannot run; a missing file.
- **Hold paths** – a held create writes no row, branch or window; a held wake records its
  reason, spawns nothing, and a later wake clears it; the CLI exits 75 and prints the reason.
- **Background** – a real `sleep` tree lowered and restored, read back from base priority; a
  process already in the background is neither recorded nor restored; lease expiry on a test
  clock; the restart path from the file; a recycled PID (start time mismatch) left untouched.
- **By hand, once** – one stub agent tab at background priority still takes input and shows
  output.

## Who reclaims what

- The two terminal columns live and die with their row.
- `agent-background.json` is one file, owned by the sweep and by daemon start.
- Neither feature creates a branch, window, process or directory.

## Not in this version

- Checking TBD's own daemon rails.
- A queue of held starts inside TBD, with retries.
- Toggles in the app's settings; `tbd config set` sets both flags.

## Rejected alternatives

- **TBD retries held starts itself.** That compiles an answer to "when to try again", and
  the callers that make these requests already queue them.
- **TBD reads the camera, the microphone or a calendar.** That is one user's policy; the
  admission command and the caller of background priority hold it.
- **`renice` instead of background priority.** Nice changes CPU priority only. Background
  priority is the macOS policy for work that must not compete with the person at the
  machine, and it throttles I/O too.
- **A per-repo admission hook.** Room on the machine does not depend on the repository.
- **Lowering an agent at the moment it spawns.** It would add a step to every spawn path
  for a gain of at most one sweep interval, during a lease in which an admission policy
  usually holds new starts anyway.
