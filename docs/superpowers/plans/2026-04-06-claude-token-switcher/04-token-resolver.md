# Phase 04: Token Resolver

> **Parent plan:** [../2026-04-06-claude-token-switcher.md](../2026-04-06-claude-token-switcher.md)
> **Depends on:** Phase 01, Phase 02
> **Unblocks:** Phase 06 (spawn path), Phase 07 (poll scheduler)

**Scope:** `ClaudeTokenResolver` that combines per-repo override, global default, and Keychain load into a single `resolve(repoID:)` call used by the spawn path.

## Context

The spawn path needs a single entry point that, given an optional repo ID, returns either a fully-loaded token (row + secret bytes) or `nil`. Resolution order per spec section "Token resolution":

1. Repo override (`repo.claudeTokenOverrideID`) — if the row or Keychain entry is missing, fall through with a logged warning (do **not** error; the user may have deleted the token while a repo still references it).
2. Global default (`config.defaultClaudeTokenID`) — if the row or Keychain entry is missing, return `nil`.
3. Otherwise return `nil`.

On any successful resolution, bump `tokens.touchLastUsed(id:)` so the Settings UI can sort by recency.

The Keychain accessor is injected as a closure so tests can run without touching the real Keychain.

## Tasks

### Task 1: Add `ResolvedClaudeToken` value type

In a new file `Sources/TBDDaemon/Claude/ClaudeTokenResolver.swift`, declare:

```swift
public struct ResolvedClaudeToken: Sendable, Equatable {
    public let tokenID: UUID
    public let name: String
    public let kind: ClaudeTokenKind
    public let secret: String
}
```

`ClaudeTokenKind` is the enum introduced in Phase 01 (`oauth` / `apiKey`).

### Task 2: Declare `ClaudeTokenResolver` struct and initializer

In the same file:

```swift
public struct ClaudeTokenResolver: Sendable {
    let tokens: ClaudeTokenStore
    let repos: RepoStore
    let config: ConfigStore
    let keychain: @Sendable (String) throws -> String?

    public init(
        tokens: ClaudeTokenStore,
        repos: RepoStore,
        config: ConfigStore,
        keychain: @Sendable @escaping (String) throws -> String? = { try ClaudeTokenKeychain.load(id: $0) }
    ) {
        self.tokens = tokens
        self.repos = repos
        self.config = config
        self.keychain = keychain
    }
}
```

The default keychain closure forwards to `ClaudeTokenKeychain.load` from Phase 02.

### Task 3: Implement private `loadResolved(id:)` helper

Add a private helper that, given a token UUID, attempts to load the row and secret:

```swift
private func loadResolved(id: UUID) async throws -> ResolvedClaudeToken? {
    guard let row = try await tokens.get(id: id) else { return nil }
    guard let secret = try keychain(id.uuidString), !secret.isEmpty else { return nil }
    return ResolvedClaudeToken(
        tokenID: row.id,
        name: row.name,
        kind: row.kind,
        secret: secret
    )
}
```

Returning `nil` (not throwing) lets the caller decide whether to fall through or give up.

### Task 4: Implement `resolve(repoID:)` with the documented precedence

```swift
public func resolve(repoID: UUID?) async throws -> ResolvedClaudeToken? {
    // Step 1: repo override
    if let repoID, let repo = try await repos.get(id: repoID),
       let overrideID = repo.claudeTokenOverrideID {
        if let resolved = try await loadResolved(id: overrideID) {
            try await tokens.touchLastUsed(id: resolved.tokenID)
            return resolved
        }
        // Row or keychain missing — log and fall through to global default.
        TBDLog.warning("claude token override \(overrideID) for repo \(repoID) is missing; falling back to global default")
    }

    // Step 2: global default
    if let defaultID = try await config.get().defaultClaudeTokenID {
        if let resolved = try await loadResolved(id: defaultID) {
            try await tokens.touchLastUsed(id: resolved.tokenID)
            return resolved
        }
        return nil
    }

    // Step 3: nothing applies
    return nil
}
```

Use whichever logger the daemon already exposes (the warning string is the spec wording — if `TBDLog` is named differently, match the existing convention).

### Task 5: Wire up an in-memory test harness

Create `Tests/TBDDaemonTests/ClaudeTokenResolverTests.swift`. In `setUp`, build a fresh in-memory database and stores:

```swift
let db = try TBDDatabase(inMemory: true)
let tokens = ClaudeTokenStore(database: db)
let repos = RepoStore(database: db)
let config = ConfigStore(database: db)
var keychainMap: [String: String] = [:]
let resolver = ClaudeTokenResolver(
    tokens: tokens, repos: repos, config: config,
    keychain: { id in keychainMap[id] }
)
```

Add small helpers to insert a token row and to register a repo. Use `XCTestCase` (or whatever framework `TBDDaemonTests` already uses).

### Task 6: Test all resolution branches

Cover each branch from the spec, one test per case:

1. `resolve_nilRepo_noDefault_returnsNil` — empty config, `repoID: nil` → `nil`.
2. `resolve_nilRepo_globalDefault_keychainPresent_returnsResolved` — insert token row, set `config.defaultClaudeTokenID`, populate `keychainMap` → returns `ResolvedClaudeToken` with the right id/name/kind/secret.
3. `resolve_nilRepo_globalDefault_keychainMissing_returnsNil` — same as above but leave `keychainMap` empty → `nil`.
4. `resolve_repoOverride_keychainPresent_overrideWins` — insert two tokens (`A`, `B`), set `B` as global default and `A` as repo override, populate keychain for both → resolved token is `A`.
5. `resolve_repoOverride_keychainMissing_fallsBackToGlobal` — same as above but only `B`'s secret is in `keychainMap` → resolved token is `B` (no error thrown).
6. `resolve_repoNoOverride_globalSet_usesGlobal` — repo with `claudeTokenOverrideID == nil`, global default set → resolved token matches global.

### Task 7: Test `touchLastUsed` side effect on the success path

Add `resolve_success_bumpsLastUsedAt`:

1. Insert a token row, capture its `lastUsedAt` (expect `nil` initially per Phase 01).
2. Set it as the global default and populate the keychain map.
3. Call `resolver.resolve(repoID: nil)`.
4. Reload the row via `tokens.get(id:)` and assert `lastUsedAt != nil` and is within the last few seconds of `Date()`.

Optionally add a negative assertion: when resolution returns `nil` (e.g. keychain missing), `lastUsedAt` is **not** bumped.

### Task 8: Build and run the new test target

```sh
swift build
swift test --filter ClaudeTokenResolverTests
```

Fix any compile errors against the actual Phase 01/02 APIs (record field names, store method signatures, logger name) before committing. Commit with `feat: add ClaudeTokenResolver with repo override and global default precedence`.

## Acceptance criteria

- `Sources/TBDDaemon/Claude/ClaudeTokenResolver.swift` exists and exposes `ResolvedClaudeToken` and `ClaudeTokenResolver` with the signatures above.
- `resolve(repoID:)` implements the three-step precedence and only bumps `lastUsedAt` on success.
- A missing repo override row or Keychain entry logs a warning and falls through; a missing global default row or Keychain entry returns `nil`.
- All seven test cases pass under `swift test`.
- No real Keychain access in tests — all reads go through the injected closure.
