# Migrating TBDApp's observable state to `@Observable`

## Why

`AppState` is an `ObservableObject` carrying 109 `@Published` properties, consumed
through `@EnvironmentObject` by 106 binding sites across 69 view files. Under
`ObservableObject`, `objectWillChange` is object-wide: a write to any one of those
109 properties invalidates every view observing the object, whether or not that
view reads the property that changed. Readership is irrelevant to invalidation —
only writer frequency matters.

The waste is measurable, and it is the largest single consumer of the main
thread while a terminal scrolls. Sampling the app across windows **verified to
contain actual scrolling** — each window scored for scroll-event frames and for
terminal draw volume, with windows failing that check discarded rather than
averaged in — SwiftUI view-graph re-evaluation (`GraphHost.flushTransactions`)
accounts for **25.1% and 18.1%** of main-thread samples in the two validated
windows, against **3.7%** in a quiet baseline. Over the same windows the
terminal's own draw subtree accounts for 20.7% and 11.6%, against 4.0% quiet.

Named contributors inside that flush, as a share of the whole main thread:
`RepoSectionView.body` at 3.7% and 3.0% (0.7% quiet), `WorktreeRowView.body` at
1.2% and 1.7% (0.4% quiet), with `TabBarItem` and `PanePlaceholder` re-evaluating
alongside them. None of these display anything new while a terminal scrolls. The
main thread runs 45% to 64% busy across the windows, with TBDApp near 47% of a
core.

Counts in a `sample` call graph are inclusive of children, so a symbol and its
own callees must never be summed together — doing so double-counts the subtree.
The figures above are top-level subtree totals.

That validation step is not incidental. An unvalidated sampling window is
indistinguishable from a mistimed one, and a window that captured no scrolling
looks like a quiet baseline with a misleading label. Every number in this
document comes from a window that passed the check.

`@Observable` replaces object-wide notification with per-property dependency
tracking. A view re-evaluates only when a property it actually read changes.

### What this migration does not fix

**Wheel-event amplification sits upstream of this cost and should be fixed
first.** TBD intercepts every scroll wheel event in a local `NSEvent` monitor
and emits `max(1, Int(abs(deltaY)))` SGR mouse reports per event
(`Sources/TBDApp/Terminal/TerminalPanelView.swift:794-797`), with no
momentum-phase filter and no fractional-delta accumulator, so a sub-line delta
still sends a full report and a trackpad flick's momentum tail delivers events
at 60-120 Hz. The inner terminal application repaints per report, and that
output streams back through the PTY into a full-viewport redraw. Scrolling
manufactures the output flood that both the draw path and this graph churn then
pay for — and because the SwiftUI flush runs as a run-loop observer, its
*frequency* scales with how often the run loop turns. Bounding the report rate
shrinks the feed, the redraws, and the flush count together.

**The terminal's own draw cost is a separate, comparable expense.** SwiftTerm
rebuilds an `NSAttributedString` for every visible row on every redraw
(`drawTerminalContents` → `buildAttributedString`, measured at 12.8% and 7.5% of
the main thread — roughly two-thirds of the draw subtree). It lives in a pinned
upstream dependency and is tracked separately.

So this migration addresses the largest single main-thread consumer during
scroll, but it is one of three independent costs and not the first one to land.
It is justified on the structural argument — object-wide invalidation across 106
binding sites is wrong at any writer frequency, and the measured five-to-sevenfold
rise in graph flush is that defect made visible — rather than as the remedy for a
slow-feeling terminal on its own.

### What this evidence does not establish

The specific `@Published` write driving the scroll-time rise is not isolated, so
the size of the available win is bounded above by the numbers here rather than
predicted by them. Two ways it could shrink further:

- **The sidebar reads terminal state.** Rows render activity dots and status
  chips from `terminals` and `notifications`. If the writes firing during a
  scroll are terminal-shaped, per-property tracking still re-evaluates the
  sidebar, because the sidebar legitimately reads those properties. The win then
  comes only from the views that *don't* read them.
