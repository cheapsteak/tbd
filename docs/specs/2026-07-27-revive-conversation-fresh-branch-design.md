# Revive a conversation on a fresh branch

**Date:** 2026-07-27
**Status:** Approved, not implemented

## Problem

Often the only useful thing in an old archived worktree is the conversation.
Reviving it today resurrects the stale branch too, so the first thing you do is
ask the agent to rebase, or you branch off `origin/main` by hand and lose the
conversation. Both are annoying.

We want a second action next to "revive with this session": take *this*
conversation to a brand-new worktree branched off latest `origin/<default>`, and
leave the stale branch behind.

## Solution

A new RPC creates a fresh worktree through the ordinary **create** path and
seeds its primary terminal with a *fork* of the chosen conversation. The
archived row is read-only for the whole operation.

```
archived  stale-owl   [tbd/stale-owl @ abc1234, sessions A, B]   ← untouched
   │
   │  "Revive this session · on fresh main"   (session A)
   ▼
active    stale-owl (revived)   [tbd/brisk-elk off origin/main @ def5678]
          └─ primary  claude --resume A --fork-session '<context prompt>'  → new id A'
          └─ Notes    provenance block
          └─ (plus whatever the repo's setup/preSession hooks normally add)
```

Nothing about the archived row changes: status, `branch`, `archivedHeadSHA` and
`archivedClaudeSessions` are all left alone, so plain Revive still works on it
and still restores session A.

## Decisions

| Question | Decision | Why |
| --- | --- | --- |
| Result shape | New worktree row; archived row stays archived | Non-destructive; the stale branch is still there if you want it |
| Session identity | **Fork** — `--resume <id> --fork-session` | `--resume` alone reuses the original session ID. Without the fork flag, a later plain Revive of the archived row would put a second process on the same transcript JSONL |
| Which sessions | The one you picked | Usually one conversation is the useful thing. Restoring all of them spawns N agents you didn't ask for |
| Entry point | Second button beside the existing CTA in the History pane | You are already looking at the session list and picking one |
| Naming | Fresh auto-name; display name marks the origin | Branch names stay clean and collision-free; the sidebar says where it came from |
| Fetch failure | Create anyway, warn visibly | Offline should not cost you the conversation, but "latest" must not be a silent lie |
| Provenance | Seeded Notes tab + display name | No audit-log table exists, and this needs no schema change |
| Agent context | Initial prompt delivered with the resume | Otherwise the agent edits files against a remembered state that no longer exists |
| Feature flag | None | See "Conventions" below |

## RPC

```swift
// RPCMethod
public static let worktreeReviveConversationFresh = "worktree.reviveConversationFresh"

public struct WorktreeReviveConversationFreshParams: Codable, Sendable {
    public let archivedWorktreeID: UUID
    public let sessionID: String
    public let cols: Int?
    public let rows: Int?
}

public struct WorktreeReviveConversationFreshResult: Codable, Sendable {
    public let worktree: Worktree
    /// Non-nil when the on-demand fetch failed and the base ref may be stale.
    /// Rendered as a non-error alert naming the base SHA and its age.
    public let warning: String?
}
```

The result is a struct, not a bare `Worktree`, because the stale-base warning has
nowhere else to travel.

## Daemon flow

New file `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+ReviveFresh.swift`.

1. **Load and validate.** Fetch the archived worktree and its repo. Reject
   `status != .archived`. Reject scratch rows (`repoID == nil`) with an explicit
   error — a repo-less worktree has no branch to be fresh relative to.
2. **Resolve the transcript.** Locate the session's JSONL via
   `TranscriptProjectDirSync`. **Fail here if it is missing**, before anything is
   created. `--fork-session` against an unknown ID silently starts a *blank*
   session; the swap handler already logs this exact case
   (`"no source transcript found for session … — fork will start fresh"`).
   Failing early is the difference between an error message and a worktree that
   quietly contains the wrong thing.

   **Post-ship correction — validate against the root the spawn will use.** As
   shipped, this step scanned the *ambient* projects root while the spawn synced
   from the resolved model profile's root
   (`spawnPrimaryTerminals` → `ClaudeProfileConfigDirManager.resolveConfigDir`).
   Validation passing therefore proved nothing about the spawn, and the first
   real use surfaced as Claude's own
   `No conversation found with session ID: …` — the exact outcome this step
   exists to prevent. Validation now resolves the profile the same way the spawn
   does (profile-resolution failure falls back to ambient, matching it). Any
   pre-flight check must read the same input as the operation it is guarding.
   (Compounding it: `FileManager.contentsOfDirectory(at:)` lists a *symlinked*
   directory URL as EMPTY, and profile config dirs symlink their `projects` slot
   at the host store — so the by-session-ID scan had been silently finding
   nothing for every profile-bound resume, not just this feature.)
