# Composer draft save-and-restore mod

TBD parks idle Claude sessions to free memory and revives them on demand. A
park must never lose text the person typed into Claude Code's composer but did
not send. Today a screen-scrape guards that, and the guard breaks silently
whenever Claude Code redraws its composer. This design replaces the guard with
a Claude Code mod that TBD ships in its plugin directory. The mod saves the
draft as the person types and puts it back when the session revives, so a park
can go ahead with a draft in the box and lose nothing. The work ships behind a
default-off flag, soaks with the scrape running in shadow, and ends by deleting
the scrape and the keystroke veto.

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

## Design

### Overview

When the flag is on, TBD loads a second plugin, `tbd-composer`, into every
Claude session it spawns. The mod writes the composer's state to a per-session
file on every change and refreshes a heartbeat every 30 seconds. Before a park,
the daemon reads that file. If the file is current for the live process, the
park proceeds, with or without a draft, and ends Claude with a signal instead
of typed keys. When the session resumes, the mod fills the saved draft back
into the box and shows a short notice above the prompt. When the daemon cannot
confirm the file is current, it treats the draft as unknown: automatic parks
skip the session, and a manual park asks the person.

### The mod

`tbd-composer` is a plugin of its own, separate from the shared `tbd` plugin, in
a sibling directory under the same application-support root. `PluginDirWriter`
writes it at daemon start and replaces the directory wholesale, so a module
from an older TBD never lingers. Its source ships inside the install, as the
`tbd` plugin's skills do.

A spawn made while the flag is on passes a second `--plugin-dir` naming it,
plus two environment variables:

- **`TBD_COMPOSER_DRAFT_DIR`** – the drafts directory, derived from
  `TBDConstants` so it follows `TBD_HOME`.
- **`TBD_TERMINAL_INCARNATION_ID`** – already set on wake, swap and recreate;
  mod-mode spawns set it on fresh spawns too, so every mod-mode process carries
  one.

A spawn made while the flag is off passes neither, and the mod never loads. A
loaded mod puts a hook in the typing path, so off must mean absent, not loaded
and idle.

The module's hooks:

- **`session.start`** – writes the status file, then restores the saved draft
  (below).
- **`prompt.edit`** – awaits `next(e)` and queues a write of the resulting box.
  It does not await the write, so typing never waits on disk.
- **`prompt.change`** – queues a write of `e.text`. A `clear` empties the box,
  so the write records no draft.
- **`session.end`** – queues a final write and awaits it.
- **`ui.render` on `AbovePrompt`** – draws the restore notice while it is
  visible, and otherwise passes through with `next(e)`.

Writes run one at a time inside the mod, and a queued write replaces any
queued write behind it, so an older box can never land after a newer one. A
non-empty box saves its text and cursor. An empty box removes the text and
records that no draft exists. A `$.clock.every` timer rewrites the status
file's heartbeat every 30 seconds.

### Files

All three live in `TBD_COMPOSER_DRAFT_DIR`, keyed by Claude session ID.
`--resume` keeps that ID across every wake and revive, while terminal IDs
change on archive and history revive.

- **`<sessionID>.json`** – written only by the mod: session ID, incarnation ID,
  whether a draft exists, the draft text and cursor, when the box was last
  saved, the heartbeat time, and the mod's version. The mod writes under
  `$.session.id()` at write time, so a `/clear` that moves the process to a new
  session ID moves its writes too.
- **`<sessionID>.spawn`** – written only by the daemon, before the Claude
  process starts, on every mod-mode spawn: session ID, incarnation ID, spawn
  time. A wake rewrites this marker and never touches the mod's file, so the
  saved draft survives for the mod to restore.
- **`<sessionID>.unrestored`** – the text of a draft the mod could not restore
  because the box already held text. Later saves never touch it.

The status reader ignores fields it does not know, so a session spawned under
an older TBD keeps working after an update. A missing required field reads as
unknown.

### Draft status

