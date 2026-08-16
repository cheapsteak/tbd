# Retiring a remote lane

**Date:** 2026-08-16
**Status:** Approved, built.
**Depends on:** [`docs/remote-provider-contract.md`](../remote-provider-contract.md)
(the `archive` and `unarchive` capabilities, the `archived` field on the Session
object, and the optional `meta.workspace_dirty` key),
[`2026-08-10-remote-sessions-in-worktree-tree-design.md`](2026-08-10-remote-sessions-in-worktree-tree-design.md)
(the local/remote boundary, adoption, and the archive and revive semantics this
design implements).

## Summary

A remote agent session that TBD has adopted as a worktree row cannot be retired.
Every path that would retire a row refuses a remote one, and the code beneath
those refusals resolves rows through `WorktreeStore.getLocal`, which returns
nothing for a remote row. Adopted lanes are therefore permanent: they accumulate
in the active sidebar and no gesture removes them.

This gives a remote lane its own retirement path. Archive composes over the
capabilities a provider declares rather than over a fixed teardown, because what
retiring means on the far side is the provider's to define. Where a provider
declares nothing, TBD refuses rather than filing a row it cannot stand behind —
a retirement TBD did not perform is not a retirement it may claim.

## The gap

Four paths are structurally local, and the first three carry an explicit refusal
while the fourth would fail beneath one:

- `handleWorktreeArchive` returns an error for a row whose location is not local.
- `handleWorktreeForget` does the same.
- `AutoArchiveOnMergeCoordinator.handleMergedTransition` returns `false`
  silently, which is right for a background rail.
- `handleWorktreeRerunPreSession`'s sibling `beginReviveWorktree` carries no
  refusal at all, and resolves through `getLocal` like the others.

Lifting the refusals alone would not work. `beginArchiveWorktree`,
`forgetWorktree`, and `beginReviveWorktree` each obtain their row through
`getLocal`, and `LocalWorktree.init?` rejects a remote row before anything else.
Beneath them the local archive path captures scrollback, kills tmux windows,
runs git checks, and removes a directory — work that has no meaning for a lane
whose files are on another machine. A remote lane needs a different path, not an
unfenced one.

The merged-transition rail reaches remote lanes today, so its refusal is load
bearing rather than theoretical: PR polling was re-keyed on the branch when
adoption shipped, and `pollableWorktrees` admits remote rows so a lane carries a
PR badge like any other.

## Archive

Archive retires a lane from the working set. It has one success path and one
exemption.

- **The provider declares `archive`** — guard, invoke `archive <id>`, then mark
  the row archived. The retirement is a fact on the backend rather than TBD's
  private bookkeeping, so every other client of that backend sees it.
- **The session is `gone`** — mark the row archived and call nothing. A `gone`
  session is one the provider has stopped enumerating, so there is no live
  session to misdescribe and no verb that could reach it.
- **Neither** — refused, naming `archive` as the capability the provider needs
  to implement.

**Refusing is the point, not a gap in coverage.** Filing a row while the
provider still reports the session active leaves two records disagreeing, and
the one the user reads says a retirement happened that did not. A provider is
free to define archiving as it likes — retiring an entry in its own inventory is
enough, and the contract defines `archived` as retirement from the working
inventory rather than as a statement about liveness — but it must say so through
the capability and report it back through `list`. What TBD will not do is
synthesize that claim on a provider's behalf.

**TBD does not substitute `stop` for a missing `archive`.** The contract names
the two verbs separately because ending compute and retiring a record are
different acts, and a provider that declared only `stop` has said it can do the
first. Reaching for it when the user asked for the second would be TBD deciding
that a kill is a good enough synonym for a filing decision. `stop` remains
available as its own gesture on the Provider Desk, where the user asks for it by
name.

The `gone` exemption is the only route out for a lane whose provider cannot
archive, and it is deliberately narrow. A lane whose session is still enumerated
stays in the active list until its provider implements the capability.

