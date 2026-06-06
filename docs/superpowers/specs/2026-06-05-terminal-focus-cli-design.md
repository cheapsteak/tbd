# `tbd terminal focus` — push the user to a child worktree's tab

## Problem

An orchestration session (a parent Claude agent) spawns child worktrees and wants
to direct the user's attention to a *specific tab* in one of those children — e.g.
"the child working on the migration needs your input, look at its tab." Today there
is no CLI command that focuses a worktree, let alone a particular tab.

The constraint that shapes the whole design: **push, don't pull.** The orchestrator
should be able to *flag* a tab for attention without yanking the user out of whatever
they are doing. Stealing OS focus (foregrounding the app) is disruptive and must be
opt-in, not the default.

## What already exists (and what the gap actually is)

Most of the machinery is already shipping via `tbd notify`:

- `tbd notify --worktree W --terminal T --type … --message …` fires a banner + sound,
  records unread on W, and stamps the terminal UUID into the notification record.
- The macOS banner click already calls `navigateToWorktree(W, terminalID: T)`, which
  selects the exact tab **and** foregrounds the app
  (`Sources/TBDApp/Services/MacNotificationManager.swift:147`). That is the
  "user explicitly asked → pulling is fine" path, for free.
- For `response_complete`, the originating tab even bolds in the sidebar while
  backgrounded (`unreadTerminals`).

So the soft "mark + notify, land on the tab when the user chooses to look" behavior is
~90% implemented. The genuine gaps:

1. **No immediate loud push** — nothing foregrounds + selects *without* a user click.
2. **Tab bolding is `response_complete`-only** — an attention push won't bold the
   specific child tab in-app (only worktree-level unread + banner).
3. **Discoverability/semantics** — an orchestrator reaches for *"focus the user on this
   child's tab,"* not *"notify."*

This feature closes gaps 1–3 with a thin, intent-revealing command that reuses the
notify path end to end.

## Design

### Command

```
tbd terminal focus --terminal <uuid> [--message <text>] [--activate]
```

- `--terminal <uuid>` (required) — the target tab's terminal. The worktree is derived
  daemon-side from the terminal record, so the orchestrator only needs the terminal
  UUID it already has from `tbd terminal list` / `tbd terminal create`.
- `--message <text>` (optional) — banner / notification text.
- `--activate` — escalate from the soft push to an immediate foreground + select.

Lives under the existing `terminal` command group, alongside `send` / `output` /
`conversation`.

Unlike `tbd notify` (deliberately silent and lenient for hook usage), `focus` is an
**explicit orchestrator command**, so it surfaces errors (e.g. unknown terminal) rather
than swallowing them.

### Addressing primitive

The terminal UUID is the addressing primitive, consistent with the rest of the CLI
(`tbd terminal send --terminal <uuid>`) and with the app's tab-matching code, which
already resolves a terminal UUID to the tab whose content references it
(`Sources/TBDApp/AppState+Worktrees.swift:186`). A "tab" can be a split with several
terminals or a non-terminal pane; matching by terminal UUID is well-defined and reuses
existing logic.

### Data flow

```
CLI terminal focus ──RPC terminalFocus{terminalID, message?, activate}──▶ daemon
  daemon: terminals.get(id) → worktreeID
          notifications.create(type: .focusRequest, message, terminalID)
          broadcast .notificationReceived(NotificationDelta{…, activate})
  app subscribe handler (handleNotificationDelta):
    activate == false → record unread on W + bold T's tab + fire banner/sound   (soft)
    activate == true  → navigateToWorktree(W, terminalID: T) → foreground+select (loud)
```

The only new transport field is a single `activate` bool on `NotificationDelta`. Notification
persistence, the unread summary, and the sound are all reused unchanged; the banner gains a
focus-specific title prefix (see "Distinguishing the banner" below).

### Distinguishing the banner

