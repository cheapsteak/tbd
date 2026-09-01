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

So adoption implements nothing new. It is a two-field edit to `describe`:
declare `"contract_versions": [1, 2]`, **and — if you implement `stop` — make
sure `"stop"` is in your `capabilities` list.** That second half is not
optional bookkeeping. `stop` was required at v1, so a v1 caller invoked it
without consulting `capabilities`; at v2 it is capability-gated, and a caller
never invokes a capability you did not declare. Change only the version list and
your `stop` verb keeps working while no caller ever calls it — the action
quietly vanishes from the user's surface. Section 4 covers this in full.

With both fields set you are fully conformant, having written no new code.
Everything else in this document is opt-in, and each item below states plainly
what happens if you ignore it — in every case the answer is "your provider
behaves exactly as it does under v1."

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

```sh
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

**If you ignore it.** The caller still has an archive action, because retiring a
session from *its* own working set is its decision to make; what changes is how
much of that reaches you. It composes over what you declare — with `stop`
declared it terminates the session and files it as retired on its side, and with
neither verb declared it files it on its side and calls you not at all. What you
lose is the shared state: your backend never learns the session was retired, so
`archived` (if you report it) is read-only from the caller's point of view, and
the retirement is invisible to your other clients.

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
   acceptable and is the smallest correct change. It also earns your sessions
   the protections a caller reserves for termination: TBD reads a declared
   `stop` as "this backend can end compute" and, on such a provider, guards
   archiving the same way it guards stopping — refusing without an explicit
   force while the agent is mid-task or the remote checkout is known dirty.
   Declaring `archive` alone tells it the opposite, so archiving through you is
   treated as the filing change you said it was.
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

```sh
p transcript <id> [--since <cursor>]
```

stdout is Claude Code transcript JSONL. The cursor for the next call is returned
in a JSON envelope on **stderr**, not as a trailing line of the data stream —
a single object, `{"cursor": "<opaque-provider-string>"}`. (For every other verb
stderr remains diagnostic and unparsed; this verb is the one exception.)

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

```sh
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
  remote session. `true` means the two diverge from the moment of landing;
  `false` means they stay one conversation and later local work still reaches
  it. Report `true` unless you can actually guarantee that continuity — `false`
  is a promise about where subsequent work goes, and over-reporting it silently
  loses work. It also costs the caller a capability: a non-forking session can
  only be landed once, since two local copies would be two writers on one
  conversation.

**Required?** No.

**What the caller does with the response.** It creates a local workspace for the
repository, checks out `branch`, and — if you supplied one — spawns the first
pane running `resume_command`. Preconditions are checked before anything is
created, so a failure never leaves a half-built workspace: the local
repository's configured remote must match `remote_url`, the branch must exist on
the remote, and the target workspace path must be free.

With `forks: true`, the caller presents the landed copy and the remote session
as two independent lines of work and never implies that typing in one reaches
the other. What it then does with your session is caller policy rather than
contract, and it is worth knowing which way TBD goes: having brought the work
to the user's own machine, it retires the session from the working set — an
`archive` call right after the `land`, if you declare `archive`, and nothing at
all if you don't. It never calls `stop` on the strength of a landing, whichever
capabilities you declare, because landing is not a teardown and your box may
still hold work that was never pushed. With `forks: false` it leaves the session
in the working set untouched, since the landed copy and the session are one
conversation.

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

- **`branch` must match the ref-name grammar the normative contract spells out
  under `land` — ASCII letters, digits, `.`, `_`, `-` and `/` only, with the
  usual git ref exclusions — and must not begin with
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

Negotiation works as it did in v1, with one genuine addition at `describe` time
covered below.

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

**What `describe` itself sees is new.** `describe` is the call that produces the
negotiation, so there is no negotiated value when it runs. Under v1 it received
a hardcoded `1`; it now receives the **caller's own highest supported major**.
A v2-capable caller therefore invokes your `describe` with
`TBD_CONTRACT_VERSION=2` before knowing anything about you.

This is a difference in kind rather than in value, so it is worth being explicit
about what it does and does not license. It is informational only: **you MUST
NOT vary your `describe` response based on it.** Report every major you support
regardless of what the caller announces. A caller that supports a newer major
than you do still needs to see your full `contract_versions` list so it can
negotiate down — tailoring your answer to what the caller asked about is how a
provider ends up unusable by the very caller it was trying to accommodate. In
practice this costs you nothing: `describe` answers from static local data, so
there is nothing there to vary.

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
majors. Inside `describe` it is worse than unnecessary: there the value
describes the caller rather than any agreement with you, and branching on it is
the mistake the MUST-NOT-vary rule above exists to prevent.

## 8. Worktree identity keys — new since v1, but not a v2 change

**What they are.** Two well-known `meta` keys on the Session object,
`tbd_worktree_id` and `tbd_parent_worktree_id`, both UUID strings. The first is
the session's own lane identity; the second names the lane that spawned it. The
normative rules — including what the caller does with a value that is absent,
malformed, or names a lane it already has — are under Worktree identity keys in
the contract.

**Why they are in this guide even though they are not a v2 delta.** They ride
inside `meta`, which is a provider-defined map at every major, so they are
readable at contract major 1 and 2 alike. You can populate them without
declaring `[1, 2]`, and declaring `[1, 2]` does not oblige you to. They are here
because they did not exist when v1 was published, so a v1 implementer who reads
only the version delta would never learn about them.

**Required?** No. A provider that sets neither is fully conformant, and the
caller mints identifiers of its own. Both values are things a caller tells you
rather than things you can look up, and the contract's `create` stdin does not
yet carry either one — so until it does, populate them only where your own
registration or invocation path already hands you the value.