- **The driver may not be a write-rate change at all.** One consistent
  explanation is runloop coalescing: when quiet, several `objectWillChange` fires
  within one runloop turn collapse into a single graph flush; while scrolling,
  the runloop spins at display rate, so each fire lands in its own flush. If that
  is the mechanism, per-property tracking helps exactly to the extent the firing
  property is one the sidebar does not read.

The acceptance gate below settles this empirically rather than by assertion, and
the diagnostic capture in "Acceptance" makes a null result interpretable instead
of merely disappointing.

## Scope

All nine `ObservableObject` classes in `Sources/TBDApp` convert to `@Observable`:

- **`AppState`** — `AppState.swift`, the object this design is about
- **`AppearanceSettings`** — `Terminal/AppearanceSettings.swift`
- **`ThemeStore`** — `Terminal/ThemeStore.swift`
- **`TranscriptOverlayCoordinator`** — `Panes/Transcript/TranscriptOverlayCoordinator.swift`
- **`WebviewState`** — `Panes/WebviewPaneView.swift`
- **`HoverMenuModel`** — `Sidebar/HoverMenuModel.swift`
- **`TerminalThemeEditorViewModel`** — `Settings/TerminalThemeEditorViewModel.swift`
- **`QueuedPromptTarget`** — `Worktree/QueuedPromptModal.swift`
- **`JumpMenuViewModel`** — `JumpMenu/JumpMenuViewModel.swift`

Two facts make the conversion tractable. The package targets macOS 15, so
Observation is available. And the **view layer** contains no Combine `$property`
publisher usage — no `.sink`, `.assign`, `debounce`, or `combineLatest` over a
`@Published` projection in any view file. The app's Combine dependencies on these
nine classes total exactly three non-view sites, enumerated in hazard (a); each
one must be rebuilt on Observation primitives by the PR that converts the class
it subscribes to.

## Mechanical shape

- `@Published var x` becomes a plain stored property; the macro supplies tracking.
- `@EnvironmentObject var appState: AppState` becomes
  `@Environment(AppState.self) var appState`. Both forms crash at runtime when
  the object was never injected, so the failure mode does not change.
- `.environmentObject(x)` becomes `.environment(x)` — 29 sites in `Sources`, 4 in
  `Tests`, plus the manual re-injection sites for detached and nested hosting.
- `@StateObject` becomes `@State` (13 sites) — carries hazard (c).
- `@ObservedObject` becomes a plain `let` (8 sites) — two of them sit inside
  `Commands` scenes, flagged in hazard (d).
- A view needing `$appState.foo` declares a local `@Bindable var appState =
  appState` inside `body` — `@Bindable` cannot be combined with `@Environment`
  in one declaration.
- `AppState` remains a `@MainActor final class`; that combination is the
  sanctioned Swift 6 shape and has no known interop issue with the macro.

**The macro inverts the tracking default, and that inversion is an audit, not a
find-replace.** Under `ObservableObject`, a property participates in invalidation
only if someone wrote `@Published`; under `@Observable`, *every* stored property
is tracked unless someone writes `@ObservationIgnored`. `AppState` carries on the
order of sixty non-`@Published` stored properties whose unpublished status is a
deliberate, documented decision — memo caches, ordering watermarks
(`terminalPresentationOrderObservedAt`, `terminalSessionOrderObservedAt`, whose
doc comments exist precisely to keep a same-value poll from publishing), sequence
counters, in-flight `Task` handles, `AnyCancellable`s. A naive conversion
silently flips every one of those decisions and re-introduces exactly the churn
the comments prohibit. PR 1 therefore includes a property-by-property pass over
`AppState`'s stored properties: each currently-unpublished one gets
`@ObservationIgnored` unless there is a positive reason to track it.

Two compiler-enforced corners of the same pass, verified against the current
toolchain:

- **`lazy var` does not compile under `@Observable`** — the macro's expansion
  rejects it. `AppState`'s ~27 `lazy var` injection seams (`worktreeCreator`,
  `tabStatesFetcher`, and kin) all become `@ObservationIgnored lazy var`, which
  compiles and preserves their behavior. Tests reassigning the seams are
  unaffected: nothing observes them.
