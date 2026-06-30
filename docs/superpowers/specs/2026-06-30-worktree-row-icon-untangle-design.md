# Worktree Row Icon Untangle — Design

**Date:** 2026-06-30
**Status:** Approved (design), pending implementation plan

## Problem

The per-worktree sidebar row has a single icon slot resolved by a strict
priority chain (`RowStatusIndicator.resolve`). That one slot is asked to
express three orthogonal axes at once:

1. **Lifecycle** — creating, suspended
2. **Activity / attention** — working, plus four notification severities
3. **PR status** — eight states

Because they share one slot, a higher-priority axis *hides* the others. The
most painful consequence: **PR status is lowest priority, so it disappears
whenever the agent is working, suspended, or has an unread notification** —
even though the PR icon is the most useful thing to click. On top of that,
four differently-colored notification dots (red/orange/green/blue) require the
user to memorize a color→meaning map.

## Goals

- **PR icon is always visible and clickable**, independent of all other state.
- **Remove all colored notification dots** — no color-memorization.
- Replace the dots with self-explanatory treatments: bold name, or a glyph
  suffix whose *shape* carries the meaning.
- Replace the static `asterisk` working glyph with a **dancing-dots typing
  animation** that does **not** reintroduce the CPU cost that got the previous
  `ProgressView` spinner removed (#266).
- Keep the suspended indicator's glyph and color exactly as they are today.

## Non-goals

- Redesigning PR-state icons/colors (`PRStatusPresentation` is unchanged).
- Changing repo-header decorations, hierarchy guides, selection, hover "+",
  or the home-repo tag.
- Changing notification *generation* in the daemon — only how the app
  *presents* existing `NotificationType` values on a row.

## Design

### New layout

```
[leading icon]  Worktree name  [activity suffix]  (repo)
```

Two independent regions replace the single shared slot.

### Leading icon — identity / PR (clickable)

Pulled out of the shared priority chain so it is never suppressed. Cases are
mutually exclusive in practice:

| Condition | Rendering |
| --- | --- |
| PR exists and `!isMain` | PR status icon — clickable `Button`, hover tooltip, colored by `PRStatusPresentation`. **Unchanged** styling/behavior; only no longer gated by other state. |
| `status == .creating` (and not editing) | `circle.dotted`, `.secondary`, 12×12 (a creating worktree has no PR yet, so no conflict). |
| otherwise | empty |

### Name

- **Bold** when the unread notification is `responseComplete` (replaces the
  blue dot) **or the worktree needs attention** (`attentionNeeded` /
  `focusRequest` — bold tracks the attention suffix so the two read
  consistently). Otherwise regular weight. The `hasBoldNotification` logic and
  the truncation-measurement font weight stay in sync with this.

### Activity suffix — single priority-resolved slot (trailing)

Resolved highest-first; renders at most one:

| Priority | State | Glyph | Color |
| --- | --- | --- | --- |
| 1 | error | `exclamationmark.octagon.fill` | red (adaptive) |
| 2 | attention — `attentionNeeded` **or** `focusRequest` | `hand.raised.fill` | amber (adaptive) |
| 3 | working — any terminal `activityState == .working` | **dancing dots** (CALayer animation), small (3px dots / 2px gap), nudged closer to the name and slightly lower | `.secondary` gray (revised from coral after live review — coral read as too loud) |
| 4 | suspended — any terminal `suspendedAt != nil` | `pause.circle.fill` | `.secondary` (**unchanged glyph + color**) |
| — | none | — | — |

> **Live-review revisions (2026-06-30):** the working dots were changed from
> the terracotta/coral pair to `.secondary` gray and made smaller, then nudged
> `-3px` toward the name and `+2px` down; and the name now also bolds for the
> attention state (not just `responseComplete`). The tables above reflect the
> shipped result.

### Notification mapping (replaces `badgeColor(for:)`)

| `NotificationType` | Old (dot) | New |
| --- | --- | --- |
| `error` (sev 4) | red dot | error suffix (octagon) |
| `attentionNeeded` (sev 3) | orange dot | attention suffix (hand) **+ bold name** |
| `focusRequest` (sev 3) | orange dot | attention suffix (hand) **+ bold name** |
| `taskComplete` (sev 2) | green dot | **nothing** |
| `responseComplete` (sev 1) | blue dot | **bold name only** |

The colored `Circle()` badge case is removed entirely.

### Working-state animation — CPU-safe dancing dots

**Why the old one was removed:** the previous indicator was a SwiftUI
`ProgressView()` spinner. Per #266 / `cdd0cea` and the 2026-06-11 CPU
investigation, it "forced continuous CoreAnimation commits on the main thread"
— ~10% of a core *per working row*, because in a SwiftUI hosting context every
animated frame drags in `GraphHost.flushTransactions`.

**How the new one avoids it:** a `TypingDotsView: NSViewRepresentable`
wrapping a layer-backed `NSView`:

- 3 small `CALayer` dots laid out horizontally (~3 px each).
- One `CAKeyframeAnimation` on `opacity` (e.g. 0.3 → 1.0 → 0.3),
  `repeatCount = .infinity`, duration ~1.2 s, staggered via `beginTime`
  (0 / 0.2 / 0.4 s) for the typing "wave".
- Animations are added **once** in `makeNSView` and never touched again.

A committed `CAAnimation` runs on the **render server (a separate process)** —
no per-frame main-thread work, no SwiftUI body re-evaluation, no
`flushTransactions`. The render server only recomposites the dirty ~12×12
region. This is categorically different from `ProgressView`,
`Timer`+`@State`, or `withAnimation(.repeatForever)`, all of which would
reintroduce the main-thread cost.

**Visibility guard:** observe `NSWindow.didChangeOcclusionStateNotification`
(and view `window` membership); pause the layer animation
(`layer.speed = 0`) when the window is occluded/miniaturized and resume
(`layer.speed = 1`) when visible, so a backgrounded TBD does no render-server
work for working rows. This is cheap insurance; the core correctness does not
depend on it.

Dot color is `.secondary` gray (revised from the original terracotta/coral
during live review — see the "Live-review revisions" note above). The
`NSColor` is re-baked on `viewDidChangeEffectiveAppearance()` so the dots track
a live light↔dark switch.

## Components

1. **`RowStatusIndicator`** (`Sources/TBDApp/Sidebar/RowStatusIndicator.swift`)
   — refactor the single `resolve(...)` into two pure resolvers:
   - `leadingIndicator(isPending:hasPRStatus:) -> Leading?` → `.pending` |
     `.prStatus` | `nil`
   - `suffixIndicator(notification:isWorking:isSuspended:) -> Suffix?` →
     `.error` | `.attention` | `.working` | `.suspended` | `nil`

   `badgeColor(for:)` is removed. Suffix glyph/color live in the view (or a
   small presentation helper), mirroring how `PRStatusPresentation` is
   structured.

2. **`TypingDotsView`** (new, `Sources/TBDApp/Sidebar/`) —
   `NSViewRepresentable` described above. No SwiftUI state; `updateNSView` is
   a no-op (or only toggles color on appearance change).

3. **`WorktreeRowView`** (`Sources/TBDApp/Sidebar/WorktreeRowView.swift`) —
   restructure the `HStack` into leading icon → name → suffix. `rowIcons()`
   splits into `leadingIcon()` and `suffixIcon()`. Bold-name logic and the
   truncation measurement are unchanged. Remove the `.notificationBadge`
   `Circle()` rendering.

4. **Color helpers** — amber-attention and red-error adaptive pairs via the
   existing `adaptiveColor(light:dark:)`.

## Testing

Per the repo rule "add a test for each branch of a gating conditional":

- **`leadingIndicator`**: PR present ⇒ `.prStatus` regardless of working /
  suspended / any notification; creating + no PR ⇒ `.pending`; neither ⇒ `nil`;
  `isMain` suppression verified at the call site (PR hidden on main).
- **`suffixIndicator`** priority: `error ≻ attention ≻ working ≻ suspended`;
  `focusRequest` resolves to `.attention`; `taskComplete` ⇒ `nil`;
  `responseComplete` ⇒ `nil` (suffix); no state ⇒ `nil`.
- **Bold name** (`RowStatusIndicator.shouldBoldName`, shared by the sidebar
  row and the jump menu): `responseComplete` / `attentionNeeded` /
  `focusRequest` ⇒ bold; `error` / `taskComplete` / none ⇒ regular. Covered by
  `ShouldBoldNameTests`.
- **Jump menu** (`JumpMenuRow`): the old colored severity dot is removed too;
  it now bolds the name and shows the same error/attention suffix glyph via the
  shared resolver, so the two views stay consistent.
- **`TypingDotsView`** smoke test: constructs, is layer-backed, holds no
  SwiftUI `@State`. Animation smoothness + the occlusion pause/resume are
  verified live (headless tests can't see CA render-server output).

## Risks / notes

- **Two regions can now co-occur** (e.g. PR icon + working dots). That is the
  intended untangling; it is bounded — leading is one icon, suffix is one icon.
- **Live verification required** for the animation and overall row look — per
  project experience, transcript/sidebar visual + animation behavior is
  LIVE-only; a green headless test does not prove the dots animate or that CPU
  stays flat. Verify via `scripts/restart.sh`, eyes on the sidebar, and a CPU
  sample of a working row (compare against the static-asterisk baseline).
- `PRStatusPresentation` and the suspended glyph are deliberately untouched.
