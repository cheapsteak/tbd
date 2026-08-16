# Profile-dir GC: a reconciler for `~/tbd/profiles/`

## Problem

Every non-bedrock model profile gets an isolated config directory at
`~/tbd/profiles/<uuid>/` (created lazily by
`ClaudeProfileConfigDirManager.ensureAPIKeyDir`/`ensureOAuthDir` on session
spawn or OAuth login prep). The only deletion path is the `modelProfile.delete`
RPC, and it deletes the DB row — the sole pointer to the directory — *before*
its best-effort Keychain and directory cleanup, each of which only logs on
failure. A daemon crash or a failed `removeItem` between the row delete and the
directory removal orphans the directory permanently: no row will ever reference
it again, and nothing sweeps `~/tbd/profiles/`.

This is the same failure shape that produced the tmux-socket and per-attempt
branch leaks: a best-effort delete on the happy path with no compensating
sweep. Profile config directories are the one durable resource class with no
named reconciler. This design closes that gap with two changes of different
kinds:

1. **Bug fix** — reorder `modelProfile.delete` so the row outlives the
   directory. This restores the existing theory (deletes should not orphan)
   and would not need a spec on its own.
2. **Feature** — a new OrphanGC collector, `ProfileDirCollector`, the named
   reconciler for `~/tbd/profiles/`. It reclaims directories with no matching
   `model_profiles` row. Because it deletes persisted state autonomously and
   the directories can contain user data, it ships behind its own default-off
   flag.

## What a profile directory contains

The stakes differ from the existing collectors. Most slots inside
`<uuid>/claude/` are symlinks into the host `~/.claude` store (`projects/`,
`plugins/`, `skills/`, …), but the directory also holds real per-profile
data:

- `.claude.json` — login identity, onboarding state, per-profile settings.
- `.credentials.json` — fallback OAuth credentials when the Keychain is
  unavailable. A secret.
- `<slot>.profile-local` sidecars — real pre-existing user content moved
  aside when a slot was converted to a symlink.

There is also a paired login-Keychain item
(`Claude Code-credentials-<sha256-prefix-of-configDir-path>`) keyed by the
directory's absolute path.

Agent worktrees reap safely because a git snapshot ref makes them restorable;
scratchpads reap safely because they are disposable tmp. An orphaned profile
dir has neither property: once the row is gone there is no other copy of this
data. That asymmetry drives the quarantine decision below.

## Decisions

Three questions were put to a human; each answer below is theirs.

- **Own default-off flag, not a rider on `gcEnabled`.** A new config column
  `gc_profile_dirs_enabled`, shipped default OFF; the collector runs only when
  `gcEnabled` AND this flag are both on. `gcEnabled` shipped default-ON for
  reclaims that are restorable or disposable; a new collector over
  directories holding credentials and user content warrants its own soak.
  Graduation is a one-line flip of the Swift default constant.
- **Quarantine, then expire — not delete outright.** Reaping renames the
  directory into `~/tbd/profiles/.reaped/<uuid>-<timestamp>/` (rename as the
  atomic commit point, the same pattern as `WorktreeDeletionQueue`) and
  deletes the quarantined copy only after the existing
  `gcSnapshotRetentionDays` window (default 30 days). A misclassification is
  recoverable for a month; the quarantine cannot grow unboundedly because the
  same sweep expires it.
- **Liveness gate: keep while any terminal row references the profile.**
  `modelProfile.delete` deliberately leaves `terminal.profile_id` on
  terminals whose sessions were spawned with the profile's env, so a live (or
  hibernated, resumable) session can still be using the directory via
  `CLAUDE_CONFIG_DIR`. The collector keeps any candidate whose UUID appears
  in any terminal row. Terminal rows are removed when terminals close, so
  this converges; it is deliberately stricter than the interactive delete
  path, because a background sweep yanking credentials from a running session
  is worse than a user-initiated delete doing so.

## Bug-fix half: deletion order in `modelProfile.delete`

Reorder `handleModelProfileDelete`
(`Sources/TBDDaemon/Server/RPCRouter+ModelProfileHandlers.swift`) so
everything keyed by the row happens while the row still exists:

1. Clear the default-profile pointer and repo overrides (unchanged).
2. Delete the usage row (unchanged).
3. Delete the API-key Keychain entry and the path-keyed login-Keychain item
   (moved earlier; still log-only on failure).
4. Remove the profile directory (moved earlier; still log-only on failure).
5. Delete the `model_profiles` row (moved last).

A directory-removal failure still proceeds to delete the row — the user asked
for the profile to be gone, and the collector is now the backstop for the
leftover directory. What the reorder buys is crash-safety: a daemon killed
mid-handler now leaves "row present, directory gone or present", both benign
(the directory is recreated lazily on next spawn; the user retries the
delete), instead of an unreferenced directory nothing will ever reclaim.

Interactive delete keeps outright removal rather than routing through
quarantine: the user explicitly asked for deletion, and keeping their
credentials on disk for another 30 days after an explicit delete would be
worse, not safer.

A regression test pins the order — the directory removal must be observed
before the row delete — and fails against the pre-fix handler.

## Feature half: `ProfileDirCollector`

A new collector in `Sources/TBDDaemon/GC/`, run as an additional phase of
`OrphanGC.sweep()`. It follows the established division of labor: the
collector owns filesystem enumeration and mutation; `OrphanGC` owns every DB
read (row listing, terminal references, the pre-reap re-read), mirroring how
`DeletionQueueCollector` stays database-free.

### Flag mechanics

- Migration adds `gc_profile_dirs_enabled` to `config` via
  `addColumnIfMissing(table:column:type:)` with **no SQL default**, so NULL
  remains the third state ("nobody has chosen").
