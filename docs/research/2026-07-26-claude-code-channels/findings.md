# Draft-safe message injection: the Claude Code inbox socket and Codex app-server

**Status:** Investigated, not implemented
**Claude Code measured:** 2026-08-14 and 2026-08-15 against Claude Code 2.1.233
on macOS 26.1
**Codex schema inspected:** 2026-07-26 with codex-cli 0.145.0

This directory is named for Claude Code channels; the Claude Code mechanism it
examines is the per-session inbox socket, which is the surface a script or hook
posts into.

## Summary

Claude Code binds a Unix-domain **inbox socket** for every session with
cross-session messaging enabled. Anything running as the same OS user can
connect to it and post a message, and a message the receiving session accepts
is enqueued as a user turn without writing into its terminal composer. It is a
supported, documented surface: no agent-side MCP server, no startup flag, and
no per-session consent prompt.

Draft safety was measured directly. With an unsent draft sitting in the
composer, an external Python script posted a message to the socket; the message
was delivered and answered, and the draft was byte-for-byte unchanged
afterward. This held with the receiver idle, and with a turn already running —
both when the message waited for that turn to finish and when it joined the
turn in flight.

The real constraint is not access, it is the receiver's **inbound gate**. A
message can be delivered, held for approval, or dropped, depending on the
receiving session's `crossSessionInbound` setting and — when that is unset — on
the two sessions' permission-mode classes. Upstream documents one consequence
that matters most here: a fire-and-exit script on macOS must present the
session's messaging token, or a bypass-permissions receiver will hold its
message.

Codex exposes a separate native pathway through its experimental app-server
protocol. A client can steer an active turn or start a new turn without sending
terminal input. The protocol shape is documented and present in the installed
Codex schema, but composer-draft preservation and concurrent-client behavior
have not been tested.

Official documentation:

- [Cross-session messaging](https://code.claude.com/docs/en/cross-session-messaging)
- [Channels](https://code.claude.com/docs/en/channels) — the separate shipped
  feature for pushing external events (CI results, chat) into a session
- [Settings](https://code.claude.com/docs/en/settings) — `crossSessionInbound`,
  `dialogExpiry`, `isolatePeerMachines`
- [Codex app-server](https://learn.chatgpt.com/docs/app-server.md)
- [Codex scheduled tasks](https://learn.chatgpt.com/docs/automations.md)

A broader external message-injection API is an open upstream feature request:
[anthropics/claude-code#53049](https://github.com/anthropics/claude-code/issues/53049).

TBD already ships against this mechanism, and those two documents are where to
start before designing anything further on it:

- [`docs/cross-session-messaging.md`](../../cross-session-messaging.md) — the
  user-facing description of what TBD supports today.
- [`docs/specs/2026-08-09-cross-session-messaging-design.md`](../../specs/2026-08-09-cross-session-messaging-design.md)
  — the shipped design, including the decision to mirror the session registry
  into the host store so TBD's per-profile config directories stay mutually
  visible.

## How these findings were established

Three kinds of evidence back the Claude Code sections, and each section says
which ones it rests on. A section citing two has both:

- **Measured** — reproduced live against Claude Code 2.1.233 on macOS 26.1, by
  running a session and probing it.
- **Read from the 2.1.233 binary** — recovered by inspecting the installed
  executable. These are implementation details of one version, not a stable
  contract, and should be rechecked on upgrade.
- **Documented** — stated by upstream documentation and not independently
  reproduced here.

The Codex app-server section rests on a different and older basis: the
generated experimental schema shipped with codex-cli 0.145.0, read on
2026-07-26, plus upstream Codex documentation. Nothing in it was measured
against a running Codex session.

## The session registry

**Measured.** Every session that binds an inbox socket also writes a
`<pid>.json` row under `$CLAUDE_CONFIG_DIR/sessions`, defaulting to
`~/.claude/sessions`. Across the
61 rows present on the probe machine, every row carried `pid`, `sessionId`,
`cwd`, `startedAt`, `procStart`, `version`, `peerProtocol`, `kind`,
`entrypoint`, `name`, `status`, `statusUpdatedAt` and `updatedAt`; most also
carried `tmux` (a target pane), `messagingSocketPath` and `nameSource`. Some rows
carry `bridgeSessionId`; on the probe machine those were the rows belonging to
cloud and Remote Control sessions.
`status` is coarse — `idle`, `busy`, `waiting`, `shell`. **No transcript
content appears in the registry.**

The registry lives under the config directory, so it **fragments per config
directory**. Sessions started with different `CLAUDE_CONFIG_DIR` values cannot
see each other's rows. The socket directory does not fragment; it is per OS
user.

## The socket

**Read from the 2.1.233 binary.** The socket path is
`$XDG_RUNTIME_DIR/cc-socks/<pid>.sock`. When `XDG_RUNTIME_DIR` is unset the
base is `$CLAUDE_CODE_TMPDIR`, falling back to `/tmp`, which is what makes the
macOS path `/tmp/cc-socks/<pid>.sock`. If that path would exceed 103 bytes —
the `sun_path` limit — the fallback is `<tmp>/cc-socks-<uid>/<pid>.sock`.

The socket file is created mode 0600, so it is reachable only by the OS user
that owns the session. The peer key file described below is written mode 0600
into a mode 0700 directory.

## Environment variables

**Documented, and measured for an interactive session.** Claude Code exports
two variables into hooks — including `SessionStart` — and into every Bash tool
call:

- **`CLAUDE_CODE_MESSAGING_SOCKET`** — this session's own socket path.
- **`CLAUDE_CODE_MESSAGING_TOKEN`** — this session's **child** token.

Each session exports its own pair, never one inherited from a parent. *Read
from the 2.1.233 binary:* when a session starts before the feature flag that
turns messaging on has resolved, both are exported once the fetch completes, so
processes started earlier keep seeing them unset. `/status` shows the same path in its `Peer address` row,
prefixed `uds:`.

## Wire protocol

**Read from the 2.1.233 binary.** The socket speaks newline-delimited JSON. The
receiver drops the connection if its read buffer passes 1 MiB without a
newline.

An auth frame, when sent, must be the first line:

```json
{"type":"auth","token":"<32 hex characters>"}
```

A user message:

```json
{"type":"user","from":"ci","priority":"next",
 "message":{"role":"user","content":"…"}}
```

`message.content` must be a non-empty string; anything else is ignored with a
warning. Optional fields on the user frame:

- **`session_id`** — if present and it does not match the receiving session's
  ID, the message is dropped. This is the guard against a reused pid.
- **`priority`** — `now`, `next`, or `later`; anything else falls back to
  `next`. *Measured:* posted to a session mid-turn, `next` waits for the
  running turn to finish, while `now` joins that turn in flight and is answered
  in the same assistant reply as the prompt already being worked on. `later`
  was not exercised.
- **`msg_id`** — correlates the sender-side delivery receipt described below.
- **`uuid`** — the queue entry's identifier; one is generated if omitted.
- **`file_attachments`** — materialized locally before the message is enqueued.

Control frames carry an `action`:

```json
{"type":"control","action":"rename","name":"…"}
{"type":"control","action":"peer_message_status",
 "status":"held|denied|expired|delivered","orig_msg_id":"…"}
```

`rename` changes the name the session answers to in `ListAgents`.
`peer_message_status` is the sender-side delivery receipt; a status naming an
`orig_msg_id` with no outstanding send is discarded.

An injected user message is enqueued with `isMeta: true` and
`skipSlashCommands: true`, so **a slash command inside an injected message is
inert** — it arrives as plain text and is never executed. That is a meaningful
safety property for anything built on this surface.

**Measured.** The transcript entry an injected message produces carries
`isMeta: true`, `promptSource: "system"`, `userType: "external"` and
`origin: {"kind":"peer","from":"<the label the sender asserted>"}`. Posting the
literal text `/help` drew a prose answer describing the session rather than the
slash command's output, so the inert-slash-command property holds in practice
and not only in the binary.

The CLI logs its own injection recipe at bind time, which is the most direct
citation for the format:

```sh
[uds-messaging] Inject messages (auth line optional here):
{ echo '{"type":"auth","token":"'"$CLAUDE_CODE_MESSAGING_TOKEN"'"}';
  echo '{"type":"user","message":{"role":"user","content":"hello"}}'; } |
socat - UNIX-CONNECT:/tmp/cc-socks/<pid>.sock
```

## Trust classes, and why auth is not a gate

**Read from the 2.1.233 binary.** Two 16-byte random tokens exist per session,
rendered as 32 hex characters:

- **`peerToken`** — published in
  `$CLAUDE_CONFIG_DIR/sessions/<pid>.<sha256-of-socket-path>.key`, mode 0600,
  readable by the OS user. Authenticates as trust class **peer**.
- **`childToken`** — the `CLAUDE_CODE_MESSAGING_TOKEN` environment variable.
  Authenticates as trust class **child**.

Whether an auth frame is required at all resolves as `requireAuth ??
isWindows()`, and cross-session messaging is not offered on native Windows.
**In practice the auth frame is therefore never mandatory**: it does not gate
entry to the socket. What it does is establish the sender's trust class, which
is what the inbound gate then judges.

## The inbound gate

**Read from the 2.1.233 binary, and consistent with the documentation.**
Delivery runs through the `crossSessionInbound` setting:

- **`accept`** — deliver the message.
- **`hold`** — set it aside undelivered, show a notice, and release it only if
  an `accept` later applies.
- **`refuse`** — drop it, with no notice to the sender.

When no value applies, Claude Code decides per message from the two sessions'
permission-mode classes. It groups sessions that bypass permission prompts into
one class and every other session into the other:

- **A receiver that prompts for permissions** delivers each message, holding
  one only when the sender identifies itself as bypassing.
- **A receiver that bypasses permission prompts** holds each message for
  approval, delivering one only when the sender also identifies as bypassing.

The gate fails closed: an unrecognized or unreadable permission mode holds.

Other limits:

- **Held-message expiry** — a held message expires at `dialogExpiry`, one of
  `60s`, `5m`, `10m` or `never`, defaulting to `5m`. A message held by an
  explicit `hold` setting does not expire; it waits for an `accept` to apply.
- **Hold buffer** — at most 100 held messages; past that the oldest is evicted
  and reported to its sender as expired.
- **Accepted queue and loop throttling** — *documented, not verified here*:
  Claude Code rate-limits repeated messages per sender, drops identical repeats
  arriving within a short window, and caps accepted messages waiting to be read
  at 50 per session, so a message loop between two sessions stops on its own.

For an unattended `claude -p` worker, set `crossSessionInbound: accept` in its
`--settings` value.

## Own-child messages and the macOS seam

This is the single most important operational detail for anything TBD would
build here.

**Documented, and matched by the 2.1.233 binary's verification logic.** When no
`crossSessionInbound` value applies, a message Claude Code verifies came from
its own child process — a hook or a Bash command posting back to its own
session's socket — is delivered. Verification has a platform seam:

- **On Linux, including WSL 2**, process evidence survives the poster exiting,
  so a fire-and-exit script still verifies.
- **On macOS**, process evidence holds only while the posting process is still
  alive.
- **In a container where Claude Code runs as process ID 1**, there is no
  process evidence at all.

Where process evidence is missing, the `CLAUDE_CODE_MESSAGING_TOKEN` auth frame
is what verifies the child. **A fire-and-exit script on macOS must therefore
present the token**, or it is treated as asserting no permission class — which
a bypass-permissions receiver holds for approval.

**Documented.** One prerequisite sits underneath all of this: a Bash command
running inside Claude Code's sandbox reaches the socket only if the sandbox's
Unix-socket settings, `sandbox.network.allowAllUnixSockets` and
`sandbox.network.allowUnixSockets`, permit it. That constrains the hook and
Bash-command path, not a host-side process posting from outside the session.

## Availability

**Documented.** Cross-session messaging requires Claude Code v2.1.224 or later.
It runs on macOS and Linux including WSL 2, and is not offered on native
Windows. It is not available on Amazon Bedrock, Claude Platform on AWS, Google
Cloud's Agent Platform, or Microsoft Foundry. It stays off entirely when
feature-flag evaluation is disabled by any of
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_TELEMETRY`, `DO_NOT_TRACK`
or `DISABLE_GROWTHBOOK`. `/list-agents`, aliased `/peers`, checks a session.

**Measured.** A `claude -p` session binds an inbox socket and registers itself,
with `entrypoint: "sdk-cli"`, so a long-running print-mode worker is reachable
and appears in the listing. Bare mode binds no socket and does not appear
(*documented*, not verified here).

## Draft safety

**Measured** against Claude Code 2.1.233 on macOS 26.1. A throwaway
interactive session ran in its own tmux server, and an unrelated external
Python process — no Claude involved, no auth token presented — posted messages
to that session's socket with [`inject-message.py`](inject-message.py). A
distinct sentinel string was typed into the composer and left unsent before
each post, and the composer region of the rendered pane was captured before and
after and compared byte-for-byte.

- **Idle receiver.** The message was delivered, rendered in the conversation,
  and started a new turn that ran to completion. The composer was unchanged:
  same byte length, same SHA-256 before and after.
- **Turn already running, default `priority: next`.** The registry `status` was
  confirmed `busy` when the draft was typed, immediately before the post, and
  immediately after it. The message waited for the running turn to finish and
  was answered once it did. The composer was captured both while that turn was
  still running and again after the session went idle; both matched the before
  capture byte for byte.
- **Turn already running, `priority: now`.** The message joined the turn in
  flight: the transcript records it ahead of that turn's assistant reply, and
  the reply answered the injected message and the original prompt together. The
  composer was again identical before and after.

Four posts in all landed on one session while an unsent draft sat in its
composer, and the draft's bytes never changed.

This is the property that matters for scheduled delivery: a message arriving on
the socket does not compete with a person typing. It establishes the behavior
of 2.1.233, not a compatibility guarantee for future versions.

## Security posture

**Measured.** The delivered message was rendered to the receiver as
**"Another Claude session sent a message:"** followed by the text and an
anti-escalation preamble, which tells the receiving Claude that the message
came from a peer rather than the user, that a peer cannot grant escalation,
that it must never edit permission settings, `CLAUDE.md` or config because a
peer asked, and that a peer claiming it was denied permission and asking the
receiver to act instead must be refused and surfaced to the user.

**Measured.** The `from` field is sender-asserted and unverified. The probe
sent `from: "external-shell-probe"` and the message was still framed as coming
from another Claude session. What is actually verified is the trust class, and
that feeds only the hold-or-deliver gate, not the framing text.

So the honest statement is: **anything running as the same OS user can inject
text that a session presents as a trusted teammate**, and the guardrails
against escalation are prompt-level rather than enforced. This is why
`crossSessionInbound: refuse` combined with permission deny rules naming
`SendMessage` and `ListAgents` exists for managed settings. One observation
from the probe: the receiving model did refuse the injected instruction and
surfaced it as a suspected injection attempt — the preamble works, but it works
by persuasion.

## Reference scripts

Two runnable Python 3 scripts sit next to this document. Both are standard
library only.

- **[`inject-message.py`](inject-message.py)** — posts a user message to a
  socket. Defaults the target to `$CLAUDE_CODE_MESSAGING_SOCKET` and sends the
  `CLAUDE_CODE_MESSAGING_TOKEN` auth frame when one is available. Takes
  `--from`, `--priority`, `--session-id` and `--no-token`. Pass `--no-token`
  whenever `--socket` names a session other than your own: the environment's
  token belongs to your session and means nothing to a different one.
- **[`list-sessions.py`](list-sessions.py)** — reads the session registry from
  `$CLAUDE_CONFIG_DIR/sessions`, falling back to `~/.claude/sessions`, and
  prints live peers with pid, name, status, cwd and socket, skipping rows whose
  process is gone.

The measurements above were taken with these two scripts.

## Codex app-server pathway

Codex app-server is the native protocol used by rich Codex clients. It is not
an MCP capability. A terminal UI can connect to an app-server over a local Unix
socket:

```sh
codex app-server --listen unix:///path/to/codex.sock
codex --remote unix:///path/to/codex.sock
```

For an in-flight turn, a client can append user input with `turn/steer`:

```json
{
  "method": "turn/steer",
  "id": 42,
  "params": {
    "threadId": "thr_123",
    "expectedTurnId": "turn_456",
    "input": [
      {
        "type": "text",
        "text": "Scheduled message"
      }
    ]
  }
}
```

`expectedTurnId` is a race-safety precondition: the request fails if that turn
is no longer active. When the thread is idle, the client can instead use
`turn/start`. The server emits `turn/completed` when a turn finishes, giving a
scheduler a machine-readable point at which to start a queued follow-up.

The generated 0.145.0 experimental schema does not expose a server-side queue
request. Codex clients provide queueing as a user-interface behavior, so a TBD
adapter should retain a scheduled message until `turn/completed` and then call
`turn/start`. Some active turns, including `/review` and manual `/compact`, can
reject steering with `activeTurnNotSteerable`; the adapter must wait or report
that state rather than silently dropping the message.

Codex also supports scheduled tasks that can return to an existing chat on
minute-based intervals. Scheduling is managed through the ChatGPT web or
desktop surfaces, not Codex CLI. That product feature may cover user-facing
follow-up loops, but it does not replace a TBD-controlled local delivery
protocol.

No official Codex documentation describes an MCP server pushing unsolicited
messages into a Codex conversation. App-server is therefore the narrowest
documented integration point for TBD.

## Unknowns and limitations

- Draft preservation is established for Claude Code 2.1.233 on macOS, for a
  single-line composer draft. It is not a compatibility guarantee for future
  versions, it was not re-measured on Linux, and a multi-line or
  attachment-bearing draft was not tested.
- The own-child macOS seam — that a fire-and-exit poster needs the token — was
  not reproduced against a bypass-permissions receiver; it rests on the
  documentation and on the binary's verification logic.
- The documented loop throttles (per-sender rate limiting, identical-repeat
  suppression, the 50-message accepted queue cap) were not reproduced.
- Reconnect, session restart, burst ordering, backpressure, and failure
  recovery were not tested.
- The registry's `status` field is coarse and its freshness was not
  characterized; it is not a substitute for a liveness signal TBD owns.
- Everything read from the 2.1.233 binary describes one version's
  implementation, not a stable public contract.
- Codex app-server is experimental.
- The Codex pathway has not been exercised with an unsent terminal composer
  draft. Because it bypasses terminal input, draft preservation is plausible,
  but it is not yet an observed fact.
- Multiple clients addressing the same app-server thread, reconnect behavior,
  and scheduler recovery after a rejected steer remain unverified.

## Implication for TBD

If TBD pursues scheduled, draft-safe messages to Claude Code sessions, the
narrowest design needs nothing inside the agent at all:

```text
TBD scheduler
    -> tbdd
    -> read $CLAUDE_CONFIG_DIR/sessions/<pid>.json for the session
    -> connect to /tmp/cc-socks/<pid>.sock
    -> {"type":"auth",…} then {"type":"user",…}
    -> Claude Code conversation queue
```

Three consequences follow for TBD specifically:

- **Session identification is a lookup, not an inference.** The registry row
  carries `sessionId`, `cwd` and the tmux target pane, so TBD can match a
  session to a worktree without reading terminal content. Sending `session_id`
  on the user frame makes a reused pid a dropped message rather than a
  misdelivered one.
- **The registry fragments per config directory, and TBD already un-fragments
  it.** TBD gives each model profile its own `CLAUDE_CONFIG_DIR`, which would
  otherwise leave profiles mutually invisible to one another.
  `ClaudeProfileConfigDirManager` lists `sessions` among its host-mirror slots,
  so every profile's `sessions/` is a symlink to the single host store and a
  TBD session is discoverable whichever profile spawned it. The daemon should
  read the host store rather than hunt for a per-profile copy. The socket
  directory is per OS user and never fragmented.
- **Delivery is gated at the receiver, so it must be arranged at spawn.** A
  fleet session running in bypass-permissions mode holds an unauthenticated
  message. TBD would need to pass `crossSessionInbound: accept` in the
  session's settings, present the child token, or accept that delivery depends
  on the receiver's mode. Writing the frames is not evidence of delivery;
  `peer_message_status` is the receipt, and a first implementation should
  describe delivery as best-effort with bounded retention and deduplication in
  the daemon until it consumes that receipt.

`terminal.send` should remain the mechanism for intentional terminal input; the
inbox socket would be a distinct out-of-band path for messages that must not
disturb the composer.

For Codex, the corresponding candidate path is:

```text
TBD scheduler
    -> tbdd
    -> terminal-specific Codex app-server socket
    -> turn/steer while active, or turn/start while idle
    -> Codex conversation
```

This path has stronger protocol feedback than a single socket write:
`turn/steer` returns the accepted turn ID, rejects a stale `expectedTurnId`,
and the server reports turn completion. TBD would still need bounded retention,
deduplication, and a policy for non-steerable turns.

## Constraint tension

[`recipe/constraints/no-agent-cooperation.md`](../../../recipe/constraints/no-agent-cooperation.md)
says TBD should not require agent-side integrations or changes to agent
configuration: agents are unmodified Claude Code sessions.

The Claude Code inbox socket sits almost entirely inside that constraint. Every
eligible session binds it automatically and registers itself on disk; there is
no MCP server to install, no startup flag, and no consent prompt. Reading the
registry and writing to the socket are host-side actions against a session that
knows nothing about TBD.

What remains is narrower, and it is a capability question rather than a
cooperation one:

- **Reliable delivery to a bypass-permissions session needs a settings value.**
  Setting `crossSessionInbound: accept` at spawn is a change to the session's
  configuration, even though TBD makes it through a launch flag it already
  controls rather than through anything the user installs.
- **The capability must be detected, not assumed.** Version, platform,
  provider, and the telemetry environment variables all decide whether a
  session binds a socket at all, so TBD has to treat reachability as a
  per-session fact with a fallback, not as a property of Claude Code.

The Codex app-server path carries the heavier tension: it is a host integration
rather than an agent-side plugin, but adopting it would change how TBD launches
and owns Codex sessions.

## Recommendation

The Claude Code inbox socket is ready to be designed against as the draft-safe
delivery path, with reachability treated as a per-session fact and delivery
reported as best-effort until the `peer_message_status` receipt is consumed.

The next investigations, in order of value:

1. Reproduce the own-child macOS seam against a bypass-permissions receiver,
   with and without the token, so the spawn-time requirement is measured rather
   than inferred.
2. Re-measure draft safety on Linux and on the next Claude Code minor version,
   to learn how stable the property is.
3. Exercise the documented loop throttles, and burst and reconnect behavior,
   before anything unattended writes to a socket on a schedule.
4. Run the same empty-composer and dirty-composer tests against a remote Codex
   TUI plus app-server client, and test multiple clients, reconnect behavior,
   and non-steerable-turn recovery.

Keep scheduled delivery out of `terminal.send`: terminal input cannot provide
the draft-preservation property demonstrated here.
