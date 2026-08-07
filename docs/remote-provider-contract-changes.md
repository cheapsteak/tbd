# Migrating a remote agent provider from contract v1 to v2

This guide is for someone who already maintains a working provider against
version 1 of the remote agent provider contract and wants to know, concretely,
what version 2 changes. The normative specification is
[`remote-provider-contract.md`](remote-provider-contract.md); this document
exists only to tell a v1 implementer what is different and what, if anything,
they should do about it.

## Nothing breaks

**A v1 provider is a valid v2 provider with no code changes at all.** Read that
first and stop worrying about the rest.

v2 is purely additive:

- **No new required verbs.** `describe`, `create`, and `list` are still the
  required set.
- **One verb becomes *less* required.** `stop` moves from required to a declared
  capability. A provider that already implements it keeps working exactly as
  before by declaring the `stop` capability.
- **New response fields default to v1 behavior when absent.** Omitting them
  produces precisely the semantics a v1 caller already gets.
- **Every new verb is gated behind a capability string.** A caller invokes it
  only when you declare it, so an undeclared verb is never called.
- **No field is removed, renamed, or given different semantics.**

So the entire adoption step is a one-line change in `describe`: declare
`"contract_versions": [1, 2]`. You may do that today, implementing nothing new,
and remain fully conformant. Everything else in this document is opt-in, and
each item below states plainly what happens if you ignore it — in every case the
answer is "your provider behaves exactly as it does under v1."

The rest of this guide covers, per change: what it is, whether it is required,
what you gain by adopting it, and what you experience if you don't.

## 1. `complete` on list and snapshot envelopes

**What it is.** The `list` response envelope and the `events` stream's
`snapshot` event may carry a boolean saying whether the enumeration is the
provider's whole inventory:

```json
{"complete": true, "sessions": [...]}
```

- `complete: true` — this is your full inventory. The caller applies the v1
  drift rule unchanged: a session absent from two consecutive successful
  snapshots is considered gone.
- `complete: false` — this is a partial view. The caller may add and update rows
  from it, but must not retire anything and must not count any session as
  absent.
- Absent — treated as `true`.

"Complete" means complete with respect to the set the caller mirrors, which
under v2 includes archived sessions (see the next section). A provider that can
enumerate active sessions but not archived ones reports `complete: false`.

**Required?** No. Absent means `true`, which is exactly v1's behavior.

**Who should care.** Only a provider that sometimes cannot enumerate everything
it owns. If every successful `list` you return is your genuine full inventory —
which is the normal case, and was v1's only case — you can ignore this field
forever and nothing changes.

**What it prevents.** The v1 drift rule assumes a successful snapshot is
authoritative about what exists. If you return a partial list without saying so,
every session you couldn't see this time looks absent, and after two such
snapshots the caller marks live sessions as gone — a visible, wrong state on
sessions that are running fine. Reporting `complete: false` suppresses that
inference for as long as your view is partial.

This is the difference between a partial view and a failure, and the v1 rule
about failures still holds: a transport-overload or unreachable failure is still
a transient error (exit 3), never a successful empty list. `complete: false` is
for "I really did enumerate, but only part of what I own," not for "I couldn't
reach my backend."

**The cost of over-reporting it.** A partial snapshot does not refresh the
caller's freshness clock. The caller keeps showing its staleness indicator and
keeps whatever restrictions it applies to a mirror it considers stale, because
presenting a half-blind inventory as current would be worse than admitting the
gap. So report `complete: true` whenever you honestly did enumerate everything;
a provider that reports `false` unconditionally will look permanently stale.

**If you ignore it.** Nothing changes. Your snapshots are treated as complete,
exactly as under v1.

## 2. `archived` on the Session object

**What it is.** The Session object gains an optional boolean `archived`,
defaulting to `false`. It is a third axis, orthogonal to the two v1 axes:

- `state` — process/session liveness (`starting`, `running`, `exited`).
- `agent_state` — whether a human needs to look.
- `archived` — whether the session has been retired from the active working set.

A session can be archived while its machine is still winding down, and an active
session is never implicitly archived. Nothing about `archived` implies anything
about `state`, and nothing about `state` implies `archived`.

**Required?** No. Omit it and every session reads as not archived, which is v1's
model exactly.

**Normative rule if you do have an archive concept: archived sessions MUST still
be returned by `list`.** Do not filter them out server-side. Two things go wrong
if you do:

- **They look absent, and the drift rule retires them.** From the caller's side,
  a session that vanishes from the snapshot is indistinguishable from a session
  that was deleted. Archiving one of your sessions would silently produce a
  "gone" row instead of an archived row.
- **The caller loses the archived inventory it needs.** Archived sessions are
  browsable — the caller offers a way to look through them and revive one. If
  they never cross the wire, that flow has nothing to show.

The caller, not the provider, decides what to display: active sessions by
default, archived ones behind a filter. Your job is to report the fact
truthfully, not to curate the list.

**What you gain.** Your own notion of "done" or "archived" survives the trip
instead of being flattened into `state: "exited"`, and shows up on the caller's
side as the same kind of thing it already is on yours.

**If you ignore it.** Every session reports as unarchived. Everything works;
sessions you consider retired just aren't distinguishable from active ones,
beyond whatever `state` says.

## 3. `archive` and `unarchive` capabilities

**What they are.** Two new optional verbs, each declared by a capability string
of the same name:

```
p archive <id>
p unarchive <id>
```

Both are idempotent — archiving an already-archived session succeeds — and both
return the updated Session object.

**Required?** No. Declare them only if archiving is a real state change on your
backend.

**What you gain.** The caller can retire and restore sessions through your
backend, so the archive state is shared with every other client of it rather
than being one caller's private bookkeeping. This is the operation the caller
now uses for "retire this from my working set," which under v1 it had to
approximate with `stop`.

**If you ignore it.** The caller offers no archive action for your sessions.
Whatever archive concept you have stays internal to your backend, and `archived`
(if you report it) is read-only from the caller's point of view.

A note on what archiving means to your backend: it is worth being explicit in
your own documentation about whether an archived session still accepts input. If
archiving makes a session reject new messages, that is a genuine state change
and belongs behind `archive`, not behind a display preference.

## 4. `stop` is now optional, and means only "terminate"

This is the one place a working v1 provider's existing behavior is arguably
mismapped, so it gets the most space. It is still not a break.

**What changed.** In v1, `stop` was required and quietly did two jobs:
terminating the running compute, and retiring the session from the inventory. v1
had no archive concept at all — it said so explicitly, leaving archival as state
the caller kept on its own side — so nothing forced the two apart.

In v2 they are separate:

- **`stop` means terminate a running session, and nothing else.** It is now a
  declared capability rather than a required verb.
- **`archive` means retire the session from the active working set.**

`describe`, `create`, and `list` remain required.

**Why the split exists.** Some backends can do one and not the other. A platform
that reclaims idle compute on its own schedule, exposing no termination call to
clients, can retire a session but cannot terminate one — under v1 it could not
implement a required verb honestly, and had to either fake `stop` or lie about
the result. Conversely, a backend may be able to kill a process without having
any notion of a durable inventory to retire it from.

**What the caller does.** The stop action is now gated on the capability, the
same way attach already is. A provider that does not declare `stop` gets no stop
affordance, rather than an action that fails when invoked.

**What to do if your single existing operation does both.** This is the common
v1 shape: one operation — often called something like `done` — that tears down
the box and drops the session out of the active listing in a single call, with
`stop` wired straight to it.

The recommendation, in order:

1. **Declare both `stop` and `archive`.** Your one operation genuinely provides
   both meanings, so declaring both capabilities is more accurate than declaring
   only `stop`. Pointing both verbs at the same underlying operation is
   acceptable and is the smallest correct change.
2. **Then consider whether they should become separable operations.** Ask
   whether your backend can terminate compute without retiring the session
   record, and whether it can retire the record while leaving compute alone. If
   both are possible, splitting them gives users two distinct, useful gestures:
   "stop burning resources but keep this session in my list" and "I'm done with
   this, get it out of my way." If only the combined operation is possible, say
   so and keep both capabilities pointed at it.
3. **Report `archived: true` on sessions your operation retired**, so the
   caller can tell a retired session apart from one that merely exited.

**This is a recommendation, not a break.** A provider that declares only `stop`,
implements it exactly as it did under v1, and never mentions archiving is fully
conformant at v2. The caller shows a stop action and no archive action, which is
identical to what it did at v1.

**One real constraint if you drop `stop` entirely.** `stop` is required at
v1 and optional at v2. If you declare `contract_versions: [1, 2]` and omit
`stop`, a caller that negotiates v1 will still expect it. So a provider that
genuinely cannot terminate sessions and wants to omit the verb must declare
`contract_versions: [2]` only. Every other provider should keep `[1, 2]`. This
is the sole place in v2 where the two majors differ in what a caller may assume.

