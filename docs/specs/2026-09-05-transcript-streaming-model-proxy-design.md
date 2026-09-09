# Streaming assistant text into the transcript through a model proxy

## Summary

TBD's transcript pane renders a Claude Code session's JSONL. That file learns of
an assistant message only once the message is complete, so the pane lags the
terminal by a whole message: measured on a live session, a text block whose
own timestamp read 16:16:36 reached the file at 16:16:42, and one waited 25
seconds behind a long `tool_use` block in the same message. No hook, socket, or
subcommand of the interactive CLI exposes the text earlier, and reading it off
the rendered terminal is banned (`CLAUDE.md`, "No TUI screen-scraping").

The one machine interface that carries the text as it is generated is the
Messages API stream Claude Code itself consumes. This design puts a small
**model proxy** on loopback, routes pty-holder sessions through it by
`ANTHROPIC_BASE_URL`, and has the proxy tee each conversation stream's text
deltas into a per-session file. The app tails that file the way it already
tails the JSONL and shows one **provisional assistant row** that grows with the
stream and is retired the moment the JSONL line for that message lands.

Three decisions shape everything below, each made by a human:

- **The proxy is a standalone process the daemon owns, not code inside the
  daemon.** The holder transport exists so sessions outlive daemon restarts;
  an in-daemon proxy would quietly reverse that for the API path.
- **Two flags, not one.** `model_proxy_enabled` governs routing and the tee;
  `transcript_streaming_enabled` governs the provisional row. The proxy is
  useful beyond streaming, so it is switchable on its own. Turning streaming
  on turns the proxy on; turning the proxy off turns streaming off; the two
  toggles sit together in Settings.
- **Text only, in this slice.** Thinking and tool-input deltas are not teed
  and not rendered.

Scope is the pty-holder transport only. A tmux-backed session is never routed
through the proxy and gains nothing from this design.

## What was measured

Every claim in this section was produced against the installed CLI
(Claude Code 2.1.261 through 2.1.263) and is the evidence the design rests on.

- **The JSONL is written whole per message.** Watching a live transcript at 20
  ms, every content block of a message appeared in the same tick, though their
  embedded timestamps were seconds apart. The lag is set by the slowest block
  in the message, which is usually a tool call.
- **No hook streams text.** The hook vocabulary compiled into the binary is
  `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Stop`, `StopFailure`,
  `SubagentStart`, `SubagentStop`, `UserPromptSubmit`, `PermissionRequest`,
  `PermissionDenied`, `Notification`, `SessionStart`, `SessionEnd`,
  `PreCompact`, `Setup`, `Elicitation`, `ElicitationResult`, `TeammateIdle`,
  `TaskCompleted`, `WorktreeCreate`, `WorktreeRemove`, `FileChanged`,
  `CwdChanged`, `InstructionsLoaded`, `ConfigChange`. None carries assistant
  text.
- **Partial messages exist only headless.** The binary's own error text reads
  `--include-partial-messages requires --print and --output-format=stream-json`.
  The interactive TUI has no structured streaming output.
- **The peer messaging socket is inbound only**, one JSON line per delivered
  message. `claude attach` and `claude logs` reproduce a background session's
  rendered terminal, which is screen text.
- **A claude.ai login sends its bearer token to a custom base URL.** With
  `ANTHROPIC_BASE_URL` pointed at a loopback listener that recorded header
  names only, every request arrived with `Authorization: Bearer` and no
  `x-api-key`. Anthropic's gateway compatibility guide states the same: the
  base URL alone keeps the subscription active, provided `anthropic-beta`
  reaches upstream verbatim, and setting any credential variable disables it.
- **Every request names its session.** `x-claude-code-session-id` is on every
  request. A `Task` subagent's requests additionally carry
  `x-claude-code-agent-id`, which the parent's never do. Both headers are
  documented by Anthropic for exactly this purpose.
- **The TUI's session-title request is distinguishable by shape.** It carries
  an empty `tools` array and wraps the user's text in `<session>…</session>`;
  a conversation request carries the session's full tool list.
- **Claude retries a refused base URL for 183 seconds**, then fails the turn
  with `API Error: Connection refused`. Against an authentication error it
  retried six times in 35 seconds. Both measured with zero tokens.
- **Claude aborts a stream that is silent for 300 seconds**, counting SSE
  `ping` events and comment lines toward liveness (gateway guide). A proxy
  that coalesces or drops those aborts long thinking pauses.

- **The mechanism works end to end against the real API.** A throwaway
  streaming tee proxy (Python, forwarding chunk by chunk, `accept-encoding`
  stripped, every SSE event flushed) sat between an interactive TUI session
  with a claude.ai login and `api.anthropic.com`. For a three-sentence answer
  the tee wrote its first text delta at 17:29:29.216, five deltas followed
  over three seconds, and the JSONL assistant line for the same message id
  landed at 17:29:32.328, 3.1 seconds after the first token and 0.17 seconds
  after `message_stop`. The `HEAD /api/hello` probe was forwarded, the
  no-tools title request was skipped by the filter, and an upstream 429 on a
  side request was relayed unchanged and handled by Claude's own retry. The
  same proxy in front of the fake model API produced the same tee for a
  scripted turn at zero tokens.

## Architecture

Three pieces, each with one job.

