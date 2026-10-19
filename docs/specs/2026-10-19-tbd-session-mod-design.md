# The tbd-session mod, and composer draft save-and-restore

TBD parks idle Claude sessions to free memory and revives them on demand. A
park must never lose text the person typed into Claude Code's composer but did
not send. Today a screen-scrape guards that, and the guard breaks silently
whenever Claude Code redraws its composer.

This design adds `tbd-session`, a Claude Code mod that TBD loads into the
sessions it spawns, and gives it its first feature, `composer-draft`. The
feature saves the draft as the person types and puts it back when the session
revives, so a park can go ahead with a draft in the box and lose nothing. The
mod is built as a home for later features: one plugin, one directory per
session, one liveness check, and a per-spawn feature list. The composer feature
ships behind a default-off flag, soaks with the scrape running in shadow, and
ends by deleting the scrape and the keystroke veto.

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
  - `prompt.edit`, raised on every edit the person makes, keys and pastes alike.
    `await next(e)` resolves the box after the edit.
  - `prompt.change`, raised on every other change, with `origin.kind`: `clear`
    (submit, Ctrl+C, stash), `history`, `undo`, `plugin` (a fill), and `engine`
    (everything else, a draft put back included).
  - `$.prompt.fill({ text, mode })`, which writes the box and answers
    `isFilled: false` under a dialog or before the box mounts.
  - `session.start` and `session.end`. `session.end` fires with reason `other`
    when the process gets SIGINT, SIGTERM or SIGHUP.
  - `$.fs.write` to absolute paths, `$.env.get`, `$.session.id()`,
    `$.clock.after` and `$.clock.every`, and a `ui.render` hook on the
    `AbovePrompt` component, which draws a row above the prompt.
- **One hooks module per plugin.** The loader refuses a plugin whose manifest
  names two. A module may import other files.
- **The hooks fire as documented.** A probe mod on a private tmux socket, in a
  live 2.1.303 session, wrote the box to a file on each event:
  - typing `half-written prompt` raised `prompt.edit` with 19 characters
  - Ctrl+J and a second line raised `prompt.edit` with both lines
  - Ctrl+C raised `prompt.change` with `clear` and an empty box
  - typing one character and deleting it raised `prompt.edit` with an empty box
  - the up arrow raised `prompt.change` with `engine` and the recalled draft
- **Modules can be withheld.** The engine loads no hooks module until the
  workspace is trusted, organization policy can refuse a module, and the
  worker that runs modules can die.
- **Claude Code persists drafts itself in one place.** Its background-session
  host writes the composer to `$CLAUDE_JOB_DIR/.prompt-draft` when told to shut
  down, and fills it back on reconnect. That host speaks an internal protocol
  (`CLAUDE_BG_RENDEZVOUS_SOCK` with an auth token), but it settles the approach:
  persist the draft instead of detecting it.
- **TBD already delivers a plugin.** Every Claude spawn path passes
  `--plugin-dir` (`ClaudeSpawnCommandBuilder`), pointing at one shared
  directory that `PluginDirWriter` writes at daemon start. The exceptions are
  the `claude -p` completion probe, `claude --cloud`, and any `claude` a person
  types by hand. None of those is ever parked.
- **Parking applies to Claude sessions only.** `isClaudeResumable` excludes
  Codex and shell terminals.
- **A wake resumes the same session.** Every wake path runs
  `claude --resume <claudeSessionID>` without `--fork-session`. Archive revive
  and history revive resume the same session ID under a new terminal ID. A
  message sent with a wake travels as a trailing argument to `claude --resume`,
  not as typed keys, and `terminal.send` to a parked session is refused.

## The tbd-session mod

### Shape

`tbd-session` is a plugin of its own, separate from the shared `tbd` plugin
that carries TBD's skills, in a sibling directory under the same
application-support root. `PluginDirWriter` writes it at daemon start and
replaces the directory wholesale, so a module from an older TBD never lingers.
Its source ships inside the install, as the `tbd` plugin's skills do.

