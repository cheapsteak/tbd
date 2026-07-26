# Remote agent backends — provider contract + TBD integration design

**Date:** 2026-07-24
**Status:** Shipped in PR #514, behind `remote_backends_enabled` (default OFF).
**Scope:** TBD-side feature (contract, daemon, UI) plus the changes the first provider (agentbox, maintained in its own repo) makes to implement the contract. Neither repo references the other.

Amended over the branch's life; corrected against the shipped implementation on merge to `main` (2026-07-26) — see notes inline where behavior diverged from the original draft (repo-grouped sidebar rendering, the mirror table's actual column set, the `pending_question` contract addition, and which parts of the profile axis actually shipped vs. remain forward design).

## Summary

TBD gains support for **remote agent backends**: sessions running on machines TBD doesn't manage (e.g. a per-user EC2 box reached over SSM, a plain SSH host, a container service). The integration boundary is a **provider** — an external executable on the laptop, registered in TBD config, speaking a small vendor-neutral CLI contract. TBD owns the contract; providers own all transport and vendor specifics. Provider adapters live outside TBD's repo.

Remote sessions are a parallel concept to worktrees — their own model, sidebar section, and RPC family. They do **not** ride the `Worktree` model; the `Location {local|remote}` refactor (~20 call sites, surveyed 2026-05 at 8–12 days) is deliberately avoided.

## Goals (v1)

- Full lifecycle: create, list, stop remote sessions from TBD.
- Sidebar status: process liveness *and* agent-level state (working / waiting for input / exited).
- macOS notifications when a remote agent needs attention or exits.
- Read-only log/scrollback view without attaching.
- Send text into a session without attaching.
- Interactive attach in a normal TBD terminal pane.
- Multiple providers registered concurrently; multiple sessions per provider.

## Non-goals (v1)

- Diff / file viewer for remote workspaces (future `files` capability).
- Port forwarding (future capability).
- `log --follow` streaming (needs the same live-channel machinery as the v2 events path; cut rather than half-built).
- Hooks / plugin propagation to remote boxes. Credential material and filesystem customization are never propagated — but profile *selection* is now in scope and does travel, by reference (see "Profile axis" in Part 2).
- Making remote sessions appear as worktrees.

---

## Part 1 — The provider contract (v1)

A provider is one executable. TBD invokes `<exec> [args...] <verb> [flags]`, passes structured input on stdin when needed, and reads one JSON object (or an NDJSON stream) from stdout. stderr is diagnostic only — logged, never parsed. Env on every invocation: `TBD_CONTRACT_VERSION=1`. The provider inherits the user's login environment.

Four verbs are REQUIRED; the rest are declared capabilities.

| Verb | Required? | Invocation | stdin | stdout | TBD timeout |
|---|---|---|---|---|---|
| `describe` | required | `p describe` | — | JSON | 10s |
| `create` | required | `p create` | JSON | JSON session | 60s |
| `list` | required | `p list` | — | JSON `{sessions:[...]}` | 30s |
| `stop` | required | `p stop <id>` | — | JSON session | 30s |
| `log` | cap `log` | `p log <id> [--lines N]` | — | raw bytes | 30s |
| `send` | cap `send` | `p send <id>` | raw bytes | JSON `{}` | 30s |
| `attach` | cap `attach` | `p attach <id>` | TTY | TTY | unbounded |
| `events` | cap `events` | `p events` | — | NDJSON stream | unbounded |

### Session object

The one shape everything shares:

```json
{
  "id": "fix-flaky-ci",
  "title": "fix flaky CI",
  "created_at": "2026-07-24T18:02:11Z",
  "state": "starting|running|exited",
  "exit_code": 0,
  "agent_state": "working|waiting_input|idle|exited|unknown",
  "agent_state_reason": "permission_prompt",
  "agent_state_at": "2026-07-24T18:40:00Z",
  "meta": {"repo": "acme/api", "branch": "fix-ci", "profile": "acme-default"},
  "pending_question": {
    "id": "q-4f2a1c",
    "questions": [
      {"prompt": "Which environment should this deploy to?", "multi": false,
       "options": [{"label": "staging"}, {"label": "production"}]}
    ]
  }
}
```

