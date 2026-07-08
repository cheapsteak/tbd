# Merge-queue bus icon

Render a 🚌 in place of the PR icon when a pull request is sitting in GitHub's
merge queue, with a small badge showing its position in that queue.

## Motivation

A PR in a merge queue is in a different mode from every other PR state: it is no
longer waiting on the author. TBD currently gives no signal that this has
happened. A queued PR reports `mergeStateStatus: UNKNOWN`, which
`PRStatusManager.mapStateAndReason` maps to `(.pending, "Checks pending")` — the
ordinary olive PR icon. That is not wrong, but it is indistinguishable from a PR
whose CI is still running on the branch.

## What GitHub exposes

Verified against a live merge queue via the GraphQL API:

- `MergeStateStatus` has seven values — `DIRTY`, `UNKNOWN`, `BLOCKED`, `BEHIND`,
  `UNSTABLE`, `HAS_HOOKS`, `CLEAN`. **There is no `QUEUED`.** Merge-queue
  membership is not expressible through `mergeStateStatus`.
- `PullRequest.isInMergeQueue: Boolean!` and `PullRequest.mergeQueueEntry` are
  the real signals. `mergeQueueEntry` carries `position`, `state`
  (`QUEUED | AWAITING_CHECKS | MERGEABLE | UNMERGEABLE | LOCKED`),
  and `estimatedTimeToMerge` (seconds).
- **`position` is 1-indexed.** The PR at the front of the queue reports `1`.
- A queued PR's `mergeStateStatus` is `UNKNOWN`.
- The `gh pr view --json` field set exposes neither `isInMergeQueue` nor
  `mergeQueueEntry`. Only `autoMergeRequest` and `mergeStateStatus` are
  available there.

## Design

### Data layer — `Sources/TBDDaemon/PR/PRStatusManager.swift`

Add `mergeQueueEntry { position }` to the batch GraphQL query's per-PR node
selection.

Convert the single-PR `refresh()` path from `gh pr view --json ...` to a
`gh api graphql` call requesting the same field set. This is required, not
cosmetic: `gh pr view --json` cannot see merge-queue state at all, so leaving it
in place would make a manual refresh clobber the position back to `nil` and
flicker the bus away until the next batch poll.

`PRNode` and the refresh result type each gain `mergeQueuePosition: Int?`.

### Shared model — `Sources/TBDShared/Models.swift`

`PRStatus` gains one field:

```swift
public let mergeQueuePosition: Int?
```

It must be optional with a `nil` default. `PRStatus` is persisted as JSON inside
the single `worktree.prStatus` TEXT column (migration `v34`), so an optional
field decodes against existing rows and **no new migration is required**.

`PRMergeableState` gains **no new case.** Queue membership is orthogonal to
mergeability — a queued PR still has a meaningful underlying check state, and
collapsing the two would discard it and force edits into `mapStateAndReason`.
Keeping a separate field leaves that switch untouched.

### Presentation — `Sources/TBDApp/PRStatusPresentation.swift`

`PRStatusPresentation.make(for:)` short-circuits: when `mergeQueuePosition` is
non-nil, it returns the bus presentation regardless of `state`.

The struct's `iconName: String` becomes a glyph enum so the two render sites can
branch without duplicating the decision:

```swift
enum Glyph {
    case asset(String)   // existing bundled SVGs
    case emoji(String)   // 🚌
}
```

and gains `badge: Int?`, carrying the queue position.

### Rendering

Two call sites consume the presentation and must not drift:

- `Sources/TBDApp/Sidebar/WorktreeRowView.swift` — `leadingIcon()`
- `Sources/TBDApp/ContentView.swift` — `PRButtonLabel.coloredIcon(_:colorScheme:)`

Introduce one shared `emoji → NSImage` helper used by both.

The emoji is full-color and must **not** be tinted: the sidebar drops
`.renderingMode(.template)` for the `.emoji` case, and the toolbar skips its
color-baking fill. The toolbar already composites an `archivebox` overlay onto
the PR image when auto-archive is armed; the position badge reuses that
compositing path.

The badge is a small rounded-rect chip in the icon's corner containing the
1-indexed position.

## Deliberate trade-offs

`mergeQueueEntry.position` is typed `Int` (nullable) in the GraphQL schema. The
bus is gated on `position != nil`, so an entry that somehow reports a null
position renders the ordinary PR icon rather than a bus with an empty badge.
This is chosen so the badge always carries a number. It was not observed in
practice against a live queue.

## Testing

Per CLAUDE.md, a branching conditional that gates behavior needs a test per
branch:

- `mergeQueuePosition == nil` → existing icon and color for each `PRMergeableState`.
- `mergeQueuePosition != nil` → bus glyph plus badge, and the badge value equals
  the position.
- The batch GraphQL decoder parses `position`, and tolerates a null
  `mergeQueueEntry` by yielding `nil`.
- The rewritten `refresh()` decoder parses the same fields.
- Round-trip: a `PRStatus` JSON blob written before this change (no
  `mergeQueuePosition` key) still decodes, yielding `nil`.

Test fixtures use `acme` / `acme-prod` placeholder repo names.
