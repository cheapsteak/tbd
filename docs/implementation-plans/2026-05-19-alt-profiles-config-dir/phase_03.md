# Phase 3 — RPC: add an OAuth profile without a token

**Verifies:** alt-profiles-config-dir.AC5

`handleModelProfileAdd` currently validates an OAuth token
(`sk-ant-oat01-` prefix) and writes it to the keychain. Under the redesign an
OAuth profile carries no secret — it is just a name (and an implicit derived
config dir). Adding one stores no keychain entry and needs no token.

## Acceptance Criteria Coverage

### alt-profiles-config-dir.AC5: Adding an OAuth profile takes only a name
- **AC5.1 Success:** `handleModelProfileAdd` with `kind == .oauth` and no
  `token` succeeds and returns a `ModelProfile` with `kind == .oauth`.
- **AC5.2 Success:** After adding an `.oauth` profile, no keychain entry exists
  for that profile ID (`ModelProfileKeychain.load` returns nil).
- **AC5.3 Failure:** `handleModelProfileAdd` with `kind == .apiKey` and an empty
  or missing `token` still fails with a validation error (unchanged).

Files:
- Modify: `Sources/TBDDaemon/Server/RPCRouter+ModelProfileHandlers.swift`
- Modify: `Tests/TBDDaemonTests/ModelProfileRPCTests.swift` (or the existing
  add-handler test file the codebase-investigator confirms)

**Note on existing data:** pre-existing OAuth profiles have an orphaned
`~/tbd/claude-tokens/<uuid>.token` file. We deliberately do **not** add a
startup migration to delete them — the resolver (Phase 2) no longer reads them,
they are mode-0600 and harmless, and a startup filesystem migration carries more
risk than the wart it removes. `ModelProfileKeychain.delete` is still called on
profile deletion, so they get cleaned up naturally over time.

<!-- START_SUBCOMPONENT_A (tasks 1-2) -->

<!-- START_TASK_1 -->
### Task 1: OAuth add path skips token validation and keychain storage

**Verifies:** alt-profiles-config-dir.AC5.1, AC5.2, AC5.3

**Files:**
- Modify: `Sources/TBDDaemon/Server/RPCRouter+ModelProfileHandlers.swift`
  (`handleModelProfileAdd`, around lines 23-95)

**Implementation:**

The codebase-investigator reported `handleModelProfileAdd` branches on `kind`
and currently: validates the OAuth token prefix `sk-ant-oat01-` and the API-key
prefix `sk-ant-api03-`, stores the token via `ModelProfileKeychain.store`, and
(for bedrock) skips keychain storage.

First read the current handler to confirm exact line numbers, then:

1. For `kind == .oauth`: do **not** require a `token`, do **not** validate any
   token prefix, and do **not** call `ModelProfileKeychain.store`. Treat it like
   the bedrock branch (create the DB row, no keychain write). If a `token` is
   present in the params, ignore it.
2. For `kind == .apiKey`: keep the existing requirement that a non-empty
   `token` is present and validate the `sk-ant-api03-` prefix; keep the
   `ModelProfileKeychain.store` call. (If the codebase currently shares one
   validation path for oauth+apiKey, split it so only apiKey validates.)
3. For `kind == .bedrock`: unchanged.
4. Keep the `.modelProfilesChanged` subscription delta broadcast for all kinds.

Do not change `RPCProtocol.swift` — `ModelProfileAddParams.token` is already
optional.

**Testing:** see Task 2.

**Verification:**
Run: `swift build`
Expected: builds without errors.

**Commit:** `feat: add oauth profiles without a token or keychain entry`
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: RPC tests for the token-less OAuth add

**Verifies:** alt-profiles-config-dir.AC5.1, AC5.2, AC5.3

**Files:**
- Modify: the daemon test file covering `handleModelProfileAdd` (confirm path;
  likely `Tests/TBDDaemonTests/ModelProfileRPCTests.swift`)

**Testing:**

Follow the existing add-handler test pattern (in-memory DB, router under test).

- AC5.1: add a profile with `kind: .oauth`, `name: "Work"`, `token: nil` →
  succeeds, returned profile has `kind == .oauth` and the given name; the row
  is present via `ModelProfileStore.get`.
- AC5.2: after the AC5.1 add, `ModelProfileKeychain.load(id:)` for that profile
  ID returns `nil`.
- AC5.3: add a profile with `kind: .apiKey` and `token: ""` (and separately
  `token: nil`) → fails with a validation error; no row created.
- Confirm an existing successful `.apiKey` add test and a `.bedrock` add test
  still pass.

**Verification:**
Run: `swift test --filter ModelProfile`
Expected: all tests pass.

**Commit:** `test: cover token-less oauth profile add`
<!-- END_TASK_2 -->

<!-- END_SUBCOMPONENT_A -->
