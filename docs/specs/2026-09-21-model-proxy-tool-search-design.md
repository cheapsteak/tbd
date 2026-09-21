# Keeping proxied sessions first-party

## Summary

The model proxy (`docs/specs/2026-09-05-transcript-streaming-model-proxy-design.md`)
routes a pty-holder session by pointing `ANTHROPIC_BASE_URL` at
`http://127.0.0.1:<port>/r/<token>`. Claude Code treats any base URL whose host
is not `api.anthropic.com` as a third-party gateway and switches off a set of
first-party behaviors, among them deferred tool loading and the model catalog
that gives Opus its 1M window. A proxied session therefore sent every tool
schema in its first request and sized its window at 200k: a real session's
first turn created 222,901 tokens of cache before doing any work and compacted
at once.

The fix is two variables set beside the route URL on every routed spawn:

- `_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL=1` tells Claude Code to treat the
  base URL as first-party, which restores everything the host check gates
  except Remote Control.
- `ENABLE_TOOL_SEARCH=true` keeps tool search on even if a future Claude Code
  drops the first variable, so the first-request blowup cannot recur silently.

The first variable is internal and undocumented, so the proxy also watches for
the header Claude Code sends only in first-party mode and logs an error when a
route's first conversation request lacks it.

No new flag: all of this lives inside the existing, default-off
`model_proxy_enabled`.

## What was measured

Against Claude Code 2.1.278, read from the installed binary's embedded
JavaScript and confirmed with real turns.

- **The host check.** `isFirstPartyAnthropicHost` accepts exactly
  `["api.anthropic.com"]`, compared against `new URL(base).host`, so loopback
  never qualifies. `isFirstPartyAnthropicBaseUrl` returns true early when
  `_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL` is set; Remote Control reads the
  lower-level `isActualFirstPartyAnthropicBaseUrl` instead, and the binary's own
  message says the variable "does not apply to Remote Control".
- **What the host check gates.** Tool search (the binary logs
  `[ToolSearch:optimistic] disabled: ANTHROPIC_BASE_URL=… is not a first-party
  Anthropic host. Set ENABLE_TOOL_SEARCH=true (or auto / auto:N) if your proxy
  forwards tool_reference blocks.`); the served model catalog, which is where
  `claude-opus-5` is marked native-1M; the `x-client-request-id` header and
  billing-header fields; org policy-limit and remote managed-settings fetches;
  auto-continue after a usage-limit reset; error reporting; Remote Control and
  Ultrareview. The `anthropic-beta` set and the claude.ai connectors are keyed
  on the provider and the login, not the base URL.
- **`x-client-request-id` tracks the override.** The header is added only when
  `provider === "firstParty" && isFirstPartyAnthropicBaseUrl()`, the same
  predicate the override flips.
- **The production incident.** A proxied session spawned with
  `ANTHROPIC_MODEL=opus` recorded a first turn of `cache_creation_input_tokens:
  222901`, `cache_read_input_tokens: 0`. Its `prompt_snapshot` carried 143 tool
  definitions, about 625 KB of JSON, none deferred. Unproxied `claude-opus-5`
  sessions on the same profile the same day ran to 490k and 328k tokens of
  context without compacting.
- **The fix, one turn per configuration.** Same profile, same working
  directory, `ANTHROPIC_MODEL=opus`, `claude -p "Reply with just: ok"`, through a
  loopback forwarder that recorded header names and tool counts:

  | configuration | first-turn prompt tokens | window | tools full / deferred | `x-client-request-id` |
  |---|---|---|---|---|
  | proxy as shipped | 95,504 | 200,000 | 111 / 0 | absent |
  | proxy + both variables | 32,563 | 1,000,000 | 11 / 5 | present |
  | direct | 32,776 | 1,000,000 | — | — |

  The fixed configuration matches the direct one, including a 10,118-token
  cache read of the shared prefix. Both proxied requests carried the same
  `anthropic-beta` list apart from the tool-search beta the fixed one added, so
  the beta header was never what failed.
