# Status bar for remote sessions

**Date:** 2026-09-26
**Status:** Approved, not built.
**Depends on:** [`docs/remote-provider-contract.md`](../remote-provider-contract.md)
(the Session object's `meta` map and its well-known keys, Worktree identity
keys, and `land <id>`'s branch-name rules),
[`2026-08-10-remote-sessions-in-worktree-tree-design.md`](2026-08-10-remote-sessions-in-worktree-tree-design.md)
(adoption and the local/remote boundary),
[`2026-08-16-remote-lane-archive-design.md`](2026-08-16-remote-lane-archive-design.md)
(auto-archive of a remote lane on merge).

## Summary

For a local worktree the status bar answers three questions about the selection:
where it lives (the tilde-abbreviated path, click to copy), which branch it is on,
and which PRs belong to it. For a remote lane it answers none of them. The bar's
location and branch cluster takes a `LocalWorktree`, which a remote row can never
be, and the PR chips are gated on the same value — so the lane's own PRs, which
the daemon already tracks, are not shown either.

This design gives a remote row the same three answers:

- **Location** comes from a new well-known `meta` key, `location`, carrying host
  and working directory together as `host:/abs/path`.
- **Branch** is the session's *live* branch — `meta.branch` on the latest
  snapshot — not the branch recorded when TBD adopted the row.
- **PRs** are the union of what TBD finds itself from repo and live branch, and
  what the provider names in a second new key, `prs`. TBD always reads PR status
  from its own forge lookup; a provider's list is only a pointer.

The live-branch rule also fixes PR discovery itself. Discovery for a remote row
matches PRs by the row's stored branch, which is frozen at adoption. A remote
agent typically starts from the branch it was created on — usually `main` — and
later pushes its own branch, so today TBD looks for PRs whose head is `main`: it
finds nothing, or finds an unrelated PR opened from `main`, and a branch-found PR
can auto-archive an armed lane.

## Why the stored branch and the live branch differ

Adoption reads a session's identity once, when it creates the row, and never
re-derives it: the row's name, identifier, branch, and position are the user's
from then on. That rule is right for identity and wrong for lookup. The branch a
session was created with names where it *started*; `meta.branch` on a later
sighting names where its work *is*. An agent created from `main` that pushes
`claude/fix-flaky-ci` reports the first at adoption and the second on every
snapshot after.

So the two are kept apart. The row's stored branch stays frozen as identity and
is never rewritten. Everything that asks "which branch is this session on now" —
the status bar and PR discovery — reads the live value.

## Contract changes

A new subsection of the Session object, **Location and PR keys (optional)**, on
the same terms as the identity keys: both keys are optional and purely additive,
readable at either contract major because they ride inside `meta`, and require no
change to a provider's declared `contract_versions`.

### `location`

Where the session's working directory is, as `host:/abs/path`:

- `host` is a hostname, `user@hostname`, or a bracketed IPv6 literal
  (`[fe80::1]:/srv/acme-api`). A bracketed host ends at `]`, which must be
  followed by `:`; otherwise the host ends at the first `:`.
- The path is absolute — it begins with `/`.
- There is no scheme and no port. The value contains no whitespace and no ASCII
  control characters.

The host is mandatory. A provider that cannot name a host a human could reach —
a managed sandbox that exposes none, a session not yet placed on a machine, a
machine already reclaimed — omits the key rather than inventing one. Absence is
the normal case for many providers and needs no explanation.

A caller that cannot parse the value treats the key as absent and logs the
rejection. It displays the value and copies it verbatim, and never connects to
it: `location` is a place for a human to read and paste into `ssh` or `scp`, not a
transport TBD dials. That is also why the format is scp-style rather than a URL —
a scheme would imply a connection the caller never makes, and would force a
provider whose sessions are not reachable over SSH to claim a transport anyway.

### `prs`

Whitespace-separated absolute PR or merge-request URLs:

- GitHub — `https://<host>/<owner>/<repo>/pull/<number>`
- GitLab — `https://<host>/<group path>/<repo>/-/merge_requests/<number>`

A URL carries the host, owner, repository, and number, so it identifies a PR
unambiguously, names its forge, and can name a PR in a repository other than the
session's own `repo`. URLs contain no whitespace, so splitting is unambiguous. An
entry that does not parse is dropped on its own, with a log line; the rest stand.

The list is a pointer, never a status: a caller reads each PR's state from its own
forge lookup. Unbinding is always the user's gesture. A PR that later drops out of
`prs` stays bound to the lane, and a PR the user detached is not revived because
the provider keeps naming it.

### `branch`

One sentence joins the Session object's `meta` paragraph: a caller reads the
latest sighting's `branch` as the session's current branch — for PR lookup, for
example — while the branch recorded at adoption remains the row's identity. The
existing rule that TBD never rewrites a row's branch on a later sighting is about
the row and is unchanged.

## Daemon: PR discovery for a remote row

### Branch matching reads the live branch

The poller already admits remote rows and runs their lookups in the repository's
own checkout. What changes is the branch it matches:

- For a remote row, the branch is `meta.branch` from the latest snapshot in
  `RemoteProviderManager`'s mirror. The row's stored `branch` column is never used
  for a lookup.
- When the live branch is absent, blank, or fails the branch-name rules in the
  contract's `land <id>` section, the row is not matched by branch on that pass.
  PRs already bound to it keep refreshing through the existing bound-number path.
  There is no fallback to the stored branch: it is exactly the value that matches
  the wrong PRs.
- Every branch comparison in the PR pipeline uses the live value, including the
  head-ref-mismatch check that clears a worktree's cached status.
- A branch change adds PRs and never removes them. A PR bound while the session was
  on an earlier branch stays bound, because only a detach removes a binding.

### Provider-named PRs bind as `.provider`

`PRBindingSource` gains a case, `.provider`. On each snapshot that carries `prs`,
each parsed URL is bound to the session's row through `PRBindingCoordinator.bind`
with that source, on exactly the terms `.branch` binds on:

- **Dedupe** is on `(host, owner, repo, number)`, the binding store's existing
  key. A PR found by branch, by the `gh pr create` hook, and by the provider is
  one binding and one chip, under whichever source bound it first.
- **Tombstones refuse it.** `.provider` is an automatic source, so a PR the user
  detached stays detached however long the provider names it. Only `tbd pr attach`
  revives a tombstone.
- **Only adopted rows bind.** A session with no row — its `repo` resolved to no
  registered repository — gets no bindings.
- **At most 20 URLs per session** are bound; the rest are ignored with a log line.
  A misbehaving provider must not turn one snapshot into an unbounded fan-out of
  forge queries.

A binding in another repository gets its status from a lookup keyed by its own
`(host, owner, repo, number)`, not from the row's repository, and asked of its own
host: a GitHub Enterprise pull request is queried against that Enterprise server,
never against `github.com`, where the same owner, repository and number may name
a different pull request. A GitHub host other than `github.com` is queried only if
`gh` is already authenticated to it (it appears in `gh auth status`). The host
comes from a provider-supplied URL, so it is untrusted, and `gh` sends an
Enterprise token from the environment to whatever non-`github.com` host it is
pointed at; asking only hosts the user has logged `gh` in to means a provider can
never make TBD post a credential to a host of its choosing. When the host is not
one `gh` is authenticated to, cannot answer — unreachable, a repository TBD cannot
see — or is not a plain hostname TBD will pass to `gh`, TBD runs no query against
it and the chip shows the never-observed state rather than disappearing, since
the provider did claim it. There is no fallback to another host. A chip whose status TBD can never read still earns its place: it is the PR's
link in a stable spot beside the lane, one click from the forge's own view,
instead of a URL the user has to hunt for in the session's history.

Auto-archive is unchanged. A merged `.provider` binding feeds the existing
merged-transition rail on the rail's existing rule: it counts as the lane's own
work only when its head matches the lane's live branch or its number is the
lane's PR. Because a `.provider` binding is the one source bound without the
own-repository check, it must also be in the lane's own repository (same host,
owner and name) before either comparison applies — a branch name or a number
identifies a PR only within one repository. A provider's claim alone never
retires a lane — an already-merged earlier PR, or a companion repository's PR
the provider names, cannot archive it, even when its head shares the lane's
branch name. A lane whose only PRs came from the provider, with no matching branch, is not
auto-archived.