**The model proxy** is a new small executable, `TBDModelProxy`, one per TBD
home, spawned or re-adopted by the daemon and outliving it. It listens on a
loopback TCP port persisted in the config row. It forwards every request under
its base URL byte-for-byte to the upstream a **route** names, adds no
credentials, and logs no headers or bodies. For an event-stream response to a
conversation request it tees text deltas into a per-terminal file under the
TBD home. The tee never blocks forwarding.

**The daemon** decides who is proxied and keeps the proxy alive, and does
both only while `model_proxy_enabled` is on. With the flag on, a holder spawn
for a non-Bedrock profile gets a route and a base URL pointing at it, and a
supervisor adopts a live proxy at startup, spawns one when absent, respawns on
death, replaces a proxy whose version differs from its own, and retires routes
when their terminals end. With the flag off the supervisor never starts: no
probe, no spawn, no watch, and a fresh install runs no process it did not run
before.

**The app** tails the stream file at the transcript scheduler's existing
cadence and publishes one provisional assistant row per session. The daemon
is not in the data path.

## The proxy's contract

### Rendezvous and identity

A directory under the TBD home, `TBDConstants.modelProxyDir`, honoring
`TBD_HOME`, holds `proxy.lock`, `proxy.pid`, `proxy.log`, and a `routes/`
subdirectory. The daemon spawns the proxy with `posix_spawn`, the `flock`
descriptor riding a `dup2` file action exactly as `HolderSpawner` does
(`Sources/TBDDaemon/Holder/HolderSpawner.swift`), so a spawner that cannot take
the lock has learned a live proxy exists without connecting to it. The spawner
releases its own copy right after `posix_spawn`, leaving the child the sole
owner of the open file description the lock lives on.

The lock says **a live proxy owns this rendezvous**, so the proxy holds it from
spawn until its listener closes — a retire — or until the process exits,
whichever comes first. A proxy whose listener is closed owns no port and
answers no route; it is draining, not serving, and holding the lock through the
drain would keep a successor from being spawned at all. Nothing else in the
rendezvous needs that rule: the pid file is unlinked on the way out only while
it still names the exiting process, so a successor's file is never deleted by
its predecessor.

The proxy calls `setsid` first, ignores `SIGHUP` and `SIGPIPE`, and orphans to
launchd when the daemon exits. Its binary is a sibling of the daemon's, never
copied out of the build tree; a running image survives rebuilds as the holder's
does.

### Why one per TBD home

The proxy is one process per `~/tbd` directory rather than one per machine or
one per session. The home is the smallest unit that is already an ownership
boundary: it has one config row to hold the port, one rendezvous directory,
one daemon whose version the proxy should match and whose supervisor respawns
it, and one set of holders. A machine-wide proxy would need a machine-wide
version of each, and TBD has none; two checkouts on one machine each run a
daemon, and the holder owner token exists so one cannot adopt the other's
holders. One global proxy would put two daemons of different versions in
charge of one process with no rule for which wins. A per-session proxy would
live in the holder, which is kept frozen precisely because sessions run the
holder they were born with, and would cost one port per session for no gain:
a shared proxy's crash fails no turn, since Claude retries for 183 seconds and
the supervisor respawns in seconds.

Because every path derives from `TBD_HOME`, the test fence that redirects a
test's home gives that test its own proxy with no injection seam added for the
purpose. For an ordinary single-checkout install, per home and per machine are
the same thing.

### Port

The port lives in a new `model_proxy_port` config column. The first proxy is
spawned with port zero, reports the port the kernel assigned, and the daemon
persists it. Every later proxy is asked to bind that port. The daemon takes
`proxy.lock` **before** any bind, the same ordering the holder spawner uses
before touching a socket path, so two daemons on one TBD home cannot both mint.

On address-in-use the daemon probes the status endpoint on that port and
adopts only a process that passes the identity check below. Anything else,
including a proxy that belongs to another TBD home on the same machine after
an ephemeral-port coincidence, is not this daemon's to use, and is never
retired or replaced.

Before it gives such a port up, and only while a session is still routed
against it, the daemon waits for it. The condition is the whole justification:
with nothing routed there is nothing to strand, and a wait would only delay the
daemon's boot and the Settings toggle. The question the wait turns on is who
holds the number, asked with a plain loopback connect. A refused connect means
nothing is listening, so the holder is transient — macOS hands TCP ephemeral
ports out sequentially from one global counter (`net.inet.tcp.randomize_ports`
is 0; across the 16,384 numbers in 49152-65535 a freed number came back after
16,220 allocations, measured at 0.15 s on an idle machine), so a number a proxy
has just freed is routinely handed to an ordinary short-lived client socket
before the successor binds. That is retried every 2 seconds for 30 seconds. An
accepted connect whose occupant fails the identity check is a foreign listener,
which is bound and will not let go, so the port is given up after two
consecutive sightings rather than at the end of the window. Giving up mints a
fresh port and updates the column.

Thirty seconds is sized against Claude's 183-second retry budget for a refused
base URL, measured from the worst path that reaches a respawn: the hang ladder
already spends four missed polls, two ticks after SIGTERM, and one more tick to
notice the kill — 105 seconds — before the respawn starts, and 105 + 30 leaves
room for the spawn itself and a watch tick.

Sessions spawned against the old port lose the proxy for their
remaining life, because Claude reads `ANTHROPIC_BASE_URL` once at start. That
is the blast radius of a port change. A running proxy holds its port across
every daemon restart, so one way to reach that radius is a window in which TBD
was entirely stopped; the other is the gap a retire opens, in which the freed
number is briefly anyone's — and that gap is what the wait covers, so only a
holder that outlives the window reaches the blast radius.

