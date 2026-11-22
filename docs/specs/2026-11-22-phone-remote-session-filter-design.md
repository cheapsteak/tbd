# Phone filter for registry-provider sessions

**Date:** 2026-11-22
**Status:** Approved.
**Builds on:** [`2026-11-19-sidebar-remote-session-filter-design.md`](2026-11-19-sidebar-remote-session-filter-design.md) (the filter on the Mac sidebar),
[`2026-11-07-phone-control-design.md`](2026-11-07-phone-control-design.md) (the phone app, its list and its protocol).

## Summary

The phone's Sessions list gets the per-repo filter the Mac sidebar has. A repo whose list carries
sessions from a registry provider shows a chip after its name. Turned on, the chip hides that
repo's registry-provider rows and keeps its local and cloud rows.

The phone and the Mac share one setting per repo. Turning the filter on from either hides the rows
on both. To make that possible, the setting moves from the Mac app's `UserDefaults` to a column on
the daemon's `repo` table, and the Mac app copies the choices it already saved there once.

## User story

As a TBD user reading my sessions on my phone, I want to hide a repo's registry-provider sessions
there too, so that my own local and cloud work is not lost among rows an orchestrator manages.

## Problem

The Mac filter exists because a registry provider can fill a repo's list faster than a person can
read it. The phone shows the same rows, on a smaller screen, sorted newest first, so busy
registry-provider rows push the person's own work further down than on the Mac. The Mac's setting
lives in the Mac app's `UserDefaults`, which neither the daemon nor the phone can read.

## Terms

The terms are the Mac spec's:

- **Registry provider** – any provider other than the compiled `claude-cloud` one
  (`ClaudeCloudProvider.name`).
- **Registry row** – on the phone, a row in a repo group that has at least one session, every one
  of them a remote session of a registry provider. That is a remote lane's worktree row, or a loose session's `remoteSession` row.
  A local worktree row never carries a remote session, so it is never a registry row.

## What the phone hides and keeps

- **Hidden:** every registry row in a repo group whose filter is on, whatever its status, Exited
  included.
- **Kept:**
  - Every local row and every cloud row.
  - The selected row: the row of the session opened last (`ui.lastRowID`), which the list already
    marks. Opening another session hides it again. This is the Mac's selection exception, with
    the phone's own idea of selection.
- **Unchanged:**
  - Repos whose filter is off.
  - The scratch group and the provider groups at the foot of the list, which hold sessions that
    match no repo.
  - Everything outside the list's presentation. The store keeps every row. Route resolution, a
    pending open, a history restore and every action read the full list, so a hidden session can
    still be opened, and acted on while open.

**No tree.** The Mac keeps a registry row in view when a local or cloud row sits under it, so the
kept row is never cut off from the tree. The phone sorts by time and shows no tree, so no row can
be cut off, and it hides every registry row. In that rare case, the phone's count can exceed the
Mac's.

**The count** is the number of registry rows the filter hides in that repo, after the selection
exception.

A repo group that shows no rows after the filter keeps its header, as an empty repo group does
today, so its "+" and its chip stay reachable.

## The chip

### Placement

The chip sits on the repo's header row, directly after the repo name, before the space that
pushes the "+" to the trailing edge:

`▾ tbd [Hide agentbox] ………… +`

The name keeps its tap to fold or unfold the repo, and gives up its full-row width to make room for
the chip. The name shrinks first, so the chip and the "+" never move. The chip's tap area is the
header row's full 30 px height.

### When it shows

The chip shows while the repo has at least one registry row, judged without the selection
exception, whether or not the repo is folded. Selecting a hidden row never makes the chip vanish;
the count drops by one.

When the filter is on and the repo has no registry row left, the chip goes away and the setting
stays on. A registry session that arrives later is hidden at once, and the chip returns, on and
counted, so the filter never acts unseen.

### States

- **Off:** an outlined chip with an outlined filter symbol and the words "Hide <name>".
- **On:** an accent-tinted chip with a filled filter symbol and the words "<count> hidden".

**The name** is the provider's registry key, `RemoteProviderConfig.name` from
`~/tbd/agent-providers.json`, which every remote session reference already carries
(`PhoneSessionRef.provider`). It is the name the Mac's tooltip uses
(`RemoteProviderIdentityPresentation.headline`). When the repo has registry rows from two or more
providers, the chip reads "Hide remote". A long name is cut with an ellipsis so the chip never
pushes the "+" off the row.

**Accessible label:** "Hide <name> sessions" when off, and "<count> <name> sessions hidden. Tap to
show them." when on, with "remote sessions except cloud" in place of "<name> sessions" for two or
more providers. The chip carries `aria-pressed`.

### A tap

A tap flips the chip at once and sends the change to the laptop. The phone holds its own value for
that repo until the laptop's list reports the same value, or until the request fails. On a failure
the chip flips back and a toast gives the laptop's reason.

