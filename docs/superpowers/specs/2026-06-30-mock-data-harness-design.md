# Mock Data Harness — Design

**Date:** 2026-06-30
**Status:** Design approved, pending spec review
**Topic:** An isolated, seeded daemon+app pair for UI development and staged screenshots/recordings.

## Problem

Every TBD worktree runs against the one real daemon and `~/tbd/state.db`. That makes it awkward to:

- Develop and iterate on UI against rich, varied state (many worktrees, every status, PR badges, long transcripts) without manufacturing that state by hand in the live system.
- Take *staged*, repeatable screenshots/recordings for docs and review.
- Do either of the above from the main Claude session while a feature is being built — on this branch or another worktree's branch — without disturbing the developer's live instance or risking `~/tbd/state.db` (a documented critical rule).

We want a way to spin up a **second, fully isolated daemon+app pair** that renders **hand-authored seeded data**, drivable hands-off by the main session, leaving the real instance untouched.

## Goals

- One command (`scripts/mock.sh up`) launches an isolated, seeded daemon+app pair.
- Seeded state is deterministic, committed, reviewable, and grows as a scenario library.
- The mock instance never reads or writes `~/tbd/*` — the real daemon, app, and `state.db` are undisturbed, and the real `/Applications` LaunchServices/deep-link registration is left intact.
- The main Claude session can launch, seed, screenshot, and tear down the mock instance hands-off, regardless of which branch's binaries are built.
- High-value UI surfaces render correctly: worktree sidebar (names/statuses/PR badges/git tags), the transcript renderer, dialogs, and toolbars.

## Non-Goals (YAGNI)

- No live `claude`/`codex` process spawning in the mock instance.
- No snapshot/clone of the real `~/tbd` DB (`--from-live`). Hand-authored fixtures only.
- No notifications or `tbd://` deep-link handling in the mock instance.
- **Tier 2** — canned terminal *scrollback* (trivial tmux sessions replaying a captured ANSI dump) — is explicitly **deferred to a follow-up spec**. This spec ships Tier 1 only.

## Approach

The daemon owns all state and, at startup, runs migrations *and* a battery of live reconciliation that would clobber any hand-seeded state (`RepoHealthValidator` flips repos with non-existent paths to `.missing`; git fetch/status loops overwrite statuses; PR polling, the agent reaper, suspend/resume reconcile, and the Claude usage poller all run). So the chosen approach gates that machinery and seeds from a fixture, entirely inside the daemon, driven by environment flags — reusing every existing schema/migration/model as the single source of truth.

**Rejected alternatives:**

- *External seeder writes `state.db` directly, daemon runs normally.* The daemon's reconciliation still clobbers seeded state, so the daemon would need gating anyway — strictly more moving parts.
- *App-level demo mode bypassing the daemon.* Diverges from the real RPC/render data path (the very thing we want to develop against) and drifts from production behavior.

## Architecture

```
scripts/mock.sh up default
        │  sets TBD_HOME=<scratch>/mock-home, TBD_SOCKET_PATH=…,
        │       TBD_MOCK=1, TBD_MOCK_FIXTURE=Tests/Fixtures/mock-state/scenario-default.json
        ▼
.build/debug/TBDDaemon  ──(migrate empty DB → MockSeeder inserts fixture → skip reconciliation)──▶ mock-home/state.db
        ▲ Unix socket (TBD_SOCKET_PATH) + HTTP port (mock-home/port)
        │
.build/debug/TBD.app/Contents/MacOS/TBDApp   ◀── launched directly with same env + isolated UserDefaults suite
        │  (mock.sh captures the PID directly)
        ▼
   screencapture -l <windowID>  ──▶  artifacts/mock/<name>.png
```

### 1. Isolation (mostly already present)

`TBDConstants` resolves `TBD_HOME` (and `TBD_SOCKET_PATH`) from the environment on every access, so `state.db`, `sock`, `port`, `tbdd.pid`, `repos/`, and the derived tmux server name all relocate under the mock home. No new isolation code is required for the daemon; the harness simply exports a scratch `TBD_HOME` (e.g. under the session scratchpad or a `mktemp -d`). Because the path is deep, the socket is redirected via `TBD_SOCKET_PATH` to a short path to stay under darwin's ~104-char `sun_path` limit.

### 2. Daemon mock mode

Two env vars, read once at startup:

- `TBD_MOCK=1` — enables mock mode.
- `TBD_MOCK_FIXTURE=<path>` — scenario JSON to seed from.

When `TBD_MOCK` is set, `Daemon.start()`:

1. Runs migrations on the (empty) mock DB exactly as normal.
2. After the DB is initialized and **before** any reconciliation, invokes `MockSeeder` to insert the fixture's repos/worktrees/terminals via the existing GRDB stores.
3. **Skips** the live-reconciliation machinery so authored state renders as written:
   - `suspendResumeCoordinator.reconcileOnStartup()`
   - `recoverCreatingWorktrees()` and the per-repo `lifecycle.reconcile(...)` loop
   - `AgentReaper` sweep + periodic task
   - `RepoHealthValidator.validateAll(...)`
   - periodic git fetch, periodic git status refresh
   - `ClaudeUsagePoller`
   - `ArchivedWorktreeBackfill`

   The socket + HTTP servers, subscriptions, and RPC router all start normally so the app connects and renders through the real RPC path.

This is a behavior-gating conditional; per project convention each branch gets a test (see Testing).

### 3. Seed format & loader

Committed under `Tests/Fixtures/mock-state/`:

```
Tests/Fixtures/mock-state/
  scenario-default.json      # repos + worktrees + terminals + PR badges + git statuses + activity states
  transcripts/
    long-session.jsonl       # exercises the #129 transcript renderer
    tool-heavy.jsonl
```