### Control endpoint

- `GET /tbd/status` returns the proxy's version, pid, process start time, port,
  the TBD home it was started for, and the number of streams in flight. The
  home is what lets a daemon tell its own proxy from another home's on a
  colliding port; every adoption checks it.
- `POST /tbd/retire` closes the listener and **answers as soon as it is
  closed**, then finishes its in-flight streams without a port and exits. The
  retiring proxy releases its rendezvous lock the moment the listener is
  closed, before the answer goes out, so the successor's spawner can take both
  the lock and the port while the drain is still running — a drain may last
  minutes, and a lock held across it would mean no successor and nothing
  listening. The drained process owns no port and answers no route, and its pid
  file is unlinked only if it is still its own. The successor binds the moment
  the answer arrives. No stream is cut, and the no-listener gap is the
  successor's bind time, far inside Claude's 183-second retry budget.
  A retire frees the port; it cannot reserve it. Ephemeral ports come from one
  range every socket on the machine draws from, so an unrelated socket can be
  handed that number inside the gap — and `SO_REUSEADDR`, which is what lets a
  successor bind past the predecessor's own lingering connections, does nothing
  against a socket that does not set it. A successor that loses the race meets
  the address-in-use path above rather than a broken handshake.
- `POST /tbd/routes` and `DELETE /tbd/routes/<token>` tell the proxy a route
  file was written or should be dropped, so it need not watch the directory.

### Signals

`SIGTERM` and `SIGINT` mean to a serving proxy exactly what `POST /tbd/retire`
means: the listener closes, the rendezvous lock is released with it, the
streams already in flight finish under the same drain cap, and the process
exits when the drain ends. A signal is how a process manager, a supervisor, or
a person at a shell stops a proxy, and one that answered by tearing down its
connections would truncate every turn it was carrying — the transcript
corruption this feature exists to avoid, arriving by the most ordinary gesture
there is.

A **second** signal during that drain exits immediately, cutting whatever is
still open. It is the operator saying they meant now, and it is what keeps
"stop this proxy this instant" one signal away rather than a `SIGKILL` away. A
signal that finds nothing in flight exits promptly, because the drain it starts
has nothing to wait for, and one that arrives before the retire disposition is
armed — a window that spans the bind and the pid-file write — ends the process at
once, because there is not yet a retire to run. A signal landing
during a drain a retire has already started joins that drain rather than
beginning a second.

`SIGKILL` is therefore the only way to end a proxy that cuts a stream
mid-message.

### Adoption identity

A status document is a network response, and a local process that wins the
port-bind race can put anything in one. Adoption therefore trusts nothing the
document says about the responder that the daemon cannot confirm from ground
truth of its own, and requires all of the following:

- The pid the document names is the pid written in `proxy.pid` under this
  daemon's own TBD home, and the port recorded beside it is the port being
  probed. The proxy writes that file after its bind, holding `proxy.lock`,
  inside a directory only this user can write. A process of another user
  cannot forge it, and a process of this user already holds every credential
  the proxy would carry, so there is nothing left for an impersonation to gain.
- The process table confirms that pid: it is alive, its start time matches the
  document's within a second, and its executable is `TBDModelProxy`. This is
  the check `AgentReaper` makes before signalling anything, extended by the
  executable gate; a pid recycled by an unrelated process fails it.
- The document names this daemon's TBD home. Redundant with the pid file for
  an honest proxy, and kept because it is what makes the log line for a
  refused adoption say *which* home the answering proxy belongs to.

A responder that is not the pid-file process is refused whatever it claims,
because the two things an impersonator can be truthful about, its own pid and
start time, are exactly the two the pid file does not name.

### Routes

A route is one file, `routes/<token>.json`, written atomically by the daemon
before the spawn it serves. The token is 128 random bits. The file carries the
upstream base URL, the TBD terminal id, and whether streaming is on for that
terminal. The session's base URL is `http://127.0.0.1:<port>/r/<token>`.

The proxy trusts nothing in a request. It resolves the upstream, the terminal
id, and the streaming decision from the route alone; a request whose token
names no route is refused with 404 and forwarded nowhere. The proxy therefore
cannot be used by another local process as an open forwarder, and cannot be
made to write into a terminal's stream file by a spoofed header.

### Forwarding

Everything under `/r/<token>/` is forwarded, not only `/v1/messages`, because
the base URL governs whatever Claude Code chooses to call on it: the
`HEAD /api/hello` warm-up probe, `/v1/messages/count_tokens`, and endpoints a
future release adds. Rules, each of which a test pins:

- Hop-by-hop headers are rewritten. **Every other header passes verbatim**,
  including `anthropic-version`, `anthropic-beta`, and all `x-claude-code-*`
  and `x-stainless-*` headers, treated as open lists rather than allowlists.
  Anthropic has rejected new beta headers behind custom base URLs before, and
  the OAuth capability rides in `anthropic-beta`; stripping it is a 401.
- **`accept-encoding` is the one request header removed**, so upstream sends
  the stream uncompressed and the tee can read it. Response headers pass
  untouched.
- Request bodies, response bodies, and error bodies are streamed unbuffered
  and byte-identical. Claude's retry and capability-disable logic matches on
  upstream error wording, and prompt caching depends on the `system` array
  arriving in order; a proxy that re-serializes either breaks both silently.
