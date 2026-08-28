# SwiftTerm 2.0 migration: locked terminal access and off-main parsing

TBD pins SwiftTerm at a `main`-branch revision containing upstream's
display-link frame scheduler (`FrameDriver`) and off-main rendering — the fix
for the fixed 16.67 ms paint-scheduling floor TBD measured in the field, and
for the main-thread CPU cost of many streaming terminals (upstream issue
\#658, which matches TBD's symptom). That revision is SwiftTerm 2.0: it moves
parsing and rendering off the main thread, and in consequence removes every
API TBD used to reach the `Terminal` object from a view. This spec decides how
TBD accesses terminal state under the new concurrency model, and where PTY
parsing runs.

## The 2.0 model

Through v1.20.0, everything about a terminal happens on the main thread: the
parser mutates the cell grid (`Terminal`), the renderer reads it, and the
embedding app reads it too, via `TerminalView.getTerminal()`. One thread, no
locking.

In 2.0 the parser runs on the PTY IO thread and the renderer on a Metal
thread, so `Terminal` becomes shared mutable state guarded by a public
`TerminalLock` — a FIFO-fair ticket lock with documented re-entry rules
(`TerminalLock.swift`). Because a raw reference is only safe under that lock,
upstream removed `getTerminal()` and made the view's `terminal` property
internal, offering `Sendable` snapshots for common reads:
`terminalDimensions` (cols/rows) and `terminalStateSnapshot()` (cursor,
viewport, visible row text). Direct access is still sanctioned — upstream's
Kitty graphics integration docs instruct callers to hold
`terminal.terminalLock.withLock { … }` — but only for callers that already
hold a `Terminal` reference.

For a view embedder there is no public way to obtain that reference. The
migration guide claims `TerminalViewDelegate` callbacks pass the `Terminal`;
they pass the `TerminalView`. The view's own `withTerminal` helper and its
`terminal` property are internal, and the view's `TerminalDelegate`
conformance methods (which do receive `source: Terminal`) are public non-open
extension members, so a subclass in another module cannot override them. This
is an upstream oversight — docs and API disagree — not a policy.

## What TBD accesses, and how often

Every TBD access is gesture-frequency — a click, a scroll tick, a theme
change, a spawn — never inside a render or parse loop.

- **Dimensions (cols/rows)** — seven sites across `TerminalPanelView`,
  `LocalPTYTerminalView`, and `TBDTerminalView.gridPosition`. Covered exactly
  by the `terminalDimensions` snapshot.
- **Per-cell buffer reads on click** — `hasOSC8Payload`, `extractFilePath`,
  `extractHyperlinkURL` in `TBDTerminalView`. Read `getLine(row:)`, per-cell
  `getPayload()`/`getCharacter()`. No snapshot carries payloads.
- **Mouse forwarding** — click passthrough to tmux and scroll-wheel
  forwarding: read `mouseMode`, call `encodeButton` and `sendEvent`.
- **Mutations** — `updateFullScreen()` on theme change, `setCursorStyle`.
- **Notification interception** — an override of the view's
  `notify(source:title:body:)`, which 2.0 makes non-overridable.

`hasOSC8Payload` deserves its history: it is a deduplication guard, not the
link-opening feature (PR #113). SwiftTerm opens OSC 8 links itself
(`mouseUp` → `requestOpenLink`); TBD's mouseDown monitor also matches visible
text. When both fired, one click opened two viewer panes. The guard reads the
clicked cell's payload and stands the monitor down so the authoritative
handler owns the click — which means the read must agree with what SwiftTerm's
own mouseUp will see moments later.

## Decisions

### One access mechanism: everything under the lock

All non-snapshot access — per-cell reads, mouse calls, mutations — goes
through the view's `withTerminal { … }` under `terminalLock`. No second
mechanism.

The lock's cost supports this. Uncontended acquisition is a lock/unlock pair
on `NSCondition` — sub-microsecond. Contended, upstream's own doc comment on
the lock bounds the wait: parse batches cost a couple of milliseconds, and
FIFO fairness bounds any waiter at one batch (fairness is called out there as
a correctness requirement, not a nicety). Worst case for a click during
full-blast streaming output is a few milliseconds, once — noise against a
~100 ms gesture budget. The hottest TBD site, scroll-wheel forwarding in tmux
mouse mode, performs the same calls under the same lock as SwiftTerm's own
native mouse-reporting path, so TBD sits on the cost curve upstream designed
for. If the lock is ever suspected in practice, SwiftTerm's built-in
`SWIFTTERM_PROFILE=1` records `.lockWait`/`.lockHold` intervals per owner.

**Rejected: snapshots plus a sink-side open throttle.** Cell reads could use
`terminalStateSnapshot().visibleRows` text, with duplicate opens suppressed by
a canonical-target throttle at the viewer sink. Two defects. First, priority
inversion: the monitor fires on mouseDown, SwiftTerm on mouseUp, so a throttle
keeps whichever open comes first — the text guess — and discards the
authoritative payload open as a duplicate. A link whose payload is a web URL
but whose visible text looks path-like would open the wrong thing. Second, the
dedup only works if the monitor's extracted relative path and the payload's
absolute URL normalize to the same key, an invariant that must hold across
every case forever — the same fragility PR #113 removed. And since mutations
and mouse sends need the locked reference regardless, the hybrid saves no
machinery; it splits access across two mechanisms and adds an invariant.

**Rejected: degrading to text-only detection.** Reintroduces the #113
double-open for links whose visible text is a real path — the case Claude
Code emits constantly.

### Parsing runs on the IO thread

`TerminalView.feed(byteArray:)` parses synchronously on the calling thread,
under `terminalLock` (`TerminalRenderOwner.feed(bytes:)`); there is no
internal worker handoff. So the thread TBD feeds from decides whether parse
cost leaves the main thread — the bulk of the main-thread CPU this bump
exists to shed.

Both coordinators construct
`LocalProcess(delegate: self, dispatchQueue: .main, directDelivery: true)` —
the configuration upstream's own `MacLocalTerminalView` ships.

- **Data path**: `dataReceived` fires on the IO thread and calls `feed`
  right there. `feed` is thread-safe by design (a `Sendable` closure stored
  in locked state; the parse itself under `terminalLock`). The coordinator
  reaches the view through a `nonisolated(unsafe)` stash whose safety
  argument is precisely that documented thread-safety. The panel's
  viewer-MRU signal keeps its existing `DispatchQueue.main.async` hop. Both
  coordinators already treated the delegate queue as unspecified and hopped
  explicitly, so this is a small, local change.
- **Exit path**: `dispatchQueue: .main` still governs the
  `DispatchSourceProcess` exit monitor (`LocalProcess` creates it with
  `queue: dispatchQueue`, unaffected by `directDelivery`), so exit events
  arrive on main exactly as before. `ChildReaper` and
  `ChildExitObservation` code are untouched; the serialization note in
  `ChildReaper.swift` changes its first reason from "`LocalProcess.init`
  defaults its queue to main" to "both call sites pass `.main` explicitly —
  keep it that way".
- **Conformance**: the `LocalProcessDelegate` methods become `nonisolated`.
  `processTerminated` hops to main internally (it already arrives there).
  `getWindowSize` keeps `MainActor.assumeIsolated`: its only callers are
  `startProcess` paths, which TBD invokes from main; its `terminal.cols`
  reads become `terminalDimensions`.

**Rejected: keeping delivery and parse on main.** Smallest possible diff, and
`FrameDriver` still removes the 16.67 ms floor — but every streaming
terminal's parse cost stays on the main thread, forfeiting the larger half of
the win.

### The reference comes from a one-commit fork, offered upstream

A fork of `migueldeicaza/SwiftTerm`, branched from the pinned `main` revision,
carries one commit: make the view's `withTerminal<T>((Terminal) throws -> T)`
helper public. The helper already takes `terminalLock` itself, so TBD adds no
lock code; if inspection shows it expects the lock already held, the commit
adds a public locking equivalent instead. The same commit goes upstream as a
PR, together with the migration-doc correction (the guide names an access
route for view embedders that does not exist). `Package.swift` pins the fork
by revision; the comment block states the patch, the reason, and the exit
criterion — upstream merges an equivalent accessor, TBD re-pins to upstream,
the fork is deleted. Until then every bump costs one rebase of one commit.

**Rejected: waiting for upstream.** No fork to carry, but blocks the perf
bump on an unbounded review cycle while the performance work is active.

**Rejected: reflection (`Mirror`) on the view's internals.** Works today,
breaks silently on any upstream rename.

## Site map

- **Dimensions → `terminalDimensions`, no lock** — `TerminalPanelView`
  parked-snapshot compose, initial `TIOCSWINSZ`, control-mode resize,
  `getWindowSize`; `LocalPTYTerminalView` spawn-time size and
  `getWindowSize`; `TBDTerminalView.gridPosition`.
- **Per-cell reads → `withTerminal` copy-out** — `hasOSC8Payload`,
  `extractFilePath`, `extractHyperlinkURL`. Byte-identical behavior; the
  #113 guard reads the same cells under the same lock as SwiftTerm's click
  path.
- **Mouse → `withTerminal`** — click passthrough (`mouseMode`,
  `encodeButton`, `sendEvent`) and scroll-wheel forwarding. `sendEvent`
  under the lock matches upstream's own mouseUp; the reply path is
  marshalled to main asynchronously (`TerminalInputMainActorDelivery`), so
  no synchronous re-entry.
- **Mutations → `withTerminal`** — theme repaint (`updateFullScreen`) and
  `setCursorStyle`. First verify whether 2.0's rewritten render pipeline
  made `installColors` invalidate existing cells itself; if so, delete the
  `updateFullScreen` workaround instead of porting it.
- **Notifications** — replace the `notify` override with
  `withTerminal { $0.registerOscHandler(code: 9) { … } }` at view setup,
  routing into `onNotification` with the same not-focused guard. If OSC 9
  turns out to bypass the handler table, the fallback is one more `open` in
  the fork commit.

Lock discipline, enforced by convention and a comment block at the one place
TBD touches the lock: bodies copy values out and return — never store the
`Terminal`, never call view APIs from inside, never re-enter.

## Gating

The repo rule requires a default-off flag when wholesale-replacing a
load-bearing rendering path. A dependency pin cannot be flagged — two
SwiftTerm revisions cannot coexist in one build — so this ships unflagged,
with that stated explicitly in the PR description per the rule's requirement
to answer the question rather than skip it. Standing in for the soak: the
existing `useMetalTerminalRenderer` UserDefaults flag still gates the
Metal-versus-CoreGraphics backend choice at the new revision (verify its
mapping to upstream's `usesMetalLayerSurface` at implementation); dogfooding
on the development fleet is the soak; and the before/after performance
comparison runs on the separately validated key-to-paint harness before the
merge is judged.

## Testing

- Full suite via `scripts/test.sh`; everything currently green stays green.
- New: a round-trip test feeding OSC 8 bytes through the production `feed`
  path and asserting `hasOSC8Payload`/`extractHyperlinkURL` see the payload
  — constructed through the production path, not hand-built state — and a
  test that `dataReceived` invoked from a non-main queue feeds without crash
  or data loss.
- Manual live checklist in the PR (this class of bug is live-only): OSC 8
  cmd-click opens exactly one pane; plain-path click; scroll inside tmux
  mouse mode; theme switch repaints previously drawn cells; cursor style;
  resize; session exit leaves no `<defunct>` children.
- Out of scope: performance measurement (separate harness), and
  `viewWillDraw`-based terminal diagnostics going quiet — expected under
  off-main rendering, noted in the `Package.swift` comment block.

## Risks and open verifications

- `installColors` may now invalidate drawn cells, making the
  `updateFullScreen` workaround deletable — verify at implementation.
- OSC 9 routing through the handler table — verify; fallback named above.
- Upstream churn on these internals is high; until the accessor PR merges,
  each pin bump costs one fork rebase.
