# Phase 4 — UI: OAuth add form drops the token field

**Verifies:** alt-profiles-config-dir.AC6

The "Claude Direct" (OAuth) add form currently shows a token `SecureField`.
Under the redesign an OAuth profile is created with just a name; the user logs
in once inside a spawned session. Update the form and the `AppState` call.

## Acceptance Criteria Coverage

### alt-profiles-config-dir.AC6: OAuth add UI needs only a name
- **AC6.1 Success:** The "Claude Direct" add form shows a name field and no
  token `SecureField`.
- **AC6.2 Success:** The form shows explanatory text that the user must run
  `/login` once in a session using this profile.
- **AC6.3 Success:** `canSave` for the OAuth preset is true with just a
  non-empty name (no token requirement).

Files:
- Modify: `Sources/TBDApp/Settings/ModelProfilesSettingsView.swift`
- Modify: `Sources/TBDApp/AppState+ModelProfiles.swift`

**Note:** `ModelProfileMenu`, `RepoDetailView`, and the proxy/bedrock add
forms need no change — OAuth profiles still appear as ordinary profiles.

<!-- START_SUBCOMPONENT_A (tasks 1-2) -->

<!-- START_TASK_1 -->
### Task 1: Drop the token field from the OAuth add form

**Verifies:** alt-profiles-config-dir.AC6.1, AC6.2, AC6.3

**Files:**
- Modify: `Sources/TBDApp/Settings/ModelProfilesSettingsView.swift`
  (`AddModelProfileSheet`, the `claudeDirect` preset branch ~lines 405-415, and
  the `canSave` computed property ~lines 558-573)
- Modify: `Sources/TBDApp/AppState+ModelProfiles.swift`
  (`addModelProfile`, ~lines 35-55)

**Implementation:**

First read `AddModelProfileSheet` to confirm exact line numbers.

1. In the `claudeDirect` preset branch of the form body: remove the token
   `SecureField`. Keep the name field. Add a short explanatory `Text` (use the
   existing `LabeledField`/caption style) such as: "After creating this profile,
   open a session with it and run `/login` once. TBD keeps each profile's login
   isolated in its own config directory."
2. In `canSave`: for the `claudeDirect` preset, require only a non-empty
   trimmed name (drop any token check).
3. In the save action for `claudeDirect`: call `appState.addModelProfile` with
   `token: nil` (or omit it). Do not pass a token.
4. In `AppState.addModelProfile`: `token` is already optional — confirm it
   tolerates `nil`/empty for the oauth kind and forwards it unchanged to the
   `modelProfileAdd` RPC params. No signature change expected; adjust only if a
   non-optional assumption exists.
5. Leave `EditEndpointSheet`, `EditBedrockSheet`, the `proxy` preset, and the
   `bedrock` preset untouched.

**Testing:** see Task 2. SwiftUI view bodies are not unit-tested in this
project; verification is operational (build + manual UI check).

**Verification:**
Run: `swift build`
Expected: builds without errors.

**Commit:** `feat: oauth profile add form takes only a name`
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Verify the OAuth add flow end to end

**Verifies:** alt-profiles-config-dir.AC6.1, AC6.2, AC6.3

**Files:**
- Modify (only if a state-level assertion is feasible):
  `Tests/TBDAppTests/ModelProfileAppStateTests.swift`

**Testing & verification:**

1. If `AppState.addModelProfile` has testable pure-state behavior for the oauth
   path that does not require a daemon client, add a `@MainActor` test
   following the existing `ModelProfileAppStateTests` pattern. If it cannot be
   tested without a live daemon (the file's header comment says integration
   coverage lives in daemon RPC tests — Phase 3 already covers the RPC), state
   that explicitly and rely on Phase 3's coverage instead. Do not invent a
   brittle test.
2. Full restart and manual UI check (this project's `CLAUDE.md` requires
   verifying UI changes in the running app):
   - Run `scripts/restart.sh` from the worktree root.
   - Verify exactly one `TBDDaemon` and one `TBDApp` from the worktree path:
     `ps aux | grep -E "\.build/debug/TBD" | grep -v grep`.
   - Open Settings → Model Profiles → Add → "Claude Direct": confirm there is
     no token field, the explanatory text is present, and Save is enabled with
     only a name entered.
   - Create one, then open a session pinned to it and confirm `claude` starts
     in an isolated config dir (it will prompt for `/login` on first use).

**Verification:**
Run: `swift build && swift test`
Expected: builds; full test suite passes.

**Commit:** `test: verify oauth add flow`
<!-- END_TASK_2 -->

<!-- END_SUBCOMPONENT_A -->

---

## Final verification (all phases)

- `swift build` — clean.
- `swift test` — full suite passes.
- `swift package plugin --allow-writing-to-package-directory swiftlint --strict`
  — no `no_print_in_sources` or other violations.
- Manual: add an OAuth profile, spawn a session, `/login`, confirm the session
  works and is isolated; add a second OAuth profile and confirm the two
  sessions hold independent logins concurrently.