A declared `archive` wins over the exemption, so a `gone` lane on a capable
provider still takes the verb path — and a `not_found` response there degrades
to the same row-only filing rather than an error. A session the provider no
longer knows is exactly the case the exemption covers, and treating it as a
failure would leave a lane unretireable on a provider that declares *more* than
one whose lane files cleanly. Revive has the mirror-image degradation.

### Guards

Where archive invokes the verb, it refuses on an unsafe lane unless forced,
paralleling how local archive refuses on uncommitted changes:

- `agentState == .working` — do not retire a session mid-task by accident.
- A dirty remote checkout, reported through the optional well-known `meta` key
  `workspace_dirty`.

The second guard exists because TBD cannot see a remote working tree, and the
`working` guard does not cover it: an idle agent sitting on unpushed work looks
safe to retire. A provider that knows its checkout is dirty reports it; one that
reports nothing degrades to the `working` guard alone, so the guard is inert
until a provider adopts it and TBD never fabricates the fact. It is additive at
either contract major.

`meta` is a flat string-to-string map, so the claim arrives as text, and only
`"true"` and `"1"` — trimmed, case-insensitively — are read as one. An absent
key, an empty value, and any unrecognized value all mean no claim was made.
The reading is deliberately narrow rather than a permissive truthiness test:
this value decides whether a user's archive is refused, and inventing a claim
out of a string a provider meant for display would block a gesture nobody asked
to block.

Both guards apply to the verb path alone. The `gone` path touches nothing on the
provider and has nothing to defend. `--force` overrides both.

Guarding the verb unconditionally, rather than inferring from a provider's other
capabilities whether its archive might end compute, keeps one rule for both
locations. The contract permits termination as a side effect of retiring, so a
declared `archive` is reason enough to check.

### Auto-archive on merge

The merged-transition rail participates under the opt-in it already has. The
rail is off by default, per-worktree overridable, and armed by a deliberate
gesture; the act it performs is the same archive on the same path, and it
declines by itself when the provider declares no `archive`, exactly as a manual
archive would. A second switch would gate a switch.

## Revive

Revive returns a lane to the working set. It attempts the verb where one is
declared, degrades on what comes back, and reports it:

- **The provider declares `unarchive`** — invoke it, flip the row to active, and
  report the session's condition: running, exited, or no longer there. `archive`
  and `unarchive` are idempotent per contract, so an already-active session, an
  exited one, and a `gone` one all flip cleanly, with `not_found` degrading to a
  row-only flip rather than surfacing an error.
- **No `unarchive`, and the provider currently reports the session archived** —
  refused, naming `unarchive` as the missing half and saying the retirement
  stands on the backend until it exists.
- **No `unarchive`, and the provider does not report it archived** — flip the
  row, call nothing. This is the lane filed under the `gone` exemption: TBD's own
  decision, which a TBD gesture reverses.

The discriminator is what the provider reports right now, not how the row came to
be archived, so no provenance has to be persisted. A lane the provider still
reports archived is one TBD retired through the verb; a lane it does not report
at all, or reports unarchived, is one TBD filed on its own.

Attempting the verb even for a lane that looks dead is worth a call TBD expects
to fail. `gone` means only that a session missed two consecutive snapshots, and
a provider may list it again; an exited session may still be a record the
provider can unarchive. The verb is idempotent, so the attempt costs a round
trip and never a wrong outcome, and what comes back is better evidence than what
TBD believed beforehand.

**The refusal is mechanical rather than a matter of taste.** With no verb to
call and the provider still reporting `archived: true`, a row-only flip would be
re-archived by the filing sync on the next snapshot, and again on every snapshot
after. Refusing is what keeps the two records from fighting. Where the provider
reports nothing, there is no such contradiction to create: the sync reads
`archived` only from a provider declaring `archive`, and only when present, so
nothing will arrive to undo the flip.

## The filing decision travels back

A session the provider reports as archived leaves TBD's active list, and one
reported back to unarchived returns to it, so a lane retired on the provider's
own surface or from another machine does not persist as a lane nobody will use.
This holds only while a row's location is remote. A row whose files are on this
machine takes its status from TBD alone.