## 5. `transcript` — the conversation as structured messages

**What it is.** A new declared capability:

```
p transcript <id> [--since <cursor>]
```

stdout is Claude Code transcript JSONL. The cursor for the next call is returned
in a JSON envelope on **stderr**, not as a trailing line of the data stream.
(For every other verb stderr remains diagnostic and unparsed; this verb is the
one exception, and the exact envelope shape is specified in the normative
contract.)

The reason the cursor does not ride in the data stream is worth internalizing:
mixing a control record into the JSONL would make a truncated response
indistinguishable from a provider with no incremental support. Keeping the data
stream homogeneous means a short read is detectably a short read.

A provider with no incremental support simply returns no cursor, and the caller
refetches from the beginning next time. Cursors are entirely opaque to the
caller — any encoding you like, including an offset, a timestamp, or a server
token.

**Required?** No.

**Relationship to `log`.** `transcript` is not a replacement for `log`, and
neither one supersedes the other. `log` remains raw ANSI scrollback bytes for a
read-only terminal pane, for providers that host a terminal. Structured messages
rendered into a scrollback view would lose every tool card; ANSI bytes fed to a
transcript renderer produce garbage. Implement either, both, or neither.

**What you gain — this is the highest-value item in v2 for most providers.**
The verb is not vendor-specific in any way that should scare you off: **any
provider running Claude Code already has transcript JSONL sitting on disk.**
Declaring `transcript` and streaming files you can already reach upgrades your
sessions from raw ANSI scrollback to a structured conversation view with tool
cards — the same rendering a caller gives its own local sessions. For most
providers this is a small change reading files they already have access to, and
it is the single most visible improvement available.

Two details worth knowing when you implement it:

- The caller accumulates what you return, keyed by provider and session id, and
  appends each cursor-tailed response to what it already has. Returning a stable
  cursor therefore saves real work on every refresh, but not returning one is
  merely less efficient, never incorrect.
- File paths inside your transcript refer to a machine the caller cannot reach,
  and the caller knows this — it suppresses local file linking for remote
  transcript rows rather than opening an unrelated local file. You do not need
  to rewrite or strip paths.

**If you ignore it.** Sessions render with whatever `log` gives (raw scrollback)
or with no conversation view at all if you don't implement `log` either.
Everything else is unaffected.

## 6. `land` — reconstructing a remote session locally

**What it is.** A new declared capability:

```
p land <id>
```

Response:

```json
{
  "remote_url": "git@github.com:acme/api.git",
  "branch": "claude/fix-flaky-ci",
  "resume_command": ["claude", "--teleport", "sess_01ABC"],
  "forks": true
}
```

- **`remote_url`** – required. The repository the work belongs to.
- **`branch`** – required. The branch the work is on. It must already exist on
  the remote; the caller does not push anything on your behalf.
- **`resume_command`** – optional argv the caller runs in the new local
  workspace's first pane. Omit it when there is nothing to resume.
- **`forks`** – required boolean. Whether local work continues to reach the
  remote session. `true` means the two diverge from the moment of landing.

**Required?** No.

**What the caller does with the response.** It creates a local workspace for the
repository, checks out `branch`, and — if you supplied one — spawns the first
pane running `resume_command`. Preconditions are checked before anything is
created, so a failure never leaves a half-built workspace: the local
repository's configured remote must match `remote_url`, the branch must exist on
the remote, and the target workspace path must be free.

With `forks: true`, the caller presents the landed copy and the remote session
as two independent lines of work: it records the link between them, retires
neither, and never implies that typing in one reaches the other. Landing the
same session twice produces a second workspace on a suffixed branch
(`<branch>-2`, then `-3`) from the same commit, because one branch cannot be
checked out into two workspaces — deliberately, since two landings are two
independent lines of work.

Landing is always a user gesture. The caller never triggers it from session
state, so implementing `land` does not expose you to background invocations.

**Why this is cheap for many providers.** If your work materializes as a branch
pushed to a repository the user already has locally — which is the ordinary
shape for a remote agent that commits and pushes — then you already know both
required fields. `remote_url` and `branch` are session metadata you almost
certainly track. `resume_command` and a `forks: true` are then the entire rest
of the implementation. There is no new transport and nothing to stream.

**Validation the caller performs, and why.** These fields are not treated as
trusted input, because they may originate from session metadata that was created
somewhere other than the machine running the caller. Before any of them reaches
git:

- **`branch` must match a conservative ref-name pattern and must not begin with
  `-`.** A leading dash makes a branch name look like a command-line option to
  git, so it is rejected outright.