`ComposerDraftStatus` is a pure function of the spawn marker, the mod's file,
the live incarnation ID and the current time (the injected date seam). It
answers one of three states:

- **Legacy** – no spawn marker. The session was spawned without the mod and
  keeps today's park path until it next respawns.
- **Saved** – the marker and the mod's file name the live incarnation, and the
  heartbeat is no older than 90 seconds. Carries whether a draft exists.
- **Unknown** – a marker exists but the mod has not confirmed this process.
  The reason is one of: no file from the mod; a file from another incarnation
  (the mod did not load this time); a heartbeat older than 90 seconds (a dead
  worker, or writes failing on a full disk); an unreadable file.

The 30-second heartbeat and the 90-second limit are named constants. They are
liveness attestation, which the placement doctrine keeps compiled.

### Parking

The gate's existing rails run unchanged. The draft status then decides:

- **Legacy** – today's path: `hasPendingInput`, then the typed `/exit`.
- **Saved** – the park proceeds, draft or no draft.
- **Unknown** – the idle sweep and merge-park skip the session and log the
  reason. A manual park returns a distinct refusal; the app turns it into
  "TBD can't confirm this session's draft is saved. Hibernate anyway?", and a
  yes reissues the park with an override.

In mod mode, TBD never types into a Claude composer to end a session: no
`/exit`, and no Escape or Ctrl+C fallback either, because a daemon-sent Ctrl+C
clears the box and the mod would record the draft as gone. It sends SIGTERM to
the Claude process. `session.end` then makes the final save, and the existing
escalation (`respawn-window -k` on tmux, abandon on the holder) still
guarantees the process ends. The rule covers the tmux park, the holder park,
and both in-place profile swaps; the tmux swap loses drafts today.

While the flag exists, a park of a session whose status is saved still runs
`hasPendingInput`, only to compare with the mod. Each disagreement goes to the
`com.tbd.daemon` log under category `composer-draft` at `.notice`, which `log
show` retains, naming the terminal, the mod's answer and the scrape's answer.
The scrape never decides a non-legacy park.

### Waking

A wake resumes the session as it does today. In the new process, the mod's
`session.start` hook reads its file. When a draft exists, the mod:

1. Waits until the box is mounted and empty, retrying `$.prompt.fill` every
   500 milliseconds while it answers `isFilled: false`.
2. Fills the box with `mode: 'replace'`.
3. Shows "Restored your unsent draft" above the prompt for 3 seconds. A
   `$.clock.after` timer hides it, and the band redraws without it.

The fill raises `prompt.change`, which saves the draft again, so a second park
before any edit still keeps it. If the person's own text reaches the box
before the fill lands, the mod leaves the box alone, writes the saved draft to
`<sessionID>.unrestored`, and logs it.

A message delivered with the wake arrives as an argument to `claude --resume`.
Implementation verifies, against the fake model API, that Claude submits that
argument without passing it through the box. If it does pass through the box,
the mod waits for that first prompt's submit before restoring, so the draft
and the message never mix.

A revive on a fresh branch (`--fork-session`) gets a new session ID; the draft
stays with the original session.

### Reclaiming files

The drafts directory is a new durable resource, reclaimed by a new `OrphanGC`
arm under `gcEnabled`. A `.json` or `.spawn` file is reclaimed once no terminal
row's `claudeSessionID` and no worktree's `archivedClaudeSessions` names its
session ID, and nothing has written it within `gcGraceSeconds`. A parked session's draft therefore survives however
long the park lasts. An `.unrestored` file is reclaimed 30 days after its last
write, as the `unsent-prompts/` arm reclaims its files.

The `tbd-composer` plugin directory needs no reconciler: it is one directory,
rewritten at every daemon start.

### Flag

`composer_draft_enabled`, default off:

- a `.sql` migration, `ALTER TABLE config ADD COLUMN composer_draft_enabled
  INTEGER;` with no `DEFAULT`, appended to the migration manifest test
- `ConfigRecord` holds `Bool?`, resolved with `?? Config.composerDraftDefault`
  (`false`)
