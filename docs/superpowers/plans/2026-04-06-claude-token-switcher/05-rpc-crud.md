# Phase 05: RPC — CRUD + Manual Fetch

> **Parent plan:** [../2026-04-06-claude-token-switcher.md](../2026-04-06-claude-token-switcher.md)
> **Depends on:** Phase 01, 02, 03
> **Unblocks:** Phase 08 (DaemonClient stubs)

**Scope:** Seven RPC methods for Claude token management — list, add (with validation), delete, rename, setGlobalDefault, setRepoOverride, fetchUsage (dedup-cached).

---

## Context

Phase 01 has landed `ClaudeToken`, `ClaudeTokenUsage`, `ClaudeTokenKind`, and the GRDB stores (`db.claudeTokens`, `db.claudeTokenUsage`, `db.config`) plus the optional `repo.claude_token_override_id` column. Phase 02 has landed `ClaudeTokenKeychain` (with an injectable seam for tests). Phase 03 has landed `ClaudeUsageFetcher` (protocol + `LiveClaudeUsageFetcher`) returning a `ClaudeUsageFetchResult` whose cases include `.ok(ClaudeTokenUsage)`, `.http401`, `.http429`, `.networkError`.

This phase wires those pieces into the daemon RPC surface so the app (Phase 08+) can manage tokens. It does NOT touch terminal spawn — that is Phase 06.

Token bytes are received once on `add`, immediately written to Keychain, and never returned to the client again. `list` returns metadata + cached usage only.

---

## Task list

### 1. Add shared types to `Sources/TBDShared/Models.swift`

- [ ] Add `public struct ClaudeTokenWithUsage: Codable, Sendable { public let token: ClaudeToken; public let usage: ClaudeTokenUsage? }` with public init.
- [ ] Verify `ClaudeToken`, `ClaudeTokenUsage`, `ClaudeTokenKind` from Phase 01 are already `Codable & Sendable` and `public`. If not, fix in this phase (note in commit).

### 2. Add RPC method constants to `Sources/TBDShared/RPCProtocol.swift`

- [ ] In `enum RPCMethod` add:
  - `claudeTokenList = "claudeToken.list"`
  - `claudeTokenAdd = "claudeToken.add"`
  - `claudeTokenDelete = "claudeToken.delete"`
  - `claudeTokenRename = "claudeToken.rename"`
  - `claudeTokenSetGlobalDefault = "claudeToken.setGlobalDefault"`
  - `claudeTokenSetRepoOverride = "claudeToken.setRepoOverride"`
  - `claudeTokenFetchUsage = "claudeToken.fetchUsage"`

### 3. Add parameter and result structs to `RPCProtocol.swift`

- [ ] `ClaudeTokenAddParams { name: String; token: String }`
- [ ] `ClaudeTokenAddResult { token: ClaudeToken; warning: String? }` — `warning` populated when oauth validation could not reach the server (network/429) and the token was accepted optimistically.
- [ ] `ClaudeTokenDeleteParams { id: UUID }`
- [ ] `ClaudeTokenRenameParams { id: UUID; name: String }`
- [ ] `ClaudeTokenSetGlobalDefaultParams { id: UUID? }` (nil clears the default)
- [ ] `ClaudeTokenSetRepoOverrideParams { repoID: UUID; tokenID: UUID? }` (nil clears the override)
- [ ] `ClaudeTokenFetchUsageParams { id: UUID }`
- [ ] `ClaudeTokenListResult { tokens: [ClaudeTokenWithUsage] }`
- [ ] `ClaudeTokenFetchUsageResult { usage: ClaudeTokenUsage }`
- [ ] All structs `public Codable Sendable` with public memberwise inits, matching the existing style in this file.

### 4. Extend `RPCRouter.init` with a `ClaudeUsageFetcher`

- [ ] Add a `public let usageFetcher: ClaudeUsageFetcher` stored property.
- [ ] Add `usageFetcher: ClaudeUsageFetcher = LiveClaudeUsageFetcher()` to the init signature (default after `conductorManager`).
- [ ] Assign in init.
- [ ] Confirm `ClaudeUsageFetcher` is declared `Sendable` so the router stays `Sendable`. If the protocol from Phase 03 is not `Sendable`, this phase widens it.
- [ ] Update any existing call sites of `RPCRouter.init` (search the codebase) — the new parameter is defaulted, so they should still compile.