- **`remote_url` is only ever compared against the local repository's
  configured remote — never passed to git as a remote argument.** This is what
  rules out git's `ext::` transport family, whose URLs specify a command for git
  to execute. Your URL is used to answer "is this the same repository?" and
  nothing else.
- **`resume_command` is accepted only from a registered provider executable**,
  never from repository content.

So: emit an ordinary branch name and an ordinary clone URL and you will never
see a rejection. If you generate branch names from user- or agent-supplied text,
sanitize them to a plain ref name before returning them, or a hostile-looking
name will be refused at the gate rather than landed.

**If you ignore it.** The caller offers no land action for your sessions. Users
can still do whatever manual fetch-and-checkout they do today.

## 7. Version negotiation

The mechanics are unchanged from v1; only the values are new.

**Declaring.** `describe` reports every contract major you support:

```json
{
  "contract_versions": [1, 2],
  "name": "example-provider",
  "provider_version": "0.5.0",
  "capabilities": ["log", "send", "attach", "events", "stop", "transcript"]
}
```

Remember that `describe` must still answer entirely from static local data: no
network, no authentication. That rule has not changed and it applies to
everything new here.

**Negotiating.** At registration the caller invokes `describe`, intersects its
own supported majors with your `contract_versions`, and picks the highest common
value. An empty intersection means the caller refuses to use the provider and
says so. Whatever major is chosen rides on every subsequent invocation as the
`TBD_CONTRACT_VERSION` environment variable — so a provider that declares
`[1, 2]` against a v2-capable caller will now see `TBD_CONTRACT_VERSION=2`, and
against an older caller will still see `1`.

**You must behave correctly at whichever major was negotiated.** In practice one
code path serves both, because of how v2 was shaped:

- New response fields (`complete`, `archived`) are ignorable by construction —
  the v1 forward-compatibility rule already requires callers to ignore fields
  they don't recognize, so emitting them unconditionally is safe at either
  major.
- New verbs are gated behind capability strings a v1 caller doesn't recognize,
  so it never invokes them. Declaring `transcript`, `land`, `archive`, or
  `unarchive` is harmless at v1.
- The forward-compatibility rule is symmetric, and unchanged: **you must ignore
  fields you don't recognize in structured stdin** rather than fail on them.

The one asymmetry to keep straight is the `stop` requirement described in
section 4: required at v1, optional at v2. If you declare support for v1, you
must implement `stop`.

**Do not branch on `TBD_CONTRACT_VERSION` unless you have a reason.** For nearly
every provider, reading it is unnecessary — the same behavior is correct at both
majors.

## What to do if you maintain a v1 provider

In order, most value per unit of effort:

1. **Do nothing. You still work.** No v2 change breaks a v1 provider. Verify
   this by re-reading section headings above if you want; there is no deadline
   and no deprecation.

2. **Declare `"contract_versions": [1, 2]`.** One line in `describe`. It is
   accurate the moment you write it, because you already satisfy every v2
   requirement — v2 requires strictly less than v1 did. Keep `1` in the list
   unless you are dropping `stop` (section 4).

3. **Decide whether `complete` applies to you, before adopting any feature.**
   This is a correctness question, not an enhancement. If every successful
   `list` you return enumerates everything you own, you are done — do nothing.
   If some `list` responses are partial, add `"complete": false` to those and
   `"complete": true` to the rest. Getting this wrong causes live sessions to be
   wrongly retired, which is the worst failure available in this contract.

4. **If you run Claude Code, declare `transcript`.** Highest payoff of anything
   here. You almost certainly already have the JSONL on disk; streaming it turns
   a raw ANSI scrollback pane into a structured conversation with tool cards.
   Start without incremental support (return no cursor) and add the stderr
   cursor envelope later if refetch cost becomes noticeable.

5. **If you have any "done" or archive concept, model it as archiving.** Add
   `archived` to your Session objects, declare `archive` and `unarchive`, and
   make sure archived sessions are still returned by `list`. If your existing
   single operation both terminates and retires, declare both `stop` and
   `archive` pointing at it, then consider whether they can become two
   operations (section 4).

6. **If your work materializes as a pushed branch, declare `land`.** Usually a
   few lines returning metadata you already track. Emit plain ref names and a
   normal clone URL so the caller's validation passes without incident.

7. **If you cannot terminate a running session at all, drop `stop`** — and in
   that case declare `contract_versions: [2]` only, since v1 requires it.

Anything not on this list requires no action.
