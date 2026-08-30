# Bridging Claude Code's `SendMessage` across machines

**Date:** 2026-08-29
**Status:** Findings only. Nothing built.
**Provenance:** Reverse-engineered by a sibling agent session working in a
different repo, then copied here because the design work it feeds lives in TBD.
The original write-up was in a private monorepo's wiki; this is the scrubbed,
durable copy. Everything below marked **T1** was verified by running it against
live Claude Code (2.1.251 on macOS, 2.1.238 on a Linux remote box), not inferred.

**Evidence tiers:** **T1** = ran it; **T2** = documented elsewhere; **T4** = inferred.

## Why this was investigated

Cross-session `SendMessage` works between Claude Code sessions on one laptop and
does not reach a session on a remote agent box. The only ways to talk to a remote
session today are the provider's `send` verb (types keystrokes into a pane) or a
GitHub issue used as a mailbox — both cost a human action per round trip, and
neither carries attribution or a reply path.

The goal is a bridge that makes a remote session addressable by the *same*
mechanism as a local one, **reusing the existing socket channel rather than
inventing a protocol**.

## What the local channel actually is

### Discovery is a directory of files — T1

`~/.claude/sessions/<pid>.json`, one record per session. A real one:

```json
{
  "pid": 46403,
  "sessionId": "4E12DD65-92B8-4D8E-9920-214C6553FC63",
  "cwd": "/Users/chang/tbd/worktrees/acme-app/20260829-useful-swallow",
  "startedAt": 1788041297648,
  "procStart": "Sat Aug 29 22:07:57 2026",
  "version": "2.1.251",
  "peerProtocol": 1,
  "peerFeatures": ["notify_idle", "reply_across_default_dirs", "artifact_yield"],
  "kind": "interactive",
  "entrypoint": "cli",
  "pidDomain": "darwin",
  "tmux": "main:@3541.%3541",
  "messagingSocketPath": "/tmp/cc-socks/46403.sock",
  "name": "Agentbox Init Research",
  "nameSource": "user",
  "status": "busy",
  "bridgeSessionId": "session_01UtqSLziKj54E115uNsHyUt"
}
```

The pid is parsed from the **filename**, not from the `pid` field — the loader
rejects a record whose filename does not round-trip as an integer. `ListAgents`
reads this directory and liveness-probes each `messagingSocketPath` with a
connect-and-drop.

### The sample above is not the whole key set — T1

A census over 84 live records (2026-08-30) gives the real picture, and the
single sample above is misleading in both directions: it shows a key carried by
under a third of records and omits one carried by every single one.

- **84/84** — `pid`, `sessionId`, `cwd`, `startedAt`, `procStart`,
  `peerProtocol`, `peerFeatures`, `kind`, `entrypoint`, `messagingSocketPath`,
  `name`, `nameSince`
- **83/84** — `version`, `status`, `updatedAt`, `statusUpdatedAt`
- **82/84** — `bridgeSessionId`
- **80/84** — `tmux`. Four records carry none, independently corroborating that
  a record without it is legal.
- **63/84** — `pidDomain`. Absent from a quarter of records, so it is optional
  rather than structural.
- **24/84** — `nameSource`, the key the sample shows.
- **6/84** — `waitingFor`.

`procStart`'s format is `ctime(3)` — `"Fri Aug 28 17:20:19 2026"`.

Two consequences for anything impersonating a record. Absence is broadly
tolerated: probe records omitting `nameSince`, `updatedAt`, `statusUpdatedAt`
and `bridgeSessionId` listed correctly. But `updatedAt` and `statusUpdatedAt`
plausibly feed staleness in some surface, so a long-lived stand-in that never
writes them may eventually read as stale even while it is answering — untested,
and the first thing to suspect if shadows go quiet after hours rather than
immediately.

### A `from-mode="default"` frame is delivered to a bypass-mode session — T1

The `<cross-session-message>` wrapper is composed by the sender, so anything
standing in for a remote peer chooses the `from-mode` it claims. The worry is
that claiming less than the receiver holds would get the message held for
approval or refused, since inbound delivery is documented as turning on sender
and receiver sharing a permission class.

It does not. A frame stamped `from-mode="default"`, written into the socket of a
session TBD had spawned with permissions bypassed, was delivered mid-turn with
the full peer-trust preamble intact.

So a stand-in can stamp the least-privileged class rather than echoing whatever
the far side claimed, and pay nothing in deliverability. That matters because
the alternative — forwarding the far side's own `from-mode` — would let a remote
peer name its own permission class.

Measured for `default` into a bypass receiver only. The reverse pairing, and the
explicit `crossSessionInbound` policies (`accept` / `hold` / `refuse`), were not
exercised.

### An unrecognised field VALUE is tolerated, unlike an unrecognised KEY — T1