Neither direction touches `state`. Filing and liveness are separate axes, and a
row that collapses them lies about one of them.

### Whose report counts

TBD reads `archived` **only from a provider that declares `archive`, and only
when the field is present**.

The capability half is what makes the exemption durable. A provider with no
archiving concept never sets the field, and the contract requires an absent
`archived` to be read as `false` — so without the gate, every snapshot from such
a provider would carry an implicit "not archived" that returned rows to the
active list about once a minute, forever.

The presence half defends against a provider that declares the capability and
omits the field anyway. Absent means no claim was made; explicit `false` is a
claim. Display still reads absent as `false`, exactly as the contract says; only
the sync abstains, because a rule about whether to overwrite the user's own
filing decision needs to distinguish silence from denial.

`RemoteSessionPayload.archived` is therefore stored as `Bool?` and never
collapsed at decode. A computed reading supplies the contract's absent-is-false
semantics wherever display needs it.

### Stale snapshots

The payload carries no provider-side timestamp or sequence number, and the
mirror stamps arrival time from TBD's own clock, so a response composed before a
local filing decision is indistinguishable on its face from one composed after.
A `list` launched half a second before an archive and returning after it carries
a pre-archive `archived: false`, which passes both gates above and returns the
row the user just retired.

The consequence is worse than a brief flicker, because the app's archive
tombstone defers it. A tombstone is dropped early only when the daemon reports
the row archived or absent; over a row the daemon reports active it is held to
its TTL. So the lane disappears on archive, stays hidden while the tombstone
lives, reappears when it expires, and files itself again on the next clean poll.
The symptom presents as a lane returning unbidden some seconds after being
archived, which reads as a persistence bug rather than a stale read. Revive has
the mirror-image case.

TBD therefore records when it last made a filing decision on a remote row, and
suppresses a snapshot-driven flip whose request began earlier:

- `pollOnce` captures the request start before invoking the provider and carries
  it to the apply, alongside the arrival time the mirror already stamps. The
  events path supplies the connection-open time for a `snapshot`, and arrival
  for a pushed `session`, which is fresh by construction.
- The provider manager holds an in-memory map of worktree id to filing time,
  written whenever TBD locally archives or revives a remote row, and swept of
  entries older than two poll intervals.
- A flip applies only when the row's recorded decision is no later than the
  request start.

This is exact rather than a tuned window: a response to a request sent before a
decision provably could not have accounted for it. It covers both directions,
which a timestamp on the row itself cannot — revive clears `archivedAt`, leaving
the un-archive direction with nothing to appeal to.

Holding the map in memory rather than in a column is what the durability is
worth. The window it defends is open only while a provider request is
outstanding, and such a request dies with the process; after a restart every
request start is later than every prior decision, so there is nothing left to
suppress. A persisted column would buy survival of a window that cannot survive.

### Never silent

A sync-driven archive writes a notification record rather than only broadcasting
a delta, so a lane that leaves the active list without a gesture says why. The
merge rail already establishes this shape for the other case where a worktree is
retired without the user asking at that moment.

The same obligation covers the refusals. A refused archive names `archive` as
the capability to implement, and a refused revive names `unarchive` and says the
retirement stands until it exists. Both point at the provider contract. Telling
someone an action is unavailable without telling them what would make it
available leaves them with a dead control and no next step.

## Where the branches live

`RemoteLaneLifecycle` owns the remote path, holding the provider manager and the
worktree store. The archive and revive handlers and the merge rail branch into
it on location; the local path beneath `getLocal` is untouched, and the boundary
`LocalWorktree` draws stays exactly where it is.

Capability routing is a pure function over the declared capability set and the
row's `gone` flag, so the decision is testable without a provider process:

```swift
enum RemoteLaneArchivePlan { case invokeVerb, rowOnlyGone, refused(String) }
enum RemoteLaneRevivePlan  { case invokeUnarchive, rowOnly, refusedNoUnarchive(String) }

static func archivePlan(capabilities: Set<String>, isGone: Bool) -> RemoteLaneArchivePlan
static func revivePlan(capabilities: Set<String>, providerReportsArchived: Bool)
    -> RemoteLaneRevivePlan
```

