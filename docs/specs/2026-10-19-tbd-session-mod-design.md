# The session mod, and composer draft save-and-restore

TBD parks idle Claude sessions to free memory and revives them on demand. A
park must never lose text the person typed into Claude Code's composer but did
not send. Today a screen-scrape guards that, and the guard breaks silently
whenever Claude Code redraws its composer.

This design gives TBD's Claude Code plugin, `tbd`, a hooks module: the
**session mod**. Its first feature, `composer-draft`, saves the draft as the
person types and puts it back when the session revives, so a park can go ahead
with a draft in the box and lose nothing. The mod is built as a home for later
features: one module inside the existing plugin, one directory per session,
one liveness check, and a per-spawn feature list. The composer feature ships
behind a default-off flag, soaks with the scrape running in shadow, and ends
by deleting the scrape and the keystroke veto.

Related: [pending-input detection](../superpowers/specs/2026-07-09-pending-input-detection-design.md)
(the keystroke veto this replaces), [named-reconciler doctrine](2026-08-15-named-reconciler-doctrine-design.md),
[theory placement](../theory-placement.md).

## Problem

`HibernationSafetyChecks.hasPendingInput` captures the terminal screen, finds
the composer's prompt line, and refuses the park when text follows the prompt
glyph. It fails in the unsafe direction: when Claude Code changes how it draws
the composer, the scan finds no composer and reports "nothing pending". That
happened. The scan looked for a line starting with `>`; current Claude Code
draws the composer between two rules and starts the prompt line with `❯`.
Against real screens captured from Claude Code 2.1.302, the original scan read
all five draft states as empty, failing 10 of 14 cases. No test failed,
because every fixture used the old screen. PR #1202 adds the new glyphs; the
next redraw can break the scan the same way.

The keystroke veto (`InputActivityTracker`, `hibernate_input_veto_enabled`) does
not close the gap. It records that input reached a pane after the session went
idle, but cannot tell whether that input was submitted or cleared. It is
default-off, and it gates only the idle sweep and merge-park, never a manual
park.

A third hazard sits in how a park ends Claude. On tmux it types `/exit` and
Enter into the composer, then falls back to Escape, Ctrl+C, Ctrl+C and SIGTERM.
On the pty holder it writes `/exit\r`, then signals. Typing `/exit` is safe only
while a guard guarantees an empty box. With a draft present, `/exit` lands at
the end of the draft and Enter sends the half-written prompt to the model.

**Goal:** a park never loses unsent composer text, and nothing in that
guarantee reads the screen.

## Facts this design rests on

Field measurement and source reading, against Claude Code 2.1.303 and the
current tree. Only the newest Claude Code release is supported.

- **Settings hooks see no composer.** The full hook-event list in 2.1.303 has
  no event that fires while the person types. `UserPromptSubmit` is the finest
  grain.
- **The mod API reads and writes the composer.** A mod is a plugin whose
  `hooks/hooks.json` names a hooks module. Its typed API offers:
  - `$.prompt.read()`, which returns `{ text, cursor }`.
  - `prompt.edit`, raised on the edits the person's keys make, short pastes
    included. `await next(e)` resolves the box after the edit.
  - `prompt.change`, raised on every other change, with `origin.kind`: `clear`
    (submit, Ctrl+C, stash), `history`, `undo`, `plugin` (a fill), `app`, and
    `engine` (everything else: a draft put back, a large paste). A kind the
    engine adds later is to be treated as `engine`.
  - `$.prompt.fill({ text, mode })`, which writes the box and answers
    `isFilled: false` under a dialog or before the box mounts.
  - `session.start` and `session.end`. `session.end` fires with reason `other`
    when the process gets SIGINT, SIGTERM or SIGHUP.
  - `$.fs.write` to absolute paths, `$.env.get`, `$.session.id()`,
    `$.clock.after` and `$.clock.every`, `$.state` (session-scoped values), and
    a `ui.render` hook on the `AbovePrompt` component, which draws a row above
    the prompt.
