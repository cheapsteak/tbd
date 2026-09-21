# Remote attach recovery after network changes

Issue: #884.

## Problem

A remote pane runs the provider's `attach <id>` as a child of the app, on an app-owned pty (`Sources/TBDApp/Remote/LocalPTYTerminalView.swift`). The contract makes the child's exit the only viewer-side signal and forbids parsing its bytes. A provider whose attach child keeps running on a dead transport is therefore invisible: the pane looks exactly like an idle session, forever.

Field evidence: an attach child's TCP socket sat in `CLOSED`, bound to the Wi-Fi address, after a VPN installed a new default route seconds after the attach started. About 2.9 KB crossed the pty — a banner and a prompt — and the child never exited. A second pane attached 47 seconds later, after the route change, and worked. The provider was healthy throughout (`list`: `state: running`).

The existing recovery paths start only after the child exits: exponential reconnect backoff (`RemoteReconnectPolicy`) and the Reattach button. The manual Reconnect action, a per-selection restart generation behind `AppState.reconnectRemoteSession`, handles a hang the user notices. This design covers the hangs nobody notices, plus the provider-side obligation that makes them rare.

## Design

Two halves. The provider owns transport liveness, and the contract says so with a bound. The caller re-attaches when the event that most often kills a transport — a network path change or a wake from sleep — has just happened. Neither half infers anything from output.

### Caller: re-attach after a path change or wake

**`RemoteAttachNetworkWatcher`** (app), started once from `AppState`, emits a *network change* event from two sources:

- **Path changes.** An `NWPathMonitor` update is reduced to a fingerprint: status, the ordered interface names, and the gateways. An event fires only when the path is `.satisfied` and the fingerprint differs from the last one seen. The first update after launch seeds the fingerprint and emits nothing. The ordered interface list captures a VPN's `utun*` interface and a primary-route change. Cost and constrained flags are left out, since they flap without affecting transports.
- **Wake.** `NSWorkspace.didWakeNotification` always emits an event. Sleep kills TCP connections without necessarily changing the path, so the path monitor alone misses it.

Events are debounced by 2 seconds on an injected clock, per the repo rule for timers. A burst, such as wake followed by a VPN reconnecting, collapses into one event carrying the latest change time `t`.

**`AppState.handleNetworkChange(at: t)`** does three things:

- **Restart live children.** Every attached remote selection whose attach child started before `t` gets a fresh restart generation, which the pager turns into a kill and a re-exec. Children started after `t` already run on the new path and are skipped, as are children that have not spawned yet. The restart generation records each child's start time for this comparison. The panes are walked least-recently-attached first, because each restart moves its selection to the front of the attach recency log and walking the most-recent-first list forwards would leave that log reversed.
- **Expire backoff.** The deadline of every entry in `pendingReconnectRemoteSessions` that is still waiting moves to `t`, since a network change is exactly what makes an earlier failure stale. The attempt count is kept: escalation is the only bound on a respawn loop, and a flapping network must not reset it. A child the event restarts carries its entry across the restart for the same reason, with the same deadline. The provider-health gate (`RemoteReconnectPolicy.isBlocked`) still applies unchanged: an auth-needed session stays blocked, and a session on an unhealthy provider waits for `.ok`.
- **Re-evaluate now.** It re-evaluates the reconnect policy immediately, rather than on the next `remoteProviders` republish (roughly every 60 seconds).

Each handled event logs one `os.Logger` info line (`com.tbd.app`, category `remote-attach`): the trigger (`path` or `wake`), the old and new fingerprints, and the number of sessions restarted and un-backed-off. An unnecessary restart can then be diagnosed after the fact.

### Contract: a bound on attach liveness

In the `attach` section of `docs/remote-provider-contract.md`:

> A provider's `attach` SHOULD exit 3 within 30 seconds of losing its transport, rather than holding the pane open on a dead channel. Transport liveness is the provider's own signal — keepalives, channel state — never output silence: an idle session legitimately writes nothing.

`attach` is the one long-lived verb that had no liveness rule; `events` (90 seconds) and `messages` (30 seconds) already have one. The bound matches `messages`, the other verb a person is watching in real time.

The contract also states the caller behavior providers must tolerate: a caller MAY kill and re-exec `attach` at any moment, including after a network path change or a wake from sleep. Targeting and idempotence already make that lossless; the sentence makes it explicit.

## Rollout

No flag. This is a bug fix. It restores the promise the contract already makes — that a pane recovers from a dropped channel — for providers that do not supervise their own transport. A restart is lossless, because session state lives on the provider and `attach` is required to be targeted and idempotent. The worst case of an unnecessary restart is a repaint.

## Testing

- **Fingerprint.** Pure function: identical paths compare equal; an added `utun*` interface, a reordered primary interface, or a changed gateway compare unequal; cost and constrained flags are not fields of the fingerprint, so they cannot make two fingerprints differ; an unsatisfied path emits nothing; the seed update emits nothing.
- **Debounce.** Driven by a test clock: a burst of events yields one handled event carrying the latest time.
- **Handler.** Children started before `t` get a new restart generation, and those started after keep theirs. A pending session's deadline moves to `t` while its attempt count survives, including for a session whose pane is restarted. The attach recency order is unchanged by a restart of every pane. An auth-needed session is still blocked after the event.
- Each test must fail with the behavior removed.

## Rejected alternatives

- **Inferring death from output silence.** An idle agent session legitimately emits nothing for hours. Any threshold would either kill healthy panes or be too long to matter.
- **Inspecting the child's sockets (libproc).** Precise for a direct TCP transport, but the attach child is opaque: its transport may be an ssh subprocess, a Unix socket, or something else. Reading a provider's internals couples the caller to one implementation.
- **Restarting on every path-monitor update.** The monitor fires on changes that do not affect transports, so every attached pane would repaint for nothing.
- **Leaving backed-off sessions on their schedule.** A session that failed because the network was down would wait up to 300 seconds after the network came back.
