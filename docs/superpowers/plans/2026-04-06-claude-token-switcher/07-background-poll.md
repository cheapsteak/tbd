# Phase 07: Background Usage Poller

> **Parent plan:** [../2026-04-06-claude-token-switcher.md](../2026-04-06-claude-token-switcher.md)
> **Depends on:** Phase 01, 02, 03, 05
> **Unblocks:** Phase 08

**Scope:** A `ClaudeUsagePoller` actor that keeps `claude_token_usage` fresh for OAuth tokens on a 30-minute cadence with 30 s startup stagger, 60 min 429 backoff, 401 exclusion, focus-pause + resume, and dedupe. Wired into daemon lifecycle. Fully testable with an injected clock.

## Context

Spec section "Usage fetching" (`docs/superpowers/specs/2026-04-06-claude-token-switcher-design.md` lines 139–178) defines triggers and rules. This phase implements the *background* trigger and the *focus regained* trigger; the on-demand triggers (Settings opened, swap RPC, menu opened) are handled by Phase 05's `claudeToken.fetchUsage` handler invoking `pokeAll()` / single-token `poke()` on this poller.

Existing daemon lifecycle hook for long-running tasks: `Sources/TBDDaemon/Daemon.swift:122-150` already starts background `Task`s (`gitFetchTask`, `gitStatusTask`) at the bottom of `Daemon.start()`. The poller is wired in beside them and cancelled in `Daemon.stop()`.

There is **no existing app→daemon focus signal** (verified via grep for `setForeground|focus|appLifecycle` across `Sources/`). This phase adds an `app.setForegroundState(isForeground: Bool)` RPC.

## Key rules (verbatim from spec)

- OAuth tokens only; `kind == api_key` skipped permanently.
- Default cadence: 30 min per token.
- Startup stagger: first poll for each token at `random(0..30s)` from `start()`.
- HTTP 429 → next poll for that token 60 min out; first success after that reverts to 30 min.
- HTTP 401 → stop polling that token entirely. Row stays; Settings shows "Invalid".
- Focus loss: if app stays unfocused for >10 min, pause the loop. On focus regained, resume immediately and `pokeAll()`.
- Dedupe: if `fetched_at < 60 s` ago, skip the network call (reuse cache).
- Every successful poll writes to `ClaudeTokenUsageStore` and calls `broadcast` with the updated row.

## Design

**Single scheduler loop, not one task per token.** A single `Task` inside the actor runs `while !cancelled { sleep until earliest nextFireAt; tick(); }`. Per-token state lives in `var schedule: [TokenID: Entry]` where `Entry { nextFireAt: Date, backoffActive: Bool, excluded: Bool }`. This is lighter than N tasks and avoids cross-task synchronization for the per-token map.

**Clock injection.** Define a `protocol PollerClock: Sendable { func now() -> Date; func sleep(until: Date) async throws }`. Production impl wraps `Date()` + `Task.sleep(for:)`. Test impl is a `TestPollerClock` actor that tracks a virtual `now`, exposes `advance(by:)`, and resolves any in-flight `sleep(until:)` continuations whose deadlines have been crossed. All scheduling uses wall-clock `Date` (not `ContinuousClock`) so the 60 s dedupe against `fetched_at` and the 10-min focus threshold use the same time base.

