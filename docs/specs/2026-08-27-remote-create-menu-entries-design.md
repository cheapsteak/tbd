# Remote create menu entries: a named place, and a list you configured

TBD can start an agent session somewhere other than this machine. Two kinds of
"somewhere" exist, and they are not the same kind of thing:

- **The compiled Claude Cloud provider.** TBD ships it. A user who has turned
  `claude_cloud_enabled` on did so by name, and comes to the `+` menu looking
  for the thing they enabled.
- **A registry provider.** The user wrote it into `~/tbd/agent-providers.json`
  themselves. They already know its name, because they chose it.

This document fixes how the create surfaces present those two. The short form:
**the cloud provider gets an entry of its own, and is not a member of the
generic enumeration.** Everything else about the two entries — when they act
outright, when they ask first, what they do when the provider is unhealthy,
whether they may nest — is identical.

Scope is presentation. No flag, no migration, and no config column: this is how
existing create paths are offered, over the existing default-off
`claude_cloud_enabled`.

## Why cloud is not just another row

A single generic row can name the cloud provider — with one provider
registered, the row's subtitle carries the negotiated `describe` name, so
"Run on Claude Cloud" does appear. That is enough to identify the row once you
are reading it closely, and not enough for the job the row has.

The menu is scanned, not read. A user who enabled a feature called Claude Cloud
is looking for the word they enabled, in the position a title occupies. Making
them infer it from a subtitle under a generic title spends their attention to
save a row. Worse, the inference fails exactly when the fleet grows: add one
registry provider and the subtitle stops naming any provider at all — it
becomes "Choose a provider", and the only path to cloud is a drill-in page the
user has no reason to expect it behind.

The generic row earns its generic title for the opposite reason. Its members
are user-authored; the user's own config file is the authority on what they are
called, and TBD enumerating them is the whole service it provides.

So the two entries are siblings, never nested inside one another. Cloud is
filtered **out** of the generic list rather than surfaced twice: a shortcut that
duplicates one entry of a list teaches that the list is incomplete somewhere
else too, and it makes "how many providers are there" ambiguous at exactly the
moment the count decides whether the generic row drills in.

## The gates

Three named functions in `CloudCreateEntryPresentation`, and no surface derives
a gate inline:

- **`registryProviders(_:)`** — every provider except the compiled cloud one.
  This is what the generic row and both context-menu submenus enumerate. It
  does not consult `claudeCloudEnabled`: cloud is never in this list, so the
  flag has nothing to say about it.
- **`cloudEntry(_:claudeCloudEnabled:)`** — the compiled provider when the flag
  is on and the daemon registered it; nil otherwise. A stale snapshot does
  **not** withdraw it (see "Staleness disables" below).
- **`offersCreate(provider:claudeCloudEnabled:)`** — the per-provider verdict
  the Remote section's provider header row needs for its own `+`: true for
  every provider except the cloud one with the flag off.

The flag check lives in the last two and nowhere else. Its subject is narrow
and worth stating: a provider that was never registered is already absent from
`remoteProviders` and needs no filtering. What the flag covers is a daemon that
**booted** with `claude_cloud_enabled` on and a user who has since turned it
off — the provider is still registered, and every one of its verbs is refused
by the daemon's inner gate. An entry that can only fail is what
omit-don't-disable exists to prevent.

## Five entries, four surfaces

- **Repo-header `+` picker** — cloud row, then generic row, both in the top
  group above the profile list.
- **Nested worktree-row `+` picker** — the same pair. Cloud nests; see
  "Nesting" below.
- **Repo context menu** — a "New Cloud Session…" item beside the existing "New
  Remote Session…" item (which becomes a submenu at two or more registry
  providers).
- **Worktree-row context menu** — the same pair, behind that row's existing
  `isMain` gate. The main worktree is the repo's checkout, not a parent to nest
  under, so it offers neither.
- **Remote section provider header row** — its own `+`, gated per provider by
  `offersCreate`.

