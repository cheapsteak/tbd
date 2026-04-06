# Phase 08: DaemonClient Stubs + AppState Wiring

> **Parent plan:** [../2026-04-06-claude-token-switcher.md](../2026-04-06-claude-token-switcher.md)
> **Depends on:** Phase 05, 06, 07
> **Unblocks:** Phase 09, 10, 11, 12 (all UI phases)

**Scope:** App-side RPC stubs for all new claude-token methods, `AppState` published properties + helpers, and focus-change forwarding to the daemon so the poller can pause/resume.

---

## Context

- Client lives in `Sources/TBDApp/DaemonClient.swift` — actor with private `call` / `callVoid` / `callNoParams` helpers wrapping `sendRaw`. Each new RPC is a thin typed wrapper over those.
- Existing pattern: one wrapper per RPC method, taking primitive args and constructing the `*Params` struct from `TBDShared`. Examples: `addRepo`, `worktreeSelectionChanged`, `terminalSuspend`.
- `AppState` (`Sources/TBDApp/AppState.swift`) is a `@MainActor ObservableObject`. Real-time updates flow through `subscribe(onDelta:)` → `handleDelta(_:)` switch on `StateDelta`. New delta cases must be added to `Sources/TBDShared/StateDelta.swift` and handled in both daemon broadcast sites and `AppState.handleDelta`.
- `StateDelta` enum is in `Sources/TBDShared/StateDelta.swift`. Adding a case is a backward-compatible Codable change as long as old daemons never emit it.
- App focus: `TBDAppMain` in `Sources/TBDApp/TBDApp.swift` uses `AppDelegate` (NSApplicationDelegate). There are no existing `didBecomeActive`/`didResignActive` handlers — Phase 08 adds them.
- `Tests/TBDAppTests/` exists (`LayoutNodeTests`, `PaneContentTests`, `PlaceholderTests`) but does **not** mock `DaemonClient` — it's a concrete actor, not a protocol. We will not retrofit a protocol in this phase; instead add a single smoke test that constructs `AppState` and calls a no-op helper path that doesn't require a daemon.
- Per `Sources/TBDShared/CLAUDE.md`: any change in `TBDShared` requires `scripts/restart.sh` after building.

---

## Tasks

### Task 1: Add `claudeTokenUsageUpdated` delta case to `StateDelta`

- [ ] In `Sources/TBDShared/StateDelta.swift`, add:
  - `case claudeTokenUsageUpdated(ClaudeTokenUsageDelta)`
  - New `public struct ClaudeTokenUsageDelta: Codable, Sendable` with fields `tokenID: UUID`, `usage: ClaudeTokenUsage` (type from Phase 01).
- [ ] Confirm `ClaudeTokenUsage` is `Sendable` (added in Phase 01); if not, fix it there or add a TODO comment referencing Phase 01.
- [ ] Verify `swift build` (TBDShared target) compiles.

### Task 2: Add `claudeTokensChanged` delta case (covers add/delete/rename/default change)

- [ ] In `Sources/TBDShared/StateDelta.swift`, add:
  - `case claudeTokensChanged` (no payload — coarse signal that triggers a `listClaudeTokens` refresh in the app).
  - Rationale: token CRUD is rare and the list is small; full refresh is simpler than per-row deltas and avoids leaking secret-bearing models through the wire (none of the public delta payloads carry token bytes, but the simpler shape removes that whole class of risk).
- [ ] Note in plan: Phase 05 (RPC CRUD) and Phase 06 (swap RPC) must broadcast this delta on every mutation; Phase 07 must broadcast `claudeTokenUsageUpdated` after each cache write. If those broadcasts aren't already in 05/06/07, this phase adds them as part of integration (search `subscriptions.broadcast` in `Sources/TBDDaemon/`).

### Task 3: Create `Sources/TBDApp/DaemonClient+ClaudeTokens.swift`