- The socket to Claude is `TCP_NODELAY` and every SSE event is flushed as it
  arrives, `ping` events and comment lines included. No idle timeout on either
  leg is shorter than 300 seconds.
- The upstream leg is TLS from the proxy and honors `HTTPS_PROXY` and
  `NO_PROXY` from the daemon's environment, so a user behind a corporate
  proxy keeps working. Loopback is always in the exception list whatever
  `NO_PROXY` says, because a route's upstream is a loopback fake in every test
  the proxy has.
- **Redirects are relayed, never followed.** A `Location` naming another host
  would otherwise carry the client's `Authorization` there, since the HTTP
  client copies a request's headers onto the one it follows with. The 3xx —
  head, headers and body — reaches Claude as it stands, which is both what it
  would have seen talking to the upstream directly and where the decision
  belongs.
- Non-2xx responses and upstream connection failures are relayed unchanged,
  with the upstream's status and body, so Claude sees exactly what it would
  have seen.
- **The upstream leg is Foundation's `URLSession`, which is not a byte pipe.**
  Two of its behaviors are visible from outside and neither takes anything
  away: it may add `Accept`, `Accept-Language` or `User-Agent` to a request
  whose client sent none, and it collapses duplicate response header lines
  into a single comma-joined value. Nothing the client sent is stripped or
  rewritten by either, and comma-joining is the same field value as repeated
  lines for the list-valued headers this path carries (RFC 9110 §5.3). The
  rule the forwarding contract states is "nothing the client sent is lost",
  not "the bytes on the two legs are identical".
- **A stream is counted in flight from the moment its route resolves**, not
  from the upstream head. Time to first byte is a whole model round trip, and
  a request waiting on it has produced nothing to be seen by; counted from the
  head, a retire arriving in that window would drain at zero and exit on a
  turn that had just started. The count is released when the relay ends, on
  every path — a clean end, a cut, a 502, or a client that hung up.

### The tee

A response is teed when its route has streaming on, its content type is
`text/event-stream`, the request path ends in `/v1/messages`, the request
carries no `x-claude-code-agent-id`, and the request body's `tools` array is
non-empty. The first two say it is a stream worth reading; the last two say it
is the parent conversation and not a subagent or the title request. Reading
`tools` is the proxy's only look at a request body, and it is a length check
on a parsed copy, never a rewrite of the bytes forwarded.

The SSE parser works across chunk boundaries and joins multi-line `data:`
fields with newlines. Parsing and writing happen on a task separate from the
forwarding task; the forwarder hands it copies of chunks and never waits.

The stream file is `TBDConstants.streamsDir/<terminal-id>.jsonl`, mode 0600,
one line per event, every line tagged with the API message id:

- `message_start` writes `{"type":"start","message":<id>,"at":<iso8601>}`.
  If no other stream is in flight for the route the file is truncated first;
  otherwise the line is appended, so two concurrent parent requests interleave
  rather than clobber.
- A text block's `content_block_start` writes `{"type":"block","message":<id>,
  "index":<n>}`; each `text_delta` writes `{"type":"text","message":<id>,
  "index":<n>,"text":<delta>}`.
- `message_stop` writes `{"type":"stop","message":<id>}`.
- A stream that ends without `message_stop`, including an SSE `error` event
  from upstream, writes `{"type":"aborted","message":<id>,"reason":<text>}`.

The abort rule is deliberately **"no `message_stop` was seen"** rather than
"an error arrived", because the second cannot see the shape that matters most.
An upstream that truncates a chunked body reaches the HTTP client as a *clean*
completion: the connection closes without the terminating chunk, and nothing
in the response framing says a length was promised. A turn the model never
finished arrives at the tee looking exactly like one it did, and only the
absence of the stop line tells them apart.

Thinking and tool-input deltas are not written. A tee write failure closes
that message's tee, logs once, and leaves forwarding untouched.

### Retention

The file holds at most the messages in flight plus the last one completed.
Truncation at the next `message_start` bounds it by one message's output.
Between messages the last text lingers, which is text the JSONL already holds.
The app does not delete the file: it cannot know whether the proxy is
mid-append on the next message, and an unlink then would send that message's
deltas into an unlinked inode.

Truncation is decided per proxy, and during a handover there are two. A
successor spawned while its predecessor is still draining can open a terminal's
stream file for a new message and truncate it while the predecessor is still
appending to a message of its own. The cost is bounded and local: that one
file's display is damaged until the next `message_start` truncates it cleanly,
and nothing else — no other terminal, no route, no in-flight turn — is
affected. It is accepted rather than locked against, because a cross-process
lock on every stream file would put a contended acquisition in front of every
`message_start` to prevent a cosmetic fault in a window that lasts as long as
one drain.

When the daemon retires a route, the proxy drops it, unlinks the route file,
and unlinks the stream file. When no daemon has adopted the proxy for 24 hours
and no stream is in flight, the proxy retires itself. The window is a policy
rather than a measurement, chosen from two bounds: it must outlast any daemon
absence a person sleeps through, since a proxy that retires during an
overnight outage strands every session spawned against its port, and it must
be finite, since a proxy nobody adopts is exactly the orphan the reconciler
doctrine forbids. A day clears the first bound with margin and costs nothing
against the second, because a proxy with no streams is idle. Any value from a
few hours upward would do; the constant lives in one place and is not tuned.

## The daemon

### Spawn

`WorktreeLifecycle+Create` builds a spawn through `ClaudeSpawnCommandBuilder`
and then diverges by transport for one call
(`Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift`, `holderLaunch`).
On the holder branch, with `modelProxyEnabled` true and a profile kind other
than Bedrock, the daemon asks `ModelProxySupervisor` for a route carrying the
resolved upstream: the profile's base URL, else an env-override base URL, else
the public API. The spawn's process environment gains
`ANTHROPIC_BASE_URL=http://127.0.0.1:<port>/r/<token>` and a `NO_PROXY`
extended with `127.0.0.1,localhost`. `NO_PROXY` travels in `sensitiveEnv`
alone. The route URL travels **both** in `sensitiveEnv` and as an inline export
in the command string, from one field so the two cannot disagree, because the
inline export runs after the shell's rc files: a user whose `.zshrc` sets
`ANTHROPIC_BASE_URL` would otherwise have it clobber whatever the process
environment carried, and the session would talk straight to that endpoint while
its row recorded a stream file that never fills. The profile's base URL has
always been defended that way, and a route that replaces it as the endpoint the
session must reach needs the same defence.