- `state` — process liveness only. Provider's job.
- `agent_state` — "does the human need to look". **Normative rule: agent state MUST come from machine interfaces (agent lifecycle hooks, transcript files, process exit codes) — never from parsing rendered terminal output.** This exports TBD's no-TUI-scraping rule across the wire. Providers without instrumentation return `"unknown"`; TBD then shows liveness only.
- `exit_code` present iff `state=exited` and known.
- `meta` — string→string display pairs, provider-defined. The contract blesses `repo`, `branch`, and `profile` as well-known keys a caller MAY interpret; TBD acts on exactly one of them today — `repo` drives the sidebar repo-matching in Part 2 — and renders every other key, including `branch`/`profile`, as an opaque detail row alongside whatever else the provider sends.
- `pending_question` (optional) — a structured choice the agent is currently blocked on, layered on top of `agent_state: waiting_input` (never a substitute for it). Display-only in v1: answering still goes through `attach` or `send`, no dedicated answer verb. Full shape and lifecycle rules: `docs/remote-provider-contract.md` § "Pending question". **Not yet consumed TBD-side** — `RemoteSessionPayload` doesn't decode it and no UI renders it; it rides the wire today per the forward-compatibility rule (unrecognized fields are ignored) so providers can start emitting it ahead of TBD adding the card.

The notify-worthy condition is an `agent_state` **edge**, not a value: transitions into `waiting_input` or `exited` (see Part 2).

### `describe`

**MUST answer from static local data — no network, no auth.** TBD calls it at registration and app start; an expired SSO token must not break app launch.

```json
{
  "contract_versions": [1],
  "name": "agentbox",
  "provider_version": "0.4.2",
  "capabilities": ["log", "send", "attach", "events"],
  "create_params": [
    {"name": "repo",   "type": "string", "label": "Repository", "required": true},
    {"name": "branch", "type": "string", "label": "Branch", "default": "main"},
    {"name": "prompt", "type": "text",   "label": "Initial prompt"},
    {"name": "size",   "type": "enum",   "label": "Size", "values": ["small","large"], "default": "small"}
  ]
}
```

`create_params` is a flat field list, not JSON Schema. Types: `string | text | bool | int | enum`. TBD renders the form dumbly (the most complex widget is an enum popup) and does required/type checks only; the provider is the validator of record via the error model. Well-known names `repo`, `branch`, `prompt`, `title` get TBD-side prefill from the selected repo/context.

### `create`

stdin:

```json
{
  "params": {"repo": "acme/api", "branch": "fix-ci", "prompt": "..."},
  "idempotency_key": "tbd-9a1c..."
}
```

Response: a Session object. Create MUST return within seconds — slow provisioning returns `state: "starting"` and `list`/`events` carry it to `running`. TBD retries a timed-out create with the **same** key; the provider MUST dedupe (same key → same session, never a duplicate). This is the defense against "transport timed out but the session actually started".

### `list`

`{"sessions": [Session...]}`. Providers SHOULD keep exited sessions listable ≥24h (`state: "exited"`) rather than dropping them instantly — silent disappearance is indistinguishable from drift.

### `stop <id>`

