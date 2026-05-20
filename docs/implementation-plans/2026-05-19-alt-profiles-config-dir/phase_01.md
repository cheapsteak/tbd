# Alternate profiles → config-dir — Implementation Plan

**Goal:** Make every alternate Claude profile spawn through one uniform
mechanism — a per-profile `CLAUDE_CONFIG_DIR` — so OAuth profiles bill as
ordinary interactive subscription sessions and the OAuth-shape vs. API-key-shape
divergence is removed.

**Architecture:** OAuth profiles stop storing a `setup-token` and stop injecting
`CLAUDE_CODE_OAUTH_TOKEN`; instead they get an isolated `CLAUDE_CONFIG_DIR` the
user `/login`s into once. API-key profiles keep injecting `ANTHROPIC_API_KEY`
but now *all* of them (not just proxy ones) get an isolated `CLAUDE_CONFIG_DIR`.
Bedrock is unchanged. The env var changes from the undocumented
`ANTHROPIC_CONFIG_DIR` to the documented `CLAUDE_CONFIG_DIR`.

**Tech Stack:** Swift 6, SwiftPM, GRDB, NIO, Swift Testing (`@Test`/`#expect`),
SwiftUI.

**Scope:** 4 phases. Source design:
`docs/specs/2026-05-19-alternate-profiles-redesign-design.md`.

**Codebase verified:** 2026-05-19.

**No DB migration:** the config dir is derived from the profile UUID
(`~/tbd/profiles/<id>/claude/`); no schema change. `CredentialKind` and
`ModelProfile` are unchanged.

**Out of scope:** `CLAUDE_CODE_DISABLE_1M_CONTEXT` knob (decision doc follow-up),
Vertex profiles, programmatic "needs login" detection (Claude Code's own
first-run flow handles login; TBD only shows a UI hint).

---

## Acceptance Criteria Coverage

### alt-profiles-config-dir.AC1: OAuth profiles use an isolated config dir, no token
- **AC1.1 Success:** A spawned oauth-profile claude session's `sensitiveEnv`
  contains `CLAUDE_CONFIG_DIR` pointing at `<configDir>/profiles/<id>/claude`.
- **AC1.2 Success:** A spawned oauth-profile claude session's `sensitiveEnv`
  contains no `CLAUDE_CODE_OAUTH_TOKEN` key.

### alt-profiles-config-dir.AC2: API-key profiles always get an isolated config dir
- **AC2.1 Success:** A direct (non-proxy, `baseURL == nil`) api-key profile
  spawn's `sensitiveEnv` contains `CLAUDE_CONFIG_DIR`.
- **AC2.2 Success:** The injected env key is `CLAUDE_CONFIG_DIR`; the string
  `ANTHROPIC_CONFIG_DIR` appears nowhere in `sensitiveEnv`.
- **AC2.3 Success:** An api-key profile spawn still contains `ANTHROPIC_API_KEY`
  with the resolved secret.

### alt-profiles-config-dir.AC3: Bedrock unchanged
- **AC3.1 Success:** A bedrock-profile spawn contains `CLAUDE_CODE_USE_BEDROCK=1`
  and `AWS_REGION`, and no `CLAUDE_CONFIG_DIR` / `ANTHROPIC_CONFIG_DIR` /
  `ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN`.

---

# Phase 1 — Config-dir manager + spawn command builder

**Verifies:** alt-profiles-config-dir.AC1.1, AC1.2, AC2.1, AC2.2, AC2.3, AC3.1

Generalize `ClaudeProfileConfigDirManager` so it produces a config dir for both
oauth and api-key profiles, and rewire `ClaudeSpawnCommandBuilder` to inject
`CLAUDE_CONFIG_DIR` (renamed from `ANTHROPIC_CONFIG_DIR`) for every non-bedrock
profile while injecting an auth token only for api-key profiles.

Files:
- Modify: `Sources/TBDDaemon/Claude/ClaudeProfileConfigDirManager.swift`
- Modify: `Sources/TBDDaemon/Claude/ClaudeSpawnCommandBuilder.swift`
- Modify: `Tests/TBDDaemonTests/ClaudeProfileConfigDirManagerTests.swift`
- Modify: `Tests/TBDDaemonTests/ClaudeSpawnCommandBuilderTests.swift`
- Modify: `Tests/TBDDaemonTests/ModelProfileSpawnTests.swift`

<!-- START_SUBCOMPONENT_A (tasks 1-3) -->

<!-- START_TASK_1 -->
### Task 1: Generalize `ClaudeProfileConfigDirManager`

**Files:**
- Modify: `Sources/TBDDaemon/Claude/ClaudeProfileConfigDirManager.swift`

**Implementation:**

The manager today only serves proxy api-key profiles. Generalize it:

1. Keep `configDirectory(forProfileID:)` as-is — it already returns
   `<base>/profiles/<id>/claude`.
2. Keep the existing `ensureDir(forProfileID:apiKey:)` (api-key pre-approval
   path) but rename it to `ensureAPIKeyDir(forProfileID:apiKey:)` for clarity.
3. Add `ensureOAuthDir(forProfileID:) throws -> URL`: creates the same
   `<base>/profiles/<id>/claude` directory, and writes a minimal `.claude.json`
   containing only `{"hasCompletedOnboarding": true}` if the file does not
   already exist (so the spawned `claude` skips the theme/onboarding screens and
   lands in a REPL where the user can run `/login`). Do NOT write
   `customApiKeyResponses` for oauth. If `.claude.json` already exists, leave it
   untouched.
