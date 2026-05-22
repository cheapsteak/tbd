# Claude Spawn Environment Settings — Design

Date: 2026-05-21
Status: draft — under brainstorming, not yet approved

## Problem

Claude Code's classic renderer streams full-frame repaints as plain text
through the tmux relay into SwiftTerm. SwiftTerm paints partial frames,
producing visible screen-tearing inside TBD terminal panes. Claude Code's
**fullscreen rendering** (alternate-screen buffer, opt-in via
`CLAUDE_CODE_NO_FLICKER=1`) renders only visible messages with diffed
redraws, which eliminates the tearing. It also gives flat memory use and
in-app scroll.

The immediate need is to enable fullscreen rendering by default for Claude
sessions, with a user-facing toggle. But fullscreen is one of dozens of
behavior/UX environment variables Claude Code exposes. Rather than wiring a
bespoke toggle, this design introduces a **registry-driven system** for
managing Claude spawn-time environment settings, and ships fullscreen as
its first entry.

## Goals

- A registry-driven system for Claude spawn-time env settings that
  accommodates dozens of settings of mixed value types (boolean, integer,
  choice) at O(1) cost per new setting — no migration, no RPC change, no
  per-setting UI code.
- Ship `fullscreenRendering` as the first registry entry, on by default.
- The default value of every setting holds for **every** spawn path,
  including daemon-restart reconcile and CLI-driven spawns with no app
  running.
- In-pane mouse behavior (wheel scroll, drag-select, link/file clicking)
  continues to work with fullscreen Claude.

## Non-goals

- Per-profile, per-repo, or per-terminal configuration. Settings are
  global.
- Managing env vars already owned by TBD's profile system —
  `ANTHROPIC_MODEL`, auth tokens, `CLAUDE_CONFIG_DIR`, the AWS/Bedrock
  vars (see `ClaudeSpawnCommandBuilder`). The registry covers only
  behavior/UX/limit env vars; profile-owned keys must never appear in it.
- Migrating the existing `suspendEnabled` flag into this system.
  `suspendEnabled` rides on the `worktreeSelectionChanged` RPC and is
  consumed synchronously with that event — read at selection-change time,
  never persisted, always fresh. This registry is for values read at
  *spawn* time, decoupled from any event, which is why they must be
  persisted. Different lifetimes; `suspendEnabled` stays on the selection
  event.
- Codex sessions (Claude only).
- Reworking `ClaudeStateDetector` logic. Its interaction with the
  alternate screen is **verified**, not assumed — see Testing.
- `.integer` / `.choice` setting UI (see "v1 scope" — model only).

## Design

### 1. The registry

A single declarative registry in `TBDShared`, compiled into both the app
and the daemon, is the one source of truth for what settings exist:

```swift
enum ClaudeEnvValue: Codable, Equatable {   // persisted form
    case bool(Bool)
    case int(Int)
    case string(String)
}

struct ClaudeEnvSetting {
    let id: String          // stable semantic key, e.g. "fullscreenRendering"
    let envVar: String      // "CLAUDE_CODE_NO_FLICKER"
    let title: String       // UI label
    let help: String        // UI help text
    let kind: Kind

    enum Kind {
        case toggle(default: Bool,   emit: (Bool) -> String?)
        case integer(default: Int,   range: ClosedRange<Int>, emit: (Int) -> String?)
        case choice(default: String, options: [String],       emit: (String) -> String?)
    }
}

enum ClaudeEnvRegistry {
    static let all: [ClaudeEnvSetting] = [
        ClaudeEnvSetting(
            id: "fullscreenRendering",
            envVar: "CLAUDE_CODE_NO_FLICKER",
            title: "Fullscreen rendering for Claude sessions",
            help: "Flicker-free renderer. Claude Code research-preview "
                + "feature; use /tui in-session to override.",
            kind: .toggle(default: true, emit: { $0 ? "1" : nil })
        ),
    ]
}
```

Key properties of the `Kind` model:

- Each kind bundles its **default**, its value type, and an **emit
  function** `(value) -> String?` that returns the env value to set, or
  `nil` to omit the variable entirely.
- The emit function decouples the user-facing semantic from the env
  emission. A normal flag emits when on (`{ $0 ? "1" : nil }`); an
  inverted `DISABLE_*` flag emits when off (`{ $0 ? nil : "1" }`); a
  scalar omits when it equals the Claude default.
- The registry holds closures, so it is code, not data — it is never
  serialized. Only setting *values* are persisted.

### 2. Persistence — daemon `config` table, one JSON blob

The daemon owns Claude spawning, is a separate process, and **respawns
Claude during boot-time reconcile before any client can connect**. A
memory-only cache would be empty for reconcile spawns and for CLI-driven
spawns when the app is closed — breaking the default guarantee. So setting
values are **persisted in the daemon database**.