### 5. Create `Sources/TBDDaemon/Server/RPCRouter+ClaudeTokenHandlers.swift`

- [ ] New file mirroring the layout of `RPCRouter+TerminalHandlers.swift`: `import Foundation; import TBDShared; extension RPCRouter { ... }`.
- [ ] One section comment per handler group.

### 6. Implement `handleClaudeTokenList`

- [ ] No params.
- [ ] Load all rows from `db.claudeTokens.list()`.
- [ ] For each, fetch cached usage from `db.claudeTokenUsage.get(tokenID:)` (returns `ClaudeTokenUsage?`).
- [ ] Map to `[ClaudeTokenWithUsage]`, return `ClaudeTokenListResult`.

### 7. Implement `handleClaudeTokenAdd`

- [ ] Decode `ClaudeTokenAddParams`.
- [ ] Trim whitespace from `token`.
- [ ] Determine kind:
  - prefix `sk-ant-oat01-` → `.oauth`
  - prefix `sk-ant-api03-` → `.apiKey`
  - else → return `RPCResponse(error: "Token must start with sk-ant-oat01- or sk-ant-api03-")`.
- [ ] Check for duplicate name via `db.claudeTokens.findByName(name:)`. If exists → return `RPCResponse(error: "A token named '\(name)' already exists")`.
- [ ] If kind is `.oauth`:
  - Call `usageFetcher.fetch(token: trimmed)`.
  - On `.http401` → return `RPCResponse(error: "Token invalid")`. Do NOT write keychain or DB.
  - On `.http429` or `.networkError` → set `warning = "Could not verify token with Anthropic; saved anyway"`. Do NOT cache usage.
  - On `.ok(let usage)` → `warning = nil`, remember `usage` to upsert after the row is created.
- [ ] If kind is `.apiKey`: skip fetcher entirely; `warning = nil`.
- [ ] Generate `let id = UUID()`.
- [ ] Write to keychain: `try ClaudeTokenKeychain.store(id: id, token: trimmed)`. If this throws, return the error and DO NOT insert a DB row.
- [ ] Insert DB row: `let token = try await db.claudeTokens.create(id: id, name: name, kind: kind)`. If this throws, attempt `try? ClaudeTokenKeychain.delete(id: id)` to roll back the keychain write, then rethrow.
- [ ] If we have a fresh `usage` from the validation step, upsert it via `db.claudeTokenUsage.upsert(usage)` (with `tokenID == id`, `fetchedAt = Date()`).
- [ ] Return `try RPCResponse(result: ClaudeTokenAddResult(token: token, warning: warning))`.

### 8. Implement `handleClaudeTokenDelete`

