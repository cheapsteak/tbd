# UI-Daemon Communication Review

**Date:** 2026-04-13
**Status:** Proposal / RFC
**Scope:** App ↔ Daemon IPC patterns, state synchronization, connection lifecycle

---

## Executive Summary

TBD's SwiftUI app communicates with the daemon via JSON-RPC over a Unix domain socket. The current architecture combines **poll-primary** state synchronization (7+ RPC calls every 2 seconds) with a **supplementary push channel** that is 79% unused. This review identifies concrete inefficiencies, surveys how Docker, Syncthing, Tailscale, VS Code/LSP, and others solve the same problem, and proposes a phased migration to a **push-primary** architecture that would eliminate most polling while requiring minimal protocol changes.

---

## 1. Current Architecture

### 1.1 Protocol

- **Transport:** Unix domain socket at `~/.tbd/sock` (NIO server-side, POSIX client-side)
- **Framing:** Newline-delimited JSON
- **Schema:** Custom JSON-RPC-like — `RPCRequest { method, params }` / `RPCResponse { success, result, error }`
- **Params encoding:** Double-encoded — params are a JSON string embedded inside the outer JSON object
- **Connection model:** One-shot per RPC call — `socket()` → `connect()` → `send()` → `recv()` → `close()`
- **Subscription channel:** Separate persistent socket for `state.subscribe`, streaming `StateDelta` events

### 1.2 State Synchronization

The app uses a **hybrid poll + push** model, but polling dominates:

| Mechanism | Frequency | What it fetches |
|-----------|-----------|-----------------|
| `refreshAll()` poll | Every 2s | repos, worktrees, terminals, notes, notifications, conductors |
| `refreshPRStatuses()` poll | Every 30s | PR merge states |
| `state.subscribe` push | Real-time | 14 delta types (but only 3 handled by app) |

### 1.3 Poll Cycle Breakdown

Each 2-second poll cycle makes **7 sequential RPC calls**, each creating a new socket connection:

```
refreshAll()
├── refreshRepos()           → 1 RPC: repo.list
├── refreshWorktrees()       → 3 RPCs: worktree.list, terminal.list, note.list
├── refreshNotifications()   → 1 RPC: notifications.list (+N markRead calls)
└── refreshConductors()      → 2 RPCs: conductor.list, terminal.list (DUPLICATE)
```

**For a typical user** (3 repos, 5 worktrees, 2 visible with notifications):
- **~9 socket connections per 2s cycle**
- **~270 connections/minute**
- All calls are sequential (no parallelism)
- `terminal.list` is called twice per cycle (refreshWorktrees + refreshConductors)

### 1.4 Delta Infrastructure — Mostly Unused

The daemon broadcasts 14 `StateDelta` cases:

| Delta | Broadcast by daemon? | Handled by app? |
|-------|---------------------|-----------------|
| `worktreeCreated` | Yes | **No** (falls to `default: break`) |
| `worktreeArchived` | Yes | **No** |
| `worktreeRevived` | Yes | **No** |
| `worktreeRenamed` | Yes | **No** |
| `notificationReceived` | Yes | **Yes** |
| `repoAdded` | Yes | **No** |
| `repoRemoved` | Yes | **No** |
| `terminalCreated` | Yes | **No** |
| `terminalRemoved` | Yes | **No** |
| `worktreeConflictsChanged` | Yes | **No** |
| `terminalPinChanged` | Yes | **No** |
| `worktreeReordered` | Yes | **No** |
| `claudeTokenUsageUpdated` | Yes | **Yes** |
| `claudeTokensChanged` | Yes | **Yes** |

**3 of 14 delta types are handled** (21%). The remaining 11 are received, decoded, and discarded. The same data is then re-fetched 0-2 seconds later by the polling loop.

### 1.5 Missing Delta Types

Several state categories have **no delta events at all** — they are only discoverable via polling:

- **Notes** — creation, update, deletion
- **Conductors** — setup, start, stop, suggestion changes
- **PR statuses** — status changes from GitHub polling
- **Terminal state changes** — suspend/resume, label changes, session ID updates

---

## 2. Industry Patterns Survey

### 2.1 Notable OSS Projects