- A new numbered GRDB migration adds one column,
  `claude_env_settings TEXT`, to the existing `config` singleton table
  (`Database.swift:294`, the single-row `id = 'singleton'` table). It
  holds a JSON-encoded `[String: ClaudeEnvValue]` — an **overrides map**:
  setting ID → user-chosen value, containing only settings the user has
  changed from their registry default. Per the project migration rule,
  the same commit updates the GRDB `Config` record type and the
  `TBDShared` Codable model; the field is optional so existing rows
  decode.
- Because the column stores only *overrides*, adding a new registry entry
  needs **no migration** — the JSON shape is stable forever. This is the
  one and only schema change for the entire system.
- Effective value of a setting = `overrides[id] ?? registry default`. A
  daemon with an empty/absent blob (fresh install, boot-time reconcile,
  CLI-only usage) still uses every setting's registry default — so
  fullscreen-on-by-default holds with zero client interaction.
- `ConfigStore` (GRDB writer) serializes all access; no in-memory cache,
  no bespoke locking.

### 3. App ↔ daemon plumbing

- RPC payload struct `ClaudeSpawnPreferences { settingOverrides: [String:
  ClaudeEnvValue]? }` in `TBDShared` — one stable Codable field, keyed by
  semantic setting ID, never by env-var name.
- New RPC `setClaudeSpawnPreferences(ClaudeSpawnPreferences)`. The daemon
  writes the overrides map into the `config` table.
- No daemon→app broadcast. The app's Settings UI binds directly to its
  own `@AppStorage` values — the app is the display source of truth. The
  daemon `config` table is the *spawn-time* persistence, and the app keeps
  it in sync by pushing (see below). Since no other writer of the
  overrides exists, a broadcast would add nothing.
- **App push timing.** The app pushes `setClaudeSpawnPreferences`
  (a) whenever the user changes a setting, and (b) whenever it
  establishes or re-establishes a daemon connection — both
  `connectAndLoadInitialState()` *and* the poll-driven reconnect branch
  in `startPolling()` (`AppState.swift:548-571`) — so a daemon restart
  while the app runs re-syncs. The push is reconciliation only; the DB
  column is the source of truth.

The boundary stays semantic: the RPC and the persisted blob carry setting
IDs and typed values. The env-var *name* is declared once, in the
registry, in shared code both processes compile against. The app never
hardcodes Claude's env-var vocabulary; it iterates `ClaudeEnvRegistry.all`.

Version skew is graceful: an override for an unknown setting ID (app
newer than daemon, or the reverse) is ignored; a registry entry with no
override falls back to its default.

### 4. Env var injection — single choke point

`ClaudeSpawnCommandBuilder.build` gains one parameter,
`envSettingOverrides: [String: ClaudeEnvValue]`. When the resolved command
is a Claude command (the `resumeID` / `freshSessionID` branches), the
builder computes spawn env vars by iterating `ClaudeEnvRegistry.all`. For
each setting it switches on `kind` to read that kind's `default` and
`emit`, resolves the effective value against the overrides map, and sets
the env var when `emit` returns non-nil:

```
for setting in ClaudeEnvRegistry.all {
    // switch on setting.kind → (default, emit) for that case
    let value = overrides[setting.id] ?? <kind default>
    if let envValue = <kind emit>(value) { env[setting.envVar] = envValue }
}
```

The `cmd` / `shellFallback` branches return before `env` is populated, so
Codex and plain-shell spawns are structurally unaffected.

All `ClaudeSpawnCommandBuilder.build` call sites (9 total) pass the
overrides map, read from `ConfigStore`:

| File | Line | Claude spawn? |
|---|---|---|
| `WorktreeLifecycle+Create.swift` | 280 | yes — fresh/resume first terminal |
| `WorktreeLifecycle+Create.swift` | 364 | yes — restore additional archived sessions |
| `WorktreeLifecycle+Reconcile.swift` | 273 | yes — `recreateAfterReboot` |
| `WorktreeLifecycle+Reconcile.swift` | 295 | conditional — codex/shell branch (no-op) |
| `WorktreeLifecycle+Reconcile.swift` | 308 | conditional — codex/shell branch (no-op) |
| `SuspendResumeCoordinator.swift` | 380 | yes — resume after suspend |
| `RPCRouter+TerminalHandlers.swift` | 198 | yes — create terminal |
| `RPCRouter+TerminalHandlers.swift` | 574 | yes — recreate window |
| `RPCRouter+TerminalHandlers.swift` | 598 | yes — recreate window (alt branch) |

Non-Claude call sites may pass an empty map or the real one; the builder's
early return makes it a no-op. The implementation plan confirms each site.

Changing a setting affects **newly spawned** sessions only.

### 5. Settings UI

A new section in `TerminalSettingsView` iterates `ClaudeEnvRegistry.all`
and renders one control per setting, switching on `Kind`:

- `.toggle` → `Toggle`, label/help from the registry.