The pairing is what makes the split safe: because a cloud entry accompanies the
generic one on every surface that had a generic one, removing cloud from the
enumeration takes nothing away.

## Both entries behave alike

**The ellipsis is a promise, kept exactly when it is made.** A row that will
open the create form carries a trailing "…"; a row that will create outright
carries none. The decision comes from `RemoteCreateFormLogic
.willCreateImmediately`, asked with the same inputs the click itself uses, so
the label and the action cannot disagree. The cloud row obeys this like any
other — it is special in placement, not in behavior.

A row that drills into the provider list never spends the ellipsis on that
fact: its trailing chevron already says so, and the provider chosen on the next
page may create outright. Each row on that page then makes the promise for
itself.

**One provider acts directly.** The generic row with exactly one registry
provider *is* that provider — its name in the subtitle, selecting it starts the
session. A page containing a single row asks the user to confirm a choice they
had no alternative to. The drill-in exists to disambiguate, so it appears when
there is something to disambiguate.

**The `+` menu's rows are the one-click path; the context-menu items always
open the form.** That asymmetry is deliberate: a
nested lane created one-click has no other surface on which to type a prompt or
pick a branch, so the context menu keeps an always-asks entry point next to the
sometimes-acts one.

## Staleness disables, never withdraws

A provider whose inventory snapshot is stale keeps its row on every surface,
rendered disabled and subtitled "Unavailable — inventory is stale". This holds
for the cloud entry and for registry providers alike.

Omit-don't-disable is the convention for capabilities **this install does not
have**, where a row would advertise something untrue. Staleness is a transient
state of a capability the install *does* have. To a user hunting for a provider
they know is configured, absence reads as "TBD dropped support for this" — an
error that is both wrong and unrecoverable from inside the menu, because there
is nothing left to click and no text explaining anything. A dimmed row naming
its own reason costs one line and answers the question.

**Rejected: withdrawing the cloud entry on staleness** on the grounds that the
daemon would refuse the create with "inventory is stale", so a row leading to a
guaranteed error is worth no row. The premise is true and the conclusion does
not follow: the row is not only a button, it is also the menu's statement about
what exists. Suppressing it suppresses a true statement to avoid an error the
row can simply decline to commit.

**Rejected: withdrawing every stale provider,** harmonising the other
direction. Same objection, applied more widely, and it can empty the menu of
remote entries entirely during a transient outage.

## Nesting

`parentWorktreeID` is not a gate on either entry. The nested `+` promises the
new lane nests under that worktree, and the create path keeps that promise:
`RemoteCreateParams.parentWorktreeID` carries the click through to adoption.

**Rejected: cloud sessions on the repo header only,** on the theory that a
cloud session is created against a repository and not beneath a lane. That
describes a limitation of one implementation of one provider, not a property of
remote sessions. Nesting is TBD-side filing — where the row appears in the
user's tree — and the remote side neither knows nor needs to know about it. A
provider that genuinely could not be filed under a parent would be saying
something about TBD's tree, which is not a thing a provider gets to say.

## Testing

The cross-surface parity suite is the load-bearing test, and it exists because
these gates are duplicated across surfaces that are easy to edit one at a time.
It covers five entries rather than four, and asserts the same verdict from each
for a given (providers, flag, staleness) input:

- Flag off, cloud registered: every surface hides the cloud entry.
- Flag on, healthy: every surface shows it.
- Never registered: every surface shows nothing for it, with no flag
  dependence.
- Stale: every surface **shows it, disabled** — one verdict, no divergence.
- A registry provider is unaffected by the flag in every state.
- Cloud never appears in `registryProviders`, at any flag value.

Both flag branches stay covered, per the repository's rule that a gating
conditional gets a test per branch.

## Non-goals

Repo-declared remotes and their trust gate, the resolution ladder above tier 1,
and any change to the create form itself are out of scope. So is the shape of
the precedence chain that decides whether a click can create outright, which is
fixed by
[`2026-08-20-remote-lane-creation-design.md`](2026-08-20-remote-lane-creation-design.md)
and only consumed here.