Capabilities come from the provider manager's cached `describe` response,
reached through its public `providerStatuses()` rather than the private
`describes` map — the same door the app already uses client-side, so daemon and
app derive a provider's capabilities identically instead of through two paths
that can drift. No contract negotiation is involved: `describe.capabilities`
already carries `archive` and `unarchive`, and a caller must not invoke a verb
whose capability a provider has not declared.

`worktree.forget` keeps its refusal for a remote lane. Forget means "stop
tracking this checkout but leave its files alone", and a remote lane has no
checkout here to leave alone. Its message changes from describing an
unimplemented gap to stating that retiring a lane is archive's job.

## Wire surface

Two RPC methods, mirroring `remote.stop`'s shape:

```swift
static let remoteArchive   = "remote.archive"
static let remoteUnarchive = "remote.unarchive"

public struct RemoteArchiveParams: Codable, Sendable {
    public let provider: String
    public let sessionID: String
}
public struct RemoteUnarchiveParams: Codable, Sendable { /* same shape */ }
```

And one field on the Session payload:

```swift
public let archived: Bool?          // nil = absent = no claim made
public var isArchived: Bool { archived ?? false }
```

Both verbs return the updated Session object per contract. Both are idempotent,
so archiving an already-archived lane or unarchiving one that is not archived
succeeds and changes nothing.

## Surfaces

`RowActionMenu.Context` gains the row's location, its provider name, and the
provider's declared capability set. Archive stays visible and destructive-styled
for a lane whose provider cannot archive, but disabled, with the reason in the
item's own title — the same treatment the menu already gives a row with active
children, and for the same reason: a tooltip on a disabled menu item is easy to
miss. Hiding the item instead would leave the absence unexplained and give a
provider author no signal that a capability is missing.

`ArchivedWorktreesView`'s hide-empty filter admits a remote lane on its location.
The filter keeps a row when it has conversations or a revive in flight, and a
remote lane's synthetic `remote://` path resolves to no Claude project
directory, so its session count is structurally zero. Left alone, the filter is
on by default and every archived lane would be invisible — archived successfully
and then hidden, which is indistinguishable from the archive having failed.

## The record

A refusal happens above the actuation row. Nothing was attempted, and the record
may claim solely acts that were attempted, so a refused archive writes no
request and no outcome — the same shape the current location gates use, and the
same reason `repo.remove` writes no dispose row for a lane it never tore down.

The `gone` path does write a row and confirm it dispatched. No provider call was
made, but the row genuinely changed status, and that is the act the record names.

A sync-driven archive writes its own row with the daemon actor and a rail name,
as the merge coordinator does, because no RPC carried it.

## Flag, migration, and reconciliation

**No new flag.** Everything here is inert unless `remote_backends_enabled` is on
and a provider is registered, and a remote row cannot exist otherwise. The
filing sync is background behavior that mutates persisted state, which ordinarily
argues for its own default-off gate, but the subsystem it belongs to is already
behind exactly such a gate and a second one would gate a flag.

**No migration.** `archived` rides the existing payload blob the mirror already
stores, and the stale-snapshot watermark is in-memory.

**Reconciliation.** This creates no durable external resource: it mutates rows
that already exist and calls verbs the contract defines as idempotent. The one
divergence it can produce is a verb that succeeded against a row that was never
written, leaving TBD active and the backend archived. The filing sync reconciles
that on the next snapshot, and is the named answer for it. No new sweep is
required.

## Testing

All tests run against the existing stub provider fixture, with no network, under
`TBD_HOME` isolation.

Archive:

- Each plan is taken against the capabilities declared: a provider declaring
  `archive` is archived through the verb, a `gone` lane is filed with no provider
  call, and a provider declaring neither is refused with the row untouched.