3. **Fetch.** `git.fetch(repoPath:branch:timeout:)` on `<defaultBranch>` with a
   15-second timeout, called directly rather than through `FetchCache` — this is
   an explicit user gesture asking for latest, so a cached answer defeats the
   point. On failure, record a warning and continue.
4. **Resolve the base.** `origin/<default>`, falling back to local `<default>` —
   the fallback `attemptWorktreeAdd` already performs
   (`WorktreeLifecycle+Create.swift:423`). Capture the base SHA and its commit
   date for the prompt, the note, and the warning.
5. **Create.** `beginCreateWorktree(repoID:)` with no folder or branch override,
   so `NameGenerator` picks the name and the branch is `tbd/<name>`. Set
   `displayName` to `"<archived display name> (revived)"`. Display names are not
   unique in this schema (`name` and `path` are), so reviving the same
   conversation twice simply yields two rows with the same display name and
   different branches. That is acceptable and needs no disambiguation.
6. **Spawn and seed.** `completeCreateWorktree(…, carryover:)` — see below.
7. **Broadcast** `.worktreeCreated` and return the new row plus any warning.

## Carrying the conversation

```swift
/// Everything the revive-fresh flow injects into an otherwise ordinary create.
struct ConversationCarryover: Sendable {
    let sourceSessionID: String
    let contextPrompt: String
    /// Markdown seeded into the worktree's initial Notes tab.
    let notesSeed: String
}
```

The notes seed rides in this struct rather than being written by the caller after
the fact, because on the `preSession` branch `createInitialNoteTab` runs *inside*
the detached phase-3 task — `completeCreateWorktree` returns `.preSessionPending`
before any note row exists, so a caller-side write would race it.
`createInitialNoteTab` gains an optional `seed: String?` parameter, defaulting to
nil so the ordinary create path is unchanged.

Threaded from `completeCreateWorktree` down to `spawnPrimaryTerminals`. When
present, `spawnPrimaryTerminals`:

- forces the primary terminal kind to `.claude`, bypassing
  `resolvePrimaryTerminalKind`'s configured preference;
- calls `TranscriptProjectDirSync.ensureSessionResumableDetached(sessionID:
  worktreePath:projectsRoot:storedTranscriptPath: nil)` so the JSONL is reachable
  from the *new* path's derived project dir — this is what makes a conversation
  path-independent, and it is already used on every resume;
- builds with `resumeID: sourceSessionID`, `forkSession: true`,
  `initialPrompt: contextPrompt`, `appendSystemPrompt: nil`. The builder appends
  the prompt atomically with the resume, so it can never land in the wrong
  process;
- stores `claudeSessionID = sourceSessionID` provisionally.

### Both create branches must carry it

This is the create-path twin of the two-revive-paths trap that has bitten
per-worktree revive flags before. `completeCreateWorktree` spawns terminals from
**two** places, and a `carryover` threaded into only one silently no-ops on the
other:

| Branch | Site |
| --- | --- |
| Inline spawn (no `preSession` hook) | `WorktreeLifecycle+Create.swift:358` |
| `preSession` hook → phase 3 | `Create.swift:333` → `WorktreeLifecycle+PreSession.swift:343` |

Both get a test.

### Learning the forked session ID

`--fork-session` mints a new ID that TBD does not know in advance. Two existing
mechanisms converge on it, in order of reliability:

1. **The SessionStart hook bridge** (`tbd session-event` →
   `handleTerminalSessionEvent`). Keyed by `TBD_TERMINAL_ID` from the spawn env
   and validated against the reported `cwd`, which matches because the fork runs
   in the new worktree. Profile-independent.
2. **`scheduleSessionRecapture`** — the 5-second poll the `.fork` swap already
   uses. Backup only: `ClaudeStateDetector.captureSessionID` reads
   `~/.claude/sessions/<pid>.json` under the *ambient* home, so it can miss a
   session running under an alternate profile config dir. (It reads a JSON file,
   not screen text — no TUI-scraping exclusion is added.)

