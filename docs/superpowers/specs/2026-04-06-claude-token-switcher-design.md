# Multi-token Claude switcher for tbd

**Status:** Design approved, ready for implementation plan
**Date:** 2026-04-06

## Motivation

The user holds multiple Claude accounts and wants to swap between them when one runs out of quota, without losing conversation context. Today, tbd spawns `claude` with no auth overrides and inherits whatever OAuth login is stored in Claude Code's keychain. There's no way to store additional tokens, swap between them, or see how much headroom each one has.

## Goals

1. Store multiple named Claude tokens securely and let the user designate a global default.
2. Allow per-repo override of the global default.
3. Allow a one-shot mid-conversation swap of a running claude terminal's token — without losing context.
4. Show 5-hour and 7-day usage percentages per token, lazily fetched and cached.

## Non-goals

- Per-terminal persistent override (covered by one-shot swap).
- `CLAUDE_CONFIG_DIR` isolation per token — all tokens share `~/.claude` so `--resume` works across swaps.
- Aggressive polling, usage graphs, historical tracking.
- Managing tokens for tools other than `claude` CLI.

## Background: how Claude Code auth works

- `claude setup-token` produces a long-lived OAuth token of the form `sk-ant-oat01-...`, backed by a Claude.ai Pro/Max subscription.
- Setting `CLAUDE_CODE_OAUTH_TOKEN=<token>` in a process's environment overrides the keychain login for that process only, with no interactive prompt.
- The undocumented endpoint `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <oauth-token>` and `anthropic-beta: oauth-2025-04-20` returns `{ five_hour: { utilization, resets_at }, seven_day: { utilization, resets_at } }`. Costs zero tokens. Rate-limited (persistent 429s reported in anthropics/claude-code#31021), so polling must be conservative.
- `sk-ant-api03-...` console API keys do not support the OAuth usage endpoint. They can still be stored and used for auth, but will show no usage numbers.

## Data model

New GRDB migration (next sequential version in `Database.swift`), adding:

### `claude_tokens` table

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT (UUID) | Primary key |
| `name` | TEXT | Unique, user-supplied (e.g. "Personal", "Work") |
| `keychain_ref` | TEXT | Opaque identifier; actual token bytes live in macOS Keychain under service `app.tbd.claude-token`, account = this UUID |
| `kind` | TEXT | `oauth` or `api_key`, inferred from prefix at paste time |
| `created_at` | DATETIME | |
| `last_used_at` | DATETIME | Nullable; updated on spawn |

### `claude_token_usage` table (cache)

| Column | Type | Notes |
|---|---|---|
| `token_id` | TEXT | FK to `claude_tokens.id`, primary key |
| `five_hour_pct` | REAL | Nullable |
| `seven_day_pct` | REAL | Nullable |
| `five_hour_resets_at` | DATETIME | Nullable |
| `seven_day_resets_at` | DATETIME | Nullable |
| `fetched_at` | DATETIME | Nullable |
| `last_status` | TEXT | `ok`, `http_429`, `http_401`, `network_error` |

### `config` table additions

| Column | Type | Notes |
|---|---|---|
| `default_claude_token_id` | TEXT | Nullable, FK to `claude_tokens.id`. Null = use claude's own keychain login. |

### `repo` table additions

| Column | Type | Notes |
|---|---|---|
| `claude_token_override_id` | TEXT | Nullable, FK to `claude_tokens.id`. Null = inherit global default. |

### `terminal` table additions

| Column | Type | Notes |
|---|---|---|
| `claude_token_id` | TEXT | Nullable. Records which token this terminal was actually spawned with (after override/default resolution and any subsequent swap). Used by UI to show the current token and to respawn on swap. |

All new fields have `.defaults(to:)` in the migration. Matching updates land in the same commit in:
- `Sources/TBDDaemon/Database/` record types
- `Sources/TBDShared/Models.swift` (new fields optional)

## Token storage

macOS Keychain via Security.framework. Wrapper at `Sources/TBDDaemon/Keychain/ClaudeTokenKeychain.swift`:

```swift
enum ClaudeTokenKeychain {
    static func store(id: String, token: String) throws
    static func load(id: String) throws -> String?
    static func delete(id: String) throws
}
```

Service constant `app.tbd.claude-token`, account field = token UUID. No Touch ID gate in v1. Tokens never written to disk outside Keychain, never logged, never included in error messages.

### Keychain implementation notes (verified via dry run 2026-04-06)

A Swift `SecItem` round-trip was executed end-to-end (`SecItemAdd` → `SecItemCopyMatching` → update → `SecItemDelete` → load-after-delete returned `errSecItemNotFound` / -25300) and confirmed the API behaves as expected on this machine.

- **Upsert pattern.** `SecItemAdd` returns `errSecDuplicateItem` when an entry exists, so `store(id:, token:)` performs `SecItemDelete` + `SecItemAdd` as a single unit for both initial writes and updates. No `SecItemUpdate` needed.
- **Access attributes.** Use the default `kSecAttrAccessibleWhenUnlocked`, no `SecAccessControl`, no biometric gate. Reads succeed without prompts once the login keychain is unlocked — consistent with the v1 no-Touch-ID decision.
- **Unbundled-executable caveat.** TBDApp runs as a bare SPM executable, not a `.app` bundle (see `CLAUDE.md`). Keychain APIs do work without a bundle identifier — unlike `UNUserNotificationCenter` — but items stored by a SPM binary get the calling binary's path in their ACL. After a rebuild, the daemon binary path changes and macOS may show a one-time *"tbd-daemon wants to use your keychain"* prompt the first time a rebuilt binary tries to read an existing item. Expected UX, not a defect. A user can click "Always Allow" to suppress subsequent prompts for that binary path.

## Token resolution

When spawning a `--type claude` terminal, the daemon resolves the token in order:

1. If the repo has `claude_token_override_id` set → use that token.
2. Else if `config.default_claude_token_id` is set → use that token.
3. Else → no env var injection. Claude uses its own keychain login.

The resolved token's UUID is written to `terminal.claude_token_id` at spawn time (null if none resolved). `last_used_at` is bumped on the token row.

## Spawn mechanism

The existing claude spawn path at `Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift:38` gains a branch:

- If a token was resolved, the daemon loads the token from Keychain and prepends `CLAUDE_CODE_OAUTH_TOKEN=<value> ` to the shell command string before handing it to tmux.
- If no token was resolved, the command is unchanged from today.

No `CLAUDE_CONFIG_DIR` injection — all tokens share `~/.claude`, which means:
- `claude --resume` works across token swaps (critical for mid-conversation swap).
- Settings, MCP config, and CLAUDE.md are shared across tokens.
- The in-claude `/resume` picker shows sessions from all accounts interleaved.

## Mid-conversation token swap

New RPC: `terminal.swapClaudeToken(terminal_id: UUID, new_token_id: UUID?)`.

Daemon flow:

1. Look up the terminal's current claude session ID (already tracked for the existing resume flow).
2. Send `C-c` to the pane, wait 500 ms for the running claude process to terminate.
3. Respawn `claude --resume <session-id> --dangerously-skip-permissions` in the same pane. If `new_token_id` is non-null, prefix with `CLAUDE_CODE_OAUTH_TOKEN=<value> `; if null, omit (falls back to keychain login).
4. Update `terminal.claude_token_id` to the new value. **One-shot only** — does not write to `repo.claude_token_override_id` or `config.default_claude_token_id`.
5. Trigger an immediate usage fetch for the new token (see below).

If `--resume` fails (stale session, claude crashes), the pane is left in its dead state for the user to close manually. Daemon surfaces the error via existing terminal-status channels; it does not retry automatically.

## Usage fetching

New module `Sources/TBDDaemon/Claude/ClaudeUsageFetcher.swift`:

```swift
struct ClaudeUsageResult {
    var fiveHourPct: Double
    var sevenDayPct: Double
    var fiveHourResetsAt: Date
    var sevenDayResetsAt: Date
}

enum ClaudeUsageStatus { case ok(ClaudeUsageResult), http429, http401, networkError }

func fetchUsage(token: String) async -> ClaudeUsageStatus
```

Implementation: `URLSession` GET to `https://api.anthropic.com/api/oauth/usage` with:
- `Authorization: Bearer <token>`
- `anthropic-beta: oauth-2025-04-20`

Parses both `five_hour` and `seven_day` blocks.

### Triggers

| Trigger | Notes |
|---|---|
| Token added in Settings | Validates + first reading. 401 → reject save. |
| UI surface opened (menu bar submenu, context menu on claude tab, Settings tab) | Lazy fetch; dedupe if `fetched_at < 60s` ago. |
| Token swap (RPC) | Immediate fetch for the newly selected token. |
| Background poll every 30 min per token | Staggered across first 30 s of daemon startup. |
| App focus regained after >10 min unfocused | Resume background poll + immediate fetch for all tokens. |

### Rules

- **OAuth tokens only.** Tokens with `kind = api_key` are skipped permanently and displayed as `—`.
- **On HTTP 429:** back off that specific token to 60 min until next success. Log once, do not surface as an error. UI shows last cached value with a `· stale` indicator.
- **On HTTP 401:** mark the token invalid (red badge in Settings). Stop polling that token. Do not auto-delete — user may be rotating.
- **App unfocused >10 min:** pause all background polling until focus returns.

All successful results are written to `claude_token_usage` and broadcast to the app via the existing state-update channel so UI stays live.

## UI

### Settings → new "Claude Tokens" tab

Top of tab: `Global default: [Default (claude keychain login) ▾]` picker. Options: "Default (claude keychain login)" + each stored token.

List of tokens below. Each row shows:
- Name
- Kind badge (`OAuth` or `API key`)
- Usage: `5h 42% · 7d 18%` with relative `fetched_at` timestamp (or `—` for API keys, or a red "Invalid" badge, or "Stale" badge after a 429)
- Tooltip on the percentage: `Resets in 2h 14m` (computed from `resets_at`)
- Row actions: rename, delete, "Set as global default"

"+" button opens an add-token modal:
- Field: `Name` (required, unique)
- Field: `Token` (required, monospaced input)
- Tooltip below the token field: *"Run `claude setup-token` in a terminal and paste the resulting `sk-ant-oat01-...` token here."*
- On save:
  - Detect kind from prefix (`sk-ant-oat01-` → oauth, `sk-ant-api03-` → api_key, else → reject).
  - If oauth: call `/api/oauth/usage` to validate. 401 → reject with "Token invalid". 200 → store in Keychain, insert row, cache the fresh usage.
  - If api_key: warn "Usage percentage is not available for API keys. Continue?" On confirm, store without validation.

Delete flow: if any terminals have `claude_token_id = <this>`, confirm with "N running terminal(s) are using this token. They'll keep running on this token until closed. Delete anyway?"

### Repo settings sheet (existing)

New row: `Claude token override: [Inherit global default ▾]` picker. Options: "Inherit global default", "Default (claude keychain login)", + each stored token. Writes to `repo.claude_token_override_id`.

### Menu bar — TBD menu → new "Claude Token" submenu

```
● Default (logged in)         —
○ Personal          5h 42% · 7d 18%
○ Work              5h  8% · 7d  3%
──
Manage tokens…
```

- `●` marks the currently selected **global default**.
- Selecting a row updates `config.default_claude_token_id`. Takes effect for newly spawned claude terminals. Does not touch repo overrides or running terminals.
- "Manage tokens…" opens the Settings tab.
- Usage values come from the `claude_token_usage` cache; opening the submenu triggers a lazy fetch (subject to 60 s dedupe).

### Claude tab context menu — new section

Rendered only on `--type claude` terminals. Section sits above existing context-menu items, separated by a divider.

```
Token: Personal · 5h 42% · 7d 18%   [disabled header]
Swap token →
    ● Personal           5h 42% · 7d 18%
    ○ Work               5h  8% · 7d  3%
    ○ Default (logged in)            —
```

- Header shows `terminal.claude_token_id`'s current state. If null: `Token: Default (logged in)`.
- "Swap token" submenu triggers `terminal.swapClaudeToken` RPC. One-shot — does not change repo or global default.
- Usage values come from cache; opening the context menu triggers a lazy fetch.

## Failure modes

| Case | Behavior |
|---|---|
| Token deleted while terminals use it | Terminals keep running (env was set at spawn). On next swap/resume from the daemon, falls back to repo/global default. Settings delete confirmation surfaces the count. |
| `/api/oauth/usage` 429 | Back off that token to 60 min. UI shows last cached value with `· stale`. |
| `/api/oauth/usage` 401 | Mark token invalid. Stop polling. Red badge in Settings. |
| Swap during active claude prompt | Daemon sends `C-c`, waits 500 ms, respawns. If in-flight response is lost, user notices and can redo the message from the resumed conversation. |
| `claude --resume` fails after swap | Pane left in its dead state. Error surfaced via existing terminal-status channel. |
| Keychain access denied | Settings surfaces a clear error. Tokens unavailable until resolved. No plaintext fallback. |
| App running on a machine without the token in its Keychain (e.g. state.db restored from backup) | Token rows exist but `ClaudeTokenKeychain.load` returns nil. Settings shows "Missing from Keychain — re-add". Spawns skip the env prefix and fall back as if no token resolved. |

## File layout

**New:**
- `Sources/TBDDaemon/Database/ClaudeTokenRecord.swift`
- `Sources/TBDDaemon/Database/ClaudeTokenUsageRecord.swift`
- `Sources/TBDDaemon/Keychain/ClaudeTokenKeychain.swift`
- `Sources/TBDDaemon/Claude/ClaudeUsageFetcher.swift`
- `Sources/TBDDaemon/Claude/ClaudeTokenResolver.swift` (resolution order + Keychain load)
- `Sources/TBDDaemon/Server/RPCRouter+ClaudeTokenHandlers.swift` (CRUD + swap RPC)
- `Sources/TBDApp/Settings/ClaudeTokensSettingsView.swift`
- `Sources/TBDApp/MenuBar/ClaudeTokenMenu.swift`

**Modified:**
- `Sources/TBDDaemon/Database/Database.swift` — new sequential migration
- `Sources/TBDShared/Models.swift` — new token/usage model types, new optional fields on Config/Repo/Terminal
- `Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift` — env prefix on spawn, `swapClaudeToken` handler
- `Sources/TBDApp/Settings/SettingsView.swift` — new tab
- Existing repo settings sheet — new picker row
- Existing claude-tab context menu builder — new section

## Testing

- **Migration test** applies cleanly to an existing DB, decodes pre-existing rows.
- **Keychain wrapper** round-trip (store → load → delete) test.
- **Token resolution** precedence test: per-repo beats global; null repo falls through; both null = no env.
- **Spawn test:** when a token resolves, command string begins with `CLAUDE_CODE_OAUTH_TOKEN=`; when none, command is byte-identical to today.
- **Usage fetcher:** mock `URLSession` for 200/401/429/network error; assert parsed fields and status mapping.
- **Backoff:** after 429, next scheduled poll is 60 min out; after subsequent 200, returns to 30 min.
- **Stagger:** N tokens polling on startup spread across 0–30 s.
- **Swap RPC:** `terminal.claude_token_id` updated, session ID preserved, new command string includes new token's env.
- **Per CLAUDE.md branching rule:** each gated branch in resolution and env injection has a test asserting on/off behavior.

## Open questions (deferred)

- Whether to fetch usage reset timestamps in a machine-readable format usable for more than tooltips (e.g. "Personal resets in 12 min" alerts).
- Whether to surface total remaining budget as a tbd menu bar badge when the active default is running low.
- Touch ID gating on Keychain reads.

These can be layered on without schema changes.