An unknown *key* makes a record invisible while leaving it on disk. An unknown
*value* does not. A record with `status: "unknown"` — outside Claude Code's
`idle`/`busy`/`waiting`/`shell` vocabulary — listed normally, and rendered
identically to a record omitting `status` altogether: the status simply does not
appear in the row. An `idle` control published alongside them rendered its
status, which is what isolates the behavior to the value rather than to the
publishing.

So the strictness measured earlier is about the record's *shape*, not its
contents. That is the difference between a stand-in that must mirror a key set
exactly and one that may carry values the loader has never seen.

### There is a third per-peer artifact: a peer-token file — T1

Alongside each record sits `<pid>.<sha256(messagingSocketPath)>.key`, mode 0600
— 83 of them against 84 records. The filename's digest was confirmed to be
sha256 of that record's own `messagingSocketPath` (6 of 6 sampled). Each holds a
`peerToken` plus a `procStart` and `pidDomain` matching its record exactly.

This is almost certainly the "start token" behind the uds-client's
`not the process that wrote to us (start token differs — recycled pid)`
refusal. **The token values are secrets and are not reproduced here.**

It matters for two reasons. It is a **third durable artifact per peer**, so
anything counting or reclaiming peer artifacts that knows only about records and
sockets is incomplete. And a stand-in that publishes no token file delivers fine
today — but the ratio is the finding: **83 of 84 records carried a key; the one
that did not was a stand-in of our own making.** A keyless record is a population
of one, authored by us, against 83 written by Claude Code itself. It works by the
absence of a check rather than by a documented tolerance.

The keys are mode 0600 where the records are 0644 — the token is treated as a
secret, the record as public.

### Transport is one JSON line per message — T1

A `SOCK_STREAM` Unix socket at `/tmp/cc-socks/<pid>.sock`, mode `0600`, one
connection per message. Captured verbatim from a real `SendMessage`:

```json
{"msgV":1,"msg_id":"fc0d956d-d005-4c7f-b98b-19cc22cea78c","type":"user",
 "priority":"next",
 "from":"uds:/tmp/cc-socks/46403.sock",
 "message":{"role":"user","content":
   "<cross-session-message from=\"uds:/tmp/cc-socks/46403.sock\" from-name=\"Agentbox Init Research\" from-mode=\"bypass\">\nbridge probe: …\n</cross-session-message>"}}
```

That is the whole protocol. Reply routing is the `from` field; there is no
handshake, no session-id exchange, no ack.

### Addressing is already scheme-tagged — T1

The address grammar compiled into the binary is `^(?:uds|bridge|did):…{1,200}$`
— three schemes. `uds:` is the local socket. `bridge:` is Anthropic's own hosted
cloud relay (driven by `CLAUDE_BRIDGE_BASE_URL` / `CLAUDE_BRIDGE_OAUTH_TOKEN`,
i.e. Remote Control), a hosted service we cannot stand up ourselves. `did:` is
unexplored.

`CLAUDE_CODE_MESSAGING_SOCKET` overrides a session's own socket path — T1 from
the binary, not exercised.

### The registry is already machine-aware — T1

`pidDomain` is `"darwin"` on macOS; on Linux it is derived from
`/etc/machine-id` plus `/proc/self/ns/pid`. It gates **reaping**: the predicate
that decides whether a stale record may be deleted returns false when the
record's `pidDomain` differs from ours, because a foreign pid's liveness cannot
be checked locally.

This is the single most important fact for the design. **Claude Code already
tolerates session records that belong to another machine** — it lists them and
refuses to garbage-collect them. The seam exists.

## What was proven

### Both halves of the channel are open — T1

A ~30-line Python process that bound a UDS in `/tmp/cc-socks/` and wrote a
session record for itself:

- appeared in `ListAgents` as an ordinary peer within seconds;
- received a real `SendMessage` as the frame above;
- and, writing by hand into a **real** session's socket, delivered a frame
  **mid-turn**, correctly attributed, with the full `<cross-session-message>`
  framing and the standard peer-trust preamble.

So: *receiving* into a bridge needs a real local process holding a socket;
*sending* into a session needs nothing but a local socket write. A bridge is a
pair of shims, not a protocol.

### The peer-credential check does not block a stand-in — T1, with a T4 caveat

The UDS client verifies its peer via `SO_PEERCRED` and refuses to write on
mismatch, with distinct errors:

```
[uds-client] connected endpoint is pid <X>, expected <Y> — refusing to write
[uds-client] connected endpoint is owned by uid <U>, not ours — refusing to write
[uds-client] connected endpoint pid <X> is not the process that wrote to us
             (start token differs — recycled pid) — refusing to write
```

If that applied to peer sends, no relay could stand in for a remote session. It
does not: records whose `pid` did not own the target socket delivered fine, in
**both** a foreign `pidDomain` and the local `"darwin"` domain.

**T4:** the *why* was not isolated — most likely the expected-pid argument is
undefined on the peer path and used only for the parent/child agent path. Treat
it as observed behavior a future Claude Code build could tighten, and pin a test
to it rather than relying on it silently.

