# Jump Menu — Recency-Dominant Search Result Ordering

**Date:** 2026-05-22
**Status:** Approved, ready for implementation

## Problem

When a query is typed into the Cmd+K jump menu, results are ordered
alphabetically by display name (after an unread-severity tier). The sort
ignores how recently a worktree was used and ignores match quality. Typing
`standup` surfaces `fix standup tmp file` above `standup2` purely because
`f < s`, even when `standup2` was visited far more recently.

Two latent issues compound it:

- The alphabetical key leads with the display name's emoji prefix
  (`<emoji> <Title Case>`), so ordering is partly driven by emoji Unicode
  values rather than words.
- Recency data already flows into the view model (`recentIDs`) but is unused
  on the typed-query path.

## Goal

Make typed-query results **recency-dominant**: among matches, the
most-recently-used worktree ranks highest. Match position is explicitly not a
factor. Unread worktrees still float to the top.

## Scope

In scope: the sort comparator in `JumpMenuViewModel.matchRows()`.

Out of scope: the filter predicate (unchanged — case-insensitive substring on
display name or repo name), the empty-query `defaultRows()` path, fuzzy
matching, match-position scoring, and persisting real visit timestamps.

## Design

All changes are confined to `JumpMenuViewModel.matchRows()` in
`Sources/TBDApp/JumpMenu/JumpMenuViewModel.swift`.

### Recency lookup

At the top of `matchRows`, build `recencyRank: [UUID: Int]` from
`recentIDs.enumerated()` — index 0 is the most recent. Worktrees absent from
`recentIDs` (never visited this session, or beyond the 32-item LRU cap) are
treated as rank `Int.max`.

### Comparator

Sort each matched row by, in priority order:

1. **Unread tier** — rows with an unread severity sort before rows without.
   (Unchanged.)
2. **Severity** — higher severity first. Relevant only within the unread tier;
   non-unread rows have `nil` severity and compare equal here. (Unchanged.)
3. **Recency** — lower `recencyRank` first. New key. Applies to *both* tiers,
   so unread rows of equal severity are also recency-ordered.
4. **Alphabetical fallback** — for rows with equal recency (notably the
   `Int.max` non-recent group), compare display names with a leading emoji
   stripped (see helper below).
5. **UUID tiebreak** — lexicographic, for deterministic output. (Unchanged.)

### Emoji-strip helper

A small pure helper produces the alphabetical fallback key: drop leading
characters that are neither letters nor digits, trim whitespace, lowercase.
Because a Swift `Character` is a grapheme cluster, a multi-scalar emoji (flags,
ZWJ sequences) is a single `Character` and is dropped cleanly. A name that is
entirely emoji yields an empty key; it sorts to the top of the fallback group
and the UUID tiebreak keeps it deterministic.

## Testing

Add cases to `Tests/TBDAppTests/JumpMenuViewModelTests.swift`:

- A recently-used match outranks a non-recent match regardless of display name.
- An unread worktree still outranks a more-recently-used read worktree.
- Within the unread tier, equal-severity rows are recency-ordered.
- Emoji-prefixed display names sort by words, not emoji, in the fallback group.
- Non-recent matches (rank `Int.max`) still produce a stable alphabetical
  order.

## Accepted limitations

- `recentWorktreeIDs` is an in-memory LRU: it resets on app restart and caps at
  32 entries. A worktree searched for by name is almost always one touched
  recently in the same session, so this is acceptable. Persisting real
  timestamps was considered (would need a DB migration) and rejected as not
  worth the cost.
