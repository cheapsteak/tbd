# Note content belongs to the app, not the daemon

## The problem

`note.list` reads every note content file on the machine, from disk, on every
poll cycle. A `sudo fs_usage` capture of `TBDDaemon` (20 s, 235,351 filesystem
operations) attributed **27.1% of all daemon filesystem operations** to
`~/tbd/notes` — 22,352 operations, of which exactly 2 were writes:

- `getattrlist` — 16,762
- `open` — 5,587

For comparison, transcript parsing over `~/.claude/projects` accounted for 0.5%.

The raw trace repeats one shape, once per note row:

```
getattrlist  ~/tbd/notes
getattrlist  ~/tbd/notes/<worktreeUUID>
getattrlist  ~/tbd/notes/<worktreeUUID>/<noteUUID>.md
open         ~/tbd/notes/<worktreeUUID>/<noteUUID>.md
```

Three operations chain to one file read, and the daemon does it for every row
it returns.

### Why it happens

`NoteStore.list(worktreeID:)` ends with `return notes.map(overlayContent)`, and
`overlayContent` does `String(contentsOfFile:)` — a full file read per note.
That is correct for `get(id:)`, where content is the point. On `list` it means
the endpoint's cost is proportional to the total bytes of every note on the
machine.

The caller that makes it a storm is `AppState.refreshWorktrees`, which calls
`daemonClient.listNotes()` **with no `worktreeID`** inside the 2-second poll
cycle that also fetches terminals. Two multipliers stack on top:

- **Unfiltered.** The call returns every note row, not the visible ones. On the
  machine that produced the trace that is 700 rows, of which only 97 belong to a
  non-archived worktree — a 7× amplification, since the app immediately discards
  notes for worktrees it is not showing.
- **Unconditional.** It runs whether or not any note changed, forever, for as
  long as the app is open.

The denominator is note rows, not worktrees: there are 2,052 worktree rows and
700 notes, spread one per worktree across 700 of them. 700 rows × 4 operations
against an effective cycle rate a little under 0.5 Hz — the timer is 2.0 s and
`pollCycleInFlight` skips a tick when the previous cycle is still draining —
gives ~280 opens per second, against the 279 observed.

## The deeper problem, and the actual fix

Tuning that read is treating a symptom. **The daemon has no reason to be in the
note-content path at all.**

TBD already knows this. Two file-backed subsystems place content on exactly the
opposite side of the socket:

- **`TerminalHistoryEntry`** is metadata in the DB and text on disk, and its
  model comment states the rule outright: the app reads
  `TBDConstants.terminalHistoryPath` directly, *not* over RPC
  (`AppState.selectClosedTerminal`).
- **Claude transcripts** moved into the app in PR #752, parsing incrementally
  from the file rather than asking the daemon for parsed messages.

And the app **already has the store to do it**. `NotesFileStore`
(`Sources/TBDApp/Notes/NotesStorage.swift`) reads, writes, and creates note
files, deleting the file when content is empty or whitespace-only — the same
semantics as the daemon's `writeContentFile`, which acknowledges the duplication
in its own comment ("mirrors the app's `NotesFileStore` semantics").

The app and the daemon are always on the same machine. Sending a local file
read across a unix socket, so the process on the other end can read the same
disk and send the bytes back, buys nothing and costs a poll-rate storm.

So: **`note.list` becomes pure metadata and the daemon stops touching note
content entirely.** The app owns the file.

## The design

### `note.list` performs zero filesystem operations

Not "fewer" — zero. `NoteStore.list` fetches rows and maps them. It does not
stat, enumerate, or open anything.

It returns `[NoteSummary]`, a new type in `TBDShared`:

```swift
public struct NoteSummary: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var worktreeID: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Content in the LEGACY DB column. Not "this note has content".
    public var hasLegacyContent: Bool
}
```

A distinct type rather than a `Note` with `content` left empty. An emptied
`Note` is the same trap one level down: every existing and future caller keeps
compiling, keeps reading `.content`, and silently gets `""`. `NoteSummary` makes
the compiler point at each site that needs content and forces it to say where it
comes from.

`hasLegacyContent` is `!record.content.isEmpty` — free, since the row is already
in hand. It is deliberately **not** named `hasContent`: a file-backed note with
an empty legacy column reports `false`, and any reader who assumes otherwise has
a bug. The app owns the union.

`NoteListParams` also gains an optional `worktreeIDs: [UUID]?`, and
`refreshWorktrees` passes the visible set it is about to iterate. Of the 700 note
rows, only 97 belong to a non-archived worktree; the rest are encoded, sent,
decoded and discarded every cycle. With the filesystem work gone this is a
payload and decode lever rather than a syscall one, and worth keeping on that
basis: PR #754's RPC volume probe found JSON decoding to be a standing
multi-core load in the app, spread across six cooperative threads.

### The app reads and writes the file

`NotePaneView` loads its text from `TBDConstants.noteContentPath(worktreeID:
noteID:)` — a path it already computes for its own footer — off the main thread,
mirroring `selectClosedTerminal`'s `Task.detached(priority: .userInitiated)`.
It saves through `NotesFileStore`, on the debounce it already has.

`note.update` keeps the title. The daemon's content path is retired.

### The legacy DB column is the sharp edge

`NoteStore`'s startup sweep (`exportContentColumnToFiles`, called from
`Daemon.swift`) has drained most legacy rows to disk, but not all: of 14 rows
with a non-empty content column, 13 also have a file and **one does not**. So
the column is still a live content route, and two things follow.