**Focus tracking.** Actor stores `lastFocusLostAt: Date?` and `isPaused: Bool`. `onFocusChanged(false)` records the timestamp; `onFocusChanged(true)` clears it, sets `isPaused = false`, fires `pokeAll()`, and resumes the loop. The scheduler loop, before each tick, checks `if let lostAt = lastFocusLostAt, now - lostAt > 10*60 { isPaused = true; }` and waits on a `CheckedContinuation` until focus returns. (No timer needed for the 10-min threshold itself — the loop's natural wakeups catch it.)

**Dedupe.** Before each network call, the poller reads the current `ClaudeTokenUsage` row for the token via `usage.get(tokenID:)`; if `fetched_at` is within 60 s, skip the call entirely (do not even update `nextFireAt` cadence — the next tick simply rolls forward by 30 min from now).

## Tasks

### Task 1: Define `PollerClock` protocol and production impl

Create `Sources/TBDDaemon/Claude/PollerClock.swift`:

```swift
public protocol PollerClock: Sendable {
    func now() -> Date
    func sleep(until deadline: Date) async throws
}

public struct SystemPollerClock: PollerClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(until deadline: Date) async throws {
        let interval = deadline.timeIntervalSince(Date())
        if interval > 0 { try await Task.sleep(for: .seconds(interval)) }
    }
}
```

### Task 2: Define `ClaudeUsagePoller` actor skeleton

Create `Sources/TBDDaemon/Claude/ClaudeUsagePoller.swift` with the actor declaration, init, stored state (`schedule: [String: Entry]`, `isPaused: Bool`, `lastFocusLostAt: Date?`, `loopTask: Task<Void, Never>?`, `wakeContinuation: CheckedContinuation<Void, Never>?`), and stub methods `start`, `stop`, `onFocusChanged`, `pokeAll`. Wire dependencies (`tokens`, `usage`, `keychain`, `fetcher`, `clock`, `broadcast`).

### Task 3: Implement `start()` with stagger

`start()` lists tokens via `tokens.list()`, filters to `kind == .oauth`, assigns each a `nextFireAt = clock.now() + Double.random(in: 0..<30)` seconds, populates `schedule`, then launches the scheduler loop `Task`. Idempotent: if `loopTask` already exists, no-op.

### Task 4: Implement scheduler loop

The loop: pick the entry with the earliest `nextFireAt`; await `clock.sleep(until: that)`; if focus is paused, `await withCheckedContinuation { wakeContinuation = $0 }` until `onFocusChanged(true)` resumes it; then call `tick(tokenID:)`. After each tick, recompute and continue. Handles `tokens.list()` changes by re-reading the token list at the top of every iteration so newly added tokens get scheduled and deleted ones drop out.

### Task 5: Implement `tick(tokenID:)` core fetch path

Inside `tick`:
1. Load token from `tokens` to confirm it still exists and is `oauth`. If not, drop from `schedule` and return.
2. Dedupe: if `usage.get(tokenID:)?.fetchedAt` is within 60 s of `clock.now()`, skip network and just reschedule `nextFireAt += 30 min` (or `+ 60 min` if backoff still active).
3. Load secret via `keychain(tokenID)`. If nil, skip and reschedule normally.
4. Call `fetcher.fetchUsage(token:)`.
5. Branch on result:
   - `.ok(let result)` → write to `usage.upsert(...)`, call `broadcast(updatedRow)`, clear `backoffActive`, set `nextFireAt = now + 30 min`.
   - `.http429` → write status `http_429` to usage row (preserving cached pcts), set `backoffActive = true`, `nextFireAt = now + 60 min`. Log once per token (track in a `loggedBackoff: Set<String>` to avoid log spam).
   - `.http401` → write status `http_401`, mark entry `excluded = true`, remove from `schedule`. Do not reschedule.
   - `.networkError` → write status `network_error`, reschedule `nextFireAt = now + 30 min` (or 60 min if backoff active). No status escalation.

### Task 6: Implement `pokeAll()` and `poke(tokenID:)`

`pokeAll()` sets every non-excluded entry's `nextFireAt = clock.now()` and signals the loop to wake (resume `wakeContinuation` if waiting, or cancel current sleep via a sentinel — simplest impl: store the loop's current sleep task and `cancel()` it; the loop catches `CancellationError` from `clock.sleep`, treats it as wake-up, and re-evaluates). `poke(tokenID:)` does the same for one token; used by Phase 05's `claudeToken.fetchUsage` handler for single-token refresh on UI surfaces.

### Task 7: Implement `onFocusChanged(isForeground:)`

- `isForeground == false` → set `lastFocusLostAt = clock.now()`. Loop continues normally for the first 10 minutes; on the next tick after the threshold crosses, the loop sets `isPaused = true` and parks on the continuation.
- `isForeground == true` → set `lastFocusLostAt = nil`, `isPaused = false`. If `wakeContinuation` is set, resume it. Then call `pokeAll()`.

### Task 8: Implement `stop()`

Cancel `loopTask`, nil it out, resume `wakeContinuation` (so cancellation propagates), clear `schedule`. Idempotent.

### Task 9: Wire poller into `Daemon.start()`

In `Sources/TBDDaemon/Daemon.swift`, after Task 12 (git fetch task) and before Task 13 (git status task):

