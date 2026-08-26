# Migrating TBDApp's observable state to `@Observable`

## Why

`AppState` is an `ObservableObject` carrying 109 `@Published` properties, consumed
through `@EnvironmentObject` by 106 binding sites across 69 view files. Under
`ObservableObject`, `objectWillChange` is object-wide: a write to any one of those
109 properties invalidates every view observing the object, whether or not that
view reads the property that changed. Readership is irrelevant to invalidation —
only writer frequency matters.

The cost is measurable. Sampling the running app for 20 seconds while a terminal
is scrolled:

- **TBDApp consumes 12.29 s of CPU** — 61% of a core — against 4.35 s over an
  equivalent quiet window.
- **The main thread is 50.3% busy** (3,921 of 7,801 samples), against 18.7% quiet.
- **Roughly half that busy time, 1,925 samples, is SwiftUI view-graph update** —
  `NSHostingView.beginTransaction` → `GraphHost.flushTransactions` →
  `AG::Subgraph::update` → `ViewBodyAccessor.updateBody`.

The bodies re-evaluating are the sidebar, none of which depend on the terminal
being scrolled: `RepoSectionView` at 420 samples, `WorktreeRowView` at 240,
`TabBarItem` at 139, `PanePlaceholder` at 47. `TerminalView.draw` — the view that
actually changed — accounts for 157.

Normalized per 1,000 main-thread samples, `RepoSectionView.body` evaluates 6.6
times when quiet and 53.8 times while scrolling: an eightfold increase in
re-evaluation of a view whose displayed content did not change.

`@Observable` replaces object-wide notification with per-property dependency
tracking. A view re-evaluates only when a property it actually read changes.

### What this evidence does not establish

The specific `@Published` write driving the scroll-time increase was not isolated.
Writer-frame counts sampled during scrolling and during quiet windows are
comparable, so the eightfold jump in `RepoSectionView.body` has no identified
write behind it.

This design therefore rests on the structural argument — object-wide invalidation
is wrong at any writer frequency — and not on a demonstrated causal chain. The
measured numbers above bound the size of the prize; they do not prove that
per-property tracking captures all of it. The acceptance gate below exists to
settle that empirically rather than by assertion.

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

Converting only `AppState` was considered and rejected: it leaves a mixed
paradigm, and `AppState` holds and bridges `AppearanceSettings` with Combine, so
the seam has to be resolved either way.

Two facts make the conversion tractable. The package targets macOS 15, so
Observation is available. And the view layer contains **no Combine
`$property` publisher usage at all** — no `.sink`, `.assign`, `debounce`, or
`combineLatest` over a `@Published` projection — so the usual blocking dependency
on `ObservableObject`'s publisher semantics does not exist here. The exceptions
are the explicit `objectWillChange` subscribers treated as hazard (a) below.

## Mechanical shape

- `@Published var x` becomes a plain stored property; the macro supplies tracking.
- `@EnvironmentObject var appState: AppState` becomes
  `@Environment(AppState.self) var appState`.
- `.environmentObject(x)` becomes `.environment(x)` — 29 sites in `Sources`, 4 in
  `Tests`.
- `@StateObject` becomes `@State` (13 sites); `@ObservedObject` becomes a plain
  `let` (8 sites).
- Any view needing `$appState.foo` declares `@Bindable`.
- `AppState` remains a `@MainActor final class`.

## Hazards

**(a) AppKit consumers of `objectWillChange`.** `TBDTerminalView` is an `NSView`
subclass that subscribes to `AppearanceSettings.objectWillChange` through a
Combine sink and reapplies theme settings on every fire. `@Observable` publishes
no such stream. The replacement is `withObservationTracking(_:onChange:)`, whose
`onChange` is **one-shot**: it must be re-armed after each fire or the view stops
responding to theme changes permanently. The existing hop to the main queue must
be kept — `onChange` fires in `willSet` position, before the new value is
readable, exactly as `objectWillChange` did.

This failure is silent and no existing test covers it, so the sibling PR that
converts `AppearanceSettings` carries a test that changes a setting and asserts
the terminal reapplies it more than once. Re-arming correctly is the whole point;
a single-fire test would pass against the broken implementation.

