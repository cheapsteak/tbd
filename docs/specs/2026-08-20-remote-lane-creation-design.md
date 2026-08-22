# Remote lane creation: one click, and the answers behind it

Starting an agent session on a remote machine should cost what starting a local
worktree costs — one gesture from the `+` menu, landing where the user pointed.
This document records the decisions that make that possible: when TBD may
create without asking, where each create-param answer comes from, the one field
that refuses to fall through, how the stored answers are shaped, and the one
contract addition the feature needs.

The subject is the **creation** path. Where a lane is filed once it exists, and
who may reparent it afterwards, belongs to the adoption rules in
[`docs/remote-provider-contract.md`](../remote-provider-contract.md) and to
[`2026-08-22-remote-lane-parent-healing-design.md`](2026-08-22-remote-lane-parent-healing-design.md),
which records why a lane adopted without a parent may take one exactly once.

## One-click creation

**Create immediately when every required field is answerable; open the form
only when a required field cannot be resolved.**

The `+` menu's remote-lane row asks the precedence chain below for every field
the provider declared. If nothing required is left blank, there is no question
to put to the user, so no sheet is shown and the create call goes out. If
anything required is still empty, the sheet opens prefilled with everything
that *was* resolved, and the user answers only the remainder. The row labels
itself honestly for whichever outcome applies — a trailing ellipsis promises a
dialog, and its absence promises a create.

Four situations always open the form, and they are the shape of the rule rather
than exceptions to it: the provider has not reported its `create_params` yet,
so TBD does not know what it would be answering; a required field no level
could answer; the provider asks which repository to work in and no repo-scoped
level could say (see "`repo` refuses to fall through" below); and a resolved
value that fails the same local validation the form applies, since that error
belongs in front of the user next to the field it concerns.

**Rejected: always one-click, letting the provider reject what TBD guessed.**
This reads as simpler and is worse in exactly the case that matters. A provider
declaring a required field TBD has no ambient source for — anything outside the
well-known names — becomes uncreatable from the `+` menu: every click produces
a provider-side validation error about a field the user was never shown, with
no way to supply it short of finding the other entry point. The form is not a
fallback for TBD's convenience; it is where a question TBD cannot answer gets
asked.

**Rejected: a modifier-key variant** (plain click creates, ⌥-click opens the
form, or the reverse). It puts a second, invisible meaning on the same row.
Whether a click will open a dialog is already decided by facts TBD holds before
the click, so the row can simply say which it will do — a hidden alternate
gesture adds a mode where a label suffices.

## The precedence chain

Four levels, highest first:

1. **The repo's stored map** — `repo.remote_create_defaults`, what the user
   saved for this repository.
2. **Ambient prefill** — what this click itself implies: the repo whose `+` was
   clicked, and a freshly generated lane `slug`.
3. **The machine-wide stored map** — `config.remote_create_defaults`.
4. **The provider's declared `default`** for the field.

The first level to produce a non-blank value wins; a blank at any level falls
through as though it were absent.

This mirrors the model-profile precedent, which resolves
`repo.profile_override_id` → `config.default_profile_id` in
`ModelProfileResolver`: repo-scoped storage outranks machine-wide storage, and
a level that cannot answer defers rather than substituting a blank.

**Ambient sits inside the repo tier, above the global map, not below both
stored levels.** The ambient value is repo-scoped evidence — the user clicked
*that* repository's `+`, which is a fact about this click and about no other.
Ordering a machine-wide stored value above it would let a `repo` saved once, in
another repository's settings, decide where a session lands on a multi-repo
machine: the user clicks `acme-app`'s `+` and gets a live session in
`acme-infra`. The repo's own stored map still outranks ambient, because that
map is scoped to the same repository and is the more specific statement about
it — a user who saved "always create against this fork" for this repo meant it.

## `repo` refuses to fall through

