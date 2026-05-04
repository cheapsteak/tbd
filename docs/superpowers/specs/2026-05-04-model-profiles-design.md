# Model Profiles — Design

**Date:** 2026-05-04
**Status:** Approved, pending implementation plan

## Goal

Let any terminal in TBD run `claude` against any Anthropic-compatible endpoint — Claude direct (today) or a local proxy such as [claude-code-router](https://github.com/musistudio/claude-code-router) (CCR) routing to OpenAI/Codex/GPT-5 — selectable per-terminal. Generalize the existing Claude-token system into a unified "model profile" abstraction so the UX you already use to swap accounts also covers swapping endpoints and models.

## Non-goals

- TBD spawning, supervising, or configuring CCR. The user runs CCR (or any other Anthropic-compatible proxy) themselves. TBD stays agnostic about which proxy software is in use.
- Editing CCR's config from inside TBD.
- Cross-profile cost/usage aggregation. Today's `claude_tokens_usage` poller is Claude-API-specific; usage tracking for proxy-routed traffic is deferred until we know what that data looks like.
- A first-class "Codex via CCR" preset in the profile-creation form. The generic "Anthropic-compatible proxy" preset (see UI section) is enough to start. Revisit after dogfooding.

## Architecture

CCR (or any other Anthropic-compatible proxy) runs as a user-managed background process. TBD never starts, supervises, or talks directly to it. TBD's contribution is one new abstraction:

A **model profile** is a named bundle of `{auth credential, optional base URL, optional model}`. When TBD spawns `claude` in a terminal, it injects the profile's values as env vars via tmux's `-e KEY=VALUE` flag, identically to how today's Claude tokens flow:

- Auth: `CLAUDE_CODE_OAUTH_TOKEN` (oauth) or `ANTHROPIC_API_KEY` (api key).
- `ANTHROPIC_BASE_URL` if the profile has one (proxy case).
- `ANTHROPIC_MODEL` if the profile has one (proxy case).

A profile with `base_url=nil, model=nil` is "Claude direct" — bit-for-bit equivalent to today's Claude-token behavior.

## Data model

### Rename `claude_tokens` → `model_profiles`

Add two nullable columns:

| Column | Type | Meaning |
| --- | --- | --- |
| `base_url` | `TEXT NULL` | Anthropic-compatible endpoint URL. Nil → Claude direct. |
| `model` | `TEXT NULL` | Model id sent in `ANTHROPIC_MODEL`. Nil → Claude default. |

Existing rows decode unchanged: both new fields nil reproduces today's behavior exactly.

### Terminal row addition

Add `profile_id TEXT NULL` to the terminal row. Records which profile a terminal was created with so resume can stay on the same model (see *Resume*).

### Shared model

`TBDShared.ClaudeToken` → `ModelProfile`. New fields are optional / defaulted so existing JSON-encoded payloads in flight during the upgrade still decode (per the project's migration rules in `CLAUDE.md`).

Keychain entry per profile, keyed by profile id — unchanged from today's per-token keychain layout.

### Migration

Single new GRDB migration:

1. Rename `claude_tokens` table to `model_profiles`.
2. `ALTER TABLE model_profiles ADD COLUMN base_url TEXT;`
3. `ALTER TABLE model_profiles ADD COLUMN model TEXT;`
4. `ALTER TABLE terminals ADD COLUMN profile_id TEXT;`
5. Backfill `terminals.profile_id` for existing rows by running the resolver once per terminal (so resume continues to work after upgrade).

Per `CLAUDE.md`, never edit prior migrations — this is a new sequential `v<N>`.

## Resolution

Rename `ClaudeTokenResolver` → `ModelProfileResolver`. The precedence chain is unchanged:

1. **Per-repo override** — if the repo row has a `profile_override_id` and the profile loads, use it.
2. **Global default** — `config.defaultProfileID`.
3. **Nothing** — no env injection, `claude` falls back to its own auth chain.

`loadByID` is preserved for explicit picks (mid-session swap, terminal creation with a chosen profile).

On terminal creation, the resolved profile's id is written to `terminals.profile_id`. On resume, that pinned id is loaded directly via `loadByID` — the precedence chain is **not** re-run. This keeps resumed conversations on the model they started with even if the worktree default has since changed. The user can override mid-session via the swap menu.

## Spawn

`ClaudeSpawnCommandBuilder` is extended:

- Input gains `baseURL: String?` and `model: String?` from the resolved profile (replacing today's bare `tokenSecret` + `tokenKind`).
- `Result.sensitiveEnv` now contains, when applicable: the existing auth var, plus `ANTHROPIC_BASE_URL` and `ANTHROPIC_MODEL`.
- Secret-handling guarantees are unchanged: nothing sensitive ever enters the shell command argv. All env vars flow through `TmuxManager.createWindow(sensitiveEnv:)` and tmux's `-e` flag.

The `base_url` and `model` values are not technically secrets, but routing them through the same `sensitiveEnv` channel keeps a single, audited path.

## UI

### Settings → "Model Profiles" pane

Renamed from "Claude Tokens." Same list-of-rows layout. Each row shows name, kind (oauth / api-key), and — if a base URL is set — a small caption. Caption rendering depends on which optional fields are populated:

- `baseURL` set, `model` set → `via {baseURL} · {model}`
- `baseURL` set, `model` nil → `via {baseURL}` (no trailing separator)
- `baseURL` nil → no caption (Claude direct, today's UX)

**"+ Add profile"** opens a form with two preset buttons at the top:

- **"Claude (direct)"** — hides the base-URL and model fields. The form collapses to today's add-token form (name + kind + secret).
- **"Anthropic-compatible proxy"** — shows the base-URL and model fields. Base-URL placeholder: `http://127.0.0.1:3456`. **Base URL is required; model is optional.** Helper text under the model field: *"Leave blank to pass through whatever model Claude Code selects."* The optional model is essential for pass-through use cases (logging proxies, mitmproxy-style inspection, request recorders) where overriding the model would defeat the proxy's purpose.

On save, TBD performs a lightweight health probe of `base_url` and surfaces the outcome inline. A failed probe is a **warning**, not a save-blocker — the proxy might just not be running yet. The probe uses a **TCP connect** (resolve host, attempt to open the port) rather than an HTTP request: a bare `GET <base_url>` returns 404/405 against api.anthropic.com and most proxies, which would warn on entirely correct configs. TCP connect is the cheapest no-false-positive reachability signal. (A future enhancement could send a minimal `/v1/messages` POST, but only if the user supplies a real-traffic credential, which we don't want to do unsolicited.)

A future "Codex via CCR" preset (option C from brainstorming) is explicitly deferred. We can add it as a third button later without schema changes.

### Repo detail

The existing per-repo Claude-token override picker becomes a per-repo **default profile** picker. Same control, same precedence semantics.

### Tab bar / mid-session swap

The existing "swap token mid-session" menu now lists profiles. Picking one atomically swaps creds + endpoint + model for that terminal (writes the new id to `terminals.profile_id` and respawns/resumes with the new env). Visual treatment is unchanged.

### Tab badges

Each terminal tab shows a small profile badge **only when the tab's profile differs from the resolved default for its worktree.** If everything matches the default (the common case for users with one profile), no badge — no added visual weight. The badge text is the profile name, kept short.

### Error surfacing

If `claude` fails to reach the configured `base_url` (typical symptom: connection refused), surface an inline hint in the terminal panel:

> Proxy unreachable at `<base_url>`. Is your local proxy running?

Wording is generic; no CCR-specific copy in TBD.

## Resume

- Terminals pin their profile via `terminals.profile_id` at creation.
- `claude --resume <session-id>` runs against the pinned profile, no re-resolution.
- Mid-session swap is the explicit escape hatch — it updates `profile_id` and respawns.

## Back-compat

- Existing `claude_tokens` rows: migrated as `base_url=nil, model=nil` → identical behavior.
- Existing terminals: `profile_id` backfilled at migration time by running the resolver once. After the migration, resume on any pre-existing terminal uses the same token it would have used pre-upgrade.
- `TBDShared.ClaudeToken` (used over the wire) → `ModelProfile` with new optional fields. JSON payloads from older daemon/app pairs decode without error in either direction; new fields default to nil.

## Testing strategy

Following the project's branching-conditional rule (`CLAUDE.md`): each new gate gets a test for both branches.

- `ModelProfileResolver`: existing precedence-chain tests, parameterized over profiles with and without `base_url`/`model`.
- `ClaudeSpawnCommandBuilder`: new test cases for `sensitiveEnv` with and without `base_url`/`model`. Verify the auth-only branch (today's behavior) still passes.
- Migration test: load a fixture DB at the prior schema version, run migration, assert rows decoded as expected and `profile_id` backfilled.
- Resume pinning: integration-level test that creating a terminal under one default, changing the default, then resuming uses the original profile.
- Health probe: unit test the probe function against a stub server returning success/failure/timeout — verify warning surfaces correctly without blocking save.

## Open questions for the implementation plan

- Whether the per-repo default picker UI needs any visual changes beyond the rename.
- Migration ordering relative to any pending migrations on `main`.

## Resolved design questions

- **Health probe shape:** TCP connect (resolved 2026-05-04). Bare HTTP GET would 404/405 against api.anthropic.com and most proxies — would warn on correct configs. Cheapest no-false-positive signal.
- **Model field on proxy preset:** optional, not required (resolved 2026-05-04). Pass-through use cases (logging proxies, mitmproxy, request recorders) need to forward whatever model Claude Code negotiates without override. Schema was already nullable; only form validation and helper copy change.