**(b) `didSet`-driven memo invalidation.** `AppState` serves `children(of:)` and
`allWorktrees` from memoized caches invalidated by `worktrees.didSet` and
`scratchWorktrees.didSet`. These are load-bearing: recomputing `children(of:)` per
render pass measured 79.5 ms. `didSet` continues to work on plain stored
properties under `@Observable`, so the caches survive the conversion — but the
implementation must verify this rather than assume it, because a silent
regression here restores an O(N²) render pass.

Both caches are deliberately *not* observable storage. A write to observable state
from inside a view body traps with "Modifying state during view update", and these
caches fill lazily from their getters, which run inside body evaluation. They stay
plain stored properties after the conversion.

**(c) Bindings.** Every site passing `$appState.foo` requires `@Bindable` on the
declaring view. These surface as compile errors, so the risk is effort rather than
silent breakage.

## Landing

**PR 1 converts `AppState` alone.** This step is atomic by necessity: the class
declaration and all 106 binding sites must flip together, spanning roughly 69
source and 6 test files. It carries the entire measured win, and the acceptance
gate below applies to it.

**PRs 2 through 9 convert one sibling observable each**, independently green and
independently revertable. `AppearanceSettings` is its own PR because it owns
hazard (a).

PR 1 modifies `RepoSectionView.swift` at the `@EnvironmentObject` declaration, and
so rebases over the separate formatter-caching fix in that same file, which is
confined to the `matchedRemoteSessions` and `parsedCreatedAt` regions.

## Acceptance

**A discriminating test.** Mutate an `AppState` property that a given view does not
read, and assert that view's body does not re-evaluate, counting evaluations in a
test host. This test fails against `ObservableObject`, where every write
invalidates every observer, and passes under per-property tracking. A test that
merely asserts the view still renders correctly would pass both before and after
and would guard nothing.

**A measured gate.** Re-run the scroll profile and compare against the baseline
recorded here: 12.29 s of CPU per 20 s window, 50.3% main-thread busy, and
`RepoSectionView.body` at 53.8 evaluations per 1,000 main-thread samples. The
migration is accepted on a material reduction in the SwiftUI view-graph share of
main-thread busy time. Because the driving write was never isolated, a null result
is a real possible outcome and must be reported as one rather than absorbed.

**The existing suite green**, with the 6 test files' injection sites updated, run
through `scripts/test.sh`.

## Waivers

**This change ships without a feature flag.** TBD's convention is that
wholesale-replacing a load-bearing path lands behind a default-off flag, and the
view layer's observation mechanism qualifies. The waiver here is forced rather
than chosen: the selection between `@EnvironmentObject` and `@Environment` is made
at compile time, so a runtime flag would require every affected view body to exist
twice. The revert path is the branch itself plus `scripts/restart.sh`, which the
author exercises continuously by dogfooding the app.

**This supersedes an earlier decision to defer `@Observable`** pending cheaper
measures. That deferral rested on the migration touching every view file while
cheaper options remained untried. The judgment recorded here is that object-wide
invalidation is a defect in the observation model rather than a tuning parameter,
and is worth correcting on its own terms.

The cheaper measure that deferral named — auditing frequent writers for equality
guards sitting in `didSet` rather than at the assignment site — remains valid and
is **not** retired by this migration. `@Published` fires on assignment rather than
on change, so a guard inside `didSet` suppresses downstream work but not the
invalidation. `applyTerminalActivityDelta` is a live instance: it assigns
`activityState` unconditionally and then calls `removeValue` on two further
observable dictionaries, firing up to three notifications for a delta that may
carry no change at all. Per-property tracking narrows who those notifications
reach; it does not stop them being sent. That audit is worth doing independently.

## Rejected alternatives

**Converting `AppState` only.** Smallest diff, but leaves two idioms in the
codebase indefinitely and does not resolve the `AppState`-to-`AppearanceSettings`
Combine bridge, which has to be addressed regardless.

**A single pull request for all nine classes.** One review and one revert point,
but a diff of roughly 75 files in which a subtle observation defect in any single
view is expensive to bisect, and where reverting discards eight easy conversions
along with the one hard one.

**Converting the siblings before `AppState`.** Establishes the pattern on low-risk
classes first, but defers the measured win behind eight PRs that deliver none of
it.

**Shipping without the measured gate.** Per-property tracking is correct by
construction, so the argument runs that measurement is ceremony. Rejected because
the write driving the observed churn was never identified: without a
before-and-after number, a migration touching 75 files would carry no evidence
that it addressed the symptom that motivated it.