| Project | Transport | Real-time Updates | Connection Model |
|---------|-----------|-------------------|------------------|
| **Docker Desktop** | REST over Unix socket | Streaming HTTP response (chunked JSON) | Persistent, auto-retry |
| **Syncthing** | HTTP REST on localhost | Long-poll `/rest/events?since=N` | Cursor-based, 60s timeout |
| **VS Code / LSP** | JSON-RPC over stdio | Bidirectional notifications (no `id` = no reply expected) | Persistent, capability negotiation |
| **Tailscale** | HTTP over Unix socket (Linux) / XPC (macOS App Store) | Streaming `/watch-ipn-bus` with bitmask filter | Persistent, 250ms retry backoff |
| **iTerm2** | WebSocket + protobuf | Subscription model — subscribe/unsubscribe per event type | Persistent |

**Common patterns across all five:**
1. **Persistent connections** — no project uses one-shot connections for regular operations
2. **Push-primary for state** — polling is a fallback, not the primary mechanism
3. **Event type filtering** — clients subscribe to specific event categories (Syncthing bitmask, Tailscale mask param, iTerm2 subscribe/unsubscribe)
4. **Cursor-based reconnect** — Syncthing's `since=lastEventID` pattern lets clients resume without missing events

### 2.2 Key Design Principles from Literature

- **Neil Fraser's Differential Synchronization:** Maintain shadow copies; send only diffs. Simpler in single-machine scenarios where network partitions are impossible.
- **Event Sourcing for Local IPC:** The daemon emits an append-only event log with sequence numbers. The UI replays from its last-seen sequence on reconnect. This is how Apple's Core Data persistent history tracking works.
- **GRDB's `ValueObservation`:** The daemon already uses GRDB. `ValueObservation` watches SQLite tables and emits change events automatically — purpose-built for exactly this pattern.
- **Apple's recommendation (WWDC 2012, 2021):** XPC is preferred for app-to-daemon communication, but requires a bundled `.app`. For unbundled executables, Unix sockets with push-based state sync is the viable alternative.

---

## 3. Identified Issues

### 3.1 Wasted Work (High Impact)

**Issue:** 79% of delta infrastructure is unused. The daemon does the work of encoding and transmitting deltas; the app does the work of receiving and decoding them; then both sides discard the result and the app re-polls for the same data.

**Impact:** Every 2 seconds, the app transfers and decodes full state snapshots (repos, worktrees, terminals, notes, notifications, conductors) even when nothing has changed. In steady state, >95% of polled data is unchanged.

### 3.2 Sequential RPC Calls (Medium Impact)

**Issue:** `refreshAll()` makes 7+ RPCs sequentially. Each must complete before the next begins.

**Impact:** If the daemon takes 5ms per RPC, the poll cycle takes ~35ms of wall-clock time. Parallelizing would reduce this to ~5ms. Not a user-visible issue at current scale, but compounds with connection overhead.

### 3.3 Duplicate RPC Calls (Low-Medium Impact)

**Issue:** `terminal.list` (with no filter) is called twice per cycle — once in `refreshWorktrees()` (line 471) and again in `refreshConductors()` (line 654).

**Impact:** ~135 wasted socket connections/minute, plus redundant serialization work on both sides.

### 3.4 Connection-per-Call Overhead (Medium Impact)

**Issue:** Every RPC creates a fresh POSIX socket, connects, sends, receives, and closes. On the daemon side, NIO bootstraps a new channel pipeline per connection.

**Impact:** ~270 `socket()`/`connect()`/`close()` syscall sequences per minute. The per-call cost is ~15-25μs (negligible), but the NIO channel setup/teardown and associated allocations add up. No project in our survey uses this pattern.

### 3.5 Double JSON Encoding (Low Impact)

**Issue:** `RPCRequest.params` is a `String` containing JSON, embedded inside the outer JSON. This means params are encoded to JSON, then that JSON string is encoded again as a JSON string value (with escaping).

**Impact:** Extra encode/decode cycle per call, escaped strings in wire dumps make debugging harder. Functional but inelegant.

---

## 4. Proposals

### Proposal A: Complete the Delta Handling (High Impact, Low Effort)

**What:** Extend `AppState.handleDelta()` to apply all 14 existing delta types directly to `@Published` properties, instead of ignoring 11 of them.