Until one lands, the terminal row points at the source ID. Harmless: the row is
corrected within seconds, and the source transcript is not being written by this
process.

## Accepted limitation: daemon restart mid-hook

If the daemon restarts while a `preSession` hook is running,
`recoverCreatingWorktrees` (`WorktreeLifecycle+Recovery.swift:126`) resumes the
row as an ordinary mid-create and spawns a **blank** Claude. The fork is lost.

Honoring it would require persisting the carried session on the row, i.e. a
migration. Reusing the existing `archivedClaudeSessions` column instead would be
worse than useless: recovery treats a `.creating` row carrying that column as
*mid-revive* and resumes it **without** `--fork-session`, which is exactly the
double-writer hazard the fork exists to prevent.

We accept the gap. The conversation is still intact on the untouched archived
row, so the recovery is "run the action again". The daemon logs the loss at
`.warning`.

## App surface

`SessionTranscriptView` header (`Sources/TBDApp/Panes/HistoryPaneView.swift:342`),
archived worktrees only:

```
"add retry to the poller"     Revive this session:  [ in original branch ]  [ on fresh main ]
                                                         prominent               bordered
```

Active worktrees (`TranscriptAction.resume`) keep the single `Resume` button. The
default branch name is substituted from `repo.defaultBranch`, so it reads "on
fresh master" where that is the truth.

`AppState.reviveConversationOnFreshBranch(worktreeID:sessionId:)` mirrors
`reviveWithSession` with one deliberate difference: it must **not** touch
`revivingArchived`. That dictionary holds a lingering snapshot of a row *leaving*
the archived list; here the archived row stays exactly where it is. Instead the
button shows in-flight state locally, and on success the new worktree is selected
in the sidebar.

## Context prompt

Delivered as the resume's trailing prompt argument:

```
You have been moved to a fresh worktree. This conversation previously worked on
branch tbd/stale-owl (archived 2026-06-01). You are now on tbd/brisk-elk,
branched from origin/main (def5678). The working tree does NOT match what you
last saw — re-read any file before editing it.
```

## Notes seed

```markdown
# Revived conversation

Forked from **stale-owl** on 2026-07-27.

| | |
| --- | --- |
| Original branch | `tbd/stale-owl` @ `abc1234` (archived 2026-06-01) |
| This branch | `tbd/brisk-elk` |
| Branched from | `origin/main` @ `def5678` (2026-07-27) |
| Source session | `A` |
```

## Conventions

- **No feature flag.** CLAUDE.md requires one for behavior that acts without a
  user gesture or destroys state. This runs only on a click, creates a new
  worktree and a new session ID, and mutates nothing that existed before. The
  same doc warns against flag sprawl.
- **No migration.** No new columns on any table.
- **No new sleeps or timers**, so no injected clock is needed. The one timed
  path, `scheduleSessionRecapture`, already exists and is unchanged.
- **No `print()`**; `os.Logger` on `com.tbd.daemon`, category `archive`.
- **No TUI scraping** introduced.

## Testing

Daemon:

- Fork reaches the spawn command on the **inline** create branch.
- Fork reaches the spawn command on the **`preSession` hook** branch — the
  no-op-on-one-path trap.
- The built command carries `--fork-session` and the context prompt.
- The archived row is byte-identical afterwards: status, `branch`,
  `archivedHeadSHA`, `archivedClaudeSessions`.
- The source transcript is reachable from the new worktree's derived project dir
  after the spawn.
- Fetch failure → worktree still created, `warning` non-nil.
- Unresolvable session ID → error, and **no** worktree row or directory created.
- Scratch row (`repoID == nil`) → explicit error.
- New row's `displayName` is `"<old> (revived)"`; branch is `tbd/<generated>`.
- The Notes tab is seeded, not empty.

App:

- Archived worktrees render two buttons; active worktrees render one.
- The fresh-branch action leaves `revivingArchived` untouched.
- A returned warning surfaces as a non-error alert.

## Out of scope

- Carrying more than one conversation in a single action. The remaining sessions
  stay on the archived row and can be pulled in afterwards.
- Any change to plain Revive.
- Tombstoning, renaming or deleting the archived row or its branch.