- **A module's hooks are fixed when it loads.** The module runs with no Node
  environment, so `register` cannot read environment variables; hooks read
  them through `$.env.get` when they run. One plugin names at most one hooks
  module, which may import other files.
- **Interactive sessions hot-reload `--plugin-dir` folders.** When files in such
  a folder change, the session reloads the plugin: `register` runs again and
  `session.start` fires again. Values in `$.state` survive a reload; the
  module's own variables start over. Removing the module from the folder
  unloads it. `claude -p` and SDK hosts do not hot-reload. Every load and
  unload prints a dim system line in the session's transcript, `tbd: reloaded
  …` or `… unloaded`, in every running session that loaded the plugin, legacy
  sessions included (measured live).
- **A plugin's name is part of its identity.** It names the plugin's skills
  (`tbd:tbd`, `tbd:nightwatch`), its error lines, `$.plugin.name`, and the keys
  of its `$.state` and `$.store`.
- **The hooks fire as documented.** A probe mod on a private tmux socket, in a
  live 2.1.303 session, wrote the box to a file on each event:
  - typing `half-written prompt` raised `prompt.edit` with 19 characters
  - Ctrl+J and a second line raised `prompt.edit` with both lines
  - Ctrl+C raised `prompt.change` with `clear` and an empty box
  - typing one character and deleting it raised `prompt.edit` with an empty box
  - the up arrow raised `prompt.change` with `engine` and the recalled draft
- **Some of what the box holds never reaches the mod.** Measured against
  2.1.303 with the fake model API:
  - a 50-line paste raised no `prompt.edit`. It raised `prompt.change` with
    `engine`, and its `text` held only Claude Code's placeholder,
    `x[Pasted text #2 +50 lines]`, never the pasted lines
  - the up arrow recalling a cleared draft that held such a paste raised
    `prompt.change` with `engine` and the placeholder
  - a short paste, `short paste`, raised `prompt.edit` whose `inputText` was
    the text itself, with no placeholder
  - Ctrl+C raised `prompt.change` with `clear`

  A draft holding a collapsed paste therefore cannot be saved from the box's
  text: restoring that text would restore the placeholder, and so would
  restoring anything else the box shows as one, such as an image.
- **Modules can be withheld.** The engine loads no hooks module until the
  workspace is trusted, organization policy can refuse a module, and the
  worker that runs modules can die.
- **Claude Code persists drafts itself in one place.** Its background-session
  host writes the composer to `$CLAUDE_JOB_DIR/.prompt-draft` when told to shut
  down, and fills it back on reconnect. That host speaks an internal protocol
  (`CLAUDE_BG_RENDEZVOUS_SOCK` with an auth token), but it settles the approach:
  persist the draft instead of detecting it.
- **TBD already delivers a plugin.** Every Claude spawn path passes
  `--plugin-dir` (`ClaudeSpawnCommandBuilder`) naming one shared directory,
  the `tbd` plugin, which `PluginDirWriter` writes at daemon start. The
  exceptions are the `claude -p` completion probe, `claude --cloud`, and any
  `claude` a person types by hand. None of those is ever parked.
- **Parking applies to Claude sessions only.** `isClaudeResumable` excludes
  Codex and shell terminals.
- **A wake resumes the same session.** Every wake path runs
  `claude --resume <claudeSessionID>` without `--fork-session`. Archive revive
  and history revive resume the same session ID under a new terminal ID. A
  message sent with a wake travels as a trailing argument to `claude --resume`,
  not as typed keys, and `terminal.send` to a parked session is refused.

## The session mod

### Shape

The session mod is the hooks module of the existing `tbd` plugin, beside the
skills that plugin already carries. The plugin keeps its name, because its
skills are named after it. `hooks/hooks.json` names `hooks/register.ts`, a thin
entry point. Each feature lives in a file of its own under `hooks/features/`
that exports the hooks it needs, and `register.ts` imports every feature and
wires its hooks. A later feature adds a file and a line in `register.ts`. The
entry point also owns the parts every feature shares: the liveness heartbeat,
the per-session directory, and the feature gate.

### Presence

The module is present only while at least one feature's flag is on.
`PluginDirWriter` owns the plugin's `hooks/` directory and its plugin-root
`types/` directory, which holds the mod's `$.state` contract:

- It writes `hooks/` and `types/` whenever any feature flag is on, and removes
  both when every feature flag is off. While they are present, the plugin
  manifest names the contract, `"types": "./types/index.d.ts"`; with every flag
  off, the manifest names none. It acts whenever a feature flag changes, and at
  daemon start once the database is open, since the flags live there, and
  before any spawn path is reachable. A daemon in mock mode writes nothing to
  the plugin folder, which lives outside `TBD_HOME`.
- It writes a file only when its content differs from what is on disk. Every
  write reloads the plugin in every running session, so an unchanged daemon
  restart must write nothing. The same rule applies to the skill files it
  already writes.
- It leaves alone what others write in the directory: `.claude-plugin/types/`,
  which the engine lays down at each load, and runtime folders under `skills/`.

Hot reload carries each change to running sessions. Turning the first feature
flag on loads the module everywhere; turning the last one off unloads it
everywhere; an update that changes the module reloads it everywhere. With
every feature off, no session loads a hooks module at all.

### Feature list

A spawn made while at least one feature's flag is on sets three environment
variables:

- **`TBD_SESSIONS_DIR`** – the root of the per-session directories, derived
  from `TBDConstants` so it follows `TBD_HOME`.
- **`TBD_MOD_FEATURES`** – a comma-separated list of the features on for this
  spawn, such as `composer-draft`.
- **`TBD_TERMINAL_INCARNATION_ID`** – already set on wake, swap and recreate;
  every spawn made with a feature on sets it, fresh spawns included.

A spawn that forks a new session (`--fork-session`, as carryover and a forked
profile swap do) learns its session ID only after it starts, so it sets none of
them and stays legacy until it next wakes.

A spawn with every feature off sets none of them. Every feature's hooks check
`TBD_MOD_FEATURES`, read once through `$.env.get` and cached, and a feature
not on the list passes each event straight to `next(e)` and writes nothing. A
session spawned before a flag turned on therefore loads the module through hot
reload, but runs none of its features.

### Reloads

A reload re-runs `register` and fires `session.start` again in a process that
has been running all along. The mod keeps per-process facts that must survive
a reload in `$.state`, never in module variables. A feature's `session.start`
work that must happen once per process checks `$.state` first. The heartbeat
timer starts with each load.

A reload is visible: every load and unload prints a dim `tbd: reloaded …` or
`… unloaded` system line in the transcript of each running session that
loaded the plugin, legacy sessions included. Each flag toggle and each update
that changes the mod prints one.

### Per-session directory

Each Claude session gets `<TBD_SESSIONS_DIR>/<claudeSessionID>/`. It is keyed
by Claude session ID because `--resume` keeps that ID across every wake and
revive, while terminal IDs change on archive and history revive. The mod
resolves the directory from `$.session.id()` at each write, so a `/clear` that
moves the process to a new session ID moves its writes too. The daemon holds
the sessions root at mode 0700 whenever it writes a spawn record, because
drafts can hold pasted secrets.

Shared files:

- **`spawn.json`** – written only by the daemon, before the Claude process
  starts, on every spawn made with a feature on: session ID, incarnation ID,
  spawn time, and the feature list passed in `TBD_MOD_FEATURES`. A wake
  rewrites it and touches nothing else in the directory.
- **`alive.json`** – written only by the mod: session ID, incarnation ID, the
  mod's version, the features it ran, and a heartbeat time. The mod writes it
  at each load and every 30 seconds after, on a `$.clock.every` timer.

Each feature owns files named after itself, such as `composer-draft.json`.
Every JSON file carries a `schemaVersion`. Readers ignore fields they do not
know and read a file missing a required field as unknown, so the daemon and a
module from a neighboring TBD version keep working while an update reloads.

The per-session directory leaves room for a later channel from the daemon to
the mod, such as an inbox a feature reads. This design builds none.

### Liveness

`SessionModLiveness` is a pure function of `spawn.json`, `alive.json`, the live
incarnation ID and the current time (the injected date seam). It answers, for
a named feature, one of three states:

- **Legacy** – no `spawn.json`, one whose feature list lacks the feature, or
  one naming a different incarnation than the live one. The process was
  spawned without that feature and keeps the old behavior until it next
  respawns.
- **Confirmed** – `spawn.json` and `alive.json` name the live incarnation,
  `alive.json` lists the feature, and its heartbeat is no older than 90
  seconds.
- **Unknown** – the feature was spawned but the mod has not confirmed this
  process. The reason is one of: `no-alive-file`; `other-incarnation`, an
  `alive.json` from another incarnation (the module did not load this time);
  `feature-not-running`, an `alive.json` that does not list the feature;
  `stale-heartbeat`, older than 90 seconds (a dead worker, a module unloaded
  because every flag turned off, or writes failing on a full disk);
  `unreadable-file`. A feature can add a reason of its own read from its
  files: composer-draft adds `draft-not-restorable` (see "Parking").

Every daemon-side consumer of a feature starts from this answer. The 30-second
heartbeat and the 90-second limit are named constants. They are liveness
attestation, which the placement doctrine keeps compiled.

### Reclaiming files

The per-session directories are a new durable resource. Archive removes them,
and one new `OrphanGC` arm under `gcEnabled` reclaims the rest.

**Archive deletes them.** Every path that archives a worktree removes the
session directory of each Claude session in it, draft included, once that
session's process has exited. The mod writes the box one last time on
`session.end`, so a removal before the exit would be undone by that write. The
wait covers the pane's process on tmux and the job on the holder. When the
login shell execs Claude, as zsh does for the spawn command's `-c`, that
process is Claude; otherwise a late `session.end` write can recreate the
directory, and the `OrphanGC` arm reclaims it after `gcGraceSeconds`. A
session whose teardown may have left it running, such as a window whose kill
failed and whose pane's process could not be read, keeps its directory, and so
does a session another row names while that row may still be running. A
parked session has no process, so its directory goes at once. The sessions of
a revived worktree therefore resume with an empty box and no notice. Archive
has always treated a live session's box this way: ending the process discards
whatever the box held.

**The arm reclaims the rest.** A session directory stays while a person can
resume its session from a worktree that is not archived, which is while either
record names its session ID:

- **A terminal row's `claudeSessionID`** – the session is running or parked.
- **A `terminal_history` row's `claudeSessionID`, in a worktree that is not
  archived** – the terminal was closed, and `terminalHistory.revive` can resume
  it. History keeps the newest 50 entries per worktree, so a session that falls
  off the end can no longer be resumed, and its files go with it.

A worktree's `archivedClaudeSessions` is not a reference. Once no record names a
directory and nothing has written inside it within `gcGraceSeconds`, the arm
removes the whole directory. That covers a closed terminal that falls out of
history, a forgotten worktree, a write that lands after archive's removal
because teardown failed to stop the process, and an archive path that missed
its removal. Archive already logs a teardown failure, and a revive inside the
grace period that follows one could still restore the late draft. A parked
session's files survive however long the park lasts. A feature that keeps files
with a shorter life names its own rule inside the directory; later features add
files, not reconcilers.

The plugin directory needs no new reconciler: it is the existing one, and
`PluginDirWriter` decides what `hooks/` and `types/` hold.

## The composer-draft feature

### Overview

The feature writes the composer's state to `composer-draft.json` on every
change, with a mark saying whether the saved text holds all of the draft.
Before a park, the daemon checks the feature's liveness and reads that file.
If the feature is confirmed for the live process and the draft, if any, is
marked restorable, the park proceeds and ends Claude with a signal instead of
typed keys. When the session resumes, the feature fills the saved draft back
into the box and shows a short notice above the prompt. When TBD cannot
confirm the draft, because liveness is unknown or the draft is not
restorable, automatic parks skip the session, and a manual park asks the
person. Archiving the worktree deletes the draft (see "Reclaiming files").

### Hooks

- **`session.start`** – restores the saved draft, once per process (below).
- **`prompt.edit`** – awaits `next(e)` and queues a write of the resulting box.
  It does not await the write, so typing never waits on disk.
- **`prompt.change`** – queues a write of `e.text`. A `clear` empties the box,
  so the write records no draft.
- **`session.end`** – queues a write of the box when it is non-empty, and
  awaits every queued write. An empty box needs no final write: every clear
  was already saved by `prompt.change`, and a box the shutdown has already
  unmounted reads empty, which must not overwrite the saved draft.
- **`ui.render` on `AbovePrompt`** – draws the restore notice while it is
  visible, and otherwise passes through with `next(e)`.

Every hook registration carries a `.catch` that passes the event on, so a hook
that throws leaves the event as it would be without the mod.

Writes run one at a time, and a queued write replaces any queued write behind
it, so an older box can never land after a newer one. A non-empty box saves
its text, its cursor and its restorable mark. An empty box removes the text
and records that no draft exists.

**The restorable mark** says whether the box's text holds all of the draft.
Some changes put content in the box that its text does not carry (see "Facts
this design rests on"), so the mark is tracked from origins, never from the
text:

- A `prompt.change` whose origin is anything but `clear` or `plugin` (`engine`,
  `history`, `undo`, `app`, or a kind this build does not know) and that leaves
  a non-empty box marks the draft not restorable.
- The mark clears whenever the box becomes empty: a `clear`, or an edit or
  change that leaves `''`.
- A `prompt.edit` keeps the mark. Typing after a paste does not put the paste
  in the text.
- The feature's own restore fill sets the mark to the restored draft's saved
  value. When the engine changed the text the fill put in (an over-long text
  collapsed into a placeholder), the draft is marked not restorable.
- Another plugin's fill keeps the mark.

The mark lives in `$.state`, so a reload keeps it.

### Files

- **`composer-draft.json`** – whether a draft exists, the draft text and
  cursor, whether the text holds all of the draft (`restorable`, on a draft
  only), and when the box was last saved.
- **`composer-draft.unrestored`** – the text of a draft the feature could not
  restore because the box already held text. Later saves never touch it.
  `OrphanGC` removes it 30 days after its last write, as the `unsent-prompts/`
  arm does.
- **`composer-draft.restore.json`** – the outcome of the latest restore in
  this session, `restored` or `unrestored`, with the incarnation that ran it
  and when. Each outcome overwrites it. It goes with its directory.

### Parking

The gate's existing rails run unchanged. The feature's liveness, then its
file, decides:

- **Legacy** – today's path: `hasPendingInput`, then the typed `/exit`.
- **Confirmed** – the park proceeds, with an empty box or with a draft marked
  restorable.
- **Unknown** – the idle sweep and merge-park skip the session and log the
  reason. A manual park returns a distinct refusal; the app turns it into
  "TBD can't confirm this session's draft is saved. Hibernate anyway?", and a
  yes reissues the park with an override.

A confirmed session whose draft is marked not restorable, or carries no mark,
reads unknown with the reason `draft-not-restorable`: a wake would restore the
placeholder in place of the pasted content. It takes the unknown path
unchanged.

For a session spawned with the feature, TBD never types into the composer to
end it: no `/exit`, and no Escape or Ctrl+C fallback either, because a
daemon-sent Ctrl+C clears the box and the feature would record the draft as
gone. It sends SIGTERM to the Claude process. Claude Code's SIGTERM handler
runs the same graceful shutdown as Ctrl+C and SIGHUP, so `session.end` makes
the final save, and the existing escalation (`respawn-window -k` on tmux,
abandon on the holder) still guarantees the process ends. The rule covers the
tmux park, the holder park, and both in-place profile swaps; the tmux swap
loses drafts today.

While the flag exists, a park of a confirmed session still runs
`hasPendingInput`, only to compare with the feature. Each disagreement goes to
the `com.tbd.daemon` log under category `composer-draft` at `.notice`, which
`log show` retains, naming the terminal, the feature's answer and the scrape's
answer. The scrape never decides a park of a session spawned with the feature.

### Waking

A wake resumes the session as it does today. In the new process, the
feature's `session.start` hook checks `$.state` for a restore already done in
this process, then reads `composer-draft.json`. When a draft exists and no
restore has run, the feature:

1. Waits until the box is mounted and empty, retrying `$.prompt.fill` every
   500 milliseconds while it answers `isFilled: false`.
2. Fills the box with `mode: 'replace'`, and records the restore in `$.state`.
3. Shows "Restored your unsent draft" above the prompt for 3 seconds. A
   `$.clock.after` timer hides it, and the band redraws without it.

The `$.state` record keeps a reload from restoring a second time into a box
that already holds the draft. The fill raises `prompt.change`, which saves the
draft again with its saved mark, so a second park before any edit still keeps
it. Until the fill lands, an empty box is not saved, because it would
overwrite the only copy of the draft. If the person's own text reaches the box
before the fill lands, the feature leaves the box alone, writes the saved
draft to `composer-draft.unrestored`, records the restore as done, and logs
it. Either outcome is written to `composer-draft.restore.json`.

A draft marked not restorable is restored as saved after a park the person
overrode: they were warned that part of it could be lost.

A message delivered with the wake arrives as an argument to `claude --resume`.
Implementation verifies, against the fake model API, that Claude submits that
argument without passing it through the box. If it does pass through the box,
the feature waits for that first prompt's submit before restoring, so the
draft and the message never mix.

A revive on a fresh branch (`--fork-session`) gets a new session ID; the draft
stays with the original session.

### Flag

`composer_draft_enabled`, default off:

- a `.sql` migration, `ALTER TABLE config ADD COLUMN composer_draft_enabled
  INTEGER;` with no `DEFAULT`, appended to the migration manifest test
- `ConfigRecord` holds `Bool?`, resolved with `?? Config.composerDraftDefault`
  (`false`)
- an optional field on the shared `Config` model
- a setter RPC, `tbd config` support, and a Settings toggle

While it is the only feature, the flag decides whether the plugin carries the
hooks module at all, and it decides whether a spawn lists `composer-draft` in
its features. A park follows `spawn.json`, not the current flag:

- **Turning it on** loads the module into running sessions, but sessions
  spawned earlier stay legacy until they respawn.
- **Turning it off** unloads the module everywhere. Sessions spawned with the
  feature then read as unknown until they respawn: automatic parks skip them,
  and a manual park asks. That fails safe.

### Soak and graduation

The flag is turned on on the author's machine. The soak reads three signals.
Two are `com.tbd.daemon` log lines under category `composer-draft`:
feature-versus-scrape disagreements, and parks skipped or refused for an
unknown reason, with the reason. The third is restores, read from the session
directories rather than any log: each `~/tbd/sessions/*/composer-draft.restore.json`
records its session's latest restore outcome, and a
`composer-draft.unrestored` beside it holds a draft that could not go back.
The flag graduates when every case where the scrape saw a draft and the
feature did not is explained as a scrape false positive, such as a grayed
suggestion the scrape read as typed text, and restores have been seen working
on both tmux and holder. Graduation flips `Config.composerDraftDefault`.

### Deletion after graduation

A later PR deletes, together:

- the flag, which makes `composer-draft` a feature every spawn lists and keeps
  the hooks module in the plugin for good
- `hasPendingInput`, its three call sites, and its `.swiftlint.yml` exclusion
- the typed `/exit` and the Escape and Ctrl+C park endings
- the keystroke veto: `InputActivityTracker`, its gate rail, its RPC and its
  Settings toggle (the `hibernate_input_veto_enabled` column stays, since
  landed migrations are frozen)

The flag and the scrape go in one PR, so a person who opted out is never left
without a guard. After it, a session whose feature is not confirmed never
parks automatically.

## Testing

Each gating branch gets its own test.

- **Plugin writer** – `hooks/` and `types/` present, and the manifest naming
  the contract, when any feature flag is on, and all three absent when all are
  off; a flag change writes or removes them; an unchanged daemon start writes
  nothing; `.claude-plugin/types/` and `skills/` runtime folders survive every
  write.
- **Liveness** – legacy (no `spawn.json`; a feature list without the feature;
  another incarnation's `spawn.json`), confirmed, and each unknown reason: no
  `alive.json`, another incarnation, the feature not running, a stale
  heartbeat, an unreadable file.
- **Draft status** – confirmed with a restorable draft and confirmed empty, on
  top of the liveness answer; a draft marked not restorable, or carrying no
  mark, reads `draft-not-restorable`; an empty box needs no mark.
- **Park gate** – a legacy session takes the scrape path; a confirmed session
  follows its file and never consults the scrape's answer.
- **Park ending** – a session spawned with the feature gets a signal and no
  keys, asserted on the transport, for both transports and both profile swaps,
  and against a real holder, where the job's own stdin records nothing and its
  `SIGTERM` handler runs; a legacy session gets the typed `/exit` as today.
- **Manual park** – unknown returns the distinct refusal, and the override
  parks.
- **Shadow log** – a disagreement produces the log line, asserted on its
  composed text.
- **Spawn** – the flag on sets all three environment variables, lists
  `composer-draft` in `TBD_MOD_FEATURES`, and writes `spawn.json`; every
  feature off sets none of them and writes nothing.
- **Flag states** – a pre-migration row reads NULL, and an explicit `false`
  survives a change to `Config.composerDraftDefault`.
- **Reconciler** – a session directory named only by a terminal row, or only by
  a `terminal_history` row in a worktree that is not archived, is kept; one
  named only by `archivedClaudeSessions`, or only by history in an archived
  worktree, is removed past the grace period; an unreferenced one inside the
  grace period is kept; and `composer-draft.unrestored` goes at 30 days.
- **Archive** – archiving a worktree with a parked session that holds a draft
  removes that session's directory, and reviving the worktree restores nothing;
  a session whose teardown may have left it running, or that another row left
  running names, keeps its directory.
- **Mod** (`claude plugin test`, mock clock):
  - `alive.json` is written at load and its heartbeat ticks
  - a feature missing from `TBD_MOD_FEATURES` writes nothing and passes every
    event through
  - an edit saves; a clear records no draft
  - the restorable mark: an `engine` change marks the draft, a clear or an
    emptied box resets it, an edit keeps it, the restore fill carries the saved
    value, and the record carries the mark
  - a restore fills an empty box; a non-empty box produces
    `composer-draft.unrestored`; each outcome writes
    `composer-draft.restore.json`; an empty box is not saved while a restore is
    pending
  - a second `session.start` in the same process, as after a reload, restores
    nothing
  - the notice appears and disappears at 3 seconds
- **Live checks during implementation**, at zero token cost with
  `scripts/claude-stub.py`:
  - a change to the `--plugin-dir` folder reloads the module in a running
    interactive session without asking the person anything, and removing
    `hooks/` unloads it; each prints its `tbd: reloaded …` or `… unloaded`
    line in the transcript, legacy sessions included
  - rewriting a skill file with unchanged content triggers no reload
  - a SIGTERM park leaves a valid transcript tail, and the wake restores the
    draft, on tmux and on the holder
  - a wake carrying a message does not mix it into the draft
  - archiving a worktree whose live session holds a draft leaves no session
    directory once archive returns, on tmux and on the holder
  - where the notice sits relative to queued messages

## Out of scope

- Any second feature. Plausible ones: transcript streaming through
  `turn.step` instead of the model proxy (#1206); answering permission prompts
  and questions in-process (#1208); `terminal.send` delivering through
  `$.prompt.submit` instead of typed paste and Enter (#1209); usage figures
  from `$.session.usage()` in place of the status-line capture (#1207). Each
  gets its own spec.
- A channel from the daemon to the mod.
- Turning the idle sweep back on by default. `v50` turned it off because of
  the scrape's failure direction; that follow-up can cite this design's soak.
- Codex sessions, which are never parked.

## Rejected alternatives

- **Keep the scrape as a fallback for unknown liveness.** The fallback would
  run only when the mod is missing, which makes it the least exercised path in
  the system, and the scrape fails silently in the unsafe direction. Refusing
  the park fails safe, and a person at a manual park can override.
- **Have the mod report emptiness and refuse parks with a draft.** A stale
  "empty" still deletes the text, an idle session holding a draft never parks,
  and the scrape survives as an arguable second opinion on the same question.
  Saving removes the question.
- **Save only in `session.end`.** SIGKILL or a crash skips `session.end`, and
  the daemon could confirm nothing before a park.
- **Drive Claude Code's background-session host** (`CLAUDE_JOB_DIR`,
  `CLAUDE_BG_RENDEZVOUS_SOCK`). It already persists drafts, but its protocol is
  internal and unversioned, and the session kind it implies changes other
  behavior.
- **Keystroke tracking as the primary signal.** Input bytes cannot tell a
  submitted draft from a cleared one; the composer's own state can.
- **Parse Claude Code's paste placeholders** to tell a draft holding a
  collapsed paste. The placeholder is display copy: when Claude Code rewords
  or redraws it, the parse breaks silently and in the unsafe direction, the
  same failure as the screen-scrape this design removes. Change origins are a
  typed API.
- **Clear the box before typing `/exit`.** The mod cannot tell a daemon-sent
  clear from the person's own, so it would delete the draft it just saved.
- **A separate plugin for the mod, passed by a second `--plugin-dir` only to
  spawns with a feature on.** Its one advantage, keeping the module out of
  sessions spawned with every feature off, is matched by writing `hooks/` only
  while a feature is on, which hot reload carries to running sessions. A
  separate plugin would also have to merge into `tbd` once the mod is always
  on, renaming it, and a plugin's name keys its `$.state`, its `$.store` and
  its error lines; it cannot take the `tbd` name itself, because the skills
  are named after that plugin.
- **A plugin per feature.** Claude Code loads one hooks module per plugin, so
  each feature would bring its own plugin directory, environment variables,
  liveness check and reconciler. One module with feature files shares all
  four.
- **A directory per feature instead of per session.** Each feature would need
  its own reclaim rule keyed on the same session references. Grouping by
  session lets one arm reclaim everything a session left behind.
- **Keep the module loaded and idle while every feature is off.** An idle
  module still adds a hook dispatch to every edit and loads a worker into
  every session, for users who never opted in.
- **Two flags for composer-draft, one for save-and-restore and one for the park
  decision.** Four combinations to test, one of them meaningless: a park
  decision that depends on a feature that is not loaded.
- **Build the daemon-to-mod channel now.** No feature needs one yet, and its
  shape depends on the first consumer. The per-session directory leaves room
  for it.
- **Restore silently, or announce with a toast.** A draft that reappears
  without a word is easy to send by accident. A notice above the prompt, where
  queued messages appear, explains the text at the spot the person is looking,
  and dismisses itself.