A never-observed binding — one whose status TBD cannot read — leaves the lane's
bindings unresolved, since the rail requires every non-detached binding to be
terminal. It holds off auto-archive until the user detaches it, erring toward
keeping the lane. Arming stays a deliberate per-lane gesture.

No migration is needed: the source is stored as its raw string in an existing
text column. An older daemon reading a `.provider` row after a downgrade must
degrade rather than fail; the implementation verifies this and, if decoding is
strict, makes it lenient.

## App: the status bar for a remote row

When exactly one remote row is selected, the bar's left cluster shows, in order:

- **Location** — a `CopyableStatusText` of the verbatim `location` value. No tilde
  abbreviation, since the remote home directory is unknown. Middle truncation, so
  both the host and the leaf directory stay visible in a narrow window. The
  tooltip reads "Click to copy \<location\>" and the confirmation "Copied
  location".
- **Branch** — the live `meta.branch`, in the same branch control local rows use.
- **PR chips** — `effectivePRBindings` for the row, in the same `PRChipCluster`
  local rows use, so the bar, the toolbar, and the sidebar indicator cannot
  disagree about a lane's PRs.

The values come from the latest `remoteSessions` snapshot for the row's
`(provider, sessionID)`. A missing or unparseable key hides only its own element.
When the mirror is stale because the provider is unreachable, the bar shows the
last-known values — the mirror's existing stale-but-shown rule.