- Construct `ClaudeUsagePoller(tokens: ..., usage: ..., keychain: { id in try ClaudeTokenKeychain.load(id: id) }, fetcher: ClaudeUsageFetcher(), clock: SystemPollerClock(), broadcast: { row in subs.broadcastClaudeTokenUsage(row) })`.
- Store on `Daemon` as `nonisolated(unsafe) var claudeUsagePoller: ClaudeUsagePoller?`.
- Call `await poller.start()`.
- In `Daemon.stop()`, call `await claudeUsagePoller?.stop()` before cancelling other background tasks.

Note: `subs.broadcastClaudeTokenUsage` is added as a thin wrapper in this phase if it doesn't exist on `StateSubscriptionManager` yet (delegates to the existing state-update channel — see Phase 05 for the broadcast plumbing). If Phase 05 already added it, reuse.

### Task 10: Add `app.setForegroundState` RPC

There is no existing app→daemon focus signal. Add to `Sources/TBDDaemon/Server/RPCRouter.swift` (or a new `RPCRouter+AppHandlers.swift` if no app section exists yet) a handler:

- Method name: `app.setForegroundState`
- Params: `{ "isForeground": Bool }`
- Body: `await daemon.claudeUsagePoller?.onFocusChanged(isForeground: params.isForeground)` (router needs a reference to the poller — pass it through the `RPCRouter` init alongside the other deps, or expose via a closure to keep coupling minimal).

Add the matching method declaration to `Sources/TBDShared/` RPC method enum / constants if one exists; otherwise add the method string in the router switch only. Update `Sources/TBDShared/Models.swift` if a typed params struct is required by convention there.

This RPC is wired up by the app in a later phase (Phase 09 / wire-up); this phase only adds the daemon side.

### Task 11: Test — happy path stagger and cadence

`Tests/TBDDaemonTests/ClaudeUsagePollerTests.swift`. Use a `TestPollerClock` and an in-memory `MockClaudeUsageFetcher` (records calls, returns scripted results). Two oauth tokens in an in-memory `ClaudeTokenStore`/`ClaudeTokenUsageStore`.

- After `start()`, advance clock by 30 s → both tokens fetched exactly once each.
- Advance another 30 min → both fetched again (total: 2 each).

### Task 12: Test — dedupe and 429 backoff

- Pre-populate `usage` row with `fetchedAt = clock.now() - 30s`. Advance clock past first stagger; assert `fetcher.callCount == 0` for that token (dedupe hit), `nextFireAt` rolled to ~30 min.
- Script fetcher to return `.http429` for one token; advance past stagger; assert next `nextFireAt` is 60 min out, not 30. Then script `.ok`; advance 60 min; assert success and that the *following* `nextFireAt` is 30 min out (backoff cleared).

### Task 13: Test — 401 exclusion and api_key skip

- Token A oauth, token B api_key. Start poller; advance 30 s + a few minutes; assert fetcher only called for A.
- Script A to return `.http401`; advance; assert A removed from schedule; advance another hour; assert A never fetched again.

### Task 14: Test — focus pause/resume + pokeAll

- Start poller, let it complete first stagger (1 fetch per token).
- `onFocusChanged(false)` at `t0`; advance clock 11 minutes without firing the next 30-min tick (i.e., scheduler wakes via injected timer for a check) → assert no new fetches and `isPaused == true`.
- `onFocusChanged(true)` → assert immediate fetch for both tokens (pokeAll), and that the loop has resumed (subsequent 30-min advancement triggers another fetch).
- Separately, with a fresh poller mid-cadence, call `pokeAll()` directly → assert both eligible tokens fetched immediately regardless of `nextFireAt`.

### Task 15: Test — broadcast invocation

- Capture broadcast calls into a thread-safe collector. After two successful ticks, assert `broadcast` was called twice with the expected `ClaudeTokenUsage` rows (matching what's in the store).
- After a `.http429` tick, assert broadcast is *also* called (UI needs to know status changed) with the row whose `lastStatus == "http_429"`.

### Task 16: Verification

Run `swift build` and `swift test --filter ClaudeUsagePollerTests`. Confirm:
- All 6 test methods pass.
- No real-time sleeps in tests (whole suite completes in <1 s).
- `Daemon.start()` still compiles after wiring; manual `scripts/restart.sh` shows `[Daemon] Started successfully` and no warnings about the poller.
- Per CLAUDE.md branching rule: every new gated branch (oauth-only filter, dedupe hit, 429 backoff, 401 exclusion, focus pause threshold) is covered by at least one assertion in Tasks 11–15.

Commit as `feat: add background Claude usage poller`.