**How:**
```
handleDelta(.worktreeCreated(let d))    → insert worktree into worktrees[d.repoID]
handleDelta(.worktreeArchived(let d))   → remove worktree from its repo group
handleDelta(.worktreeRevived(let d))    → insert worktree into worktrees[d.repoID]
handleDelta(.worktreeRenamed(let d))    → update displayName in-place
handleDelta(.repoAdded(let d))          → append to repos list
handleDelta(.repoRemoved(let d))        → remove from repos list
handleDelta(.terminalCreated(let d))    → insert terminal, reconcile tabs
handleDelta(.terminalRemoved(let d))    → remove terminal, reconcile tabs
handleDelta(.worktreeConflictsChanged)  → update hasConflicts in-place
handleDelta(.terminalPinChanged)        → update pinnedAt in-place
handleDelta(.worktreeReordered)         → re-fetch worktrees for that repo (or add sort info to delta)
```

**Impact:** With all deltas handled, the polling interval can be relaxed from 2s to 30-60s (heartbeat/reconciliation only). This alone reduces socket connections from ~270/min to ~15/min — a **~95% reduction** in IPC traffic.

**Effort:** ~2-4 hours. No protocol changes. No daemon changes. Pure app-side work in `AppState.swift`.

**Risk:** Low. Deltas are already being received and decoded. The only new code is applying them to state.

### Proposal B: Add Missing Delta Types (Medium Impact, Medium Effort)

**What:** Add `StateDelta` cases for state categories that currently have no push mechanism:

```swift
case noteCreated(NoteDelta)
case noteUpdated(NoteDelta)
case noteDeleted(NoteIDDelta)
case conductorStateChanged(ConductorDelta)
case conductorSuggestionChanged(ConductorSuggestionDelta)
case prStatusChanged(PRStatusDelta)
case terminalStateChanged(TerminalStateDelta)  // suspend/resume/label
```

**How:** Add broadcast calls in the daemon's RPC handlers (same pattern used for existing deltas). Add corresponding handling in `AppState.handleDelta()`.

**Impact:** Closes the remaining gaps in push coverage. With Proposals A + B, polling becomes purely a reconciliation mechanism (catch-up after reconnect, sanity check).

**Effort:** ~4-8 hours. Requires daemon + shared + app changes. Each new delta type needs: struct definition in `StateDelta.swift`, broadcast call in the relevant `RPCRouter+*Handlers.swift`, and handler in `AppState.handleDelta()`.

### Proposal C: Composite Snapshot RPC (Medium Impact, Low Effort)

**What:** Add a single `state.snapshot` RPC that returns all state in one response, replacing the 4-7 sequential calls in `refreshAll()`.

```swift
struct StateSnapshot: Codable {
    let repos: [Repo]
    let worktrees: [Worktree]
    let terminals: [Terminal]
    let notes: [Note]
    let notifications: [UUID: NotificationType]
    let conductors: [Conductor]
    let prStatuses: [UUID: PRStatus]
}
```

**How:** Add `RPCMethod.stateSnapshot`, a handler in `RPCRouter` that queries all stores, and a client method in `DaemonClient`.

**Impact:**
- Initial load: 1 RPC instead of 7 (faster app startup)
- Reconnect: 1 RPC to re-sync full state
- If polling is retained as fallback: 1 connection instead of 7 per cycle

**Effort:** ~2-3 hours. Single new RPC method, straightforward aggregation.

### Proposal D: Persistent Connection with Request Multiplexing (Medium Impact, Medium Effort)

**What:** Replace one-shot socket connections with a single persistent connection for all RPC traffic. Add a `requestID` field to RPCRequest/RPCResponse for multiplexing.

```swift
// Enhanced protocol
struct RPCRequest: Codable {
    let id: UUID       // NEW: correlate request to response
    let method: String
    let params: String
}

struct RPCResponse: Codable {
    let id: UUID?      // NEW: matches request ID (nil for push deltas)
    let success: Bool
    let result: String?
    let error: String?
}
```

**How:** `DaemonClient` maintains a single persistent socket. Requests are sent with an `id`; the read loop matches responses by `id` and resumes the waiting continuation. Deltas (no `id`) are routed to the delta handler. One socket serves both RPC and subscription traffic.

**Impact:**
- Eliminates ~270 socket lifecycle operations/minute
- Enables request pipelining (send multiple RPCs without waiting for responses)
- Merges the RPC and subscription sockets into one connection
- Aligns with every OSS project surveyed (Docker, Tailscale, LSP, Syncthing — all use persistent connections)

**Effort:** ~8-16 hours. Requires changes to `DaemonClient`, `SocketServer`/`SocketRPCHandler`, and `RPCProtocol`. The daemon's NIO handler needs to support multiple in-flight requests per connection. This is the most invasive change.