That puts the route token in the job's argv, where any process running as this
user can read it with `ps -ww`. It is not a widening of the trust boundary: the
route files under `~/tbd/proxy/routes/` are mode-0700 in a directory the same
user owns, so every token is already readable by exactly that set of processes.
Losing the rc-file defence would be a real failure; this is not one.

The terminal row records `transcriptStreamPath`, the absolute stream file path,
handed to the app the way `transcriptPath` is. Resume and wake spawns take the
same branch, and so do the extra terminals `terminal.create` opens: an extra
Claude terminal born onto the holder transport is routed exactly as a primary
session is, through the same routing decision and the same row insert.

A spawn with no live proxy proceeds unproxied and logs the omission at error.
A streaming nicety never blocks or delays a session.

A `settings.json` `env.ANTHROPIC_BASE_URL`, including one from the per-repo
overlay, overrides the process environment inside Claude Code and bypasses the
proxy. The daemon detects that in the resolved overlay, logs it, and spawns
without a route rather than fighting the user's setting.

### Supervisor

`ModelProxySupervisor`, a new actor under `Sources/TBDDaemon/ModelProxy/`,
owns the proxy's life on an injected clock:

- **Gate.** `model_proxy_enabled` decides whether a *new* spawn is routed, and
  the supervisor runs for as long as any routed session is still alive. The
  daemon starts it when the flag is on at startup or when the flag is turned
  on.

  Turning the flag off does not retire the proxy where it stands. A session
  spawned while the flag was on carries the proxy's port in its environment for
  the rest of its life, so cutting the listener would not un-route it — it would
  break it mid-task, on its next turn, against a closed loopback port. The
  toggle promises that the flag applies to sessions started after the change,
  and the off direction keeps that promise as literally as the on direction
  does. So the supervisor enters **draining mode**: no new spawn is routed
  (`ModelProxyRouteAttachment` refuses on the column), while the watch keeps
  running and the proxy keeps being adopted and respawned. Each tick reads
  `routeCount` off the `/tbd/status` poll it already makes; when it reaches
  zero — every routed terminal having retired its route as it exited — the
  supervisor retires the proxy and drops it. It does not stop there: a proxy
  this daemon spawned is its child and goes on draining what is in flight for
  some seconds after its listener closes, so the watch keeps ticking with
  nothing to do but wait for that exit, and stops once it has collected it or
  once the ten minutes a drain may take have passed. Turning the flag back on
  while draining simply leaves the mode: nothing was retired, so there is
  nothing to restart — and turning it back on while that last exit is still
  outstanding returns the same watch to normal service.

  At startup with the flag off the supervisor starts in draining mode only when
  a routed terminal is still alive — one query, for a terminal row carrying a
  `transcript_stream_path` that is not exit-stamped. An install that has never
  turned the flag on has none, and runs nothing at all.

  A daemon shutdown is a third gesture and stops the watch alone, leaving the
  proxy alive: outliving the daemon is the point of a separate process, and the
  next daemon adopts it back through the port in the config row.
- **Startup.** Read the persisted port. Probe `/tbd/status`. Adopt on the
  identity check above. Otherwise take the lock and spawn, then persist what
  the proxy reports.
- **Watch.** Poll `status` on a bounded interval — 15 seconds, chosen against
  the cost of a loopback status call nobody but this daemon ever sees, wide
  enough not to be noisy and narrow enough that a dead or wedged proxy is
  noticed and respawned well inside the timeouts a session's own retries
  tolerate. On death, respawn with bounded backoff — 1s, then 5s, then 30s,
  the first retry nearly immediate because every session spawned against the
  dead port is itself retrying it, lengthening so a proxy that keeps dying on
  start is not respawned in a tight loop, and bounded overall (one exhausted
  burst plus the watch interval before the next) well inside Claude's
  183-second retry budget for a refused base URL. Giving up after the last
  backoff step is not permanent — the next watch tick sees no proxy and
  starts a fresh burst. On a version different from the daemon's own binary,
  ask the old proxy to retire and spawn the new one; different rather than
  older, because `tbd update` keeps the previous app bundle as a rollback
  route.
