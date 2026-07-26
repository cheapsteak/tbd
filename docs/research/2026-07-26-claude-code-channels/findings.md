# Claude Code Channels: draft-safe message injection

**Status:** Investigated, not implemented
**Tested:** 2026-07-26 with Claude Code v2.1.220 and Haiku 4.5

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

Official documentation:

- [Channels](https://code.claude.com/docs/en/channels)
- [Channels reference](https://code.claude.com/docs/en/channels-reference)

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
infrastructure. The next investigation should verify an approved plugin channel,
document reconnect and acknowledgement semantics, and decide whether an optional
agent integration is compatible with TBD's no-cooperation constraint. Keep
scheduled delivery out of `terminal.send`: terminal input cannot provide the
draft-preservation property demonstrated here.