Its hooks module, `register.ts`, is a thin entry point. Each feature lives in a
file of its own that exports the hooks it needs, and `register.ts` imports
every feature and wires its hooks. A later feature adds a file and a line in
`register.ts`, never a plugin. The entry point also owns the parts every
feature shares: the liveness heartbeat, the per-session directory, and the
feature gate.

### Loading and the feature list

Each feature has its own flag in the daemon's config. A spawn made while at
least one feature's flag is on passes a second `--plugin-dir` naming
`tbd-session`, plus three environment variables:

- **`TBD_SESSIONS_DIR`** – the root of the per-session directories, derived
  from `TBDConstants` so it follows `TBD_HOME`.
- **`TBD_MOD_FEATURES`** – a comma-separated list of the features on for this
  spawn, such as `composer-draft`.
- **`TBD_TERMINAL_INCARNATION_ID`** – already set on wake, swap and recreate;
  every spawn that loads the mod sets it, fresh spawns included.

A spawn with every feature off passes none of these, and the mod never loads.
A loaded mod puts hooks in the typing path, so all-off must mean absent, not
loaded and idle.

Inside the mod, every feature's hooks check `TBD_MOD_FEATURES` (read once
through `$.env.get` and cached). A feature not on the list passes each event
straight to `next(e)` and writes nothing.

### Per-session directory

Each Claude session gets `<TBD_SESSIONS_DIR>/<claudeSessionID>/`. It is keyed
by Claude session ID because `--resume` keeps that ID across every wake and
revive, while terminal IDs change on archive and history revive. The mod
resolves the directory from `$.session.id()` at each write, so a `/clear` that
moves the process to a new session ID moves its writes too.

Shared files:

- **`spawn.json`** – written only by the daemon, before the Claude process
  starts, on every spawn that loads the mod: session ID, incarnation ID, spawn
  time, and the feature list passed in `TBD_MOD_FEATURES`. A wake rewrites it
  and touches nothing else in the directory.
- **`alive.json`** – written only by the mod: session ID, incarnation ID, the
  mod's version, the features it ran, and a heartbeat time. The mod writes it
  in `session.start` and every 30 seconds after, on a `$.clock.every` timer.

Each feature owns files named after itself, such as `composer-draft.json`.
Every JSON file carries a `schemaVersion`. Readers ignore fields they do not
know, so a session spawned under an older TBD keeps working after an update,
and they read a file missing a required field as unknown.

The per-session directory leaves room for a later channel from the daemon to
the mod, such as an inbox a feature reads. This design builds none.

### Liveness

`SessionModLiveness` is a pure function of `spawn.json`, `alive.json`, the live
incarnation ID and the current time (the injected date seam). It answers, for
a named feature, one of three states:

- **Legacy** – no `spawn.json`, or one whose feature list lacks the feature.
  The session was spawned without that feature and keeps the old behavior
  until it next respawns.
- **Confirmed** – `spawn.json` and `alive.json` name the live incarnation,
  `alive.json` lists the feature, and its heartbeat is no older than 90
  seconds.
- **Unknown** – the feature was spawned but the mod has not confirmed this
  process. The reason is one of: no `alive.json`; one from another incarnation
  (the mod did not load this time); a heartbeat older than 90 seconds (a dead
  worker, or writes failing on a full disk); an unreadable file.

Every daemon-side consumer of a feature starts from this answer. The 30-second
heartbeat and the 90-second limit are named constants. They are liveness
attestation, which the placement doctrine keeps compiled.

### Reclaiming files

The per-session directories are a new durable resource, reclaimed by one new
`OrphanGC` arm under `gcEnabled`. The arm removes a whole session directory
once no terminal row's `claudeSessionID` and no worktree's
`archivedClaudeSessions` names its session ID, and nothing has written inside
it within `gcGraceSeconds`. A parked session's files therefore survive however
long the park lasts. A feature that keeps files with a shorter life names its
own rule inside the directory; later features add files, not reconcilers.