- **`weak var` compiles and is tracked** — `AppearanceSettings.themeStore` needs
  no annotation.

`didSet`/`willSet` on stored properties continue to fire under the macro: the
expansion attaches the observers to the synthesized backing storage, so
`worktrees.didSet` keeps invalidating the memo caches. This is confirmed both by
the macro's documented expansion and by a compiled check against the current
toolchain — not assumed.

## Hazards

**(a) Combine consumers of the converting classes.** Three sites, each losing its
publisher when its class converts:

- **`TBDTerminalView`** (`Terminal/TBDTerminalView.swift`) — an `NSView` subclass
  subscribing to `AppearanceSettings.objectWillChange` to reapply font, colors,
  and cursor on any settings change.
- **`AppearanceBroadcastDebouncer`** (`Terminal/AppearanceBroadcastDebouncer.swift`)
  — subscribes `appearance.$schemeID` through `dropFirst().removeDuplicates()`,
  then debounces on the injected clock before broadcasting COLORFGBG to tmux.
- **`AppState.setupAppearanceSubscriptions`** — subscribes `themeStore.$userThemes`
  (also with `dropFirst()`) to reconcile the active scheme when a theme file is
  added, edited, or deleted on disk.

The replacement primitive is `withObservationTracking(_:onChange:)`, and it is
sharper-edged than the publishers it replaces:

- **`onChange` is one-shot.** It must re-arm after every fire — the canonical
  shape is a method that arms the tracking, and an `onChange` that hops to the
  main actor, does the work, and calls the method again. A missed re-arm fails
  silently: the consumer simply stops responding, permanently.
- **`onChange` fires in `willSet` position.** The new value is not yet readable
  inside the callback. The hop to the main queue that `TBDTerminalView` already
  performs must be kept; by the time the hopped block runs, the write has
  committed.
- **There is no cancellation token.** The pattern relies on `[weak self]` in both
  closures; when the consumer deallocates, the next fire is a no-op and the
  re-arm chain ends. An armed closure that strongly captures `self` is a leak
  with no way to break it.
- **Changes between fire and re-arm are not queued.** The mitigation is to make
  every fire re-read all relevant state rather than diff — which `applyAll()`
  already does, and which the debouncer's trailing-edge design also tolerates.
- **Observation fires on every write, not on every change** (a same-value
  assignment may be suppressed for `Equatable` properties on newer toolchains,
  but that optimization is not something to build a contract on). The debouncer's
  `removeDuplicates()` must therefore be replaced by an explicit last-seen
  comparison, or same-value `schemeID` writes start scheduling broadcasts.
  Conversely `dropFirst()` needs no replacement: observation has no
  replay-at-subscription, so its job disappears.

The debouncer's clock-seam contract is already covered by a `TestClock`-driven
test; that test must survive the rewiring unchanged. The terminal-view consumer
gains the re-arm test described under "Acceptance" — a single-fire test would
pass against the broken one-shot implementation, so the test must assert two
sequential changes each get applied.

macOS 26's `Observations` AsyncSequence (SE-0475) would replace the re-arm dance
wholesale, and AppKit's automatic observation tracking
(`NSObservationTrackingEnabled`) exists on macOS 15 but only covers reads made
inside layout methods — neither fits a macOS 15 target and a reapply path that
is not layout-shaped. The manual re-arm loop is the pattern until the deployment
target moves; see "Rejected alternatives".

**(b) Memoized caches: annotation and a dependency-loss trap.** `AppState` serves
`children(of:)` and `allWorktrees` from memoized caches (`childrenIndexCache`,
`allWorktreesCache`) invalidated by `worktrees.didSet` and
`scratchWorktrees.didSet`. These are load-bearing: recomputing `children(of:)`
per render pass measured 79.5 ms. Two distinct requirements:

