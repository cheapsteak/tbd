# Draft-safe message injection: Claude Code Channels and Codex app-server

**Status:** Investigated, not implemented
**Tested:** 2026-07-26 with Claude Code v2.1.220 and Haiku 4.5
**Codex schema inspected:** 2026-07-26 with codex-cli 0.145.0

## Summary

Claude Code's research-preview Channels interface can deliver an external
message to a running interactive session without writing into its terminal
composer. In the interactive test, a channel message started a turn while an
unsent draft was present, and the draft remained byte-for-byte unchanged after
the turn.

This is a promising mechanism for scheduled TBD messages because it does not
compete with a person typing in the composer. It is not ready to be treated as a
general delivery guarantee: custom development channels require startup
consent, channel notifications have no delivery acknowledgement, and the same
development-channel mechanism did not work with `claude -p`.

Codex exposes a separate native pathway through its experimental app-server
protocol. A client can steer an active turn or start a new turn without sending
terminal input. The protocol shape is documented and present in the installed
Codex schema, but composer-draft preservation and concurrent-client behavior
have not yet been tested.

Official documentation:

- [Channels](https://code.claude.com/docs/en/channels)
- [Channels reference](https://code.claude.com/docs/en/channels-reference)
- [Codex app-server](https://learn.chatgpt.com/docs/app-server.md)
- [Codex scheduled tasks](https://learn.chatgpt.com/docs/automations.md)

## Observed facts

The test MCP server advertised the experimental channel capability in its
initialize result:

```json
{
  "capabilities": {
    "experimental": {
      "claude/channel": {}
    }
  }
}
```

It later emitted this MCP notification:

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/claude/channel",
  "params": {
    "content": "Reply with exactly: CHANNEL_RECEIVED_7c92",
    "meta": {
      "kind": "scheduled-test"
    }
  }
}
```

Claude Code represented the delivered notification to the conversation in a
channel envelope of this form:

```xml
<channel source="tbd-channel-test" kind="scheduled-test">
Reply with exactly: CHANNEL_RECEIVED_7c92
</channel>
```

With `/path/to/mcp.json` registering the test server as
`tbd-channel-test`, the interactive session was started with the development
channel explicitly enabled:

```sh
claude --model haiku \
  --mcp-config /path/to/mcp.json \
  --dangerously-load-development-channels server:tbd-channel-test
```

Development channels prompt for per-session startup consent. After consent,
Claude Code registered the server's channel handler.

Two interactive cases were exercised:

| Composer state | Result |
| --- | --- |
| Empty | The notification immediately started a Haiku 4.5 turn, which returned the requested response. |
| Unsent draft present | The notification immediately started its own turn. The pre-existing draft remained byte-for-byte unchanged in the composer afterward. |

No terminal input or textbox submission was used to trigger either channel
turn.

The custom development channel was also tested in noninteractive print mode:

```sh
claude -p --model haiku \
  --mcp-config /path/to/mcp.json \
  --dangerously-load-development-channels server:tbd-channel-test \
  "Use Bash to run sleep 7, then finish the original request."
```

The forced sleep kept the original turn active while the MCP server emitted its
notification. The server initialized and successfully emitted the notification,
but Claude Code did not register or consume it. The notification was silently
dropped, and only the original print-mode turn completed.

## Installed-binary inspection

Inspection of the installed Claude Code v2.1.220 executable showed that
development-channel CLI entries are not applied in noninteractive mode. This
matches the observed `claude -p` result.

The ordinary `--channels` parsing path remains present in noninteractive mode.
That does not establish that an approved plugin channel works with `claude -p`;
that combination was not tested.

This section describes v2.1.220 implementation details, not a stable public
contract. It should be rechecked when upgrading Claude Code.

## Codex app-server pathway

Codex app-server is the native protocol used by rich Codex clients. Unlike
Claude Code Channels, it is not an MCP capability. A terminal UI can connect to
an app-server over a local Unix socket:

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
channel messages into a Codex conversation. App-server is therefore the
narrowest documented integration point for TBD.

## Unknowns and limitations

- Channels are a research-preview Claude Code feature.
- Custom development channels need explicit consent each time the session
  starts.
- A channel notification has no delivery acknowledgement. Successful emission
  by the MCP server does not prove that Claude Code consumed it.
- Approved plugin channels with `claude -p --channels ...` remain unverified.
- Reconnect, session restart, burst ordering, backpressure, and failure recovery
  were not tested.
- The interactive tests establish composer preservation for v2.1.220; they do
  not establish a compatibility guarantee for future versions.
- Codex app-server is experimental.
- The Codex pathway has not been exercised with an unsent terminal composer
  draft. Because it bypasses terminal input, draft preservation is plausible,
  but it is not yet an observed fact.
- Multiple clients addressing the same app-server thread, reconnect behavior,
  and scheduler recovery after a rejected steer remain unverified.

## Implication for TBD

If TBD pursues scheduled, draft-safe messages, the narrowest design is a small
MCP channel adapter associated with each Claude session:

```text
TBD scheduler
    -> tbdd
    -> terminal-specific local socket
    -> MCP channel adapter launched with Claude
    -> notifications/claude/channel
    -> Claude Code conversation queue
```

TBD already supplies `TBD_TERMINAL_ID` to spawned sessions. The adapter can use
that value to bind its MCP process to the correct daemon socket and terminal,
without inferring identity from terminal content. `terminal.send` should remain
the mechanism for intentional terminal input; Channels would be a distinct
out-of-band path for messages that must not disturb the composer.

Because notifications are not acknowledged, TBD should not report delivery
merely because it wrote the MCP notification. A first implementation should
either describe delivery as best-effort or add a separate acknowledgement
protocol, with bounded retention and deduplication in the daemon.

For Codex, the corresponding candidate path is:

```text
TBD scheduler
    -> tbdd
    -> terminal-specific Codex app-server socket
    -> turn/steer while active, or turn/start while idle
    -> Codex conversation
```

This path has stronger protocol feedback than Claude Code Channels:
`turn/steer` returns the accepted turn ID, rejects a stale `expectedTurnId`, and
the server reports turn completion. TBD would still need bounded retention,
deduplication, and a policy for non-steerable turns.

## Constraint tension

This design is in tension with
[`recipe/constraints/no-agent-cooperation.md`](../../../recipe/constraints/no-agent-cooperation.md),
which says TBD should not require agent-side integrations or changes to agent
configuration. A development Channel requires both an MCP integration and a
Claude startup flag/consent flow.

There is no decision yet about changing that constraint. Plausible boundaries
for later design work include making Channels an optional capability, limiting
them to user-configured scheduled messaging, or packaging an approved plugin
channel if its noninteractive and consent behavior is acceptable. Any of these
would need an explicit product decision before implementation.

## Recommendation

Treat Channels as a validated interactive prototype, not yet as core
infrastructure. The next investigation should verify an approved Claude plugin
channel and run the same empty-composer and dirty-composer tests against a
remote Codex TUI plus app-server client. It should also test multiple clients,
reconnect behavior, and non-steerable-turn recovery before either pathway is
used for delivery.

Decide separately whether an optional Claude agent integration is compatible
with TBD's no-cooperation constraint. Codex app-server is a host integration
rather than an agent-side MCP plugin, but it would change how TBD launches and
owns Codex sessions. Keep scheduled delivery out of `terminal.send`: terminal
input cannot provide the draft-preservation property demonstrated here.
