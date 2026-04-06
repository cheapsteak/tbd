# Claude Token Switcher — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan phase-by-phase. This is a **fractal plan** — each phase has its own child document with full task breakdown. Follow the dependency order below.

**Goal:** Let the user store multiple Claude tokens, designate a global default with per-repo overrides, swap a running claude terminal's token mid-conversation without losing context, and see 5h/7d usage per token.

**Spec:** [`docs/superpowers/specs/2026-04-06-claude-token-switcher-design.md`](../specs/2026-04-06-claude-token-switcher-design.md)

**Architecture:** Tokens live in macOS Keychain, referenced by UUID from new `claude_tokens` / `claude_token_usage` tables in `state.db`. A new `config` table holds the global default; `repo` and `terminal` tables gain optional token-ID columns. Spawning a claude terminal resolves the token (repo override → global default → none) and prefixes `CLAUDE_CODE_OAUTH_TOKEN=<value> ` on the shell command passed to tmux. Mid-conversation swap kills the claude process, respawns with `--resume <session-id>` and the new env var. Usage is fetched lazily + on a 30-min background poll from `/api/oauth/usage`, cached in the DB. UI spans a new Settings tab, a repo settings picker row, a menu bar submenu, and a context menu section on claude tabs.

**Tech Stack:** Swift 5.9+, GRDB (SQLite), Security.framework (Keychain), URLSession (HTTP), SwiftUI, Swift Testing (`@Test` / `#expect`), swift-nio (already in daemon, unrelated to this feature).

---

## Phase order and dependencies

Phases may be implemented by separate subagents in parallel where deps allow. Arrows = "must finish before".

```
Phase 01 (schema + models)
  ├── Phase 02 (keychain wrapper)          [independent]
  ├── Phase 03 (usage fetcher)             [independent]
  └── Phase 04 (token resolver)
        └── Phase 05 (RPC: CRUD + fetch)
        └── Phase 06 (spawn + swap RPC)
              └── Phase 07 (background poll scheduler)
                    └── Phase 08 (DaemonClient stubs)
                          ├── Phase 09 (Settings → Claude Tokens tab)
                          ├── Phase 10 (repo override picker)
                          ├── Phase 11 (menu bar submenu)
                          └── Phase 12 (claude tab context menu)
```

**Parallelism notes for the executor:**
- Phases 02, 03, 04 all depend only on 01 and can run in parallel once 01 lands.
- Phases 09–12 all depend on 08 and can run in parallel.
- Phases 05 and 06 both touch `RPCRouter.swift` / `RPCProtocol.swift` — serialize them or expect a merge.

---

## Child plans

| # | Phase | Child plan | Scope |
|---|---|---|---|
| 01 | Schema & models | [`01-schema-and-models.md`](2026-04-06-claude-token-switcher/01-schema-and-models.md) | Migration v13, `ClaudeToken` / `ClaudeTokenUsage` / `Config` records & stores, optional fields on `Repo` / `Terminal`, model updates in `TBDShared`. |
| 02 | Keychain wrapper | [`02-keychain.md`](2026-04-06-claude-token-switcher/02-keychain.md) | `ClaudeTokenKeychain.store/load/delete` via `SecItem` with delete+add upsert pattern. |
| 03 | Usage fetcher | [`03-usage-fetcher.md`](2026-04-06-claude-token-switcher/03-usage-fetcher.md) | `ClaudeUsageFetcher` hitting `/api/oauth/usage`, status mapping, JSON decoding, unit tests with `URLProtocol` mock. |
| 04 | Token resolver | [`04-token-resolver.md`](2026-04-06-claude-token-switcher/04-token-resolver.md) | `ClaudeTokenResolver.resolve(repoID:)` order: per-repo override → global default → none. Loads from Keychain. |
| 05 | RPC: CRUD + manual fetch | [`05-rpc-crud.md`](2026-04-06-claude-token-switcher/05-rpc-crud.md) | `claudeToken.list/add/delete/rename/setGlobalDefault/setRepoOverride/fetchUsage` in new `RPCRouter+ClaudeTokenHandlers.swift`, proto constants, validation via fetcher on add. |
| 06 | Spawn + swap RPC | [`06-spawn-and-swap.md`](2026-04-06-claude-token-switcher/06-spawn-and-swap.md) | Inject env prefix in `RPCRouter+TerminalHandlers.swift` spawn path; new `terminal.swapClaudeToken` handler that C-c's + respawns via `claude --resume`. |
| 07 | Background poll | [`07-background-poll.md`](2026-04-06-claude-token-switcher/07-background-poll.md) | 30-min poll loop with 30 s stagger, 60-min backoff on 429, pause when app unfocused >10 min, resume + immediate fetch on focus. State-update broadcast on cache write. |
| 08 | DaemonClient stubs | [`08-daemon-client.md`](2026-04-06-claude-token-switcher/08-daemon-client.md) | Swift client-side RPC call wrappers used by TBDApp for all new methods + new state-update handling for usage cache changes. |
| 09 | Settings tab | [`09-settings-ui.md`](2026-04-06-claude-token-switcher/09-settings-ui.md) | `ClaudeTokensSettingsView` — list, add modal with tooltip, rename/delete/set-default, usage badges + reset-timer tooltips, tab wired into `SettingsView.swift`. |
| 10 | Repo override UI | [`10-repo-override-ui.md`](2026-04-06-claude-token-switcher/10-repo-override-ui.md) | Picker row in `RepoSettingsRow` (or equivalent) for "Claude token override", writes via `claudeToken.setRepoOverride`. |
| 11 | Menu bar | [`11-menu-bar.md`](2026-04-06-claude-token-switcher/11-menu-bar.md) | TBD app menu gets a "Claude Token" submenu with radio selection + usage badges + "Manage tokens…". Selecting an item updates global default. |
| 12 | Claude tab context menu | [`12-context-menu.md`](2026-04-06-claude-token-switcher/12-context-menu.md) | In `TabBar.swift:contextMenuContent`, add disabled header row + "Swap token →" submenu inside `if isClaudeTerminal` block. One-shot swap. |

---

## Cross-cutting rules

All phases must adhere to:

- **Per CLAUDE.md**: commit after completing each phase; verify `swift build` passes before committing; run `swift test` if the phase touched daemon/shared code.
- **Migration rule**: every DB change lands in the same commit as the GRDB record type update and the `TBDShared/Models.swift` update, and new fields MUST be optional or have defaults.
- **Branching conditional rule**: when adding a branch that gates behavior (e.g. token present vs not, per-repo override vs global vs none), add a test for each branch.
- **Never delete `~/.tbd/state.db`**. If a schema issue arises, diagnose and add a new migration.
- **Token bytes** must never be logged, written outside Keychain, or included in error strings.
- **NIO thread safety**: any `ChannelHandlerContext` access from the poll scheduler or swap flow must be wrapped in `context.eventLoop.execute { ... }`.

## Definition of done for the feature

1. `swift build && swift test` green.
2. Manual: add an OAuth token via Settings, see 5h/7d % populate; swap via menu bar, open a new claude tab, verify it uses the token (spot-check with `env | grep CLAUDE` inside the pane); swap mid-conversation via context menu, verify `/resume` preserves context and new env is applied; delete a token in use, verify the running terminal keeps working and the confirmation copy is correct.
3. All new child plans' task checkboxes ticked.