- **The caches must be `@ObservationIgnored`.** They fill lazily from getters
  that run inside body evaluation; if the macro tracked them, that fill would be
  an observable mutation during view update — the same "Modifying state during
  view update" fault their doc comment already guards against, plus a
  self-invalidation loop.
- **A warm cache severs the dependency, and that is a stale-UI bug, not a
  performance detail.** SwiftUI rebuilds a view's dependency set on every body
  evaluation from the tracked properties that evaluation actually read. A body
  evaluation served entirely from the warm cache reads no tracked property — so
  a view re-evaluated for an unrelated reason (selection change, hover) while
  the cache is warm *drops* its dependency on `worktrees`, and the next
  `worktrees` write does not invalidate it. The sidebar goes stale until some
  other property it reads happens to change. This is not hypothetical: it was
  reproduced with a compiled check against the current toolchain (cold-cache
  tracker fires on a `worktrees` write; warm-cache tracker does not). Under
  `ObservableObject` the memo was safe because invalidation was object-wide;
  per-property tracking removes the safety net the memo was leaning on.

  The fix is one line per getter: touch the tracked source unconditionally
  before consulting the cache — `childrenIndex()` reads `worktrees`,
  `allWorktrees` reads both `worktrees` and `scratchWorktrees` — so every
  evaluation re-registers the dependency. The read costs a retain, not a copy.
  A discriminating test pins this (see "Acceptance"): warm the cache through an
  unrelated re-evaluation, then mutate `worktrees` and assert the view updated.

**(c) `@StateObject` → `@State` is not behaviorally neutral.** A `@State`
default-value expression re-runs on every memberwise init of the view struct —
`@State` preserves the stored value, not the expression — and this repo has
already been bitten by exactly that (the `AgentExecutableAvailability.detect()`
regression fixed in the prior render-cost pass). There is additionally a
long-open SwiftUI defect report about `@State`-wrapped `@Observable` objects
re-initializing more often than `@StateObject` did. The 13 `@StateObject` sites
must each be audited for construction cost before the swap: `AppState`,
`AppearanceSettings`, and `TranscriptOverlayCoordinator` are constructed once at
the app root (their inits do real work — `UserDefaults` reads, subscription
setup — so verify construction frequency in the converted app rather than
assuming it); `HoverMenuModel`, `WebviewState`, `TerminalThemeEditorViewModel`
instances are per-row or per-pane and their inits must be — and stay — trivial.

**(d) Reads outside `body` do not register dependencies.** Observation tracks
only what the body evaluation itself reads. A property read inside an escaping
closure that runs later — a button action, `onAppear`, a `.task`, an `NSMenu`
construction callback — establishes no dependency. Under `ObservableObject`,
views could *appear* to depend on such reads because any write anywhere
re-evaluated them; per-property tracking withdraws that accidental subsidy, and
the view silently stops updating. Two known-delicate corners get explicit
attention in review: the `Commands` scenes (`NightwatchStatusItem`,
`ModelProfileMenu`, `TBDCommands`), whose doc comments already record that
`Commands` bodies observe unreliably and which wrap content in nested `View`s as
the workaround — that workaround must be re-verified under Observation — and any
container that receives `{ appState.foo }` closures rather than values. The
conversion PRs treat "view reads the object only inside closures" as a review
checklist item, not something the compiler surfaces.

**(e) Bindings.** Every site passing `$appState.foo` requires the local
`@Bindable` shadow on the declaring view. These surface as compile errors, so
the risk is effort rather than silent breakage.

## Landing

**PR 1 converts `AppState` alone.** This step is atomic by necessity: the class
declaration and all 106 binding sites must flip together, spanning roughly 69
source and 6 test files. It carries the entire measured win, the
`@ObservationIgnored` audit, the cache-getter dependency fix from hazard (b),
and the acceptance gate below.