Practical consequence: one shared relay process can front every remote session.
No fork-per-session is required.

### The transport works — T1

A Unix socket cannot be forwarded end to end: AWS SSM port-forwarding carries
TCP only (**T2**). So the hop is UDS → TCP → UDS. Nothing else changes — frames,
addressing, record format and delivery semantics all travel unmodified. A JSON
frame was round-tripped laptop → box → laptop over the provider's port-forward:

```
recv: b'BOX-SAW:{"msgV":1,"probe":"laptop->box over SSM"}\n'
```

## Sketched design (the investigation's proposal, not yet TBD's spec)

### Who dials whom

Easy to get backwards. **The laptop dials, in both directions.** A cloud box is
reachable; a laptop behind a VPN is not addressable. One long-lived
laptop-initiated tunnel carries both message flows. The remote never initiates.

**laptop session → remote session**

1. A local `SendMessage` targets a shadow record the bridge published.
2. The laptop relay owns that socket, receives the frame, rewrites `from` to the
   remote-side counterpart address.
3. It writes the frame down the tunnel.
4. The remote relay writes it into the real session's `/tmp/cc-socks/<pid>.sock`.

**remote session → laptop session**

1. The remote session `SendMessage`s a shadow record the remote relay published
   for the laptop session.
2. The remote relay writes it **up the same tunnel** — the connection the laptop
   already opened.
3. The laptop relay writes it into the real local socket. Delivered mid-turn.

### What has to be built

1. **A relay on each side** mirroring the other's session registry. For every
   remote session: own a local UDS, and publish a `~/.claude/sessions/<pid>.json`
   stamped with the **remote** `pidDomain` (so nothing local reaps it) and a
   namespaced name. Only `from` is rewritten, to the locally-valid counterpart
   address, so replies route home.
2. **One multiplexed tunnel per remote host**, laptop-initiated, carrying
   length-prefixed frames tagged with a session key.
3. **Reconciliation on an existing poll.** TBD already polls the provider and
   adopts remote sessions into its worktree tree; that same tick should create
   and retire shadow records.

### What breaks

- **Names, not pids, are the address.** A socket path embeds a local pid and
  means nothing across machines. Namespace shadow names (`agentbox:<slug>`) or
  `ListAgents` becomes ambiguous the first time two hosts run the same slug.
- **Tunnel drops are silent.** The tunnel ends, the sockets stay bound, so
  `ListAgents` keeps listing peers that cannot be reached while `SendMessage`
  reports success. The relay must stop answering connects when its tunnel is
  down — a listed-but-unreachable peer is worse than an absent one.
- **Stale shadows accumulate.** Foreign-domain records are deliberately never
  reaped locally, so whatever creates them owns deleting them. A crashed relay
  leaves ghosts in every session's `ListAgents`, including sessions with nothing
  to do with TBD.
- **Version skew.** Remote 2.1.238 vs laptop 2.1.251, both `peerProtocol: 1`.
  Gate on `peerProtocol`, never the version string.
- **Delivery is mid-turn and unacknowledged.** A frame lands at the recipient's
  next tool boundary; nothing tells the sender it was read. That is already true
  locally — do not invent an ack layer for the remote case that the local case
  does not have.
- **Trust boundary.** The local socket's only authority is filesystem ownership
  (0600). A bridge extends that trust to whatever is on the far end of the
  tunnel. Peer messages are already handled as untrusted teammate input, so this
  is probably acceptable — but it should be a decision on the record rather than
  a side effect.

## What this is not

- **Not MCP.** SEP-2260 (2026-07-28) makes server-initiated requests legal only
  while the server is processing a client call, so there is no idle session for
  a tool server to push into. **T2**.
- **Not A2A.** A2A models exactly this lifecycle (`SendMessage` with a `taskId`,
  `TASK_STATE_INPUT_REQUIRED`) but requires each agent to be a reachable HTTP
  server and has no pull transport. Laptop sessions behind a VPN are not
  addressable services. Borrow its *vocabulary*, not its transport. **T2**.
- **Not the provider's `send` verb.** That types bytes into a pane. It works
  today and is the right fallback, but it lands in whatever the pane is currently
  running, carries no attribution, and has no reply path.

## Where it should live

The bridge is not one provider's feature. TBD already models remote worktrees
generically (`locationKind: "remote"`, `providerName`, `providerSessionID`) and
already has a provider contract whose `send` verb is defined as *"deliver stdin
bytes verbatim as keystrokes"*. The bridge is the missing **structured-message**
surface on that contract, and it should be specified so any remote provider can
implement it.

## Reproducing the probes

Publish a session record + bind a socket; observe it in `ListAgents`;
`SendMessage` to it and capture the frame; hand-write a frame into a real
session's socket and observe mid-turn delivery; repeat with mismatched pid and
`pidDomain`; round-trip a frame over the provider's port-forward. All artifacts
were removed afterwards. Rebuild them from the frame shape and record shape above
— they are the whole contract.