A focus push must be recognizable in the macOS banner / Notification Center, separate from a
normal `tbd notify` message. macOS does not let an app swap a notification's left-side icon
(it is always TBD's app icon), so the distinction is carried by a **dedicated
`NotificationType.focusRequest`** plus an **emoji prefix on the banner title** (e.g.
`🎯 worktree-name`).

Decisions:

- **New type, not a flag.** `.focusRequest` (rawValue `focus_request`) is an additive enum
  case — safe for existing DB rows, and Swift's exhaustive switches force every site to give
  it a treatment.
- **No new in-app look.** By explicit choice, the in-app surfaces (sidebar dot, jump-menu
  dot, bolding) do **not** need to distinguish a focus push. `.focusRequest` therefore maps
  to the same presentation as `.attentionNeeded` (orange dot, `severity` 3) at every in-app
  switch. Only the banner differs.
- **Banner only.** The emoji prefix is applied in the banner builder when the type is
  `.focusRequest`; all other types render unchanged.

### Changes by layer

1. **TBDShared**
   - `NotificationType.focusRequest` (rawValue `focus_request`), with `severity` matching
     `.attentionNeeded` (3) (`Sources/TBDShared/Models.swift`).
   - `NotificationDelta.activate: Bool`, defaulting to `false` so existing broadcasts and
     any in-flight decoders are unaffected (`Sources/TBDShared/StateDelta.swift:85`).
   - `RPCMethod.terminalFocus` (`Sources/TBDShared/RPCProtocol.swift`).
   - `TerminalFocusParams { terminalID: UUID, message: String?, activate: Bool }`
     (`Sources/TBDShared/RPCProtocol.swift`).

2. **TBDDaemon**
   - `handleTerminalFocus`: decode params, resolve the terminal via
     `db.terminals.get(id:)` (return an error response if not found), persist a
     `.focusRequest` notification carrying the terminalID (mirroring `handleNotify`),
     and broadcast `.notificationReceived(NotificationDelta(…, activate: params.activate))`.
   - Route `RPCMethod.terminalFocus` in `RPCRouter`.

3. **TBDCLI**
   - `TerminalFocus` subcommand in `Sources/TBDCLI/Commands/TerminalCommands.swift`,
     registered in `TerminalCommand.subcommands`. Validates the terminal UUID and prints
     a clear error on failure (non-silent).

4. **TBDApp**
   - `handleNotificationDelta` (`Sources/TBDApp/AppState.swift`):
     - **Generalize tab bolding (gap 2):** insert into `unreadTerminals` whenever the delta
       carries a `terminalID` and that terminal is not the active focused tab — today this is
       gated to `.responseComplete`. This keeps the in-app cue as precise as the banner.
     - **Activate branch (gap 1):** handled *before* the existing visible-worktree
       early-return; when `delta.activate` is set, call
       `navigateToWorktree(worktreeID, terminalID:)` (which foregrounds + selects) and return.
     - Pass the notification `type` through to `postIfEnabled` so the banner can prefix.
   - `MacNotificationManager.postIfEnabled` gains a `type:` parameter; when the type is
     `.focusRequest`, prefix `content.title` with the focus emoji (`🎯`). All other types
     render unchanged.
   - **Exhaustive-switch sites** that must add the `.focusRequest` case, mapping it to the
     same presentation as `.attentionNeeded` (no new in-app look): `WorktreeRowView`
     (`badgeColor`, `hasBoldNotification`), `JumpMenuRow.severityColor`,
     `NotificationSoundPlayer.playIfEnabled`, and any other `switch` over `NotificationType`.

5. **Docs** — add `tbd terminal focus` to the command list in
   `Sources/TBDShared/TBDSkillContent.swift`.

### Testing (per CLAUDE.md branch-coverage rule)

Every gated branch gets a test for both states:

- **App** (`AppState.handleNotificationDelta`, mirroring existing NotificationDelta tests):
  - `activate == true` → selection moves to W and the active tab resolves to T's tab.
  - `activate == false` → selection unchanged, `unreadTerminals` contains T, no foreground.
  - Bolding: a terminalID-bearing soft push bolds a *background* tab but **not** the active
    focused tab.
- **Daemon**: `terminalFocus` resolves the worktree from the terminal and broadcasts a delta
  with the right `activate` value, persisting a `.focusRequest` notification; an unknown
  terminal yields an error response.
- **CLI**: arg parsing for `--terminal` / `--message` / `--activate`; an invalid terminal
  UUID errors.
- **Banner**: `postIfEnabled` prefixes the title with the focus emoji for `.focusRequest`
  and leaves every other type's title unchanged.

### Edge cases

- **Target tab closed / surfaced only via the pinned dock:** `navigateToActiveWorktree`
  already keeps the current tab when no match exists; soft-path bolding of a now-absent
  terminal is harmless.
- **Archived worktree:** `navigateToWorktree` routes to the archived path. Acceptable —
  the orchestrator targeting an archived child is already an unusual case.
- **`activate` while the app is not running / cold-start:** the existing `pendingDeepLink`
  buffering and `NSApplication.isRunning` guard already cover this.

### Out of scope (deferred)

- Pre-setting `activeTabIndices[W]` so that *non-banner* entry paths (e.g. a sidebar click)
  also land on T. This mutates a worktree's active tab out from under the user, which cuts
  against "don't be disruptive," and is unnecessary for the push use case.

## Operational note

Touches TBDShared + the daemon, so a full `scripts/restart.sh` (not `--app`) is required to
pick up the new RPC and delta field.