- The shipped default lives in exactly one place:
  `?? Config.gcProfileDirsEnabledDefault` (= `false`) in
  `ConfigStore.toModel()`.
- Same-commit updates to the GRDB record and the Codable `Config` model in
  `Sources/TBDShared/Models.swift` (optional with default, so existing rows
  and JSON decode).
- A config RPC setter mirroring `setGCEnabled`, reachable from the CLI, is
  the soak-time enablement path. No app UI toggle until graduation.
- Tests cover the three states: a pre-migration row reads NULL (not `0`); an
  explicit `false` survives a change to the default constant; NULL follows
  the constant.

### Orphan definition

A candidate is an immediate child of the profiles base directory
(`ClaudeProfileConfigDirManager.baseDirectory`, which honors `TBD_HOME`)
whose name parses as a UUID and which matches no `model_profiles` row. Rows
are read *after* the directory enumeration, so a profile created mid-sweep is
always in the row set. Non-UUID entries and the `.reaped/` quarantine are
never candidates. All profile kinds share one namespace: any UUID directory
with a row is kept regardless of kind.

The creation path makes this definition sound: directories are only ever
created from an already-fetched row (`resolveConfigDir` at spawn,
`modelProfile.prepareConfigDir` at login prep), so there is no window where a
legitimate young directory exists before its row.

### Keep gates

Every gate fails toward keeping and appends a KEEP reason to the sweep plan:

- **Flag** — skip the whole phase unless `gcEnabled` and
  `gcProfileDirsEnabled` are both on (dry-run plans regardless, like the
  other arms).
- **Grace** — keep directories whose creation date is younger than
  `gcGraceSeconds` (default 1 h). Belt-and-braces against any future
  creation-order change.
- **Terminal reference** — keep while any terminal row's `profile_id` matches
  the UUID.
- **Pre-reap re-read** — immediately before renaming, re-check that no
  `model_profiles` row with the UUID exists (the same
  snapshot-staleness close as the deletion-queue collector's row re-read).

### Reap mechanics

1. Measure `apparentBytes` before the rename (last moment the size is
   readable at the original path).
2. `mkdir -p <base>/.reaped/`, then atomically rename the directory to
   `<base>/.reaped/<uuid>-<timestamp>/`. Rename is the commit point; a
   failure leaves the candidate untouched for the next sweep.
3. Delete the path-keyed login-Keychain item for the *original* path — the
   rename just invalidated its key, so it is unreachable garbage either way.
   `errSecItemNotFound` is success.
4. Persist a `ReapRecord` with a new `ReapKind.profileDir`, `repoPath: ""`,
   `worktreePath` = the original directory path, and the quarantine location
   in a new optional `quarantine_path` column on `reap_records` (migration +
   GRDB record + shared model, one commit). The record's audience is
   `tbd gc list`: the app's Reclaimed section fetches records per repo and
   summarizes only the kinds it knows, and a profile directory belongs to no
   repo, so `.profileDir` records deliberately do not surface there.

### No restore path

`OrphanGC.restore` stays unsupported for `.profileDir`, like scratchpads. By
the time the collector runs, the profile row — the name, kind, endpoint —
is already gone, so renaming the directory back would only recreate an orphan
for the next sweep. Recovery is manual: `tbd gc list` prints the quarantine
path next to each record, and the user retrieves whatever they need (or
recreates a profile and moves the directory into its UUID) by hand within the
retention window. The CLI is the recovery surface — the app's per-repo
Reclaimed section does not show `.profileDir` records.

### Quarantine expiry

The same sweep phase deletes `.reaped/` entries older than
`gcSnapshotRetentionDays` (default 30 d), reusing the retention knob that
already governs how long reaped state stays recoverable. Age comes from the
timestamp embedded in the entry's name; an unparseable name falls back to the
directory's own dates, and any read failure keeps the entry. Expiry does not
write additional ReapRecords — the quarantine entry's record already exists.

### Testing

- Delete-order regression test (fails without the bug fix).
- Collector: orphan reaped into quarantine; row-matched dir kept; non-UUID
  entry untouched; `.reaped/` never a candidate; grace keeps a young dir;
  terminal-referenced dir kept; pre-reap re-read keeps a just-recreated row;
  quarantine entry expires after retention and survives before it; dry run
  plans without touching disk or DB.
- Flag: both branches (off = a real sweep is a no-op even with orphans
  present, while a dry run still plans them; on = reaps), plus the three
  NULL/false/true states.
- All tests use injection seams (`ClaudeProfileConfigDirManager(baseDirectory:)`,
  `OrphanGC`'s injected `now`/`db`), never the real `~/tbd`.

## Rejected alternatives

- **Riding `gcEnabled` with no new flag** — simpler, but puts a brand-new
  orphan classifier over credential-bearing directories live on every install
  the day it ships; the default-ON decision for `gcEnabled` was made for
  restorable or disposable reclaims.
- **Delete outright (scratchpad-style)** — no retention bookkeeping, but a
  misclassification permanently destroys credentials and user content, with
  the flag soak as the only safety net.
- **Quarantine forever with manual purge** — safest per-reap, but recreates
  the unbounded-growth disease one level down.
- **Quarantine for the interactive delete too** — rejected above: an explicit
  user delete should not leave secrets on disk for another month.
- **A rename-back restore for `.profileDir` records** — the row the directory
  depends on is unrecoverable, so restore would produce an orphan, not a
  profile.

## Reconciler doctrine

`ProfileDirCollector` is the named reconciler for the durable resource class
"per-profile config directories under `~/tbd/profiles/`". Every durable
external resource TBD creates needs exactly such a named reconciler; this
collector closes the last known class that had none.