- [ ] Decode `ClaudeTokenDeleteParams`.
- [ ] Look up the token; if missing return `RPCResponse(error: "Token not found")`.
- [ ] If `db.config.get().defaultClaudeTokenID == params.id` → call `db.config.setDefaultClaudeTokenID(nil)`.
- [ ] Null out any `repo.claude_token_override_id == params.id` via a new `db.repos.clearClaudeTokenOverride(matching: params.id)` helper. (If Phase 01 did not add this helper, add it now in `RepoStore` and document the addition in this task's checkbox.)
- [ ] Delete usage cache row: `try await db.claudeTokenUsage.delete(tokenID: params.id)`.
- [ ] Delete DB row: `try await db.claudeTokens.delete(id: params.id)`.
- [ ] Delete keychain entry: `try? ClaudeTokenKeychain.delete(id: params.id)` (best-effort; missing entry is not fatal).
- [ ] **Do NOT** touch `terminal.claude_token_id` — running terminals keep their spawn-time env var. Add a `// NOTE:` comment in the handler explaining why.
- [ ] Return `.ok()`.

### 9. Implement `handleClaudeTokenRename`

- [ ] Decode `ClaudeTokenRenameParams`.
- [ ] Trim/validate `name` non-empty; if empty return `RPCResponse(error: "Name cannot be empty")`.
- [ ] If `db.claudeTokens.findByName(name:)` returns a row whose id != params.id → return `RPCResponse(error: "A token named '\(name)' already exists")`.
- [ ] Call `try await db.claudeTokens.rename(id:, name:)`.
- [ ] Return `.ok()`.

### 10. Implement `handleClaudeTokenSetGlobalDefault` and `handleClaudeTokenSetRepoOverride`

- [ ] `setGlobalDefault`: decode, call `db.config.setDefaultClaudeTokenID(params.id)`, return `.ok()`.
- [ ] `setRepoOverride`: decode, look up repo (404 if missing), call `db.repos.setClaudeTokenOverride(repoID:, tokenID:)`, return `.ok()`.
- [ ] If Phase 01 did not add `setClaudeTokenOverride`, add it on `RepoStore` in this phase.

### 11. Implement `handleClaudeTokenFetchUsage` with 60 s dedupe

- [ ] Decode `ClaudeTokenFetchUsageParams`.
- [ ] Look up the token row; 404 if missing.
- [ ] Check existing cache row: `if let cached = try await db.claudeTokenUsage.get(tokenID: params.id), Date().timeIntervalSince(cached.fetchedAt) < 60 { return RPCResponse(result: ClaudeTokenFetchUsageResult(usage: cached)) }`.
- [ ] Otherwise load token bytes from keychain: `guard let bytes = try ClaudeTokenKeychain.load(id: params.id) else { return RPCResponse(error: "Token missing from keychain") }`.
- [ ] Call `usageFetcher.fetch(token: bytes)`.
- [ ] On `.ok(let usage)` upsert and return.
- [ ] On `.http401` return `RPCResponse(error: "Token invalid")`.
- [ ] On `.http429` return `RPCResponse(error: "Rate limited; try again later")`.
- [ ] On `.networkError(let msg)` return `RPCResponse(error: "Network error: \(msg)")`.

### 12. Wire handlers into `RPCRouter.handle()` switch

- [ ] In `Sources/TBDDaemon/Server/RPCRouter.swift`, add seven new `case` arms in the same style as the existing cases:
  ```swift
  case RPCMethod.claudeTokenList:           return try await handleClaudeTokenList()
  case RPCMethod.claudeTokenAdd:            return try await handleClaudeTokenAdd(request.paramsData)
  case RPCMethod.claudeTokenDelete:         return try await handleClaudeTokenDelete(request.paramsData)
  case RPCMethod.claudeTokenRename:         return try await handleClaudeTokenRename(request.paramsData)
  case RPCMethod.claudeTokenSetGlobalDefault: return try await handleClaudeTokenSetGlobalDefault(request.paramsData)
  case RPCMethod.claudeTokenSetRepoOverride:  return try await handleClaudeTokenSetRepoOverride(request.paramsData)
  case RPCMethod.claudeTokenFetchUsage:     return try await handleClaudeTokenFetchUsage(request.paramsData)
  ```
- [ ] Place them above the `case RPCMethod.stateSubscribe:` arm so the conventional ordering is preserved.

### 13. Tests — `Tests/TBDDaemonTests/ClaudeTokenRPCTests.swift`

Use Swift Testing (`@Test` / `#expect`) consistent with the rest of the test target. Use an in-memory `TBDDatabase` (per the helper used elsewhere in the daemon tests — search `TBDDatabase(path: ":memory:")` or the existing test factory).

Build a `StubClaudeUsageFetcher: ClaudeUsageFetcher` that holds `var responses: [ClaudeUsageFetchResult]` and a `var callCount: Int`, popping the head on each call. Make it a `final class` and mark with `@unchecked Sendable` if needed.

Mock the keychain with the same injectable closure pattern Phase 02 introduced. If Phase 02 chose the "real keychain with random UUIDs + cleanup `defer`" route, follow that route here too — read `ClaudeTokenKeychain.swift` to see which.

- [ ] **add: oauth + .ok** — fetcher returns `.ok(usage)`. Expect: row inserted with `kind == .oauth`, keychain has the bytes, `db.claudeTokenUsage.get(tokenID:)` returns the usage, result has `warning == nil`.
- [ ] **add: oauth + .http401** — fetcher returns `.http401`. Expect: response `success == false`, error == "Token invalid", `db.claudeTokens.list()` empty, keychain empty, no usage row.
- [ ] **add: oauth + .networkError** — fetcher returns `.networkError("offline")`. Expect: row inserted, keychain has bytes, NO usage row, `result.warning != nil`.
- [ ] **add: api_key prefix** — params with `sk-ant-api03-...`. Expect: fetcher `callCount == 0`, row inserted with `kind == .apiKey`, no usage row.
- [ ] **add: bad prefix** — params with `garbage`. Expect: error response, `callCount == 0`, no row, no keychain entry.
- [ ] **add: duplicate name** — pre-seed a token named "Personal", call add with the same name. Expect: error response, only the original row exists.
- [ ] **list joins usage** — seed two tokens, upsert usage for one, call list. Expect: 2 results, one with `usage != nil`, one with `usage == nil`.
- [ ] **delete clears global default** — seed token, set as global default, call delete. Expect: token gone, keychain entry gone, usage row gone, `db.config.get().defaultClaudeTokenID == nil`.
- [ ] **delete clears repo override** — seed token + repo with override pointing at it, call delete. Expect: `repo.claudeTokenOverrideID == nil` after.
- [ ] **delete leaves matching default for unrelated token** — seed two tokens A and B, set A as global default, delete B. Expect: `defaultClaudeTokenID == A.id` still.
- [ ] **rename success** — seed token, rename to a fresh name, expect row updated.
- [ ] **rename duplicate** — seed two tokens A and B, attempt to rename B to A's name, expect error and B's name unchanged.
- [ ] **setGlobalDefault round-trip** — call with id, then with nil, assert config reflects each.
- [ ] **setRepoOverride round-trip** — seed repo + token, set override, assert repo row; clear with nil, assert cleared.
- [ ] **fetchUsage dedupes within 60 s** — pre-seed usage row with `fetchedAt = Date()`, call handler. Expect: returns cached value, `stub.callCount == 0`.
- [ ] **fetchUsage refreshes after 60 s** — pre-seed usage with `fetchedAt = Date().addingTimeInterval(-120)`, queue stub `.ok(newUsage)`, call handler. Expect: `callCount == 1`, returned usage matches `newUsage`, DB cache row updated.
- [ ] **fetchUsage propagates 401** — queue stub `.http401`, call handler with no cached row. Expect: error response containing "invalid".

### 14. Verify and commit

- [ ] `swift build` — clean.
- [ ] `swift test --filter ClaudeTokenRPCTests` — all green.
- [ ] `swift test` — full suite still green (sanity check that we didn't break the existing router init call sites).
- [ ] Commit with `feat: add Claude token RPC handlers (list, add, delete, rename, defaults, fetch)`.
- [ ] Note in the commit body that Phase 06 will add `terminal.swapClaudeToken` and the spawn env wiring.

---

## Out of scope (handled later)

- `terminal.swapClaudeToken` and any spawn-time env injection — Phase 06.
- Background poll scheduler — Phase 07.
- Client-side `DaemonClient` wrappers — Phase 08.
- State-update broadcasts on usage cache writes — added in Phase 07 (the poll path is the primary writer; manual `fetchUsage` from this phase will get broadcast support retroactively in Phase 07).

## Risks / watch-outs

- **Token bytes in error strings.** Never include the raw token in any `RPCResponse(error:)`. The validator branch is the easiest place to slip up — keep error messages generic.
- **Keychain rollback on DB insert failure.** If `db.claudeTokens.create` throws after the keychain write, leaving an orphaned keychain entry would shadow a future re-add with the same UUID. Always `try? ClaudeTokenKeychain.delete(id:)` in the catch path.
- **Router `Sendable` conformance.** Adding `usageFetcher` as a stored property requires the protocol to be `Sendable`. If Phase 03 didn't mark it, do so here and call it out in the commit.
- **Duplicate-name check race.** The check-then-insert is not atomic. For now we accept the race (single-process daemon, single client); if it bites, swap to a UNIQUE index in a later migration.