Mixed-mode operation during the stack is supported and expected: the root scenes
inject `.environment(appState)` alongside `.environmentObject(appearance)` and
`.environmentObject(overlayCoordinator)` until those classes convert, and the
Combine bridges in hazard (a) keep working until the PR that converts the class
each one subscribes to. A view reading an `ObservableObject` through a converted
`@Observable` parent still needs its own subscription to the child — the chain
of automatic tracking only spans `@Observable` types — which is the existing
shape (each class is injected and observed independently) and so needs no
transitional shim.

**PRs 2 through 9 convert one sibling observable each**, independently green and
independently revertable. `AppearanceSettings` is its own PR and carries the
`TBDTerminalView` re-arm and the `AppearanceBroadcastDebouncer` rewiring;
`ThemeStore`'s PR carries the `$userThemes` reconcile bridge. The remaining six
are mechanical.

PR 1 modifies `RepoSectionView.swift` at the `@EnvironmentObject` declaration,
and so rebases over the separate formatter-caching fix (#714) confined to the
`matchedRemoteSessions` and `parsedCreatedAt` regions of that file.

## Acceptance

**A diagnostic capture before PR 1 lands.** One dogfood session with temporary,
uncommitted instrumentation — a counter on `AppState.objectWillChange` fires per
second, and `Self._printChanges()` in the four hot bodies — run during the same
scroll workload as the baseline. This does not gate the migration; it exists so
the after-measurement is interpretable. It names the property (or properties)
firing during scroll, which tells us in advance whether the sidebar reads them —
the difference between expecting a large win and expecting a null result — and
it feeds the assignment-site guard audit that remains open independently of this
migration.

**Discriminating tests** — each one fails against today's code or against the
naive conversion, per the repo rule that plan-authored tests must discriminate:

- **Unrelated-write test (PR 1).** Host a view that reads one `AppState`
  property in an `NSHostingView` inside a borderless window, pump the runloop in
  bounded slices, count body evaluations via a counter bumped in `body`. Mutate
  a property the view does not read; assert the count did not move; then mutate
  the property it does read and assert the count moved (the positive control
  that proves the harness detects re-evaluation at all). Assert on
  before/after comparisons, never exact counts — SwiftUI may legitimately
  double-evaluate. This fails under `ObservableObject`, where any write
  invalidates every observer. The repo already hosts SwiftUI in unit tests this
  way (`TableTranscriptHarness`, `WorkbenchSnapshotTests`), so the harness is
  precedented, not novel. Run it against the production view shapes
  (`RepoSectionView`, `WorktreeRowView`), not only a synthetic probe: the
  read-set as actually composed — computed properties, child composition — is
  exactly what a model-layer `withObservationTracking` assertion cannot see.
- **Cache-dependency test (PR 1).** Evaluate a sidebar view cold (registers the
  `worktrees` dependency and warms the cache), force a re-evaluation via an
  unrelated property the view reads (serving `children(of:)` from the warm
  cache), then mutate `worktrees` and assert the view re-evaluated and shows
  the new row. The naive conversion fails this; the getter-touch fix in hazard
  (b) passes it.
- **Re-arm test (AppearanceSettings PR).** Change a setting twice, sequentially,
  asserting the terminal reapplied after each change. A single-fire test passes
  against the broken one-shot implementation; two sequential fires are the
  discriminator.

**A measured gate, over validated windows.** Re-run the scroll profile and
compare against the baseline recorded here: `GraphHost.flushTransactions` at
25.1% and 18.1% of main-thread samples while scrolling against 3.7% quiet, with
`RepoSectionView.body` at 3.7% and 3.0% against 0.7%, the main thread 45% to 64%
busy, and TBDApp near 47% of a core. The graph-flush share is the primary
number; the named view bodies are how a regression is localized.

Compare subtree totals, not summed symbol occurrences — `sample` counts are
inclusive of children.

Every window on both sides of the comparison must pass the same validation the
baseline did — scored for scroll-event frames (`scrollWheel`, `gridPosition`)
and for `TerminalView.draw` volume well above the quiet baseline, with failing
windows discarded rather than averaged in. Take several short windows rather
than one long one, so a mistimed window announces itself instead of becoming a
finding. A quiet baseline must also be genuinely quiet: a session in which
tooling is running commands streams output into the terminal and drives redraws,
which inflates the very counters under comparison.

The migration is accepted on a material reduction in the graph-flush share of
main-thread samples. Because the driving write was never isolated, a null result
is a real possible outcome and must be reported as one rather than absorbed —
and the diagnostic capture above is what turns a null result into a finding
("the firing property is one the sidebar reads") rather than a mystery.

Interpret the result against the other two costs rather than in isolation. Graph
flush is the largest single main-thread consumer during scroll, but the terminal
draw subtree is comparable and the wheel-report amplification upstream drives
both. If the amplification fix lands first, this baseline must be re-measured
before the gate is applied: a lower report rate reduces run-loop turns, which
reduces flush frequency on its own and would otherwise be credited to this
migration.

**The existing suite green**, with the 6 test files' injection sites updated, run
through `scripts/test.sh`.

## Waivers

**This change ships without a feature flag.** TBD's convention is that
wholesale-replacing a load-bearing path lands behind a default-off flag, and the
view layer's observation mechanism qualifies. The waiver here is forced rather
than chosen: the selection between `@EnvironmentObject` and `@Environment` is
made at compile time, so a runtime flag would require every affected view body
to exist twice. The revert path is the branch itself plus `scripts/restart.sh`,
which the author exercises continuously by dogfooding the app; the stacked
landing keeps each sibling conversion independently revertable.

**The assignment-site guard audit is not retired by this migration.** Observation
fires on write, not on change (the `Equatable` suppression on newer toolchains
notwithstanding), so a frequent writer that assigns equal values still notifies
every reader of that property. `applyTerminalActivityDelta` is a live instance:
its non-Codex branch assigns `terminals[...][idx].activityState` unconditionally
— one object-wide fire today for a delta that may carry no change — and mutates
the two untracked watermark dictionaries beside it. Per-property tracking narrows
who a redundant notification reaches; only an assignment-site guard stops it
being sent. That audit remains open as independent work, and the diagnostic
capture above gives it a target list.

## Rejected alternatives

**Deferring the migration until cheaper measures are exhausted.** The tracking
issue (#667) deliberately deferred `@Observable` behind an assignment-site guard
audit, on the grounds that the migration touches every view file while cheaper
options remained untried. The judgment recorded here is that object-wide
invalidation is a defect in the observation model rather than a tuning
parameter: guards shrink the number of redundant fires, but every legitimate
fire still invalidates all 106 binding sites, so guard work alone converges on
"every write is justified and every view still pays for each one." The two
measures also compose rather than compete — the audit stays open above — and
deferral would leave the 79.5 ms-class memo caches permanently load-bearing
against an invalidation model that makes them necessary.

**Converting `AppState` only.** Smallest diff, but leaves two idioms in the
codebase indefinitely and leaves all three Combine bridges in hazard (a)
unresolved, two of which sit on classes other than `AppState`.

**A single pull request for all nine classes.** One review and one revert point,
but a diff of roughly 75 files in which a subtle observation defect in any
single view is expensive to bisect, and where reverting discards eight easy
conversions along with the one hard one.

**Converting the siblings before `AppState`.** Establishes the pattern on
low-risk classes first, but defers the measured win behind eight PRs that
deliver none of it.

**Shipping without the measured gate.** Per-property tracking is correct by
construction, so the argument runs that measurement is ceremony. Rejected
because the write driving the observed churn was never identified: without a
before-and-after number, a migration touching 75 files would carry no evidence
that it addressed the symptom that motivated it.

**Waiting for macOS 26 Observation APIs.** `Observations` (SE-0475) and
continuous tracking would eliminate hazard (a)'s re-arm loop, and AppKit's
automatic tracking would cover layout-shaped consumers — but both are gated on a
deployment-target move to macOS 26, which is not on the table for a symptom
users feel today. Third-party backports of those primitives were likewise
rejected: one well-audited dependency is not worth adopting to avoid a
twenty-line re-arm pattern with local tests.