The location slot only ever holds a location. With no `location` key it is empty;
it never falls back to the provider name, the session id, or anything else, since
a slot that shows different kinds of data depending on the provider leaves the
user unable to tell what they are looking at. The provider name and session id do
not appear in the status bar at all.

Unchanged:

- **Other status-bar elements.** A remote row gets no open-in-editor button and no
  auto-archive chip; the toolbar's badge and help text still state a remote lane's
  arming.
- **The sidebar.** It shows no branch for any row, local or remote, and still
  doesn't. The branch is one selection away.
- **A landed lane.** Landing turns the same row local, so it gets the ordinary
  local rendering — local path, local branch, local discovery — and nothing
  remote. After a forking landing the remote session is a different line of work;
  after a non-forking one the work continues here. Either way the local checkout
  is what the row now is.

## Placement

The status bar and the PR poller are compiled already, and this design changes
only what they read. The part that varies by provider — knowing a session's host,
working directory, and PRs — stays user-land: a provider populates two keys, and a
provider that cannot omits them and loses nothing it has today.

## No flag

Nothing here ships behind a flag, for four reasons:

- The whole remote subsystem is already behind its own flag.
- Auto-archive of a lane requires a deliberate arming gesture, and this design
  does not change the rail.
- A provider sets `location` and `prs` only on purpose; without them, the new code
  paths do nothing.
- Reading the live branch fixes discovery that matches the wrong branch today.
  Gating it would keep that defect as the default.

The status-bar rendering is small, additive UI.

## Reconcilers

No new kind of durable resource is created. `.provider` bindings are rows in the
existing binding store and follow their worktree row's lifecycle like every other
binding.

## Testing

- **`location` parsing** — `host:/path`, `user@host:/path`, `[fe80::1]:/path`
  accepted; a relative path, a missing host, an unbracketed IPv6 literal, a port,
  whitespace, and control characters rejected.
- **`prs` parsing** — GitHub and GitLab URLs accepted, including a nested GitLab
  group; junk entries dropped individually; the 20-URL cap enforced.
- **Poller branch choice** — a remote row whose stored branch is `main` and whose
  live branch is `claude/fix-x` is matched on `claude/fix-x`; an absent or invalid
  live branch skips branch matching without falling back; a local row still uses
  its stored branch.
- **`.provider` binding** — refused by a tombstone and revived only by a manual
  attach; deduped against a `.branch` binding of the same PR; still bound after it
  drops out of `prs` and after the live branch changes.
- **Status-bar label** — a pure helper over a remote row and its snapshot, with
  `location` and `branch` each present, absent, and malformed; a local row's label
  unchanged; a landed row rendered as local.

## Rejected alternatives

- **A URL form for `location`** (`ssh://user@host:port/path`). It handles ports
  and IPv6 through a standard parser, but it names a transport the caller never
  uses and forces a scheme on providers that have none to offer.
- **Separate `host` and `workdir` keys.** Two keys admit half a location, and the
  value is only useful whole.
- **Falling back to the stored branch** when the live one is absent. The stored
  branch is usually the creation branch, so the fallback preserves the defect it
  would be guarding against.
- **Display-only provider PRs.** Chips computed from each render's `prs` could not
  be detached, and would vanish when the provider stopped naming them.
- **Provider-named PRs count as the lane's own work.** A provider's claim alone
  would become an autonomous archive trigger: an already-merged PR named on first
  sighting would retire the lane at once. A new autonomous trigger of that kind
  would need its own default-off flag and soak.
- **Excluding `.provider` bindings from auto-archive.** It guards against a
  companion repository's PR merging first, but introduces a binding that does not
  count; how a merge of one of several bound PRs is treated is the rail's rule for
  every source, not this design's.
- **`provider · session-id` in the location slot** when `location` is absent. See
  the status-bar section: one slot, one kind of data.
- **A branch on sidebar rows.** Local rows do not show one, and a remote-only
  addition would distinguish the rows for a reason unrelated to where they run.
