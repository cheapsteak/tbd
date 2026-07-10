# Worktree display-name invariant: `name == displayName`

## The rule

On default worktree creation, keep the internal folder slug (`name`) equal to the user-visible tab label (`displayName`). Both should derive from a single source: the daemon-generated slug.

```
✓ CORRECT
  createWorktree() → daemon auto-generates name
  name = "eager-squirrel"
  displayName = "eager-squirrel"  (defaulted to name in daemon)

✗ BROKEN
  createWorktree() → explicit displayName without folder
  name = "eager-squirrel"        (daemon-generated)
  displayName = "Custom Label"   (app-specified)
  → worktree appears "already renamed" → stop-rename-check hook never fires
```

## Why it matters

The `stop-rename-check` hook only fires when `hasDefaultDisplayName == true`, defined as:

```swift
public var hasDefaultDisplayName: Bool { displayName == name }
```

If a worktree is born with diverged `name` and `displayName`, it looks "already renamed" and the hook skips, leaving the tab title unchanged. This breaks the auto-title UX that normalizes poorly-chosen daemon-generated names on first use.

## Implementation rule

When calling `daemonClient.createWorktree()`:
- Pass **neither** `folder` nor `displayName` to the daemon
- Let the daemon default `displayName ?? name`, ensuring they're equal
- The local optimistic placeholder still gets `displayName: placeholderName` for instant UI feedback; this is reconciled at swap time

## Regression history

- **PR #378** broke it: set `displayName` without `folder` → two independent slugs
- **PR #419** fixed it: pass neither → daemon defaults both to same value

See `Sources/TBDApp/AppState+Worktrees.swift` lines 55–63 for the current correct pattern.