Terminates the session (graceful-then-forceful is the provider's business). Idempotent: stopping an already-dead or unknown id exits 0 and returns the session in a terminal state (minimum `{"id": "...", "state": "exited"}`). No separate done/archive verb — archival is TBD-side state.

### `log <id> [--lines N]`

Raw scrollback bytes to stdout, last N lines (default 2000), ANSI passthrough. Display data for a read-only pane — no JSON envelope. (Rendering scrollback to the user is fine under the no-scraping rule; the rule forbids *inferring state* from it, which this contract never does.)

### `send <id>`

stdin bytes delivered verbatim as keystrokes. TBD decides whether to append `\n`. Exit 0 means delivered to the transport, not "agent acted on it".

### `attach <id>`

TBD execs the provider on the pane's PTY and gets out of the way. The provider is a live shim: it can refresh tokens, retry the channel, and exit with code 4 + remediation on auth failure. **Pane exit means viewer detached, never session dead** — session fate is only ever reported by `list`/`events`.

(Rejected alternative: provider prints an argv for TBD to exec. That freezes credentials at print time, gives the provider no reconnect/cleanup hook, and leaks vendor argv into TBD's process table.)

### `events` (optional)

Long-running NDJSON stream, one JSON object per line:

```json
{"event": "hello", "contract_version": 1}
{"event": "snapshot", "sessions": [Session...]}
{"event": "session", "session": {Session}}
{"event": "removed", "id": "fix-flaky-ci"}
{"event": "ping"}
```

- `hello` then `snapshot` MUST open every connection. **Snapshot-on-connect is the resync mechanism — there are no cursors.** A missed transition costs one reconnect.
- `session` events carry the full object, not diffs. Idempotent, replayable.
- `ping` at least every 30s; TBD kills the process after 90s of silence and reconnects.
- TBD supervision: one events process per provider; restart on exit with exponential backoff 1s → 60s cap, ±20% jitter, reset after 5 healthy minutes.
- Fallback (stream down, or capability absent): TBD polls `list` every 60s. This is the floor every provider gets for free.

### Error + auth model

| Exit | Meaning | TBD behavior |
|---|---|---|
| 0 | success | parse result |
| 1 | permanent error | surface, don't retry |
| 2 | usage/contract error | surface as provider bug; log full argv |
| 3 | transient | retry with backoff (max 3 for snapshot verbs) |
| 4 | auth needed | banner with remediation; pause polling this provider |

Nonzero exits SHOULD emit one JSON error object on stdout:

```json
{
  "error": {
    "code": "auth_expired",
    "message": "SSO token expired for profile acme-mgmt",
    "retryable": false,
    "remediation": {"label": "Run aws sso login", "command": "aws sso login --profile acme-mgmt"}
  }
}
```

Well-known codes v1: `auth_expired`, `auth_missing`, `not_found`, `already_exists`, `unreachable`, `invalid_params`. If stdout isn't parseable JSON on failure, TBD falls back to exit-code class + last stderr lines. On exit 4 TBD shows one actionable banner (offering to run `remediation.command` in a pane) instead of a red error every poll; any later successful invocation clears it.

### Versioning

Single integer major. TBD calls `describe`, intersects `contract_versions` with its supported set, picks the highest, refuses the provider with a clear UI error if empty. The chosen major rides on every invocation as `TBD_CONTRACT_VERSION`. Within a major: providers may add response fields anytime (TBD MUST ignore unknown fields); removing/renaming fields or changing verb semantics = new major.

### Identity & drift

- Provider mints ids: opaque, unique within that provider, durable across box reboots (derived from stored state, not PID/tmux index). TBD keys everything by `(provider_name, session_id)`.
- The provider (via `list`/`snapshot`) is the source of truth; TBD's DB is a mirror, never authoritative.
- Session absent from **two consecutive** successful snapshots → TBD marks it `gone` — a distinct visible state, not silent deletion; tombstoned after user dismissal or 7 days. One absence is not enough; transports flake.
- Unknown session appears → TBD adopts it into the sidebar (sessions created from another laptop or by hand are real).
- Provider unreachable → mirror is stale-but-shown with a staleness indicator; never treat "unreachable" as "sessions dead".

---

## Part 2 — TBD-side design

### Provider registry (file-backed)

`~/tbd/agent-providers.json` — user-authored, per the file-backed config pattern:

```json
[{"name": "agentbox", "exec": "/Users/me/.local/bin/agentbox", "args": ["provider"]}]
```

New `TBDConstants.agentProvidersPath(environment:)` helper honoring `TBD_HOME`. The settings surface shows the tilde-abbreviated path with a copy button (precedent: `RepoHooksSettingsView`); no DB column for this blob.

### Feature flag

`remote_backends_enabled` — new `config` column added by migration, **default OFF** (the feature polls in the background, spawns subprocesses, and can kill remote sessions — squarely inside the default-off flag rule). Migration + GRDB record + `TBDShared` Codable model updated in one commit; new field has a default. Both branches tested: flag off → no provider processes spawned, RPC verbs return a disabled error; flag on → poller runs. Graduation: realistically stays opt-in-by-configuration (the feature is inert without a registered provider file), so the flag can be deleted after soak rather than default-flipped.

### Mirror model + migration

New table `remote_session` (as shipped — `Sources/TBDDaemon/Database/Database.swift`):

| Column | Notes |
|---|---|
| `provider`, `sessionID` | composite key |
| `payload` | latest full Session JSON |
| `state`, `agentState` | the two liveness/attention axes, denormalized out of `payload` so the store can query and edge-detect without decoding it |
| `firstSeen`, `lastSeen` | timestamps |
| `missingCount` | consecutive snapshots absent (drives the `gone` rule) |
| `gone`, `dismissed` | drift/tombstone state |
| `resolvedRepoID` | added in a follow-up migration (see "Sidebar rendering" under App UI below) — the local repo this session's `meta["repo"]` was matched to, pinned at first sighting and never re-derived once non-null |

No separate `last_agent_state` column: `RemoteSessionStore.upsert` reads the existing row's `agentState` (about to be overwritten) as the "previous" value for edge detection in the same transaction, so a dedicated history column would be redundant with the column already there.

GRDB record in `Sources/TBDDaemon/Database/`, Codable model (`RemoteSessionInfo`) in `Sources/TBDShared/RPCProtocol.swift` (fields optional/defaulted), all in the migration's commit.

### Daemon: `RemoteProviderManager`

One actor in `TBDDaemon`, started only when the flag is on and the registry file has entries.

- Per provider: run `describe` once (offline, cheap); if `events` capability, supervise the stream per the contract's backoff rules; else poll `list` at 60s.
- Provider invocations go through a runner modeled on `HookResolver.execute` (spawn, capture stdout/stderr, hard timeout, os.Logger `com.tbd.daemon` category `remote`) — in practice this is the same shared `runBoundedProcess` engine `GitManager`/`TmuxManager` already use (`ProviderRunner.run`), not a parallel implementation.
- Snapshot application: upsert sessions, reset/increment `missingCount`, apply the two-absence `gone` rule, broadcast a `StateDelta` on any change.
- Notifications: fire through the existing notification path on `agent_state` edges into `waiting_input` or `exited` (edge detected against the stored `agentState`, so a daemon restart doesn't re-notify or miss).
- Exit-code handling per contract: 3 → bounded retry; 4 → mark provider `needs_auth` (surfaced in StateDelta), pause polling until any successful invocation.

### RPC additions

Flat additive verb family in `RPCProtocol` + `RPCRouter` cases: `remote.providers` (registry + health), `remote.sessions` (mirror read), `remote.create`, `remote.stop`, `remote.send`, `remote.log`, `remote.rename`, `remote.dismiss`. `create/stop/send/log/rename` are pass-throughs to the provider executable executed daemon-side (`rename` calls the provider's own optional `rename` capability); `remote.create` mints the idempotency key and persists it until a terminal outcome; `remote.dismiss` is TBD-local only (clears a tombstoned `gone` row, never reaches the provider).

### Profile axis: location, resolution, and identity swaps

**Shipped in this PR:** the *contract-level* pieces only — the Profile object shape, and the `profile`/`rename`/`set-profile` capability strings, documented in `docs/remote-provider-contract.md` for providers to adopt. TBD's daemon calls the provider's `rename` capability (`remote.rename`), and `meta.profile` rides the wire as an opaque display key (see Session object above). **Everything below this point — the location-resolution order, the DB-column/RPC design, and the UI surfaces — is forward design, not implemented in this PR.** There is no `remote.setProfile` RPC verb yet, no `default_location`/`location_override` columns, and no `profile_provider_credential` table. It's kept here because it's still the intended direction, but a future PR implementing it needs its own brainstorming pass (this section predates that work, not a substitute for it) and its own migration.

**Profile and location are orthogonal.** A profile (name, kind, routing, env overrides, credential) stays a single entity. Location — local, or a specific registered provider — is a property of a *creation*, chosen once when a session is created, never baked into the profile itself. There must never be parallel "local profile A" / "remote profile A" entries: the same profile can create a local session today and a remote session tomorrow.

**Location resolution order**, evaluated at creation time, most-specific wins:

1. **Explicit per-creation choice** — the user picks a location (local, or a specific registered provider) directly in the create sheet for this one session. Always available, always wins.
2. **Per-repo override** — a repo can be configured to default to a specific location.
3. **Global default location** — a single app-wide setting (default: local).
4. **Local** — the ultimate fallback when nothing else applies.

**No scratch tier.** Scratch spaces are repo-less local directories — there is no repo to hang a per-repo override off, and "remote scratch" has no meaning (there'd be no durable workspace on the remote box tying back to anything once the laptop-side scratch context is gone). Scratch creation always resolves to local; the resolution order above only applies to repo-backed creations.

**Fail-visible behavior — two distinct failure modes get two distinct behaviors, not one blanket fallback:**

- **Repo resolves to remote, but the provider is unhealthy** (unreachable, `needs_auth`, etc.) at creation time: open the create sheet as normal, showing the provider's own error and remediation (from the contract's error model) inline, with Create disabled. Add an explicit "Create locally instead" escape hatch as a distinct, deliberate action the user takes. Never silently create the session locally when the user asked for remote — a session landing somewhere the user didn't choose, silently, is worse than a blocked create sheet.
- **Repo resolves to remote via a stale per-repo override naming a provider that's no longer registered**: this is config drift, not a live-health condition, so resolution degrades to local automatically and the app flags it in Settings (e.g. "the override for this repo names an unregistered provider — creating locally until fixed") rather than blocking creation on it. The two cases differ because one is a live condition the user is actively acting on right now ("I clicked create and it's down") and the other is stale config nobody has revisited since the provider was removed — blocking every creation in the repo on a config problem nobody's looking at would be worse than degrading with a visible flag.

**DB columns and RPC additions implied:**

- A global default location: a column on `config`, e.g. `default_location` (nullable; absent means local).
- A per-repo override: a column on `repo`, e.g. `location_override` (provider name, or `NULL` to inherit the global default).
- A per-profile-per-provider credential reference map: a new table, e.g. `profile_provider_credential` (`profile_id`, `provider_name`, `credential_ref`) — a profile's `credential_ref` is per-*provider*, not global on the profile, since each provider's secret store is independent and the same profile can be registered against more than one provider with different refs. Storing a single credential_ref on the profile itself would conflate identity with one provider's view of it.
- A profile id added to `remote.create`'s params, so the daemon can look up the right `profile_provider_credential` row and build the contract's Profile object for `create`'s stdin.
- Setters for all of the above (e.g. `config.setDefaultLocation`, `repo.setLocationOverride`, a provider-credential-ref setter), following the existing DB-column/RPC-verb-pair pattern used elsewhere in this document.
- All new columns follow the project's migration rule: migration + GRDB record + `TBDShared` Codable model updated together, new fields optional/defaulted so existing rows keep decoding.

**UI surfaces that change:**

- Create sheet: a location picker (registered providers plus "Local") driven by the resolution order above; the provider-health/remediation inline block and "Create locally instead" escape when the resolved provider is unhealthy.
- Settings: the global default location; a per-repo location override control on the repo settings surface; a credential-reference field per profile-per-provider pair (placeholder text sourced from the contract's `describe.credential_ref_hint`); a banner for a stale per-repo override naming an unregistered provider.
- Sidebar/session UI: the in-place profile swap on a remote session reuses the existing "Switch account" affordance and RPC family already wired for local sessions, rather than introducing a separate remote-only control — when the target session is remote, "Switch account" routes through the contract's `set-profile` verb instead of the local in-pane respawn path. The surface and interaction stay the same; only the backing path differs.

**No `Worktree`-model unification.** None of the above forces remote sessions onto the `Worktree` model. Location resolution decides *where a new session's bytes go*; it says nothing about merging the two models that already exist to represent sessions once created. Remote sessions remain a parallel model — own table, own RPC family, own sidebar section — per the deliberate decision (see Summary) to avoid the `Location {local|remote}` refactor.

### App UI

- **Sidebar rendering (revised from the original draft — "daily-driving this is unusable with remote worktrees off in their own section"):** a session whose `meta["repo"]` resolved to a locally registered repo (`resolvedRepoID` non-nil) renders inside that repo's own `RepoSectionView`, after its local worktrees — not in a separate remote area. Only *unmatched* sessions (no resolution, or resolved to a repo currently filtered/hidden) render under the flat "Remote" section (`RemoteSectionView`), grouped by provider. A provider's header stays visible in that section even with zero unmatched rows whenever its health isn't `.ok`, so an auth/unreachable banner can't go dark just because every session happened to match a repo. Session rows: liveness dot (`starting`/`running`/`exited`), agent-state chip (`working`/`waiting_input` highlighted), tooltip with `agent_state_reason` + `meta` rows. Provider-level states: staleness indicator when unreachable, auth banner with remediation button on `needs_auth`. `gone` sessions render dimmed with a dismiss action (`remote.dismiss`).
- Create sheet: rendered from `create_params` (five field types), prefill for well-known names, provider validation errors surfaced inline from the error object.
- Attach: terminal pane whose argv is `<exec> [args...] attach <id>` via the existing `LocalProcess` PTY spawn path — a new pane flavor beside tmux-attach panes; no tmux bridge involvement. Pane close = detach only.
- Log: read-only scrollback view (terminal-history surface pattern) filled by `remote.log` on open, manual refresh.
- File viewer / diff panels don't render for remote sessions.

---

## Part 3 — Agentbox changes (first provider; its own repo)

Agentbox's API may change freely; the contract is the design driver, not the current verbs.

1. **`agentbox provider <verb>` subcommand group** speaking the contract exactly (`describe/create/list/stop/log/send/attach/events`). Human-facing verbs (`new/ls/log/send/done/attach`) remain. TBD registers `exec: agentbox, args: ["provider"]`.
2. **`describe`**: static — contract version 1, all four capabilities, `create_params` = `repo` (required), `branch`, `prompt`, using the existing defaults.
3. **Identity**: the slug is already a durable id (`meta.json` survives reboots; `ls` reports `dead`). Mapping: `dead → exited` (exit code unknown), `done → exited`, `running → running`. No identity change needed.
4. **Agent state**: at `new` time, inject Claude Code hooks (`SessionStart`, `UserPromptSubmit`, `Stop`, `Notification`) via per-session settings; each hook atomically writes (`write temp + rename`) `state.json` next to `meta.json`: `{"agent_state", "reason", "at"}`. Mapping: `SessionStart`/`UserPromptSubmit` → `working`; `Stop` → `waiting_input`; `Notification` → `waiting_input` + reason; process exit → `exited`. `ls` folds `state.json` into each session — agent state for all sessions still costs one transport round trip. Sessions predating the hooks report `unknown`.
5. **Create idempotency**: box-side `~/agents/.idempotency/<key>` file mapping key → slug; replayed create returns the existing session.
6. **Errors**: map SSO-expiry to exit 4 + `auth_expired` with the `aws sso login` remediation; stopped instance to exit 3 `unreachable`; unknown slug to exit 1 `not_found`.
7. **`events` v1 — no on-box daemon**: implemented as a laptop-side loop inside the provider process, polling its own `list` every 30–60s and emitting `hello`/`snapshot`/`session`/`ping`. One transport round trip per interval regardless of session count; ~30s notification latency. This preserves agentbox's "no daemon" principle. **v2 graduation (only if latency chafes):** on-box watcher (fs-watch on `state.json` files + tmux liveness) relayed over one long-lived SSM channel, dropping latency to ~1–2s; contract unchanged.
8. **`stop`**: wraps the existing idempotent done, returning the session object.

---

## Testing

**TBD side** (no AWS, no network):

- A stub provider — a fixture script emitting canned contract JSON, controllable via env/fixture files — exercises: describe/capability negotiation, poll + mirror upserts, the two-absence `gone` rule, unknown-session adoption, `agent_state` edge → notification (and no re-notification across daemon restart), exit-code classes (3 retry, 4 pause + banner + clear-on-success), events-stream supervision (kill stub → backoff → snapshot resync), create idempotency-key replay.
- Flag branches per repo rule: off → no subprocess spawned, RPC disabled error; on → manager runs.
- All tests use `TBD_HOME` isolation seams; registry file written into the test home.

**Agentbox side** (its repo): `provider` subcommands under the existing local-transport harness; hook → `state.json` → `list` folding in the host script's unit suite; idempotency replay; error mapping.

## Rollout

1. **Done (PR #514).** TBD PR: contract doc + registry + migration + `RemoteProviderManager` + RPC + UI, all behind `remote_backends_enabled` (default OFF). Stub-provider tests green.
2. Agentbox PR: `provider` subcommands + hooks + idempotency.
3. Soak: enable the flag, register agentbox, dogfood against the live box.
4. Graduate: delete the flag after soak (feature remains opt-in via the registry file). Revisit v2 events channel and `log --follow` only if 30s latency proves annoying.

## Deliberate v1 cuts (growth-compatible)

No cursors on `events` (snapshot resync covers it); no file/diff verbs (future `files` capability); no port forwarding; no provider-pushed notification events (derived from state edges); no minor versions; no `log --follow`; no on-box daemon for agentbox.
