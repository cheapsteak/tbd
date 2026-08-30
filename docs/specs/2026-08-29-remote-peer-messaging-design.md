# Remote peer messaging

**Date:** 2026-08-29
**Status:** Approved, not yet built.
**Depends on:** [`docs/remote-provider-contract.md`](../remote-provider-contract.md)
(capability negotiation, the Session object, and the `events` verb this design's
verb is modelled on), [`docs/cross-session-messaging.md`](../cross-session-messaging.md)
(what a peer is, the peer registry, and TBD's existing ownership of it),
[`docs/research/2026-08-29-cross-machine-messaging/findings.md`](../research/2026-08-29-cross-machine-messaging/findings.md)
(the reverse-engineered channel this builds on).

## Summary

Claude Code sessions on one machine address each other by name. A session on a
remote host cannot be reached at all: the only ways to reach one are the
provider's `send` verb, which types bytes into a pane and carries no attribution
and no reply path, or an out-of-band mailbox like a GitHub issue. Both cost a
human action per round trip.

This makes a remote session addressable by the *same* mechanism as a local one,
reusing Claude Code's socket channel rather than inventing a protocol. It is
specified on TBD's generic remote-provider contract, so any provider can
implement it.

The shape in one line: TBD publishes a **shadow peer** on the laptop for each
remote session, backed by a real process holding a real socket, and carries
frames to and from the far side over one new duplex provider stream.

## Vocabulary

[`docs/cross-session-messaging.md`](../cross-session-messaging.md) defines a
**peer**: one live Claude Code session another session can address by name —
mechanically, a registry record plus a socket that answers a connect. This
design adds three terms and no new concepts.

- **Shadow peer** — a peer standing in for a session on another machine. It
  satisfies the same membership test as any other peer: a record in
  `~/.claude/sessions/` and a socket that answers. Its three artifacts are a
  helper process, that process's socket, and that process's record.
- **Peer link** — the `messages` stream to one provider. Every shadow peer for
  that provider rides it, and its state gates all of them.
- **Origin** — the machine a shadow peer stands for, and the namespace its names
  live in on the far side.

## What was measured

Four probe records were published on a live registry (Claude Code 2.1.251,
macOS) and driven with `ListAgents`. The design rests on these four facts; each
was observed, not inferred.

- **A helper process that owns its own socket is a fully functional peer.** A
  record filed under a live non-Claude pid that genuinely owned its socket
  survived reaping, listed as an ordinary peer, and received a real
  `SendMessage` in the frame shape `findings.md` documents. The peer-credential
  check passes legitimately, so this design depends on no unexplained behavior.
- **The reaper deletes records whose pid is dead.** A record filed under a dead
  pid was gone after one `ListAgents`.
- **The reaper checks pid liveness and nothing else.** A record with a
  deliberately wrong `procStart` under a live pid survived and listed. So a
  recycled pid produces a permanent ghost, and Claude Code's reaper cannot be
  the whole cleanup story.
- **An unknown key makes a record invisible.** A record carrying an extra
  `tbdShadow` key was absent from every listing while surviving on disk;
  removing that one key made it list immediately. **A shadow peer's record
  therefore carries no field Claude Code does not already define**, and TBD
  cannot mark its own records from the inside.

Incidental, and the reason for the socket sweep below: `/tmp/cc-socks` held 92
socket files against roughly 80 records. Nothing unlinks a dead one — the same
shape as the ~7,100 orphaned tmux sockets recorded in `CLAUDE.md`.

## Who owns what

**TBD's daemon owns the local half. The provider owns the mirror-image job on
its own machine.** Each machine's registry belongs to whoever lives on it, which
is also the only party that can answer honestly whether a peer is reachable
right now.

**The laptop dials, in both directions.** A remote host is reachable; a laptop
behind a VPN is not addressable. One laptop-initiated peer link carries both
flows, and the remote never initiates. This is a requirement on the provider,
not an implementation choice left to it.

## Contract change

Two additions, both additive within contract major 2 and needing no major bump:
a new capability-gated verb, and a new optional field on the Session object.

### The `messages` verb (capability `messages`)

`<exec> messages` — a duplex NDJSON stream, **one per provider**, unbounded.
Stdin carries frames from TBD; stdout carries frames to TBD. It is `events`
shaped, for the reason `events` gives: aggregate, small, shared traffic gets one
connection per provider, while a per-session channel like `attach` exists only
because an interactive byte stream cannot be multiplexed. Message traffic is
aggregate.

Line kinds on the stream, in both directions unless noted:

- `hello` — first line TBD writes, declaring the origin label and the protocol
  it will speak. The provider answers with its own `hello`.
- `peer` — announces or updates one addressable session on the sender's side:
  its handle, display name, status, and peer protocol. Idempotent and complete,
  never a partial diff, following the `events` rule for `session`.
- `peer-gone` — that handle is no longer addressable.
- `message` — one frame for delivery, addressed by handle.
- `shadow-state` — periodic, provider to TBD only: the handles the provider
  currently publishes on its side. TBD diffs it against what it asked for and
  surfaces the difference. This is what makes the far half's hygiene observable.
- `ping` — keepalive, as on `events`.

The stream is a registry-sync protocol, not only a message pipe: the `peer` and
`peer-gone` lines are how each side learns what the other can address.

**Ordering.** A `message` naming a handle the receiver has not been told about
is dropped and logged. Senders announce before they address.

**Silence limit.** Tighter than the `events` stream's 90 seconds. The cost of
stale state on `events` is a stale badge; here it is a session sending into a
void. Detection latency is what bounds the lie, so this number is the design's
main honesty knob.

No wake handling is specified, and none is needed: the silence watchdog compares
wall-clock `Date`s and sleeps on a `ContinuousClock`, which counts time across
system sleep, so the first tick after wake already finds a dead stream and
replaces it. `NSWorkspace` notifications are unavailable to the daemon in any
case — it is `dispatchMain()` with no AppKit run loop.

### `peer_messaging` on the Session object (optional, no capability)

An optional object on the Session object, following the `pending_question`
precedent: optional, ungated, absent means no.

```json
"peer_messaging": {"protocol": 1}
```

It carries the peer protocol number, not a boolean, and a provider **MUST**
source it from the remote session's own registry row rather than assert it. That
row's existence already encodes both a new-enough CLI and the absence of the
messaging killswitches, which cannot be inferred any other way. A session
running a different agent, a shell, or a Claude Code with messaging inactive
simply has no row, so the field is absent and the session is never shadowed.

TBD shadows a session only when `protocol` matches the protocol the local
sessions speak. Frames whose `msgV` differs from the negotiated protocol are
dropped and logged.

## The local roster

The `peer` and `peer-gone` lines TBD writes are produced by a **roster watcher**
over the host registry at `~/.claude/sessions`. It is a small subsystem with its
own failure modes, and it is named here because the outbound half of this design
is otherwise ownerless.

- It watches the host directory, which TBD already makes whole across profiles by
  symlinking each profile's `sessions` into it. That unification is best-effort:
  a profile whose seeding failed keeps a private registry, so its sessions are
  absent from the roster. A partial roster is a correct roster of what TBD can
  see, and is reported rather than treated as an error.
- It admits **only TBD-spawned sessions**, and announces each one only on the
  peer links whose remote session resolves to the same repository. The two
  scoping rules from Trust are enforced here, at the point of announcement,
  rather than anywhere downstream.
- A session appearing, exiting, or changing status produces a `peer` or
  `peer-gone` line on each link that carries it. A session that exits while a
  link is down needs no catch-up: the far side unlinks every shadow when the
  stream ends, and the next `hello` re-announces the roster from scratch, the way
  `events` resyncs with a snapshot rather than a cursor.

## Addressing and naming

Names are the whole identity of a shadow peer. The pane join that resolves
ambiguity for local peers is unavailable: a shadow has no local terminal, and it
**MUST NOT** carry a `tmux` field. Remote coordinates would be actively harmful,
because the far host's tmux server is also called `main` and also has a pane
`%388`, so the row would look joinable against local panes and join to the wrong
terminal. A record with no `tmux` key lists correctly — measured.

**Forward, a remote session seen locally: `<provider>:<worktree display name>`.**
The contract makes this unique by construction — a session that resolves to a
registered repository gets exactly one worktree row, and no session may take
another's row by claiming its id — so the only collision is a display name the
user reused across two remote worktrees. That collision is a refusal naming the
`[ref]`, never a misdelivery, so it costs one round trip.

**Reverse, a local session seen remotely: `<origin>:<display name> %<pane>`.**
Here collisions are the norm rather than the exception: several Claude terminals
in one worktree all carry the worktree display name. The pane discriminator is
therefore **always present**, never added on collision — a name that changes when
some other session appears is worse than one that occasionally needs a ref. The
pane is TBD's own documented join key, so a remote agent naming one names
something `tbd terminal list` can resolve.

**Origins must be namespaced.** A remote host is multi-tenant: two laptops
bridging to it would otherwise publish colliding names for sessions on different
machines belonging to different people. The provider **MUST** namespace reverse
names by the origin declared in `hello`, and **MUST NOT** publish two shadows
under one name.

Refs are minted by Claude Code per record, so a daemon restart republishes
shadows with fresh refs and peers that had settled into bare-name addressing hit
one ref round trip. Unavoidable, and harmless while names are stable.

## Trust

The local socket's only authority is filesystem ownership. A bridge extends that
trust across a network hop, so two properties are structural rather than
advisory.

**Raw socket paths never travel on the wire, in either direction.** The frame's
routing field is a path, and delivery means writing to that path — so a wire
that carries paths lets the far side name any socket in `/tmp/cc-socks`,
including a personal non-TBD session or one on a profile logged into a different
Anthropic account. Instead TBD mints an opaque handle per shadow peer and keeps
the handle-to-socket table privately. Inbound frames are delivered only by
looking a handle up in that table, so a frame can only ever reach a session TBD
chose to mirror; a handle that is not in the table resolves to nothing. Outbound
frames have their `from` rewritten to a handle before they leave, so the far
side never learns a real path either.

**Attribution is stamped locally, never forwarded.** The
`<cross-session-message>` wrapper is composed by the *sender's* client and
travels inside the message content, so a remote peer controls `from-name` and
`from-mode` outright — it could name itself as one of your local sessions and
claim `bypass` to satisfy the inbound policy. TBD **MUST** overwrite the name
with the shadow peer's own namespaced name and the mode with the class it
actually grants. Message *content* passes byte-verbatim; only attribution is
rewritten.

**Mirroring outward is scoped twice.** Only TBD-spawned sessions are mirrored to
a remote host — never a plain-terminal session, never another profile's. And a
session is mirrored only to a host whose remote session resolves to the same
repository, so a remote lane in one project cannot reach local sessions in
another. A remote session that resolves to no registered repository has no
worktree row under the existing contract and is therefore never bridged.

One asymmetry is on the record because it cannot be engineered away.
`~/.claude/sessions` is a single per-user directory with no notion of project,
and every local session reads all of it. So TBD controls which local sessions a
remote host can *reach*, but not which local sessions *see* a shadow peer: a
session in one project will see remote peers from another and may message them.
The direction that crosses the trust boundary is the one that is scoped.

Remote message content remains untrusted teammate input, exactly as local peer
content already is. The namespaced stamp is what stops it impersonating a local
teammate; it is not a claim that the content is safe.

## Failure semantics

**Clean failure, no buffering, anywhere.** If the link is down the send fails,
exactly as messaging a session that has exited fails. No mailbox, no
store-and-forward, no acks. A queue would deliver an instruction hours later to
a session that has moved on, and would grow an ack layer the local channel does
not have.

**Link-down means the listener is closed and unlinked, not that it stops
answering.** A listening socket cannot decline: `connect()` succeeds while the
listener exists, and the protocol is connect-write-close with no handshake, so a
bound socket always reports success to the sender. ECONNREFUSED is what makes a
sender see the same failure as a dead local session and what makes the
`ListAgents` probe delist the row. Both halves **MUST** close and unlink on link
loss.

**The in-flight window is accepted, not solved.** A frame accepted by a shadow
socket whose link dies before handoff is lost after the sender saw success. The
local channel has a narrower version of the same window; here it spans the WAN
hop. This is stated so it is recognised as designed behavior rather than
diagnosed later as a bug.

**Frames are size-capped at 512 KB.** The daemon's pipe reader discards an
un-newlined buffer past 1MB, silently, so the cap sits below the size at which
loss becomes invisible. An oversized frame is dropped and counted rather than
truncated. Stdin writes to the provider are
non-blocking; a write that would block fails the frame rather than parking the
caller.

Loss is unreported to the sender in every case above, because the channel has no
reply path. Every drop is logged and counted, and the counts surface in
`tbd peer list`.

## Shadow peer lifecycle

One helper process per shadow peer, holding one socket, publishing one record
under its own real pid in the local `darwin` domain.

This is forced rather than preferred. The record's pid is parsed from its
*filename*, so one process cannot publish several valid records; and a record
under a pid that does not own its socket would depend on behavior nobody has
explained. The measured alternative — a foreign `pidDomain` so Claude Code never
reaps — opts out of the only garbage collector that exists, in exactly the
scenarios where TBD is not running to collect.

Required behaviors:

- **The record carries no field Claude Code does not define.** Measured: one
  unknown key makes the record invisible while leaving it on disk. A shadow's
  socket therefore follows the same convention as any other peer's, and TBD
  identifies its own shadows **only** from its own durable bookkeeping — never
  from a marker inside the record, and never by inspecting a path. That
  bookkeeping must survive a daemon restart, because a shadow whose row is lost
  is a shadow nothing can recognise.
- **`peerFeatures` advertises only what the bridge actually carries.** A feature
  echoed from the far side that the bridge does not forward — idle notification,
  say — would silently never fire.
- **The helper is the single writer of its own record**, taking control frames
  from the daemon over its stdin, and rewrites atomically by rename. A record
  published once and never updated shows a frozen status forever; status follows
  the remote `agent_state`.
- **The helper exits when its stdin closes.** The kernel closes that fd even
  when the daemon is `SIGKILL`ed, so a dead daemon means dead helpers within
  milliseconds.
- **On exit the helper unlinks its own record and socket.** Claude Code's reaper
  is the backstop for unclean exits, not the mechanism.
- **Helpers carry distinctive argv** so `ps` reads sanely and no pattern-kill
  takes out a sibling.

## Reclamation and detection

Per the reconciler doctrine, this feature's durable resources — a record, a
socket, and a process — get a named owner: **`ShadowPeerReconciler`**, running at
daemon startup and on its own tick. `OrphanGC`'s hourly cadence is too slow for
registry hygiene, so this does not fold into it even if it reuses its collector
shape. Its tick takes an injected clock.

It reclaims, against a durable whitelist of artifacts TBD's own bookkeeping
recorded:

- helper processes with no bridged session behind them
- shadow records with no live helper, including the **recycled-pid ghost** that
  Claude Code's reaper provably will not collect
- socket files TBD created with nothing listening
- records TBD published under a previous daemon generation

It **MUST NOT** reclaim by inference — never "any socket with nothing
listening", which races a real session between `bind()` and `listen()`.

Detection is the half that has historically been missing: every unbounded leak
in this repo's history went unnoticed because nothing counted it. So each sweep
logs a reclaimed count as an `os.Logger` info line, durable where signposts are
not, and `tbd peer list` makes the state answerable in one command.

### `tbd peer list`

Lists **every** peer TBD can see — peer means any addressable session, local or
remote, so a command under that name that showed only shadows would misname
itself. Each row carries the peer's name and ref, whether it is a local session
or a shadow peer, the worktree and terminal behind a local one, the provider
session and link state behind a shadow, and any orphan the sweep found.

This replaces a manual join the docs currently teach: pull
`tbd worktree list --json`, pull `tbd terminal list`, join them on the tmux pane
to work out which row is which lane. The command does that join, and keeps
working for rows that have no pane to join on.

**A line is added to the TBD skill** (`Sources/TBDShared/TBDSkillContent.swift`,
in the passage that currently teaches the manual join), pointing sessions at the
command:

> `tbd peer list` does that join for you — every peer TBD can see, with the
> worktree, terminal or remote session behind it.

That file's substrings are pinned by `TBDSkillContentTests`; the line lands with
the command, not before it.

## Flag and rollout

`remote_peer_messaging_enabled`, a `config` column added by migration with **no
SQL `DEFAULT`**, so unset stays a third state and graduation is a one-line change
to `Config.remotePeerMessagingDefault` that reaches everyone who never chose
while preserving every explicit opt-out. The migration, the GRDB record, and the
`TBDShared` model land in one commit.

Default off. The feature acts without a user gesture and writes into a directory
shared with every session on the machine, which is squarely what the rule
covers. The flag is the only opt-in: there is no per-worktree toggle, because a
second gate under a global one is the kind nobody tunes and everybody has to
debug around.

Graduation after a soak in which no ghost record outlives its daemon.

## Conformance

TBD can verify its own half. The far half is prose a third party implements, so
the contract states what it cannot check, and the stream makes what it can
observable.

A conforming provider **MUST**: close and unlink its listeners when the link
drops; unlink every shadow it published when the stream ends; persist no frames
across a link drop; namespace names by the declared origin; pass message content
byte-verbatim; and never deliver a frame addressed to a handle it was not given.

TBD cannot detect a provider that buffers frames and replays them, or that
leaves stale shadows on a host TBD cannot sweep. The `shadow-state` line is the
mitigation: TBD diffs the provider's claimed inventory against what it asked
for, logs the difference, and shows it in `tbd peer list`. A provider that
declares `messages` and leaks is visible as a divergence rather than a mystery.

**A stale shim is silent, and that silence is answered rather than accepted.** An
old shim never declares `messages`, so TBD never invokes it — the safety half is
free from capability gating. But the result is a feature that simply does
nothing, which is the failure this contract's users have been bitten by before.
When the flag is on and a provider does not declare the capability, TBD says so
in `tbd peer list` and in the provider's diagnostics rather than showing nothing.

## Testing

- **Both flag branches.** Off: no helper spawns, no record is published, no
  stream is opened. On: the full path. Plus the three-state column test — a
  pre-migration row reads NULL rather than `0`, an explicit `false` survives a
  change to the default constant, and NULL follows it.
- **The sweep, mutation-checked.** Plant a ghost record, a ghost socket, and an
  orphaned helper; assert all three are reclaimed. Then assert a *live* shadow's
  three artifacts survive the same pass — a reaper that eats live state is worse
  than one that leaks.
- **The Claude Code shape, pinned.** A test asserting a record with an unknown
  key is not listed, and one with the defined fields is. It fails when Claude
  Code's loader changes, which is the signal we want rather than shadows quietly
  vanishing.
- **Frames.** Oversized frames dropped and counted; a `message` naming an
  unannounced handle dropped; a frame whose `msgV` differs from the negotiated
  protocol dropped; attribution rewritten on every inbound frame; a handle
  outside the table resolving to nothing.
- **Scoping.** A local session in another repo is not mirrored; a non-TBD
  session is never mirrored.
- **Link loss** closes and unlinks listeners on both halves.

## Rejected alternatives

- **A one-shot send verb plus a polled inbox.** Easier for a shell-shaped
  provider, but it needs a mailbox on the far side — a durable queue with its own
  reclaimer and eviction policy — and that invents store-and-forward semantics
  the local channel does not have. It also degrades link liveness to a staleness
  heuristic, when liveness is the property this design is built around.
- **The provider owning both halves.** Keeps transport knowledge in one place and
  leaves TBD depending on no Claude Code internals, but every provider then
  re-implements the fragile part, and being subtly wrong there is invisible — a
  relay that keeps answering after its tunnel drops looks healthy and eats every
  message. TBD would also have no way to clean up after a provider that crashed
  in a directory TBD manages.
- **TBD shipping both halves as a remote binary.** The best answer to fragility,
  and the door stays open: the remote half's contract is the same either way, so
  a shipped helper could later become its reference implementation. Rejected for
  v1 because TBD would take on building, versioning, and distributing a
  Linux-side artifact, which nothing in the repo does today.
- **A foreign `pidDomain` so Claude Code never reaps our records.** The
  investigation's original proposal. It survives the tunnel's life by opting out
  of the only collector that exists, and leaves permanent ghosts after a reboot
  or an uninstall — the cases where TBD is not running to collect.
- **A marker field inside the record.** Measured to make the record invisible.
- **A bounded in-memory buffer across reconnects.** Would ride out a wifi blip,
  but it is store-and-forward with a smaller number on it, and the number gets
  argued upward.
- **A per-worktree bridging toggle.** A second gate under the global flag.
- **A wake handler in the daemon.** Unnecessary — the wall-clock watchdog already
  covers wake — and unavailable, since the daemon has no AppKit run loop.