## The shared setting

### Storage

A nullable column on `repo`, `registry_remote_hidden INTEGER`, added by a `.sql` migration with no
SQL default:

- **NULL** – nobody has chosen for this repo. It reads as off.
- **0** – somebody turned the filter off.
- **1** – the filter is on.

The migration, the GRDB `RepoRecord` and the `Repo` model in `TBDShared/Models.swift` change in one
commit. The model field is `registryRemoteHidden: Bool?`, nil for NULL, so an old row and old JSON
still decode.

The column is deleted with its repo row, so no saved set needs pruning when a repo is removed.

### Setting it

- **Socket RPC `repo.setRegistryRemoteHidden`** – takes `repoID` and `hidden`, writes 0 or 1, and
  broadcasts a state delta, as `repo.setHidden` does, so a running phone list wakes and gathers
  again. An unknown repo is an error.
- **Phone request `repo.setRemoteFilter`** – takes `repoID` and `hidden`, and calls the same core
  function. It answers `not_found` for a repo the phone's list does not show: an unknown repo or a
  hidden one. It answers `phone_control_off` while phone control is off, like every request.

### The phone's list

`PhoneGroupLayout` gains `remoteFilterOn`, present and `true` on a repo group whose column is 1,
and absent otherwise. A change to the column changes the layout, so the sessions publisher sends
the new layout in a `sessions.changed` event. The protocol fixtures under `phone/protocol/` gain the
new request, its reply and a layout that carries the field.

### The Mac

- `AppState` reads the setting from each `Repo` in its repo list, not from `UserDefaults`. A click on
  the header button or the menu item flips the repo in the app's list at once and calls
  `repo.setRegistryRemoteHidden`. A failed call puts the old value back.
- A change made on the phone reaches the Mac at its next repo refresh.
- **The one-time copy.** After the first successful repo refresh, the app reads the old
  `sidebarRegistryRemoteHiddenRepoIDs` key. For each listed repo that is still in the repo list and
  whose `registryRemoteHidden` is nil, it calls the RPC with `hidden: true`. A repo with a value
  already, such as one the phone turned off, keeps it. A listed ID with no repo is dropped. When
  every call succeeds, the app removes the key. When any call fails, the key stays and the copy runs
  again at the next refresh; setting a value twice is harmless.
- The Mac spec's storage section is rewritten to state this design.

## Rollout

No feature flag. Nothing is hidden until a person taps the chip, and the chip shows only where
there is something to hide, so the phone change is additive UI. The phone app as a whole is still
behind `phone_control_enabled`. On the Mac, only where the setting is stored changes, and the
one-time copy keeps every choice already made.

The phone app bundle and the daemon come from the same build, so the new request and layout field
carry no compatibility burden (phone spec, section 4.4).

No new durable external resource: the only new state is a column on an existing row, deleted with
that row.

## Rejected alternatives

- **The daemon leaves hidden rows out of the phone's list.** The phone would have no count, the
  daemon would have to track which session each phone has open, and the phone's action gate
  (`PhoneSnapshotBuilder.listsRemoteSession`) would refuse actions on a hidden session opened by a
  link or a restore.
- **Keep the Mac's `UserDefaults` and copy it to the daemon.** Two stores for one setting, and a
  change made on the phone would have to flow back into the Mac's store.
- **A setting of the phone's own.** A person who hides these rows at the desk wants them hidden on
  the phone too, and the phone's frame has no storage that survives a reload.
- **A file under `~/tbd/repos/<repoID>/`.** Files there hold user-authored blobs. A per-repo
  boolean is a small structured setting, which belongs in a column.

## Testing

- **Phone, the rule (`sessionsView`):**
  - a remote lane row and a loose session row of a registry provider are hidden in a filtered repo
  - local rows and cloud rows are kept
  - the selected row is kept, and the count drops by one
  - an unfiltered repo, the scratch group and a provider group are unchanged
  - a repo emptied by the filter keeps its header
- **Phone, the chip:** absent with no registry rows and with only cloud rows; present when off with
  one registry row; present when folded; absent when on with nothing left to hide; the one-provider
  and two-provider wording; the count.
- **Phone, a tap:** the chip flips at once, stays flipped until the layout agrees, and flips back
  with a toast on a refusal.
- **Daemon:**
  - a repo row from before the migration reads NULL, not 0
  - the RPC writes 0 and 1 and broadcasts a delta
  - the phone request sets the column, and refuses an unknown or hidden repo
  - the snapshot carries `remoteFilterOn` only on a filtered repo group, and a change to the column
    changes the layout
  - the protocol fixtures round-trip
- **Mac:**
  - the filter reads from the repo list
  - a toggle calls the RPC, and a failure restores the old value
  - the one-time copy sets only nil repos, drops unknown IDs, removes the key after full success,
    and keeps it after a failure