The `tbd-session` plugin directory needs no reconciler: it is one directory,
rewritten at every daemon start.

## The composer-draft feature

### Overview

The feature writes the composer's state to `composer-draft.json` on every
change. Before a park, the daemon checks the feature's liveness and reads that
file. If the feature is confirmed for the live process, the park proceeds,
with or without a draft, and ends Claude with a signal instead of typed keys.
When the session resumes, the feature fills the saved draft back into the box
and shows a short notice above the prompt. When liveness is unknown, automatic
parks skip the session, and a manual park asks the person.

### Hooks

- **`session.start`** – restores the saved draft (below).
- **`prompt.edit`** – awaits `next(e)` and queues a write of the resulting box.
  It does not await the write, so typing never waits on disk.
- **`prompt.change`** – queues a write of `e.text`. A `clear` empties the box,
  so the write records no draft.
- **`session.end`** – queues a final write and awaits it.
- **`ui.render` on `AbovePrompt`** – draws the restore notice while it is
  visible, and otherwise passes through with `next(e)`.

Writes run one at a time, and a queued write replaces any queued write behind
it, so an older box can never land after a newer one. A non-empty box saves
its text and cursor. An empty box removes the text and records that no draft
exists.

### Files

- **`composer-draft.json`** – whether a draft exists, the draft text and
  cursor, and when the box was last saved.
- **`composer-draft.unrestored`** – the text of a draft the feature could not
  restore because the box already held text. Later saves never touch it.
  `OrphanGC` removes it 30 days after its last write, as the `unsent-prompts/`
  arm does.

### Parking

The gate's existing rails run unchanged. The feature's liveness, then its
file, decides:

- **Legacy** – today's path: `hasPendingInput`, then the typed `/exit`.
- **Confirmed** – the park proceeds, draft or no draft.
- **Unknown** – the idle sweep and merge-park skip the session and log the
  reason. A manual park returns a distinct refusal; the app turns it into
  "TBD can't confirm this session's draft is saved. Hibernate anyway?", and a
  yes reissues the park with an override.

For a session spawned with the feature, TBD never types into the composer to
end it: no `/exit`, and no Escape or Ctrl+C fallback either, because a
daemon-sent Ctrl+C clears the box and the feature would record the draft as
gone. It sends SIGTERM to the Claude process. `session.end` then makes the
final save, and the existing escalation (`respawn-window -k` on tmux, abandon
on the holder) still guarantees the process ends. The rule covers the tmux
park, the holder park, and both in-place profile swaps; the tmux swap loses
drafts today.

While the flag exists, a park of a confirmed session still runs
`hasPendingInput`, only to compare with the feature. Each disagreement goes to
the `com.tbd.daemon` log under category `composer-draft` at `.notice`, which
`log show` retains, naming the terminal, the feature's answer and the scrape's
answer. The scrape never decides a park of a session spawned with the feature.

### Waking

A wake resumes the session as it does today. In the new process, the
feature's `session.start` hook reads `composer-draft.json`. When a draft
exists, the feature:

1. Waits until the box is mounted and empty, retrying `$.prompt.fill` every
   500 milliseconds while it answers `isFilled: false`.
2. Fills the box with `mode: 'replace'`.
3. Shows "Restored your unsent draft" above the prompt for 3 seconds. A
   `$.clock.after` timer hides it, and the band redraws without it.

The fill raises `prompt.change`, which saves the draft again, so a second park
before any edit still keeps it. If the person's own text reaches the box
before the fill lands, the feature leaves the box alone, writes the saved
draft to `composer-draft.unrestored`, and logs it.

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

The flag decides whether a spawn lists `composer-draft` in its features, and
so whether it loads the mod at all while this is the only feature. A park
follows `spawn.json`, not the current flag, so flipping the flag never
strands a running session: sessions spawned before the flip keep the behavior
they were spawned with until they respawn.

### Soak and graduation

