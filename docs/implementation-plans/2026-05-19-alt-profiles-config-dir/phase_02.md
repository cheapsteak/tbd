# Phase 2 — Resolver: oauth profiles no longer require a keychain secret

**Verifies:** alt-profiles-config-dir.AC4

`ModelProfileResolver.loadResolved` currently requires a non-empty keychain
secret for every non-bedrock profile (`guard let s = try keychain(...)`). Under
the redesign an oauth profile has no secret. Treat `.oauth` like `.bedrock`: no
keychain lookup, `secret: nil`.

## Acceptance Criteria Coverage

### alt-profiles-config-dir.AC4: Resolver resolves a secret-less oauth profile
- **AC4.1 Success:** `resolve(repoID:)` / `loadByID` for an `.oauth` profile
  row returns a non-nil `ResolvedModelProfile` with `secret == nil`, even when
  the keychain has no entry for that profile ID.
- **AC4.2 Success:** An `.apiKey` profile with a missing/empty keychain secret
  still resolves to `nil` (unchanged behavior).

Files:
- Modify: `Sources/TBDDaemon/ModelProfile/ModelProfileResolver.swift`
- Modify: `Tests/TBDDaemonTests/ModelProfileResolverTests.swift`

<!-- START_SUBCOMPONENT_A (tasks 1-2) -->

<!-- START_TASK_1 -->
### Task 1: Skip the keychain requirement for oauth profiles

**Verifies:** alt-profiles-config-dir.AC4.1, AC4.2

**Files:**
- Modify: `Sources/TBDDaemon/ModelProfile/ModelProfileResolver.swift:44-66`

**Implementation:**

In `loadResolved(id:)`, the secret-loading block currently is:

```swift
let secret: String?
if row.kind == .bedrock {
    secret = nil
} else {
    guard let s = try keychain(id.uuidString), !s.isEmpty else { return nil }
    secret = s
}
```

Change the condition so `.oauth` is also treated as secret-less. Only `.apiKey`
loads (and requires) a keychain secret:

```swift
let secret: String?
if row.kind == .apiKey {
    guard let s = try keychain(id.uuidString), !s.isEmpty else { return nil }
    secret = s
} else {
    secret = nil   // oauth + bedrock: no TBD-stored secret
}
```

Update the doc comment on `loadByID` / `loadResolved` (lines 36-43) so it states
that oauth and bedrock have no keychain secret and that only api-key returns nil
on a missing secret.

**Testing:** see Task 2.

**Verification:**
Run: `swift build`
Expected: builds without errors.

**Commit:** `fix: resolve oauth profiles without a keychain secret`
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Resolver tests for the secret-less oauth path

**Verifies:** alt-profiles-config-dir.AC4.1, AC4.2

**Files:**
- Modify: `Tests/TBDDaemonTests/ModelProfileResolverTests.swift`

**Testing:**

Follow the existing pattern in this file (in-memory DB + injected `keychain`
closure).

- AC4.1: create an `.oauth` profile row, set it as global default, inject a
  `keychain` closure that returns `nil` for every ID; `resolve(repoID: nil)`
  returns a non-nil `ResolvedModelProfile` with `kind == .oauth` and
  `secret == nil`. Same assertion via `loadByID`.
- AC4.2: create an `.apiKey` profile row, inject a `keychain` closure returning
  `nil`; `loadByID` returns `nil` (unchanged).
- Confirm an existing `.apiKey`-with-secret test and a `.bedrock` test still
  pass.

**Verification:**
Run: `swift test --filter ModelProfileResolver`
Expected: all tests pass.

**Commit:** `test: resolver handles secret-less oauth profiles`
<!-- END_TASK_2 -->

<!-- END_SUBCOMPONENT_A -->