**What you gain.** A spawned session lands in the caller's tree instead of a
flat list. `tbd_parent_worktree_id` nests it beneath the lane that spawned it,
so a fan-out reads as the hierarchy it actually is — which is what makes a
remote session orchestratable rather than merely watchable. `tbd_worktree_id`
makes the binding between session and row self-healing: if the caller loses the
row while the session is still running, the echo lets it recreate the row under
the same identity rather than minting a second one.

**What you must not do.** Never invent either value. Both describe caller-side
facts you were told, not facts you discovered; a made-up identifier names no
lane, and for `tbd_worktree_id` it defeats the echo it exists to serve. If you
were told nothing, omit the key.

**If you ignore them.** Sessions still get their rows. They appear at top level
in their repository rather than nested, and the caller mints a fresh identity
for each — so an agent inside the session has no ambient lane identity of its
own.

## 9. `messages` — addressing sessions by name across machines

**What it is.** A new declared capability, and one new optional field on the
Session object.

```sh
p messages
```

The verb is a **duplex** NDJSON stream — one per provider, held open
indefinitely, lines from the caller on stdin and lines to the caller on stdout.
It carries two things at once: announcements of which sessions each side can
currently deliver to, and the message frames addressed to the handles those
announcements minted. The line kinds are `hello`, `peer`, `peer-gone`,
`message`, `peer-inventory`, and `ping`; the normative rules for each are under
`messages` in the contract.

The field is `peer_messaging` on the Session object:

```json
"peer_messaging": {"protocol": 1}
```

It says this session can be addressed by name, and which peer protocol it
speaks. It is optional and no capability gates it. It is a declaration in your
inventory rather than a switch: what actually bridges a session is the `peer`
line announcing it on the `messages` stream, so populating the field turns
nothing on and omitting it turns nothing off.

**Required?** No, on both halves. This is a capability-gated verb plus an
optional response field — the same additive shape as `transcript` or `land` —
so a provider that ignores it is unaffected in every other respect.

**Not a v2 delta either.** Like the worktree identity keys in section 8,
`messages` was added after v2 was published rather than as part of it. A
capability string a caller does not recognize is never invoked, and an
unrecognized response field is ignored, so both halves are readable at contract
major 1 and 2 alike. Declaring `messages` does not oblige you to declare `[1,
2]`, and declaring `[1, 2]` does not oblige you to implement `messages`.

**What you gain.** A session on your box becomes addressable by name from the
caller's machine, and the caller's sessions become addressable from yours —
without a human relaying between them, and without a per-round-trip gesture.
Today the only ways across are typing bytes into a pane with `send`, which
carries no attribution and no reply path, or an out-of-band mailbox.

**What it costs, and this is the part to read before declaring it.** The
contract states six obligations for the provider's half, and three of them the
caller cannot check:

- Close and unlink your listeners when the link drops. An endpoint that stays
  reachable while the link is down accepts every message, reports success, and
  discards them — worse than not existing.
- Unlink every peer you published on the caller's behalf when the stream ends,
  however it ended.
- Persist no frames across a link drop. No buffering, no replay when the link
  returns.
- Namespace names by the origin in the caller's `hello`, and never publish two
  peers under one name. The host is multi-tenant; a collision is a
  misdelivery.
- Pass message content byte-verbatim.
- Never deliver a frame to a handle you were not given. No name match, no
  nearest match, no broadcast.

The `peer-inventory` line is how the caller keeps the unverifiable half
observable: you report the handles you currently publish, and the caller diffs
that against what it asked for. A leak shows up as a divergence in the caller's
diagnostics rather than as a mystery.

**Source `peer_messaging`, do not assert it.** The contract requires that the
field come from the remote session's own agent registry row. For a Claude Code
session that row's existence is what encodes both a new-enough CLI and the
absence of the messaging killswitches, and neither is inferable any other way. A
session running a different agent, a plain shell, or a Claude Code whose
messaging is inactive has no row — so omit the field, and let the sessions you
do announce on the stream be the ones with a row behind them.

**If you ignore it.** Nothing changes. Your sessions are reachable exactly as
they are today, through `send` and `attach`, and simply are not addressable by
name from another machine. Declaring `peer_messaging` without declaring
`messages` is the one half-adoption to avoid: it describes sessions the caller
has no channel to reach, so it buys nothing.

## What to do if you maintain a v1 provider

In order, most value per unit of effort:

1. **Do nothing. You still work.** No v2 change breaks a v1 provider. Verify
   this by re-reading section headings above if you want; there is no deadline
   and no deprecation.

2. **Declare `"contract_versions": [1, 2]` — and add `"stop"` to
   `capabilities` if you implement it.** Both fields in `describe`, in the same
   edit. The version list is accurate the moment you write it, because you
   already satisfy every v2 requirement — v2 requires strictly less than v1 did.
   The capability entry is the part that is easy to miss and the only way to
   lose something: `stop` was required at v1 and is capability-gated at v2, so
   declaring the version without declaring the capability leaves you with a
   `stop` verb no caller will ever invoke. Keep `1` in the list unless you are
   dropping `stop` entirely (section 4).

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

7. **If you are told a worktree identity, echo it back.** Two `meta` strings
   (section 8), readable at either major, and they are what put a spawned
   session in the caller's tree nested under the lane that spawned it. Never
   invent a value you were not given.

8. **If your sessions run Claude Code and you can read its registry, consider
   `messages`** (section 9). The largest lift on this list, and the only item
   whose obligations the caller cannot fully check — read the six of them before
   declaring the capability. What it buys is sessions on your box and sessions
   on the caller's machine addressing each other by name, with no human relaying
   between them.

9. **If you cannot terminate a running session at all, drop `stop`** — and in
   that case declare `contract_versions: [2]` only, since v1 requires it.

Anything not on this list requires no action to remain conformant.