Every field walks the full chain except one. **`repo` stops after the repo tier
— the repo's stored map and ambient prefill.** If neither can say, TBD does not
consult the machine-wide map, does not take the provider's declared default,
and does not omit the field: it opens the form and asks. This holds even when
the provider declares `repo` as optional, because an omitted `repo` is answered
by the provider's own default — the same wrong repository through the other
door.

The asymmetry that forces it has been observed, not assumed: letting `repo`
fall through like every other field reaches the provider's declared default and
silently creates a live session against a repository nobody chose. There is no
supported undo — archive and forget both refuse remote lanes — so the session
exists on the remote machine, the row exists in TBD's tree, and the only remedy
is to clean up by hand at the provider.

The general rule it encodes is worth more than the special case:

> **A field whose wrong value targets a different real-world resource must be
> answered only by evidence scoped to that resource.**

A wrong `permission_mode` produces a session that behaves differently from what
was wanted, and the user changes it. A wrong `repo` produces work against
someone else's code. The cost of the two mistakes is not the same, so the
resolution rules for the two fields are not the same either. When a future
field has that property — an account, an environment, a cluster — it belongs on
the `repo` rule, not the general one.

## Storage: a generic map, keyed by the provider's own field names

The stored defaults are a `[String: String]` keyed by whatever the provider
declared in `create_params`, in two places — one column on `repo`, one on
`config` — and TBD replays the values without interpreting them.

**Not a column per setting.** The setting that motivated stored defaults is
`permission_mode`, which is not a contract well-known name: it is one
provider's vocabulary. A `repo.remote_permission_mode` column would bake that
vocabulary into TBD's schema, need a migration for the next provider's next
field, and leave TBD holding an opinion about a concept it does not model. The
generic map costs one column for the whole class, and gives `cmd`, `branch` and
anything else a provider declares its defaults for free.

**Values are re-validated against the field as currently declared, on every
replay.** A stored `enum` value is projected onto the field's `values` list at
resolution time, and a candidate that matches nothing is dropped so the next
level gets its turn. `enum` is the one type with a closed value set, and a
provider is free to retire a value between the moment it was stored and this
create. Replaying it blindly would put the create back into exactly the failure
this feature also fixes — a value the provider rejects, surfaced as an error
about a field the user did not touch. Degrading to the next level is strictly
better than either that or inventing a selection.

The same projection also bridges naming conventions in the other direction: a
candidate is matched exactly, then case-insensitively, then by the last
`/`-separated component of both sides, and the last rung requires a unique hit.
It stops there deliberately — no substring, prefix, or fuzzy rung — because a
wrong guess here is a session created in the wrong repository, and ambiguity
must resolve to "no match" rather than to whichever value was listed first.

**The trade accepted:** if a provider renames a field, its stored default
silently stops applying. The value is dropped rather than misapplied, so the
create degrades to the next level instead of failing, which is the safe
direction for a map TBD does not interpret.

## Contract change: `slug` is a well-known `create_params` name

`slug` joins `repo`, `branch`, `prompt` and `title` in the contract's
well-known list, so a caller may generate a lane identifier of its own choosing
for it.

Well-known is a **caller-side prefill convention and nothing more**: it obliges
a provider to nothing, changes no validation, and names a field the provider
already declares if it wants one. So no provider change is implied by this
edit — a provider that declares `slug` simply becomes one whose form a caller
can fill in without asking.

It is load-bearing rather than tidy-up. One-click can only fire when every
required field is answerable, and the only real provider today requires `slug`
with no declared default. Without this addition TBD has no ambient source for
it, the form opens every time, and one-click never fires for the one provider
it exists to serve.

TBD fills it from `NameGenerator`, the same generator that names local
worktrees, so a remote lane reads like every other lane in the sidebar instead
of introducing a second naming scheme.

`branch` is deliberately left unfilled even though it is well-known. It is
optional, and a blank optional field is omitted from the params entirely, so
the provider's own answer applies — which is the better one: TBD would be
inventing a branch name that exists nowhere, while the provider knows what its
backend does with an absent branch.