- Scenario JSON is a Codable document decoded by `MockSeeder` into the existing model types and inserted via the existing stores, so it can never drift from the live schema.
- Placeholder repos only: `acme` / `acme-prod` (never real/Longeye names, per project rule).
- `Terminal.transcriptPath` entries point at the committed `transcripts/*.jsonl` fixtures (resolved relative to the fixture file).
- Scenarios are additive — the library grows over time (default, conflict/dirty git states, suspended terminals, deep worktree trees, PR-badge matrix, etc.).

### 4. Pane content — Tier 1 only

- **Transcript panes** render the committed `.jsonl` via the seeded `Terminal.transcriptPath`. **No tmux required** — this is the highest-value surface (the #129 renderer) and the bulk of the UI (sidebar, dialogs, toolbars, PR badges, git tags) needs no live process.
- Terminal *scrollback* panes (a live-looking shell pane) are **Tier 2**, deferred. In this spec, seeded terminals are authored so the transcript/agent view is the surface under test; a terminal pane with no live tmux pane is acceptable (shows the detached/placeholder state) and out of scope to prettify here.

### 5. Launching the app pointed at the mock daemon

`scripts/mock.sh` execs the worktree's own `.build/debug/TBD.app/Contents/MacOS/TBDApp` **directly** (not via `open`, not via `/Applications`) with `TBD_HOME` / `TBD_SOCKET_PATH` / `TBD_MOCK` exported. Consequences, all deliberate:

- **Env is inherited** (direct exec, unlike `open`), so the app resolves the mock socket + port.
- The exec path is *inside* a `.app` (the hard-linked binary `restart.sh` already assembles), so `Bundle.main` still resolves — no bundle-API crashes.
- `/Applications/TBD.app` and its LaunchServices/`tbd://` registration are **never touched**, so the real instance keeps owning deep links.
- `mock.sh` gets the app **PID directly**, used to find the window via `CGWindowList`/AppleScript and target `screencapture -l <windowID>` precisely.

**Isolated app settings:** in mock mode the app routes `AppState` (which persists window frame + layout state) to a dedicated `UserDefaults(suiteName: "com.tbd.app.mock")` (AppState already supports `userDefaults:` injection) so a mock run never writes that state back into the real `TBDApp.plist`. A few other stores (`AppearanceSettings`, emoji/editor "recents") still read `.standard` — deliberately, so the mock inherits the developer's theme for realistic screenshots; the static screenshot flow never mutates them, so nothing leaks back. The app detects mock mode from the same `TBD_MOCK` env var. Notification authorization / activation side-effects are skipped under mock mode.

### 6. `scripts/mock.sh` surface

| Command | Behavior |
|---|---|
| `up [scenario]` | Build if needed; create fresh scratch mock-home; launch seeded daemon then app; print PIDs + paths. Default scenario = `default`. |
| `down` | Kill the mock daemon + app (by recorded PID); remove the scratch mock-home. Leaves `~/tbd` untouched. |
| `shot <name>` | Screenshot the mock app window → `artifacts/mock/<name>.png`. |
| `restart` | Rebuild, then `down` + `up` (reseed). |

Recordings use the same PID→window targeting (bring the window forward, then `screencapture -v` or the macOS screen recorder).

Branch-agnostic: `mock.sh` always runs the binaries built in its own worktree (`$REPO_ROOT/.build/debug`), so the main session screenshots whatever branch is built in the target worktree by invoking that worktree's copy of the script.

## Testing

Per the project rule that a behavior-gating conditional gets a test for each branch (isolated `TBD_HOME`, Swift Testing):

- **Mock gate off (default):** daemon startup still runs reconciliation (assert the seam is invoked / repos with stale paths flip to `.missing`).
- **Mock gate on:** reconciliation is skipped and the fixture is seeded (assert seeded rows are present *and* a stale-path repo is **not** flipped to `.missing`).
- **Seeder round-trip:** decode `scenario-default.json` → seed an in-memory DB → assert expected repos/worktrees/terminals, including `transcriptPath` resolution.

The seeder is structured so the reconciliation-gating seam is injectable/testable without launching real servers.

## Risks & Mitigations

- **darwin `sun_path` overflow** for a deep scratch `TBD_HOME` → redirect the socket with `TBD_SOCKET_PATH` to a short path (existing escape hatch).
- **Two app instances of the same bundle id** → allowed because the mock is launched by direct exec (LaunchServices single-instance only applies to `open`); isolated UserDefaults suite prevents settings/window collisions.
- **Terminal pane attach without a live tmux pane** (Tier 1) → acceptable detached/placeholder state; prettified scrollback is Tier 2.
- **Fixture drift from schema** → seeder inserts through the live GRDB stores and is covered by the round-trip test, so a schema change that breaks the fixture fails a test rather than silently rendering wrong.

## Deliverables

1. `TBD_MOCK` / `TBD_MOCK_FIXTURE` gating in `Daemon.start()` (skip reconciliation; seed before servers handle traffic).
2. `MockSeeder` + Codable scenario document type.
3. `Tests/Fixtures/mock-state/scenario-default.json` + `transcripts/*.jsonl`.
4. Mock-mode `UserDefaults(suiteName:)` + skipped notification/activation side-effects in the app.
5. `scripts/mock.sh` (`up` / `down` / `shot` / `restart`).
6. Tests: mock-gate on/off branches + seeder round-trip.
7. Short `docs/` note on using the harness.

## Follow-ups (out of scope)

- **Tier 2:** canned terminal scrollback via mock tmux sessions replaying captured ANSI dumps.
- Optional `--from-live` sanitized snapshot, if hand-authored fixtures prove insufficient.
- A richer scenario library and (optionally) a visual-regression screenshot comparison.