**Reading.** `NotesFileStore.read` returns `""` for a missing file, not nil.
Loading `""` into a pane, marking it loaded, and letting the autosave flush
would destroy that note. So a missing file plus `hasLegacyContent` falls back to
`note.get`, which still overlays the column. The app must distinguish *missing*
from *empty* — `fileExists`, or treating a `String(contentsOfFile:)` throw as
missing — never a `""` return.

**Emptying.** The daemon's `update` clears the column when content goes empty,
precisely so a stale column cannot resurrect through the fallback. Once the app
writes directly, nothing clears it: the app deletes the file, the column
survives, the file is now missing, and the fallback resurrects deleted text on
the next open. So **an emptying write routes through `note.update(content: "")`**
rather than deleting the file locally. It is one RPC on a rare gesture, and it is
the only case where the app hands content writing back to the daemon.

### `closeTab` takes the union

Closing a note tab hard-deletes the row, so `closeTab` confirms first when the
note has content. It is synchronous and cannot await a fetch. It confirms when
`hasLegacyContent || the file exists and is non-empty` — one synchronous stat on
a user gesture, not on a poll. The two-source rule lives in one helper on
`AppState`, not spread across call sites.

### No feature flag

CLAUDE.md gates a change that "wholesale-replaces a load-bearing path
(rendering, input routing, persistence)" behind a default-off flag, and moving
content writes out of the daemon is arguably that. It ships unflagged
deliberately.

The reason is that nothing observable changes. The same bytes land at the same
path with the same semantics — `NotesFileStore.write` and the daemon's
`writeContentFile` both write atomically, both create intermediate directories,
and both delete the file when content is whitespace-only. Only which process
holds the file descriptor differs. A flag exists so a soak can compare two
behaviours and a bad default can be turned off; here there is no second
behaviour to compare against and nothing a user could observe to decide with.
The cost is real — a gated write means both paths live in the tree, and the
daemon's content path would have to stay reachable rather than being deleted.

What makes that acceptable rather than merely convenient: `NotesFileStore` is
already shipped and covered by `NotesStorageTests`, its writes are atomic, and
`NoteStore.delete` deliberately never removes a content file — so the failure
modes a flag would protect against do not include losing the bytes already on
disk.

## Predicted effect

Per poll cycle, on the machine that produced the trace:

- **Today** — 700 rows × (3 `getattrlist` + 1 `open` + a full read) ≈ 2,800
  operations, plus every note's bytes, plus 700 summaries encoded and decoded.
- **After** — **zero** filesystem operations, ~97 summaries.

The daemon's `~/tbd/notes` traffic should go to approximately nothing: the two
writes the capture saw, plus whatever `note.get` the legacy fallback and title
updates provoke, which is a human-gesture rate against a poll rate.

Two things to check when measuring, because they are the assumptions that could
be wrong: residual `getattrlist` against `~/tbd/notes` in the **daemon** should
be near zero rather than merely smaller (anything row-count-shaped means content
resolution crept back into `list`), and the app's own filesystem traffic should
rise only on pane opens and saves, not on the poll — if the app starts reading
note files every cycle, the storm has moved rather than gone.

### What this does not improve

The 27.1% is a share of **`TBDDaemon`'s** filesystem operations. Measured
machine-wide, the same traffic is about **1.6% of all filesystem events**. Both
figures are true and they answer different questions.

So this makes the daemon quieter; it does not make the machine quieter, and it
should not be described as improving system responsiveness or reducing
`fseventsd` load. The case for it does not need that claim: a `list` endpoint
whose cost scales with the total bytes of every file it describes is wrong at
the contract level, and it is a trap for every caller after this one.

## Rejected alternatives

**Keep content in `list` and make the read cheaper.** Several shapes were
considered — caching in `NoteStore` keyed by path and mtime, a stat-based change
token, skipping rows that cannot yield content. All of them leave the endpoint
promising content, so its cost stays proportional to the total bytes of every
note that has any, and the next caller to reach for `list` inherits the same
trap. They treat the fact that 659 of 700 rows are currently empty as a property
of the design rather than of this machine on this day.

**Resolve content-existence in the daemon with one stat per row.** This was the
design until the trace's own ratio refuted it: at 16,762 `getattrlist` against
5,587 `open`, path resolution dominates, so a per-row stat removes the smaller
term and stays O(notes) in the larger one.

**Resolve it with one enumeration of the notes tree per call.** O(directories)
rather than O(notes) — ~32 directory reads against 700 rows — and it was the
design immediately before this one. Correct and cheap, but it answers the wrong
question: it makes the daemon's filesystem work small instead of removing the
reason for it. Once the app reads its own files, there is nothing left to
enumerate.

**Write content files but never read them.** Rejected on measurement. Once
`list` stops reading, the only reads left are one per pane open. The cost is the
point of the file backing: `~/tbd/notes/<wt>/<note>.md` is editable outside TBD
and `NotePaneView`'s footer advertises the path with a copy-path button. Making
the DB authoritative would silently discard external edits — a data-loss-shaped
regression bought for approximately zero operations.

**Drive note changes off the delta/subscription channel instead of polling.**
Orthogonal, and still worth doing on its own merits: it would remove the
remaining per-cycle `note.list` payload. It does not address the endpoint's
contract, which is what makes the storm possible.

## Compatibility

`note.list`'s result changes shape, so an app binary older than the daemon fails
to decode it: `Note` requires `content`, which the response no longer carries.
The app logs the error and the affected poll cycle ends early; worktrees and
terminals, fetched earlier in the same cycle, still refresh. A restart clears it,
and `scripts/restart.sh` rebuilds both binaries together.

Emitting a vestigial `content: ""` for wire compatibility was considered and
rejected as actively harmful: an older app would load empty text into open note
panes, and its debounced autosave would then write that empty content back,
deleting the content file. A clean decode failure is the safer skew.