- an optional field on the shared `Config` model
- a setter RPC, `tbd config` support, and a Settings toggle

The flag decides how a session is spawned. A park follows the spawn marker,
not the current flag, so flipping the flag never strands a running session:
sessions spawned before the flip keep the path they were spawned with until
they respawn.

### Soak and graduation

The flag is turned on on the author's machine. The soak reads three log lines:
mod-versus-scrape disagreements, unknown statuses with their reasons, and
restores (with any `.unrestored`). The flag graduates when every case where the
scrape saw a draft and the mod did not is explained as a scrape false positive,
such as a grayed suggestion the scrape read as typed text, and restores have
been seen working on both tmux and holder. Graduation flips
`Config.composerDraftDefault`.

### Deletion after graduation

A later PR deletes, together:

- the flag, which makes mod mode the only path
- `hasPendingInput`, its three call sites, and its `.swiftlint.yml` exclusion
- the typed `/exit` and the Escape and Ctrl+C park endings
- the keystroke veto: `InputActivityTracker`, its gate rail, its RPC and its
  Settings toggle (the `hibernate_input_veto_enabled` column stays, since
  landed migrations are frozen)

The flag and the scrape go in one PR, so a person who opted out is never left
without a guard. After it, a session without a confirmed mod is unknown and
never parks automatically.

## Testing

Each gating branch gets its own test.

- **Status reader** – legacy, saved with a draft, saved empty, no file from the
  mod, another incarnation, a stale heartbeat, an unreadable file.
- **Park gate** – a legacy session takes the scrape path; a non-legacy session
  follows its status and never consults the scrape's answer.
- **Park ending** – mod mode signals and sends no keys, asserted on the
  transport, for both transports and both profile swaps; legacy mode types
  `/exit` as today.
- **Manual park** – unknown returns the distinct refusal, and the override
  parks.
- **Shadow log** – a disagreement produces the log line, asserted on its
  composed text.
- **Spawn** – flag on adds the second `--plugin-dir`, both environment
  variables and the marker; flag off adds none of them.
- **Flag states** – a pre-migration row reads NULL, and an explicit `false`
  survives a change to `Config.composerDraftDefault`.
- **Reconciler** – a referenced file is kept, an unreferenced file inside the
  grace period is kept, an unreferenced file past it is reclaimed, and an
  `.unrestored` file goes at 30 days.
- **Mod** (`claude plugin test`, mock clock) – an edit saves; a clear records
  no draft; a restore fills an empty box; a non-empty box produces
  `.unrestored`; the heartbeat ticks; the notice appears and disappears at
  3 seconds.
- **Live checks during implementation**, at zero token cost with
  `scripts/claude-stub.py`:
  - a SIGTERM park leaves a valid transcript tail, and the wake restores the
    draft, on tmux and on the holder
  - a wake carrying a message does not mix it into the draft
  - where the notice sits relative to queued messages

## Out of scope

- Turning the idle sweep back on by default. `v50` turned it off because of
  the scrape's failure direction; that follow-up can cite this design's soak.
- Letting `terminal.send` refuse when a session's box holds a draft. The mod's
  file makes it possible; it is a separate change.
- Codex sessions, which are never parked.

## Rejected alternatives

- **Keep the scrape as a fallback for unknown status.** The fallback would run
  only when the mod is missing, which makes it the least exercised path in the
  system, and the scrape fails silently in the unsafe direction. Refusing the
  park fails safe, and a person at a manual park can override.
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
- **Ship the hooks module in the shared `tbd` plugin and toggle it.** The
  shared directory is written only at daemon start, running sessions would
  diverge from it, and an idle loaded module still sits in the typing path.
- **Two flags, one for save-and-restore and one for the park decision.** Four
  combinations to test, one of them meaningless: a park decision that depends
  on a mod that is not loaded.
- **Restore silently, or announce with a toast.** A draft that reappears
  without a word is easy to send by accident. A notice above the prompt, where
  queued messages appear, explains the text at the spot the person is looking,
  and dismisses itself.