The flag is turned on on the author's machine. The soak reads three log lines:
feature-versus-scrape disagreements, unknown liveness with its reasons, and
restores (with any `.unrestored`). The flag graduates when every case where the
scrape saw a draft and the feature did not is explained as a scrape false
positive, such as a grayed suggestion the scrape read as typed text, and
restores have been seen working on both tmux and holder. Graduation flips
`Config.composerDraftDefault`.

### Deletion after graduation

A later PR deletes, together:

- the flag, which makes `composer-draft` a feature every spawn lists
- `hasPendingInput`, its three call sites, and its `.swiftlint.yml` exclusion
- the typed `/exit` and the Escape and Ctrl+C park endings
- the keystroke veto: `InputActivityTracker`, its gate rail, its RPC and its
  Settings toggle (the `hibernate_input_veto_enabled` column stays, since
  landed migrations are frozen)

The flag and the scrape go in one PR, so a person who opted out is never left
without a guard. After it, a session whose feature is not confirmed never
parks automatically. The mod itself stays, loaded on every spawn.

## Testing

Each gating branch gets its own test.

- **Liveness** – legacy (no `spawn.json`; a feature list without the feature),
  confirmed, and each unknown reason: no `alive.json`, another incarnation, a
  stale heartbeat, an unreadable file.
- **Draft status** – confirmed with a draft and confirmed empty, on top of the
  liveness answer.
- **Park gate** – a legacy session takes the scrape path; a confirmed session
  follows its file and never consults the scrape's answer.
- **Park ending** – a session spawned with the feature gets a signal and no
  keys, asserted on the transport, for both transports and both profile swaps;
  a legacy session gets the typed `/exit` as today.
- **Manual park** – unknown returns the distinct refusal, and the override
  parks.
- **Shadow log** – a disagreement produces the log line, asserted on its
  composed text.
- **Spawn** – the flag on adds the second `--plugin-dir`, all three
  environment variables, `composer-draft` in `TBD_MOD_FEATURES`, and
  `spawn.json`; every feature off adds none of them.
- **Flag states** – a pre-migration row reads NULL, and an explicit `false`
  survives a change to `Config.composerDraftDefault`.
- **Reconciler** – a referenced session directory is kept, an unreferenced one
  inside the grace period is kept, an unreferenced one past it is removed, and
  `composer-draft.unrestored` goes at 30 days.
- **Mod** (`claude plugin test`, mock clock):
  - `alive.json` is written at start and its heartbeat ticks
  - a feature missing from `TBD_MOD_FEATURES` writes nothing and passes every
    event through
  - an edit saves; a clear records no draft
  - a restore fills an empty box; a non-empty box produces
    `composer-draft.unrestored`
  - the notice appears and disappears at 3 seconds
- **Live checks during implementation**, at zero token cost with
  `scripts/claude-stub.py`:
  - a SIGTERM park leaves a valid transcript tail, and the wake restores the
    draft, on tmux and on the holder
  - a wake carrying a message does not mix it into the draft
  - where the notice sits relative to queued messages

## Out of scope

- Any second feature. Plausible ones: `terminal.send` delivering through
  `$.prompt.submit` instead of typed paste and Enter; `terminal.send` refusing
  when a session's box holds a draft; usage figures from `$.session.usage()`.
  Each gets its own spec and flag.
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
- **Clear the box before typing `/exit`.** The mod cannot tell a daemon-sent
  clear from the person's own, so it would delete the draft it just saved.
- **A plugin per feature.** Claude Code loads one hooks module per plugin, so
  each feature would bring its own plugin directory, environment variables,
  liveness check and reconciler. One plugin with feature files shares all
  four.
- **A directory per feature instead of per session.** Each feature would need
  its own reclaim rule keyed on the same session references. Grouping by
  session lets one arm reclaim everything a session left behind.
- **Ship the hooks module in the shared `tbd` plugin and toggle it.** The
  shared directory is written only at daemon start, running sessions would
  diverge from it, and an idle loaded module still sits in the typing path.
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
