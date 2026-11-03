# Archiving a sidebar selection in parallel

## Summary

Archive Selection, in the row menu, and the archive shortcut both act on the
whole sidebar selection. When more than one selected row can be archived,
`AppState.archiveInBulk` runs the archive. It sends one `worktree.archive`
call per row and runs up to four at once. A parent starts once its selected
children are done.

This design covers the app's bulk run alone. The daemon, the RPC and its
guards, the single-row path, the menu, the shortcut and the summary alert's
wording each keep their own design. It ships with no flag: the run still
starts only from a user gesture, every row passes the same daemon guards, and
no existing UI moves.

## Why parallel

Each call waits for the daemon's phase 1 to finish: the uncommitted-changes
check, the branch sync, the HEAD capture, the dev-server stop and the terminal
teardown. Phase 2 (the archive hook and handing the folder to the deletion
queue) runs detached and does not hold up the call. Awaited one at a time,
the calls empty the sidebar in a visible cascade, and the wait grows with the
size of the selection: a five-row run recorded in the app log removed one row
about every 0.4 s once the first had gone. Side by side, the wait drops to
roughly the time of the slowest row in each group of four.

The daemon already handles phase 1 for different worktrees at the same time.
Two gestures, the CLI and auto-archive on merge can each start one, and each
call runs its own phase 2 in the background.

## Scheduling

- **The cap.** At most `SelectionArchive.maxConcurrentArchives` calls, four,
  are in flight at once. While a call waits for its reply, it blocks a thread
  of the shared thread pool, which has one thread per core, so a larger cap
  starves the rest of the app. Each call also opens its own connection to the
  daemon's socket. On darwin, a connect to a listener whose accept queue is
  full is refused at once, so the app would read the refusal as a lost daemon.
- **Readiness.** A row is ready once every selected row whose parent it is,
  and that comes before it in the run order, has finished. Ready rows start in
  run order, `selectionArchiveRunOrder`: the Scratch section, then the
  sidebar's walk with children before their parents. Every outcome a row
  depends on is therefore settled before it starts, exactly as if the rows ran
  one at a time in that order. Since a row waits only for earlier rows, a loop
  in the parent links cannot deadlock the run.
- **A child that was not archived.** Its parent is skipped without a call,
  with the reason `SelectionArchive.nestedNotArchivedReason` gives, naming the
  first such child in run order. A skipped row counts as not archived, so the
  hold passes up to the grandparent. Waiting only on direct children is
  enough, because each child has already waited on its own.
- **Settling.** Each success gets `removeArchivedWorktreeFromState` as soon as
  its call returns, so rows leave the sidebar as their calls finish. The
  Scratch section's Archived tab is refreshed once, at the end, when a scratch
  row went.

The scheduling decisions live in a small pure value type in
`SelectionArchive`. Given the targets with their parent IDs, it says which
rows may start now and records each row's outcome. `AppState.archiveInBulk`
drives it with a task group, so the readiness, hold and cap rules can be tested
without the app state or a daemon.

## Failures

- **A failed call** goes through `handleConnectionError` and is recorded with
  `SelectionArchive.failureReason`, as on the single-row path. There is no bulk
  Archive anyway and no offer to discard changes.
- **A lost connection** to the daemon stops new rows from starting. Calls
  already in flight finish and are counted, archived or failed. Rows that never
  started are counted as not attempted. The Archived tab is not refreshed,
  since that call would fail too.
- **The summary alert** appears only when something failed. It lists failures
  in run order, not the order the calls finished in, so the same outcome always
  reads the same.
- **Ownership.** One bulk run at a time: a second gesture while one runs plays
  `refusalBeep` and archives nothing. While a run goes, the single-row archive
  refuses every row in `selectionArchivePendingIDs`. A row leaves that set when
  its own call ends, or when the run gives up on it.

## Testing

- **The pure scheduler.** Readiness by run order, the hold passing from a
  failed or skipped child to its parent and grandparent, a parent-link loop
  that still finishes, and the cap.
- **`archiveInBulk` with a fake archive call** that suspends until the test
  releases it. Six independent rows put exactly four calls in flight before any
  returns, where a run that awaits each call shows one. A parent's call starts only after
  its children's calls end. A failed child skips its parent with no call. A lost
  connection stops new starts while the calls in flight complete and count. The
  alert lists failures in run order when the calls finish in reverse.

## Not in this design

- **Optimistic removal.** Hiding every selected row at the gesture, and
  restoring the ones that fail, would make the sidebar change at once whatever
  the daemon's speed. It is left out until the parallel run has been used, when
  it is clearer whether the remaining stagger still matters.
- **A daemon-side bulk RPC.** One call naming every row would save round trips
  and could serve the CLI, but it is a new contract. The per-row RPC already
  carries every guard and record, so the app can run it in parallel without one.