**Risk:** Medium. Connection lifecycle management (reconnect on error, request timeout, in-flight request cleanup on disconnect) adds complexity. LSP's approach (explicit `initialize`/`shutdown` handshake) mitigates version-skew risks.

### Proposal E: Eliminate Double JSON Encoding (Low Impact, Low Effort)

**What:** Change `RPCRequest.params` from `String` (pre-encoded JSON) to `AnyCodable` or a raw `[String: Any]` so params are encoded as part of the outer JSON object, not double-encoded.

**Why not:** This is a breaking protocol change that affects daemon, app, and CLI simultaneously. The current approach works, is well-understood, and the performance cost is negligible. **Recommend deferring** unless Proposal D is implemented (which would be a natural time to clean up the wire format).

### Proposal F: Sequenced Deltas with Reconnect Replay (Low-Medium Impact, Medium Effort)

**What:** Add a monotonically increasing sequence number to each `StateDelta`. On reconnect, the app sends its last-seen sequence number; the daemon replays missed events (or sends a full snapshot if the gap is too large).

**How:** The daemon maintains an in-memory ring buffer of recent deltas (e.g., last 1000). Each delta gets an incrementing `seq` number. The `state.subscribe` RPC accepts an optional `since` parameter. If the daemon can replay from `since`, it does; otherwise it signals "full resync needed."

**Why:** This is the pattern used by Syncthing (`/rest/events?since=N`) and event sourcing systems. It provides exactly-once delivery semantics and eliminates the need for periodic polling as a catch-up mechanism. Without sequence numbers, the app has no way to know if it missed a delta during a brief socket hiccup.

**Effort:** ~4-6 hours. Daemon-side ring buffer + seq counter, protocol change to `state.subscribe`, client-side seq tracking.

---

## 5. Recommended Implementation Order

```
Phase 1 — Quick Wins (1-2 days)
├── Proposal A: Complete delta handling in AppState
├── Proposal C: Composite state.snapshot RPC
├── Fix: Deduplicate terminal.list call in refreshConductors()
└── Fix: Parallelize remaining poll calls with async let

Phase 2 — Push Coverage (2-3 days)
├── Proposal B: Add missing delta types (notes, conductors, PR, terminal state)
├── Relax polling interval to 30s (reconciliation-only)
└── Add delta sequence numbers (Proposal F, partial — just the counter)

Phase 3 — Connection Optimization (3-5 days, optional)
├── Proposal D: Persistent connection with request IDs
├── Proposal F: Full reconnect replay with ring buffer
└── Merge RPC + subscription into single connection
```

**Phase 1 alone would reduce IPC traffic by ~90%** with minimal risk. Phase 2 completes the push model. Phase 3 is a polish/optimization phase that aligns with industry best practices but is not strictly necessary at current scale.

---

## 6. What We Explicitly Do NOT Recommend

- **Switching to XPC:** TBDApp is an unbundled SPM executable. XPC requires a bundle identifier and launchd plist. The migration cost is high and the benefits (Codable transport, launchd lifecycle) can be approximated with the current Unix socket approach.

- **Switching to gRPC/protobuf:** Adds a C++ dependency (grpc-swift), code generation toolchain, and build complexity. The current JSON protocol is adequate for the payload sizes involved. The performance gain would be unmeasurable.

- **Switching to WebSockets:** Adds framing complexity over the existing newline-delimited approach with no benefit for same-machine IPC. WebSockets solve problems (HTTP proxy traversal, browser compatibility) that don't exist here.

- **Adopting CRDTs:** The daemon is the single authoritative state owner. There is no concurrent-write conflict to resolve. CRDTs solve a problem TBD does not have.

---

## Appendix: Survey Sources

- Docker Engine API: REST over Unix socket, streaming events via chunked HTTP
- Syncthing REST API: Long-poll `/rest/events?since=N`, event type filtering
- Language Server Protocol: JSON-RPC 2.0, request vs notification distinction, capability negotiation
- Tailscale localapi: Streaming `/watch-ipn-bus` with bitmask filter, XPC on macOS App Store builds
- iTerm2 scripting API: WebSocket + protobuf, subscription model
- Neil Fraser, "Differential Synchronization" (DocEng 2009)
- GRDB `ValueObservation` — SQLite change observation for Swift
- Apple WWDC 2012 "Efficient Design with XPC" (session 702)
- Maier, Odersky et al., "Deprecating the Observer Pattern" (2010)