4. Rewrite `resolveConfigDir(for:)` so it returns a path for **both**
   `.oauth` and `.apiKey` kinds, and `nil` only for `.bedrock` (and `nil`
   profile). For `.apiKey` it calls `ensureAPIKeyDir` (needs `profile.secret`;
   if the secret is nil, log a warning and return nil as today). For `.oauth`
   it calls `ensureOAuthDir`. Filesystem errors are logged and swallowed
   (return nil) exactly as the current implementation does.
5. Update the type's doc comment to describe the generalized behavior.

**Testing:** see Task 3.

**Verification:**
Run: `swift build`
Expected: builds without errors.

**Commit:** `refactor: generalize ClaudeProfileConfigDirManager to oauth + apiKey`
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Rewire `ClaudeSpawnCommandBuilder` env injection

**Verifies:** alt-profiles-config-dir.AC1.1, AC1.2, AC2.1, AC2.2, AC2.3, AC3.1

**Files:**
- Modify: `Sources/TBDDaemon/Claude/ClaudeSpawnCommandBuilder.swift:98-127`

**Implementation:**

In the non-bedrock branch (currently lines 106-126):

1. Inject an auth token **only for `.apiKey`**: keep
   `env["ANTHROPIC_API_KEY"] = secret` when `profileKind == .apiKey` and a
   `profileSecret` is present. Remove the `CLAUDE_CODE_OAUTH_TOKEN` branch
   entirely — oauth profiles no longer carry a secret and no longer inject a
   token. (`profileKind == .oauth` → no token env at all.)
2. Keep `ANTHROPIC_BASE_URL` and `ANTHROPIC_MODEL` injection as-is (still apply
   to proxy api-key profiles).
3. Change the config-dir injection: when `profileConfigDir` is non-nil, set
   `env["CLAUDE_CONFIG_DIR"] = configDir`. Remove the
   `ANTHROPIC_CONFIG_DIR` key and remove the `profileBaseURL != nil` condition —
   the caller (`resolveConfigDir`) now decides which kinds get a dir, so the
   builder injects whatever it is handed.
4. Update the type-level doc comment (lines 19-32) to describe the new behavior:
   oauth → `CLAUDE_CONFIG_DIR` only; api-key → `ANTHROPIC_API_KEY` +
   `CLAUDE_CONFIG_DIR` (+ `ANTHROPIC_BASE_URL`/`ANTHROPIC_MODEL` for proxy);
   bedrock unchanged.

Note `profileSecret` will be nil for oauth — the existing
`if let secret = profileSecret` guard already handles that; just ensure the
non-`.apiKey` path does not assign any token.

**Testing:** see Task 3.

**Verification:**
Run: `swift build`
Expected: builds without errors.

**Commit:** `feat: inject CLAUDE_CONFIG_DIR for oauth + apiKey, drop oauth token`
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Tests for config-dir manager and spawn builder

**Verifies:** alt-profiles-config-dir.AC1.1, AC1.2, AC2.1, AC2.2, AC2.3, AC3.1

**Files:**
- Modify: `Tests/TBDDaemonTests/ClaudeProfileConfigDirManagerTests.swift`
- Modify: `Tests/TBDDaemonTests/ClaudeSpawnCommandBuilderTests.swift`
- Modify: `Tests/TBDDaemonTests/ModelProfileSpawnTests.swift`

**Testing:**

Follow the existing patterns in each file (temp base dirs for the config-dir
manager; injectable `fileExists` and direct `Result` assertions for the spawn
builder; `TmuxManager` dry-run argv capture for the spawn integration test).

`ClaudeProfileConfigDirManagerTests`:
- `ensureOAuthDir` creates the directory and writes `.claude.json` with
  `hasCompletedOnboarding: true` and no `customApiKeyResponses`.
- `ensureOAuthDir` leaves an existing `.claude.json` untouched.
- `resolveConfigDir` returns a path for an `.oauth` profile.
- `resolveConfigDir` returns a path for a direct (`baseURL == nil`) `.apiKey`
  profile (changed behavior — previously nil).
- `resolveConfigDir` returns nil for a `.bedrock` profile.
- Existing `ensureAPIKeyDir` (renamed) tests still pass.

`ClaudeSpawnCommandBuilderTests` — assert on `Result.sensitiveEnv`:
- AC1.1/AC1.2: oauth profile with a `profileConfigDir` → `sensitiveEnv` has
  `CLAUDE_CONFIG_DIR` and no `CLAUDE_CODE_OAUTH_TOKEN`.
- AC2.1/AC2.2/AC2.3: api-key profile with a `profileConfigDir` → `sensitiveEnv`
  has `ANTHROPIC_API_KEY`, has `CLAUDE_CONFIG_DIR`, and no `ANTHROPIC_CONFIG_DIR`.
- AC3.1: bedrock profile → `CLAUDE_CODE_USE_BEDROCK` + `AWS_REGION` present, none
  of `CLAUDE_CONFIG_DIR`/`ANTHROPIC_CONFIG_DIR`/`ANTHROPIC_API_KEY`/
  `CLAUDE_CODE_OAUTH_TOKEN`.
- Update any existing test that asserted `CLAUDE_CODE_OAUTH_TOKEN` or
  `ANTHROPIC_CONFIG_DIR` to the new keys.

`ModelProfileSpawnTests` — update full-path argv assertions to expect
`CLAUDE_CONFIG_DIR` instead of `ANTHROPIC_CONFIG_DIR`, and to expect no
`CLAUDE_CODE_OAUTH_TOKEN` for oauth spawns.

**Verification:**
Run: `swift test --filter ClaudeProfileConfigDirManager --filter ClaudeSpawnCommandBuilder --filter ModelProfileSpawn`
Expected: all tests pass.

**Commit:** `test: cover CLAUDE_CONFIG_DIR injection for oauth + apiKey`
<!-- END_TASK_3 -->

<!-- END_SUBCOMPONENT_A -->