The control is bound to the daemon-broadcast overrides; changing it pushes
`setClaudeSpawnPreferences`. Adding a `.toggle` setting to the registry
makes its row appear automatically — no UI code.

### 6. In-pane mouse handling (fullscreen)

With fullscreen Claude, `terminal.mouseMode` flips on. TBD's mouse
architecture mostly absorbs this:

- **Wheel scroll** — `scrollMonitor` (`TerminalPanelView.swift:329`)
  forwards wheel events to the pane as mouse button 4/5 when `mouseMode
  != .off`. The code path is unchanged, but scrollback **ownership moves**:
  classic Claude → SwiftTerm's local scrollback; fullscreen Claude → the
  wheel is delivered into Claude, which scrolls its in-app message view.
  Intended behavior, and a verification item.
- **Plain click** — `handleClickPassthrough` (`TBDTerminalView.swift:292`)
  forwards the click into Claude (click-to-expand tool output). Intended.
- **Drag-select** — SwiftTerm handles it locally (`allowMouseReporting =
  false`). Unchanged.

**Known fix required:** `handleClickPassthrough` does not check modifier
keys, so a Cmd+click on a file path would both open the file in TBD *and*
send a click into Claude. Add a guard to skip the passthrough when a
modifier key is held — modified clicks belong to TBD's file/link handling,
plain clicks go to Claude.

Residual flicker (tmux does not pass synchronized-output / DECSET 2026) is
a known limitation, out of scope unless verification shows it severe.

### 7. Live-session remediation

A setting governs new spawns only. For a live session misbehaving under
fullscreen, the remedies are Claude's own `/tui default` command, or TBD's
recreate-window action (`handleTerminalRecreateWindow`,
`RPCRouter+TerminalHandlers.swift:287`), which respawns the pane with the
current `config` values. The fullscreen setting's help text names `/tui`.

## v1 scope

The design accommodates dozens of mixed-type settings; the v1 build is
deliberately narrower:

- The persisted format (`ClaudeEnvValue` with `.bool` / `.int` / `.string`)
  is defined fully now, so the on-disk JSON never migrates.
- v1 implements the `.toggle` kind end-to-end — registry, emit, daemon
  injection, settings UI, tests — and ships exactly one entry:
  `fullscreenRendering`.
- `.integer` and `.choice` exist in the `Kind` type but their settings-UI
  rendering is **not** implemented in v1, to avoid shipping unexercised UI
  branches (the project requires a test per branch). They land — as a new
  UI switch arm plus a registry entry — with the first real setting that
  needs them. No redesign required.

## Testing

- Unit: `ClaudeEnvValue` Codable round-trip for all three cases; the
  overrides map decodes with unknown keys ignored and missing keys
  defaulted.
- Unit: `ClaudeSpawnPreferences` Codable round-trip; decodes with a
  missing `settingOverrides` field.
- Unit: the new `config` migration applies cleanly; `claude_env_settings`
  is absent/empty for a pre-existing singleton row and effective values
  fall back to registry defaults.
- Unit: `ConfigStore` round-trips the overrides map.
- Unit: registry emit — `fullscreenRendering` default (no override)
  yields `CLAUDE_CODE_NO_FLICKER=1`; an explicit `false` override yields
  no env var.
- Unit: `ClaudeSpawnCommandBuilder.build` includes/omits
  `CLAUDE_CODE_NO_FLICKER` per the overrides map for Claude commands, and
  never emits it for `cmd` / `shellFallback` branches.
- Manual verification matrix (inside a TBD pane, fullscreen Claude):
  wheel scroll reaches Claude's in-app scroll; plain click; Cmd+click on
  file path; Cmd+click on OSC 8 link; PR-number link; drag-select + copy;
  split layouts; **`ClaudeStateDetector` idle/busy detection and
  auto-suspend still work** (status bar captured correctly from the
  alternate screen); residual flicker severity.
- Manual: daemon restart (`scripts/restart.sh`) — reconcile-respawned
  Claude panes come back fullscreen when the setting is on, classic when
  off.

## Resolved decisions

- **Value model:** typed (`bool` / `int` / `string`) from day one, not
  boolean-only — Claude Code's env vars include integers
  (`CLAUDE_CODE_SCROLL_SPEED`, `BASH_DEFAULT_TIMEOUT_MS`) and enums
  (`CLAUDE_CODE_EFFORT_LEVEL`).
- **Persistence:** the `config` singleton table, one JSON column for an
  overrides map — not a column per setting. Required for the default
  guarantee across daemon restarts and CLI-only usage, and keeps the
  schema fixed as settings are added.
- **Concurrency:** `ConfigStore` (GRDB writer) serializes access.
- **Boundary:** the registry never includes profile-owned env vars
  (`ANTHROPIC_MODEL`, auth, `CLAUDE_CONFIG_DIR`, AWS/Bedrock).
