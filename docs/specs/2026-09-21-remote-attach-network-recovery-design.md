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

- **Restart live children.** Every attached remote selection whose attach child started before `t` gets a fresh restart generation, which the pager turns into a kill and a re-exec. Children started after `t` already run on the new path and are skipped, as are children that have not spawned yet. The restart generation records each child's start time for this comparison, and the pager also reports when it unmounts a pane's tab item, which clears that start: a pane torn down without its child exiting — cap eviction, an explicit detach, the session vanishing, a superseded generation — leaves no live child behind, so a later change never restarts it. Each restart is a plain reconnect, the same one the manual Reconnect performs, so a restarted selection's leftover pending-reconnect entry is dropped: that entry describes a failure of a child that is no longer running, and keeping it would re-arm the provider-health gate, which blocks on any non-`.ok` health regardless of deadline — a provider going `.stale` during the very network change would then unmount the pane the handler had just restarted. The attach recency log is snapshotted before the loop and restored after it, because each reconnect moves its selection to the front of that log: without the restore, restarting every pane would reverse the order, and restarting only some would demote the skipped ones to the tail. A network change says nothing about what the user looked at last, and the order decides which pane the host slot falls back to and which pane cap pressure evicts next. When the restarted pane is displayed the replacement child spawns at once; when it is not — a warm background attach, or any remote pane while a worktree is showing — the old child dies now and the replacement spawns when the pane is next shown, since an attach child spawns from its terminal's first layout and a tab view detaches the content view of an unselected tab.
- **Expire backoff.** The deadline of every entry in `pendingReconnectRemoteSessions` that is still waiting, and whose failure predates `t`, moves to `t` — a network change is exactly what makes an earlier failure stale. A failure that landed after `t`, during the debounce window, keeps its whole cool-off: it already met the path the change installed, and respawning it at once would run it straight back into whatever killed it. An entry records no creation time, but the failure instant is derivable by subtracting the entry's own backoff interval from its deadline. The attempt count is kept either way: escalation is what bounds retries between network changes, and a flapping network must not reset it — across repeated changes the retry cadence is the change cadence itself, bounded by the watcher's debounce. The provider-health gate (`RemoteReconnectPolicy.isBlocked`) still applies unchanged: an auth-needed session stays blocked, and a session on an unhealthy provider waits for `.ok`.
- **Re-evaluate now.** It re-evaluates the reconnect policy immediately, rather than on the next `remoteProviders` republish (roughly every 60 seconds).

Each handled event logs one `os.Logger` info line (`com.tbd.app`, category `remoteAttach`): the trigger (`path` or `wake`), the old and new fingerprints, and the number of sessions restarted and un-backed-off. An unnecessary restart can then be diagnosed after the fact.

### Contract: a bound on attach liveness

In the `attach` section of `docs/remote-provider-contract.md`:

> A provider's `attach` SHOULD exit 3 within 30 seconds of losing its transport, rather than holding the pane open on a dead channel. Transport liveness is the provider's own signal — keepalives, channel state — never output silence: an idle session legitimately writes nothing.

`attach` is the one long-lived verb that had no liveness rule; `events` (90 seconds) and `messages` (30 seconds) already have one. The bound matches `messages`, the other verb a person is watching in real time.

The contract also states the caller behavior providers must tolerate: a caller MAY kill and re-exec `attach` at any moment, including after a network path change or a wake from sleep. Targeting and idempotence already leave the session itself untouched across such a restart; the sentence makes that explicit, and names the cost that is real — the viewer's local scrollback, and whatever the provider chooses to paint on a fresh connect.

## Rollout

No flag. This is a bug fix. It restores the promise the contract already makes — that a pane recovers from a dropped channel — for providers that do not supervise their own transport. Session state lives on the provider and `attach` is required to be targeted and idempotent, so a restart lands on the same session. The session loses nothing; the whole cost of an unnecessary restart falls on the viewer. A displayed pane repaints and loses its local scrollback. A pane that is not displayed drops its connection now and reconnects when it is next shown, because an attach child only spawns once its terminal has been laid out — the same way an automatically re-admitted background pane already comes back.

## Assumptions

Four things the design takes to be true without enforcing. Each names what it costs when it does not hold.

- **A child's start report lands before any change that should restart it** – the pty host reports the spawn synchronously on the main actor the moment the spawn returns, and events reach the handler only after a 2-second debounce, so the report has the wider margin. A selection with no recorded start is read as "not yet spawned" and skipped, which is the safe reading: whatever spawns next spawns on the new path. A child that somehow never reported therefore costs a skipped restart, and the manual Reconnect covers it.
- **`NWPathMonitor` delivers a distinct update when a VPN's `utun` interface joins or the primary route changes** – those are the two path moves the field evidence turns on, and the ordered interface list is the fingerprint field that captures both. A move the monitor folds into the previous update is a move this design never sees.
- **Every wake restarts every mounted pane, and the debounce is the only cooldown** – a network that flaps more slowly than 2 seconds therefore restarts its panes once per flap. A restart costs a repaint, the pane's local scrollback, and, for a pane that is not displayed, a reconnect when it is next shown. A grace period is not the remedy: it would leave the stranded pane this design exists for stranded for the length of the grace. A per-selection cooldown is the refinement to reach for if a metered provider shows a real cost in the field.
- **Spawn times and change times are wall-clock dates** – the comparison that decides whether a child predates a change is one `Date` against another, so a backward clock step across sleep can make a pre-sleep child look newer than the wake and skip it. The manual Reconnect covers that case.

## Testing

- **Fingerprint.** Pure function: identical paths compare equal; an added `utun*` interface, a reordered primary interface, or a changed gateway compare unequal; cost and constrained flags are not fields of the fingerprint, so they cannot make two fingerprints differ; an unsatisfied path emits nothing; the seed update emits nothing.
- **Debounce.** Driven by a test clock: a burst of events yields one handled event carrying the latest time.
- **Handler.** Children started before `t` get a new restart generation, and those started after keep theirs. A pending session that failed before `t` has its deadline moved to `t` while its attempt count survives; one that failed after `t` keeps its whole cool-off. A restarted pane's leftover pending entry is gone, so a provider flipping to `.stale` right afterwards cannot unmount it. The attach recency order is unchanged when only some panes restart. An event that restarts nothing and expires nothing still notifies observers, which is what re-admits a session whose deadline elapsed while the machine slept. An auth-needed session is still blocked after the event.
- Each test must fail with the behavior removed.

## Rejected alternatives

- **Inferring death from output silence.** An idle agent session legitimately emits nothing for hours. Any threshold would either kill healthy panes or be too long to matter.
- **Inspecting the child's sockets (libproc).** Precise for a direct TCP transport, but the attach child is opaque: its transport may be an ssh subprocess, a Unix socket, or something else. Reading a provider's internals couples the caller to one implementation.
- **Restarting on every path-monitor update.** The monitor fires on changes that do not affect transports, so every attached pane would repaint for nothing.
- **Leaving backed-off sessions on their schedule.** A session that failed because the network was down would wait up to 300 seconds after the network came back.
