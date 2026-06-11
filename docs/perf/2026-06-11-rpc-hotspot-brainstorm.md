# RPC steady-state hotspot: investigation + fix brainstorm — 2026-06-11

Follow-up to `2026-06-11-tbdapp-cpu-energy-investigation.md` (branch
`tbd/20260611-junior-elk`), which measured ~2.9% of a core (~50 ms per 2 s
poll cycle) spent in `Sequence.contains` / `Data.Iterator.next()` under
`DaemonClient.sendRaw`, with the app fully quiet. This doc re-derives the
cost from code + live measurements and ranks candidate fixes.

All numbers measured 2026-06-11 against the live daemon
(`~/tbd/sock`, this user's real DB) and a release-built synthetic benchmark.

## What the cost actually is

Three multiplicative factors:

### 1. Quadratic newline scan in the read loop (the sampled hotspot)

`DaemonClient.sendRaw` (`Sources/TBDApp/DaemonClient.swift:231-254`) reads
the newline-delimited JSON response like this:

```swift
responseData.append(buffer, count: bytesRead)
if responseData.contains(0x0A) { break }     // ← rescans EVERYTHING
```

`Data.contains` resolves to the generic `Sequence.contains` walking
`Data.Iterator.next()` byte-by-byte (exactly the frames in the sample), and
it rescans the *entire accumulated buffer* after every `recv`. The CLI has
the identical loop in `Sources/TBDCLI/SocketClient.swift:107-120`.

Measured against the live socket: `recv` on this Unix socket returns **8 KB
chunks** (kernel buffer), not the 64 KB the code allocates. Today's
`worktree.list` response is 475,666 bytes = **59 chunks**, so the loop scans
sum(8K, 16K, … 472K) = **14,492,178 bytes — 30.5× the payload — through a
generic iterator, per poll**. Cost is O(n²/chunkSize) in response size.

Synthetic benchmark (`swiftc -O`, 64 KB chunks — i.e. *understating* the
real 8 KB-chunk cost):

| payload | current (`contains` per chunk) | `firstIndex` on new chunk | `memchr` on new chunk |
|---|---|---|---|
| 100 KB | 0.95 ms | 1.25 ms | 0.03 ms |
| 475 KB | 10.2 ms | 1.4 ms | 0.08 ms |
| 1 MB | 37.8 ms | 3.6 ms | 0.40 ms |

With real 8 KB chunks the current path is ~8× worse than the 64 KB-chunk
bench row (8× more rescans), which lands right on the measured ~50 ms per
poll cycle. A scan-only-the-new-bytes `memchr` is effectively free at any
payload size. Note `Data.firstIndex(of:)` is also generic/slow — the fix
should be `withUnsafeBytes` + `memchr` (or track a scanned-offset and only
scan appended bytes).

This same loop frames **every** response, so it also taxes the transcript
pane's 1.5 s full-transcript poll (state C in the prior writeup), where
payloads are far larger than 475 KB.

### 2. The poll ships 815 worktrees every 2 s and throws 87% away

`AppState.refreshAll()` (every 2 s, `AppState.swift:961-987, 1119-1123`)
fetches `repo.list` + `worktree.list` (unfiltered) + `terminal.list` +
`note.list` + `notifications.list`. Live sizes today:

| method | bytes | note |
|---|---|---|
| `worktree.list` | **475,666** | 815 rows: 68 active, 7 main, **740 archived** |
| `terminal.list` | 99,214 | 158 rows; 45% of bytes = `suspendedSnapshot` blobs |
| `note.list` | 10,914 | |
| `repo.list` | 6,247 | |
| `notifications.list` | 1,380 | |

Of the 475 KB, **414 KB (87%) is archived rows** — which the app filters
out *immediately* on arrival (`AppState.visibleWorktrees`,
`AppState+ArchiveTombstones.swift:36-41` drops `.archived`). The archived
view never reads from this poll: it has its own paginated fetch
(`refreshArchivedWorktrees`, `AppState+Worktrees.swift:277-292`, pages of
50 with `status: .archived`). The daemon handler even has a comment
acknowledging the 2 s poll hits the unfiltered path
(`RPCRouter+WorktreeHandlers.swift:60-85`).

This payload grows forever — every archived worktree is shipped, parsed,
equality-compared, and discarded ~43,000 times a day, and the quadratic
scan multiplies on top of it.

Tombstone reconciliation (`reconcileTombstones`) treats "absent from the
response" identically to "status == .archived" (both confirm the tombstone),
so excluding archived rows daemon-side does not change its semantics.

### 3. Protocol overheads (smaller, certain)

- **Double-encoded JSON**: `RPCResponse.result` is a JSON *string* inside
  JSON (`RPCProtocol.swift`), so every response is parsed twice (once to
  extract the giant escaped string, once to decode the models) and carries
  escape overhead — measured **+48,695 bytes (10%)** on `worktree.list`.
- **Connection per call**: each RPC opens a fresh Unix socket
  (`makeConnectedSocket`). Cheap individually; the prior sample showed the
  poll thread blocked in `recv` ~30-50% of wall time across the 5+
  sequential calls per cycle.
- **StateDelta subscription is underused**: the daemon broadcasts a
  near-complete delta set (created/archived/revived/renamed/reordered/moved
  worktrees, repo changes, terminal created/removed/pin, conflicts,
  notifications, profiles — see `StateDelta.swift` and the
  `subscriptions.broadcast` sites in `RPCRouter+*Handlers.swift`), but
  `AppState.handleDelta` (`AppState.swift:775-797`) applies only ~7 cases
  and `default: break`s the rest. The 2 s poll is still the actual
  synchronization mechanism; the subscription is an accelerator for a few
  paths.

## Candidate directions, ranked

### A. Scan only new bytes when framing (do it now)

Track how far the buffer has been scanned; check only the appended chunk for
`0x0A` via `withUnsafeBytes` + `memchr`. Apply identically to
`DaemonClient.sendRaw` and `TBDCLI/SocketClient.swift`.

- **Payoff**: kills the sampled hotspot outright (~50 ms → ≪1 ms per cycle;
  ~125× less scan work at 475 KB, more at transcript sizes). Helps every
  client, every method, including the transcript-pane fire.
- **Risk**: near zero. Pure client-side read-loop change, no protocol or
  daemon impact. Easily unit-tested (multi-chunk framing, newline split
  across chunks, newline mid-buffer).
- **Effort**: tiny.

### B. Exclude archived rows from the 2 s poll (do it now)

Add an opt-in filter so the poll fetches only non-archived rows — e.g.
`WorktreeListParams.statuses: [WorktreeStatus]?` (or `excludeArchived:
Bool?`) honored in `WorktreeStore.list` with a SQL filter; the app's
`refreshWorktrees` passes it. The archived view's existing paginated path is
untouched.

- **Payoff**: poll payload 475 KB → ~37 KB (**13×**), and it stops growing
  with archive history. Cuts daemon-side DB fetch + encode of 740 rows,
  wire bytes, app-side double JSON parse, and the 815-element
  equality-compare — every 2 s, forever. Even without A, it collapses the
  quadratic scan (5 chunks instead of 59 → ~115 KB scanned, negligible).
- **Risk**: low. New optional param — old daemons ignore unknown JSON keys
  and return everything, and the app already filters client-side, so mixed
  versions degrade gracefully to today's behavior. Tombstone reconcile is
  unaffected (absent == archived, verified above). Needs tests for the new
  filter branch per CLAUDE.md.
- **Effort**: small (param + store filter + app call site + tests; CLI
  could optionally expose it).

### C. Make StateDelta the primary sync; demote the poll to slow reconciliation

Extend `handleDelta` to apply the already-broadcast cases it currently
drops (`worktreeCreated/Renamed/Reordered`, `terminalCreated/Removed`,
`worktreeConflictsChanged`, repo deltas, …), then stretch the poll from 2 s
to e.g. 30-60 s as an anti-entropy backstop (and/or poll fast only while a
delta gap is suspected, immediately after reconnect, or after app
foregrounding).

- **Payoff**: removes ~95% of steady-state RPCs — the recv-blocked thread
  time, the daemon's per-poll DB reads, JSON encode/decode, and compare
  churn all shrink proportionally. This is the direction that makes the
  steady-state cost *O(actual changes)* instead of *O(state size)*.
- **Risk**: medium. Every delta type the app mishandles becomes a
  staleness bug with up to a poll-interval window; some state has no delta
  today (notes; `suspendedSnapshot`/label changes; anything mutated outside
  the RPC handlers). Needs an audit of mutation sites vs broadcast sites,
  and per-case tests. The subscription channel itself (long-lived
  connection, reconnect behavior) becomes correctness-critical instead of
  best-effort.
- **Effort**: medium — incremental and shippable case-by-case (each delta
  handled is one fewer reason to keep the poll fast; the poll interval is a
  single constant to tune at the end).

### D. Protocol redesign: length-prefixed framing + inline `result` JSON

Replace newline framing with a 4-byte length prefix (no scan at all) and
make `result` a raw JSON value instead of a double-encoded string (single
parse, -10% wire).

- **Payoff**: eliminates the framing scan *by construction* and the double
  parse. Cleanest long-term protocol.
- **Risk/effort**: highest. Touches `RPCProtocol.swift`, daemon server,
  app client, CLI client; all three ship in lockstep but the *installed*
  app and a dev daemon (or vice versa) routinely skew on this machine —
  needs versioning/negotiation or a hard flag-day. A+B deliver ~all of the
  measurable win without any of this; the remaining benefit (one JSON parse
  instead of two on ~37 KB payloads) doesn't justify it today.

## Recommendation

**Do A + B together now** (independent, both small, both client/daemon-local,
no migration concerns): A removes the measured hotspot for every payload
including transcripts; B makes the recurring payload bounded and 13× smaller,
which also shrinks decode/compare costs A doesn't touch. Expected result: the
~2.9%-of-a-core steady-state RPC floor drops to noise (<0.2%), independent of
archive history.

**Queue C as a follow-up** — it's the structural fix for "cost scales with
state size", best done incrementally per delta type, and it benefits from B
landing first (smaller reconciliation payloads while it's in flight).

**Skip D** unless/until a future feature needs big binary payloads or
streaming responses.

Worth fixing opportunistically alongside A/B (same files): the 64 KB recv
buffer is misleading (kernel returns 8 KB — consider `SO_RCVBUF`/larger
socket buffer if we care, though after A it no longer matters), and
`terminal.list`'s `suspendedSnapshot` (45% of that payload) could move to a
fetch-on-demand RPC like archived worktrees did.

## Reproduction

- Live payload sizes: connect to `~/tbd/sock`, send
  `{"method":"worktree.list","params":"{}"}\n`, count bytes/chunks until
  newline (python socket script; chunks observed at 8,192 B).
- Scan cost: standalone Swift bench comparing `contains`-per-chunk vs
  `memchr`-on-new-chunk at 100 KB/475 KB/1 MB (numbers above,
  `swiftc -O`).
- In-app attribution: `sample <TBDApp pid> 10` → frames
  `DaemonClient.sendRaw` → `Sequence.contains` → `Data.Iterator.next`
  (see prior writeup's gzipped captures).