- A provider declaring only `stop` is refused, and `stop` is never invoked.
- The guards refuse on `working` and on a provider-reported dirty checkout for
  the verb path, refuse on neither for the `gone` path, and both yield to
  `--force`.
- An already-archived and an already-exited lane each flip without error.
- The merge rail archives an armed remote lane whose provider declares `archive`,
  and declines one whose provider does not, without writing an actuation row for
  the decline.

Revive:

- A provider declaring `unarchive` returns the lane whether the session is
  running, exited, or gone, and a `not_found` response degrades to a row-only
  flip rather than an error.
- A provider declaring `archive` without `unarchive`, still reporting the session
  archived, is refused, and the message names `unarchive`.
- A lane filed under the `gone` exemption by a provider declaring neither verb is
  revived by a row-only flip, with no provider call — so a `gone` archive is
  never a one-way door.

Filing sync:

- A session reported `archived: true` files its row; one reported back to
  `false` returns it; neither changes `state`.
- A provider that does not declare `archive` moves no row whatever it reports.
- An absent `archived` moves no row, while still reading as not-archived for
  display.
- A response whose request began before a local filing decision does not reverse
  it, in both the archive and the revive direction; one whose request began after
  does apply.
- A local worktree's status is never moved by any provider report.

Surfaces and record:

- The row menu disables Archive with a reason for a lane whose provider cannot
  archive, and enables it where the capability is declared.
- An archived remote lane appears in the archived list with the hide-empty
  filter at its default, alongside a local archived worktree with no
  conversations that the filter still hides — so a run that showed everything
  cannot pass by doing nothing.
- A refused archive and a refused revive each write no actuation row; a `gone`
  archive and a sync-driven archive each write one.

## Rejected alternatives

**Filing the row anyway when a provider cannot archive, and explaining
afterwards.** The gesture would always succeed and the archived row would carry a
standing note that the session is still running. Rejected because it makes TBD
the author of a retirement no other client of that backend can see, and the
record the user reads is the one that overstates what happened. A provider that
wants a filing-only archive can implement exactly that and report it through
`list`, which keeps the claim where it can be verified.

**Substituting `stop` where `archive` is undeclared.** Rejected above: the
contract separates ending compute from retiring a record precisely because a
backend may have one and not the other, and inferring a retirement from a kill
discards that distinction at the moment it matters.

**`worktree.forget` as a general escape hatch for a lane that cannot be
archived.** Attractive, because forget already means "stop tracking this, leave
the thing alone" and makes no claim about the backend. Rejected because
adoption re-creates a row for any session it sees without one, so a forgotten
lane would return on the next poll; making it stick would need a persisted
do-not-adopt fact and a way to reverse it, which is a second retirement concept
alongside archive.

**A persisted column for the stale-snapshot watermark.** Rejected on what the
durability buys: the window it protects is open only while a provider request is
outstanding, and no such request survives a restart.

**Reading `archived` from any provider, gated only on the field's presence.**
Simpler to state, and defensible — the field is plain Session data the contract
does not gate on a capability. Rejected because a provider with no archiving
concept can still emit `archived: false` for tidiness, and TBD would then let a
backend that cannot archive anything overwrite a filing decision the user made.

**A monotonic sync that files rows but never returns them.** This would remove
the stale-snapshot race outright, since the only direction it moves is one a
stale response cannot fabricate. Rejected because it breaks revive instead: a
stale `archived: true` arriving after a revive would re-file the row, and the
later corrected `false` would be ignored, leaving the row archived permanently
and the user's revive silently undone.

**Its own default-off flag for the filing sync.** Rejected because the
subsystem is already behind `remote_backends_enabled` and a remote row cannot
exist without it.

## Deliberate cuts

No recreation of a session for a lane whose session was terminated, so revive
reaches only as far as `unarchive` does. No `delete` verb, and no mapping of any
TBD gesture onto one — retiring and destroying are different acts and the
contract names only the first. No per-repo policy for which providers may be
archived automatically. No change to attach, log, send, stop, or the reconnect
policy.
