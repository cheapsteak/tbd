# The ask: a remote-session messaging protocol for TBD

**Date:** 2026-08-29. Durable copy of the task brief that started this work
(the original lived in `/tmp`). Scrubbed of private context.

## The job

Specify how TBD should carry structured agent-to-agent messages between a LOCAL
session and a REMOTE one. Agent Box is the first implementation but must not be
the design: TBD already models remote worktrees generically (`locationKind:
"remote"`, `providerName`, `providerSessionID`, `remote://<provider>/<session>`),
so this is **spec surface area on TBD's remote-provider contract** — any provider
(agentbox, claude-cloud, whatever comes next) must be able to implement it.

## Why

Many Claude Code sessions run across TBD worktrees on a laptop, plus sessions on
a remote agent box. Local sessions message each other (`SendMessage` /
`ListAgents`). A remote session cannot be reached that way at all. Today the only
options are typing keystrokes into its pane, or a GitHub issue used as a mailbox
— both cost a human action per round trip.

**Hard constraint from the maintainer:** reuse the existing socket mechanism
rather than invent a protocol.

## Constraints that save a wrong turn

- **MCP cannot be the channel.** SEP-2260 (2026-07-28) makes server-initiated
  requests legal only while the server is processing a client call. There is no
  idle session to push into. Designs where "the daemon pushes over MCP" cannot be
  built.
- **A2A cannot be the transport.** It models the lifecycle exactly but requires
  each agent to be a reachable HTTP server, with no pull transport. Laptops
  behind a VPN are not addressable services.
- **Who dials whom is easy to get backwards.** A cloud box is reachable; a laptop
  behind a VPN is not. The **laptop dials, in both directions** — one long-lived
  laptop-initiated tunnel carries both flows and the remote never initiates. The
  provider spec must state this as a requirement, not leave it to the
  implementer.

## Where TBD stands

- `tbd worktree list --json` already shows remote worktrees with `locationKind:
  "remote"`, `providerName`, `providerSessionID`.
- TBD does **not** vendor the provider CLI — it execs an installed shim
  (e.g. `~/.local/bin/agentbox-tbd-provider`). **A stale shim is silent**: it
  answers every verb correctly for the contract it knew, so a new verb simply
  does nothing, with no error on either side. Whatever verb this adds must fail
  loudly on an old shim.
- Existing verbs include `send`, defined as "deliver stdin bytes verbatim as
  keystrokes". Typing is not messaging. The structured verb is what is missing.

## The questions worth arguing about

The agenda, not a checklist:

1. **Where does the relay live?** TBD daemon, provider shim, or a separate
   per-remote-host process? The daemon already polls providers and owns the tree;
   a provider-owned relay keeps transport knowledge with the party that has it.
2. **What exactly is the new contract verb?** A bidirectional stream the daemon
   opens per remote host (`provider bridge`, stdin/stdout framing)? Or a pair of
   one-shot verbs plus a poll? The stream is faithful to local semantics; the
   poll is easier for a shell-shaped provider.
3. **How are remote sessions named and addressed?** Socket paths embed a local
   pid and mean nothing across machines. TBD's stable join key is the
   slug/`providerSessionID`. Namespacing (`agentbox:<slug>`) matters the first
   time two hosts run the same slug.
4. **Liveness and the silent-drop problem.** A tunnel drops, shadow sockets stay
   bound, `ListAgents` lists unreachable peers and `SendMessage` reports success.
   What must a conforming relay do?
5. **Who owns cleanup?** Foreign-`pidDomain` records are deliberately never
   reaped by Claude Code, so whatever creates them must delete them. A crashed
   relay leaves ghosts in every session's `ListAgents` — including sessions with
   nothing to do with TBD.
6. **How much of Claude Code's private shape may the spec depend on?** The record
   layout and frame shape are undocumented internals of a third-party binary that
   could change in any release. What is the containment strategy — a
   `peerProtocol` gate, a conformance test, a single adapter module?
7. **Trust.** The local socket's only authority is filesystem ownership (0600). A
   bridge extends that trust across a network hop. Peer messages are already
   treated as untrusted teammate input, so this is probably fine — but it should
   be a decision on the record.

## Deliverable

A design doc a TBD implementer can build from: the provider-contract change, the
relay's responsibilities and required behaviors, addressing/naming rules, failure
modes, and what conformance means. Small enough to be a real feature, not an
architecture essay.