- **Liveness beyond the process table.** A proxy the process table still
  confirms — same pid, same start time — can still be wedged: a deadlock, a
  stuck syscall, a starved thread, none of which exits the process. Missed
  status polls alone are not evidence of that, since an ordinary one is a
  proxy that is merely slow; the watch instead counts *consecutive* misses
  against the one live proxy, reset by any successful poll. Four in a row —
  one minute at the 15-second watch interval — is treated as a hang: this
  daemon sends SIGTERM, which the proxy handles as the same
  close-the-listener-and-drain shutdown `POST /tbd/retire` triggers, and keeps
  polling. Two ticks later, still unanswered, it escalates to SIGKILL. Once
  the process is actually gone the ordinary death path takes over and
  respawns it on the same port — the same path a pid the process table can no
  longer confirm always took. Every signal re-verifies identity — pid and
  start time — against the process table immediately beforehand, so a pid the
  kernel has since recycled to an unrelated process is never signalled — that
  case takes the ordinary death path immediately, on its first miss, with no
  signal in between. The whole ladder — four misses, two more, one
  tick to notice the kill landed, a respawn — finishes with comfortable room
  under Claude's 183-second retry budget for a refused base URL, which is
  what a route whose registration failed during the hang was otherwise
  waiting on with no live proxy ever left to load it.
- **Routes.** Write and register a route before a spawn; retire it when the
  terminal exits, hibernates by exiting, is archived, or is removed. A route
  registration in flight — the file is written but the running proxy has not
  yet been told about it — counts against a drain the same way a route it has
  already been told about does, so a flag flip landing in that window cannot
  retire the proxy out from under a spawn that has just been handed its port.
- **Capabilities.** Answer `daemon.capabilities` with supported, enabled, port,
  and version, so Settings can explain a disabled toggle.

### Flags and migrations

Three columns, one `.sql` migration each, no SQL `DEFAULT` clause:

```sql
ALTER TABLE config ADD COLUMN model_proxy_enabled INTEGER;
ALTER TABLE config ADD COLUMN transcript_streaming_enabled INTEGER;
ALTER TABLE config ADD COLUMN model_proxy_port INTEGER;
```

NULL means nobody chose. The shipped defaults live in
`Config.modelProxyDefault` and `Config.transcriptStreamingDefault`, both
`false`, resolved through `?? Config.<flag>Default` in `ConfigRecord.toModel()`.
The GRDB record, the Codable model, and the migration manifest test in
`SQLMigrationLoaderTests` change in the same commit.

Two RPCs keep the flags coupled:

- `config.setModelProxy(enabled:)` writes the proxy flag; turning it off also
  writes streaming off.
- `config.setTranscriptStreaming(enabled:)` writes streaming; turning it on
  also writes the proxy on.

The resolved streaming value is the conjunction, so a hand-edited row with
streaming on and the proxy off streams nothing. Both flags apply to sessions
started after the change, because the base URL is fixed in a session's
environment at spawn; the Settings help text says so.

Graduation: soak the proxy first, then streaming. Each graduates by flipping
its `Default` constant, which reaches every row that never chose and preserves
every explicit opt-out.

### Settings

Two toggles beside "Run new sessions without tmux" in the Experimental
section: "Route new sessions through the TBD model proxy" and "Stream
assistant text into the transcript". The second is disabled with a caption
when the proxy is unsupported. Turning the second on flips the first in the
same gesture, which the help text states.

## The app

### Reading

`TranscriptSource` gains a second entry kind per session, the stream file,
refreshed by `TranscriptPollScheduler` at the same tier cadence — 100 ms
foreground, 2 s background, 10 s inactive — and under the same reset rule: a
file whose size fell below the consumed offset is re-read from byte zero. The
reader folds the tagged lines into a `ProvisionalMessage`: the message id,
the concatenated text of its text blocks in index order, and whether it is
complete, aborted, or still growing.

When several messages are present, the fold keeps **the most recent message
that has text** — most recent by position in the file, which is the order the
tee controls. A message that has only started and produced nothing holds the
row only when no message has any text at all, so that a pane can show that a
turn has begun. The consequence matters to the retire rules below: a newer
`start` does not by itself take the row away from a finished message, because
until that new message emits its first delta the finished one is still the
best thing to show. A finished message's row therefore leaves on confirmation,
on the first text of a newer message, or on the 60-second rule — never on the
mere appearance of a successor.

The transcript's incremental ingest also records the API `message.id` of every
assistant line it consumes, and separately the ids of the lines that carry a
`text` block. Both are row-local reads, so they do not violate `buildItems`'
purity rule, and they make confirmation a set lookup.

The second set is the one confirmation reads, and the distinction is
load-bearing. Claude Code writes one JSONL line per content block under a
shared `message.id`, and those lines land at different times — a text block's
line was measured arriving 25 seconds after an earlier block's. A message that
opens with a `thinking` block therefore has its id in the JSONL while its text
is still streaming, so retiring on the id would take the row down with nothing
to replace it: the settled text item does not exist yet, and the user watches
live text vanish mid-turn. "Carries text" follows the parser's own rule rather
than the raw block type — an empty `text` block builds no item and so confirms
nothing.

### Publishing

The pane's on-change handler composes JSONL items, then pending
AskUserQuestion captures, then the provisional row last, as
`.assistantText` with a `stream:` id prefix. The row is published only while
the resolved streaming flag is on and its message id is unconfirmed. It is
retired when:

- the JSONL ingests the assistant line that carries that message's text,
  which is the line that brings the settled item replacing the row. A line
  carrying the id alone — a thinking block, a tool call — confirms nothing;
- a newer message with text supersedes it;
- the stream is aborted;
- a completed stream stays unconfirmed for 60 seconds, which backstops any
  side request the tee filter misses and any turn whose JSONL never carries
  text at all — one that only calls tools. The value sits above the worst JSONL
  lag measured on a live session, 25 seconds behind a long tool call, with
  room for a slower machine, and its only cost is cosmetic: a stale row
  lingers for the difference. A shorter window would retire genuine messages
  on a loaded machine; a longer one only delays removing a row nothing
  confirms.
- a stream that has not stopped goes 10 minutes without a new line, measured
  from the last line the reader saw and restarted by each one. A message
  leaves the streaming phase only when a `stop` or `aborted` line is written
  and read, so a proxy killed mid-turn — which writes neither, and whose
  request the JSONL will not confirm either — has no other way off the screen.
  The window is the proxy's own drain cap, the longest a legitimate stream can
  still be in flight — literally that constant (`ModelProxyLimits.drainCap` in
  `TBDShared`, which both the proxy's retire drain and the pane read), not a
  second value that happens to agree with it. Sixty seconds would be wrong here: the tee records text
  deltas, and a healthy turn streaming a large tool-input block emits none for
  minutes.

`TranscriptStreamPlan.updateLast` already renders a last row whose content
version changed, so a growing row costs one tail re-render per tick. A subtle
trailing cursor marks the row provisional.

The provisional row lives in the same per-session transcript store the live
pane publishes into, and **Session History reads that same store** — its
session list is the daemon's enumeration of the worktree's JSONL files, which
includes a session a pane is streaming right now, and selecting a session
deliberately reuses whatever the store already holds rather than refetching.
So History filters the row out at its read site, by the `stream:` prefix on
the item id: only settled rows reach it, and a live session read through
History looks exactly like one read after the fact. The transcript overlay
needs no such filter, because it resolves an item by an id a row hands it and
no gesture can hand it a provisional one — assistant bubbles carry no overlay
affordance, and the row is always an assistant bubble.

### Failure handling

- An unreadable stream file is no news, never a blank row.
- A proxy that dies mid-stream leaves a message the 10-minute silent-stream
  rule retires; one that dies after writing its stop leaves a message the
  60-second unconfirmed rule retires. A turn whose JSONL lines carry the
  message id but never its text is never confirmed, and leaves by that same
  60-second rule.
- A pane whose terminal has no `transcriptStreamPath` registers no stream
  file and behaves exactly as today.
- The provisional state is dropped on confirmation, retire, and deregistration.

### Composer seam

The message composer and the provisional row both live in
`TableTranscriptPaneView`. The row is transcript content above the composer
and shares no state with it. If the composer later wants its sent prompt
echoed until the stream begins, the seam is the same composition step in the
on-change handler; nothing here precludes it.

## Durable resources and their reconcilers

This design introduces three new resources, and names who reclaims each.

- **The proxy process.** `ModelProxySupervisor` adopts or respawns it. It
  self-retires after 24 hours without a daemon and without streams. A stale
  process from a build the daemon no longer matches is retired and replaced by
  the version rule.
- **Route files and stream files.** Retired with their terminal on the
  creation path. The standing guarantee is a new `OrphanGC` leg, under
  `gcEnabled` like the holder legs, keep-biased: a file younger than
  `gcGraceSeconds`, or whose age cannot be read, is kept; a file whose
  terminal row still exists and is not exited is kept; the rest are unlinked.
- **Rendezvous residue** in the proxy directory: `proxy.lock`, `proxy.pid`,
  `proxy.log`. Outside the route and stream leg's reach by construction — that
  collector is pointed at `routes/` and `streams/`, one level below the
  directory these three sit in, so it cannot enumerate them. **An unheld lock
  is the wrong anchor for them**, and that is why: a retiring proxy releases
  its lock the moment it closes its listener and then drains in-flight streams
  for up to ten minutes, so "nobody holds the lock" routinely describes a
  process that is very much alive, and unlinking its pid file or its log would
  take the record away from the thing still writing it. The residue belongs to
  a later leg anchored on **pid liveness** — read `proxy.pid`, confirm the
  process it names through the same identity check adoption uses, and only then
  sweep the triple — which asks a different question from the file leg and
  wants a soak of its own. Until it exists, the three files are bounded rather
  than unbounded: there is one of each per home, and every new proxy overwrites
  them.
- **The port** is one integer in the config row; nothing accumulates.

## Security

- The proxy listens on loopback only. Loopback is reachable by every local
  user, so the proxy holds no credential of its own, forwards only to
  upstreams the daemon wrote into routes, and refuses unknown tokens. A local
  process that guesses nothing can do nothing.
- Bearer tokens transit the proxy's memory on their way upstream. They are
  never logged, never written to a route or stream file, and never retained
  past the request.
- Stream files are 0600 and contain model output the JSONL already holds.

## Testing

Every fixture is real captured bytes or the fake model API
(`scripts/claude-stub.py`, `docs/fake-model-api.md`), which serves the exact
SSE shape and costs zero tokens.

- **Proxy.** Forwarded requests and responses are byte-identical to what the
  stub saw and sent, across chunk splits and multi-line `data:` events. `ping`
  events reach the client without coalescing. `accept-encoding` is removed and
  no other header is. An unknown token is refused and nothing reaches the
  stub. The `HEAD` probe and count-tokens are forwarded. A failing tee leaves
  the client's bytes intact. Adopt, spawn, retire, and respawn on an injected
  clock. Address-in-use against a TBD proxy adopts it; against a transient
  holder, with a session routed, is retried on the clock and keeps the port;
  against a foreign listener mints sooner; with no session routed mints at
  once. Retire answers before the drain finishes. A signal
  retires a proxy carrying a stream rather than cutting it, a second signal
  ends the drain, and a signal with nothing in flight exits promptly.
- **Tee.** A request with `x-claude-code-agent-id`, or with an empty `tools`
  array, writes nothing. Concurrent streams on one route interleave with
  their message ids and truncation waits for both.
- **Daemon.** The spawn env is set only for holder, flag on, non-Bedrock; the
  route URL reaches both the process environment and the inline export, so it
  survives an rc file that sets `ANTHROPIC_BASE_URL`
  (`routedSpawnDefendsItsRouteAgainstRCFiles`), while `NO_PROXY` stays out of
  the command string. Each RPC
  writes its coupled pair. A pre-migration row reads NULL, an explicit `0`
  survives a flipped default, and NULL follows it. The GC leg keeps young and
  live files and unlinks the rest.
- **App.** The provisional row appears, grows, and is replaced by the JSONL
  line that carries the message's text — never by one that carries only its
  id; retires on abort, on a newer message taking the row,
  on the 60 s unconfirmed rule and on the 10-minute silent-stream rule
  (which a new line restarts); sorts after pending questions; and with streaming off
  is never published while the file still updates. Chunk-split equivalence:
  *"a file delivered in arbitrary chunks folds to what the whole file folds
  to"* writes one encoded stream file to disk in seeded-random chunk splits —
  including one inside a `text` line's JSON string and one inside a multi-byte
  character — refreshing after each write, and requires the provisional it ends
  on to equal the whole-file fold taken at the same instant.
- **Live verification, deferred until a restart is permitted on the
  development machine:** the shipped `TBDModelProxy` on a holder terminal
  carries an interactive claude.ai-login turn and the pane shows its text
  before the JSONL line lands. The login-through-loopback and tee-before-JSONL
  halves are already shown by the prototype above; what remains is the
  production binary on the production spawn path.

## Success criteria

- On a proxied holder session, assistant text appears in the pane within the
  foreground poll interval of its generation, rather than at message end.
- A session behind the proxy is byte-for-byte as correct as one without it:
  same responses, same retries, same prompt-cache hits.
- With both flags off, on an install with no routed session alive, no code path
  introduced here runs: the supervisor is not started, no proxy is spawned or
  probed, and no spawn is routed.

## Non-goals

- Tmux-backed sessions.
- Thinking and tool-input streaming, and any change to tool cards.
- Persisting streamed text; the JSONL remains the record.
- Bedrock profiles, the one credential kind whose endpoint is not the
  Anthropic API. Any kind added later that talks to another endpoint is
  excluded the same way: routing keys off the profile's kind, not its URL.
- Any use of the proxy beyond forwarding and the tee: no caching, no
  rewriting, no routing between providers.

## Rejected alternatives

- **Message-level only, with a hook-driven "generating" indicator.** Cheap and
  honest, but it cannot show the text: the lag is the text sitting behind a
  tool call in the same message, and no interface exposes it before the
  message ends.
- **Running Claude headless under stream-json with TBD as the frontend.** The
  only mode with partial messages, and everything structured. It replaces the
  TUI for those sessions, so TBD would have to build permission prompts,
  AskUserQuestion, plan mode, login, MCP auth, interrupts, and the client-side
  slash commands, and it changes what the holder runs and what supervision
  observes. A second product surface, not a transcript improvement.
- **Impersonating the Remote Control bridge.** The TUI streams events to
  Anthropic's bridge when remote control is on. Private protocol, OAuth-bound,
  no compatibility promise.
- **A user-land proxy script** the daemon merely launches. Fits the placement
  rule, but a script in the token path of a whole fleet is a reliability
  trade the human declined.
- **The proxy inside the daemon.** Least code, and a daemon restart is a
  two-second blip inside the retry budget. But a crashed or stopped daemon
  would fail every proxied session's turn after three minutes, reversing the
  holder transport's reason to exist.
- **Naming the upstream in the URL path.** Simpler than routes, and an open
  forwarder: any local process could make the proxy fetch an arbitrary host
  and tee the response into any terminal's file, and the upstream would sit in
  the pane's argv for the process's life.
- **Deleting the stream file on confirmation from the app.** The app cannot
  know whether the proxy is mid-append on the next message.
- **Keying the stream file by Claude session id.** The id changes on `/clear`
  and fork-session and arrives in a client-supplied header; the terminal id
  from the route does neither.

## Prior art

Anthropic's LLM gateway compatibility guide documents the base-URL contract,
the session and agent headers, the 300-second liveness watchdog, and the
byte-identity requirements above. Open-source proxies attach the same way and
group traffic by the session header; one instrumentation proxy forwards first
and parses on a background task, the discipline the tee adopts. Every external
renderer of Claude Code sessions found uses the stream-json control protocol
or tails the JSONL; none tees the interactive TUI's API stream into a
transcript view.