- **The proxy passes tool search through.** Its forward path never parses the
  request body, and it drops only hop-by-hop headers and `accept-encoding`
  (`Sources/TBDModelProxy/UpstreamForwarder.swift`). `defer_loading`,
  `tool_reference` blocks, and the tool-search beta reach upstream as sent.

## Design

### Spawn environment

`ModelProxyRouteAttachment.attach` is the single place a route URL enters a
spawn's environment. Beside `ANTHROPIC_BASE_URL` it sets:

- `_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL=1`
- `ENABLE_TOOL_SEARCH=true`

Each is set only when the caller's resolved environment overrides do not
already name it, so a repo that sets either deliberately keeps its value. The
two are process environment only, not inline exports: they are not routing
keys, and the inline export exists to defend endpoint variables against rc
files that set them. Every unrouted outcome — tmux transport, Bedrock, flag
off, an overlay that sets its own base URL, no live proxy — carries neither.

With the override honored, the model catalog is back, so `ANTHROPIC_MODEL=opus`
resolves to Opus with its native 1M window exactly as a direct session does. No
model string changes.

`ENABLE_TOOL_SEARCH=true` is the backstop for the one failure that is
catastrophic rather than costly. If the override stops being honored, tool
search stays on and the first request stays small; the window, the catalog,
and the other first-party behaviors degrade, and the probe below says so.

### The probe

On the first `POST` under a route whose path, query stripped, ends in
`/v1/messages`, the proxy records whether the request carries
`x-client-request-id`. When it does not, the proxy logs once for that route, at
`.error`, subsystem `com.tbd.modelproxy`, category `first-party`: the terminal
id from the route and "first-party override not honored". Later requests on the
route are not examined. The latch is per route token and is dropped with the
route.

The verdict is a pure function of the method, path, and header names, so it is
tested without the logger. The probe reads headers the handler already holds,
never the body, and cannot delay or alter forwarding. A route used by a session
spawned before this change fires the error, which is true: that session is
running degraded.

A false alarm is possible if a future Claude Code stops sending the header in
first-party mode. A false pass is not: the header is added only under the
predicate the override controls.

### Accepted cost

Remote Control and Ultrareview stay unavailable in a proxied session, because
they read the base URL through a check the override does not reach. A user who
needs either in a session runs it unproxied.

## Testing

- **Attachment.** Every routed outcome carries both variables, and a test fails
  if a routed outcome sets `ANTHROPIC_BASE_URL` without them. No unrouted
  outcome carries either. A value already present in the env overrides wins.
  Neither variable appears in the builder's inline exports.
- **Probe.** The verdict: a `/v1/messages` POST, with and without the query
  string, with and without the header, and non-matching methods and paths. The
  latch examines one request per route and forgets the route when it is
  dropped.
- **Forwarding.** A request body containing `defer_loading` tools and a
  `tool_reference` block arrives upstream byte-identical. A `?beta=true` query
  string reaches upstream intact.

## Rejected alternatives

- **`ENABLE_TOOL_SEARCH=true` alone, plus `opus[1m]` for the model.** Fixes the
  two visible symptoms and leaves the catalog, request ids, policy fetches, and
  usage-limit auto-continue degraded on every proxied session.
- **A tee that does not change the base URL.** The proxy spec's measurements
  found no other machine interface that carries assistant text before the
  message ends; this would mean giving up streaming.
- **`CLAUDE_CODE_USE_GATEWAY`.** Switches the provider to "gateway" and requires
  `ANTHROPIC_AUTH_TOKEN`, which loses claude.ai-subscriber behavior.
- **A first-turn token threshold as the regression signal.** A heuristic that a
  large CLAUDE.md trips and that misses regressions costing only cache or
  features.
- **Surfacing the probe in the UI or `daemon.capabilities`.** Needs a new
  proxy-to-daemon channel or field for a signal the log carries.