- [ ] New extension file (keeps the main `DaemonClient.swift` file from growing further). Mirrors structure of existing `MARK: -` sections.
- [ ] Add `extension DaemonClient {` containing:
  - `func listClaudeTokens() throws -> [ClaudeTokenWithUsage]` → `callNoParams(method: RPCMethod.claudeTokenList, ...)`
  - `func addClaudeToken(name: String, token: String) throws -> ClaudeToken` → `call(method: RPCMethod.claudeTokenAdd, params: ClaudeTokenAddParams(name: name, token: token), ...)`
  - `func deleteClaudeToken(id: UUID) throws` → `callVoid(method: RPCMethod.claudeTokenDelete, params: ClaudeTokenDeleteParams(id: id))`
  - `func renameClaudeToken(id: UUID, name: String) throws` → `callVoid(...)`
  - `func setGlobalDefaultClaudeToken(id: UUID?) throws` → `callVoid(...)`
  - `func setRepoClaudeTokenOverride(repoID: UUID, tokenID: UUID?) throws` → `callVoid(...)`
  - `func fetchClaudeTokenUsage(id: UUID) throws -> ClaudeTokenUsage` → `call(...)`
  - `func swapClaudeTokenOnTerminal(terminalID: UUID, newTokenID: UUID?) throws` → `callVoid(method: RPCMethod.terminalSwapClaudeToken, ...)`
  - `func setAppForegroundState(isForeground: Bool) throws` → `callVoid(method: RPCMethod.appSetForegroundState, params: AppForegroundStateParams(isForeground: isForeground))` (only if Phase 07 added the RPC; if it didn't, omit and add a TODO + cross-link).
- [ ] All methods must be `nonisolated` if they're plain wrappers around the actor's existing helpers — match the style of the existing methods (which are actor-isolated synchronous `throws` functions; callers `await` on the actor). Do NOT add `async` to the wrappers — `call`/`callVoid` are synchronous from inside the actor.
- [ ] **Never** log token bytes. The `addClaudeToken` wrapper must not pass the token through any `Logger` call.

### Task 4: Add published properties to `AppState`

- [ ] In `Sources/TBDApp/AppState.swift`, after the existing `@Published var prStatuses` block, add:
  - `@Published var claudeTokens: [ClaudeTokenWithUsage] = []`
  - `@Published var globalDefaultClaudeTokenID: UUID? = nil`
- [ ] Both must be on `@MainActor` (already implied by class declaration).

### Task 5: Add helper methods to `AppState` (new file `AppState+ClaudeTokens.swift`)

- [ ] Create `Sources/TBDApp/AppState+ClaudeTokens.swift` mirroring the pattern of `AppState+Notes.swift` etc.
- [ ] `@MainActor extension AppState` with methods:
  - `func refreshClaudeTokens() async` — calls `daemonClient.listClaudeTokens()` inside a `do/catch`, on success assigns to `self.claudeTokens` and updates `globalDefaultClaudeTokenID` from whichever element is marked default (or via a separate field on `ClaudeTokenWithUsage` — depends on Phase 01 model shape).
  - `func addClaudeToken(name: String, token: String) async` — calls daemon, on success calls `await refreshClaudeTokens()`. On failure sets `alertMessage` / `alertIsError` like other helpers.
  - `func deleteClaudeToken(id: UUID) async`
  - `func renameClaudeToken(id: UUID, name: String) async`
  - `func setGlobalDefaultClaudeToken(id: UUID?) async`
  - `func setRepoClaudeTokenOverride(repoID: UUID, tokenID: UUID?) async`
  - `func swapClaudeTokenOnTerminal(terminalID: UUID, newTokenID: UUID?) async`
  - `func fetchClaudeTokenUsage(id: UUID) async` — on success, mutates the matching entry in `self.claudeTokens` rather than refetching the whole list.
- [ ] All methods set `alertMessage` on failure with a user-readable string; never include the token bytes in the alert.

### Task 6: Wire delta handling for token + usage updates

- [ ] In `AppState.handleDelta(_:)` add cases:
  - `.claudeTokensChanged`: `Task { await self.refreshClaudeTokens() }`
  - `.claudeTokenUsageUpdated(let payload)`: locate the matching token in `self.claudeTokens` by `payload.tokenID` and update its `usage` field in place. If no match, ignore (the next full refresh will pick it up).
- [ ] Make sure both are inside the existing `switch` and the `default: break` clause still compiles.

### Task 7: Forward app focus changes to the daemon

- [ ] In `Sources/TBDApp/TBDApp.swift`, extend `AppDelegate`:
  - Implement `applicationDidBecomeActive(_:)` → call into `AppState` (need a reference; either pass via `init` or look it up via the existing `@StateObject` indirection — easiest is to add a static-shared accessor on `AppState`, or call directly via `NotificationCenter` from inside `AppState.init` by observing `NSApplication.didBecomeActiveNotification` and `didResignActiveNotification`).
  - **Preferred approach:** observe the notifications inside `AppState.init` (avoids coupling AppDelegate to AppState). In `init()`, after `startMemoryPressureMonitor()`, register two observers:
    - `NSApplication.didBecomeActiveNotification` → `Task { try? await self.daemonClient.setAppForegroundState(isForeground: true) }`
    - `NSApplication.didResignActiveNotification` → `Task { try? await self.daemonClient.setAppForegroundState(isForeground: false) }`
  - Store the observer tokens and remove them in `deinit`.
- [ ] Per `CLAUDE.md` unbundled-executable rule: `NotificationCenter.default.addObserver(forName:object:queue:using:)` does not require a bundle ID — safe to use without a guard. Document this in a comment.
- [ ] **Branching test** (per CLAUDE.md branching rule): the gated behavior here is "send `setAppForegroundState` only when Phase 07's RPC method exists." If Phase 07 has not added the RPC, skip the observer registration and add a `// TODO Phase 07` comment. The test for "off" branch is implicit (compile-time absence); the "on" branch test goes in Task 9.

### Task 8: Restart daemon + verify build

- [ ] Run `scripts/restart.sh` (per `Sources/TBDShared/CLAUDE.md` — any TBDShared change requires a full restart).
- [ ] Run `swift build` and confirm zero warnings/errors.
- [ ] Run `swift test` (we touched TBDShared, per top-level CLAUDE.md).

### Task 9: Smoke test in `Tests/TBDAppTests/`

- [ ] Add `Tests/TBDAppTests/ClaudeTokenAppStateTests.swift`.
- [ ] Note in the file header: `DaemonClient` is a concrete actor (no protocol), so we cannot inject a stub. These tests verify compile-time wiring + pure-Swift state mutations only. Full integration coverage lives in the daemon RPC tests (Phase 05/06/07) and manual QA per the parent plan's DoD.
- [ ] Tests (using Swift Testing — `@Test` / `#expect`):
  - `@Test func appState_initialClaudeTokensEmpty()` → construct `AppState` on `@MainActor`, assert `claudeTokens.isEmpty` and `globalDefaultClaudeTokenID == nil`.
  - `@Test func appState_handlesUsageUpdatedDeltaInPlace()` → seed `appState.claudeTokens` with one entry, manually invoke `handleDelta(.claudeTokenUsageUpdated(...))` (may require making `handleDelta` `internal` instead of `private`, or exposing a test-only entry point), assert the in-place mutation took effect.
  - `@Test func appState_handlesTokensChangedDeltaTriggersRefresh()` → just confirm the case is handled without crashing; the actual refresh will fail because no daemon is running, but the `Task` swallowing the error is the documented behavior.
- [ ] If `handleDelta` must stay private, add an `#if DEBUG` test hook: `@MainActor func _testApplyDelta(_ delta: StateDelta) { handleDelta(delta) }`.

### Task 10: Commit

- [ ] Verify `swift build` passes.
- [ ] Verify only files this phase touched are staged:
  - `Sources/TBDShared/StateDelta.swift`
  - `Sources/TBDApp/DaemonClient+ClaudeTokens.swift` (new)
  - `Sources/TBDApp/AppState.swift`
  - `Sources/TBDApp/AppState+ClaudeTokens.swift` (new)
  - `Sources/TBDApp/TBDApp.swift` (only if AppDelegate path was taken instead of AppState observers)
  - `Tests/TBDAppTests/ClaudeTokenAppStateTests.swift` (new)
- [ ] Conventional commit: `feat: app-side claude token RPC client + state wiring`

---

## Out of scope (deferred to later phases)

- Any SwiftUI view code — Phases 09–12.
- Adding a `DaemonClientProtocol` for full mock-based testing — would require touching every existing call site; not justified for this feature alone.
- Daemon-side broadcast of the new delta cases — that's the responsibility of Phases 05, 06, 07. This phase only adds the case definitions and the receiver. If those phases land before 08, just verify the broadcasts exist; if they land after, this phase's deltas will simply never fire until they do, and the smoke test still passes.

## Risks

- **Delta enum ordering:** Adding a new case at the end of `StateDelta` is Codable-safe (Swift synthesizes by case name, not ordinal). Do not reorder existing cases.
- **Token bytes leakage:** The `addClaudeToken` path is the only place a raw token crosses the actor boundary. Audit the final diff for any `logger.*(... token ...)` or `print(... token ...)` calls before committing.
- **Focus observer leak:** if observers aren't removed in `deinit`, the closure retains `self` and `AppState` (singleton-lifetime in this app) never deallocates — acceptable in practice but document it.
