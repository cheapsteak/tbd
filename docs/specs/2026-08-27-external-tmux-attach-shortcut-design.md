# External tmux attach shortcut

Attach to a TBD terminal's tmux window from a different terminal emulator —
iTerm2, Terminal.app, Ghostty — without going through TBD's embedded panel.
TBD hands you the command; your emulator becomes a second client on the same
window.

## The question this answers, and the one it does not

TBD's terminal panels sometimes feel jerky. The instrument built here exists to
answer one specific half of why: **given the same tmux window, does the
jerkiness follow SwiftTerm, or does it follow the byte stream?** Attaching a
second emulator to the window a TBD panel is already showing is the only way to
put our renderer next to somebody else's on identical input.

It does **not** cleanly separate "tmux's fault" from "TBD's fault", and the
feature must not be described that way. Field measurement across a sevenfold
swing in paint rate (1.89–13.83 paints/s) found that the staleness of the
newest byte at the moment it painted held at 19–20 ms in every window, fast and
slow alike — about one display frame — with request-to-paint at a 1 ms median.
The slow windows were the ones where bytes arrived in bursts (3.7–6.3 chunks
coalesced per frame), not the ones where painting was slow. So the open
question is whether bytes leave tmux in bursts, and the sharper instrument for
that is `tmux pipe-pane -o`: it timestamps byte arrival at the tmux level with
no second client and no emulator differences at all. It needs no feature and no
spec. This spec builds the other instrument.

**Honest caveat, to be repeated in the CLI's help text.** tmux tailors its
output to each client's declared terminal capabilities, so two different
emulators attached to one window do not receive identical bytes. The comparison
is informative about order-of-magnitude jerkiness and is not a calibrated
measurement. A future reader must not treat it as one.

## Background: how TBD already uses tmux

- **One server per repo.** `TmuxManager.serverName(forRepoPath:)` hashes the
  repo path with djb2 and yields `tbd-<hex>`. The socket lives at
  `${TMUX_TMPDIR:-/tmp}/tmux-<uid>/tbd-<hex>`.
- **One window per terminal.** The daemon owns a session named `main` holding
  a window for every terminal in that repo, across all of its worktrees.
- **One session per visible panel.** `TmuxBridge` does not use grouped
  sessions, despite what `docs/tmux-integration.md` says. It creates an
  isolated session `tbd-view-<8hex>`, links exactly one window into it with
  `link-window`, kills the throwaway window 0, and attaches with
  `tmux -u -L <server> attach -t <session>`. Panel sizes stay independent
  because each panel holds a *different* window, not because sessions isolate
  size. Note that TBD's own viewer addresses the server by name (`-L`) while
  the command below pins the socket path (`-S`). The two resolve to the same
  socket whenever `TMUX_TMPDIR` matches, which is the ordinary case; the
  asymmetry is deliberate and its reason is given with the command.
- **A window has one size.** `window-size` is `latest` (verified on tmux
  3.6a), so among the clients displaying a window, the most recently active one
  sets its dimensions. No session arrangement changes this; only the per-client
  `ignore-size` flag does.

## The command

```sh
[ "$(tmux -S <socket> list-windows -t tbd-ext-<tid8> -F '#{window_id}' 2>/dev/null)" = '@<win>' ] || {
    tmux -S <socket> kill-session -t tbd-ext-<tid8> 2>/dev/null
    tmux -S <socket> \
        new-session -d -s tbd-ext-<tid8> -c /tmp \; \
        link-window -s @<win> -t tbd-ext-<tid8>: \; \
        kill-window -a -t tbd-ext-<tid8>:@<win> \
        || { tmux -S <socket> kill-session -t tbd-ext-<tid8> 2>/dev/null; false; }
} && tmux -u -S <socket> \
    select-window -t tbd-ext-<tid8>:@<win> \; \
    attach -t tbd-ext-<tid8> -f ignore-size \; \
    set-option -t tbd-ext-<tid8> destroy-unattached on
```

`<tid8>` is the first eight hex digits of the terminal's UUID; `<win>` is its
`tmuxWindowID`. Each part earns its place:

- **`-S <socket>`, never `-L <name>`.** Nothing under `Sources/` sets
  `TMUX_TMPDIR`; the daemon and app inherit whatever they were launched with. A
  shell exporting a different value would resolve `-L tbd-<hex>` to a path that
  does not exist and silently start a **new, empty server** — the user would
  attach to a blank shell and conclude the session was lost. It would also leak
  a socket file permanently: tmux never unlinks a socket when its server exits,
  it only clears a stale one lazily when a new server claims that exact path.
  Pinning the absolute path removes both failures.
- **Isolated session plus `link-window`.** What this shares with the recipe
  `TmuxBridge` uses for TBD's own panels is what the comparison depends on: an
  isolated session, exactly one linked window, selected and verified before any
  client attaches, and no attach at all unless the session holds the requested
  window. The external client is then structurally alike to a TBD panel,
  differing in the emulator on the other end — which is the control the
  comparison needs. The two deliberately differ in two respects. `TmuxBridge`
  classifies each stage's failure separately, because a panel has error UI to
  drive; the script has a shell's exit status. And `TmuxBridge` kills any
  same-named session unconditionally, which a panel can afford and an external
  measurement cannot (see the reuse bullet).
- **`kill-window -a`, not `kill-window …:0`.** The throwaway window a new
  session is born with does not reliably sit at index 0: a user's
  `set -g base-index 1` puts it at 1, and `TmuxManager` never passes `-f`, so
  daemon servers read `~/.tmux.conf`. Killing by index then fails, tmux aborts
  the chain there, and the session is left holding both windows — which forfeits
  the "one window, nowhere to wander" property the comparison rests on, leaks a
  `/tmp` shell, and returns non-zero. `kill-window -a -t <session>:@<win>` kills
  everything *except* the target and is base-index independent.
- **`select-window` before the attach.** A partially-built session then
  self-corrects instead of presenting whatever window happens to be current.
  The constraint against moving a current-window pointer applies to `main`,
  which the daemon's control-mode connection attaches to; inside a private
  session there is no such hazard.
- **Verify, then reuse or rebuild.** The script attaches only to a session
  whose window list is exactly the verified window — an exact comparison, not a
  containment test, since a session holding the target *plus* something else has
  somewhere to wander. Anything else is torn down and rebuilt, and a rebuild
  that fails cleans up after itself rather than leaving a half-built session for
  the next invocation to reuse. Reuse is conditional rather than absent because
  an unconditional kill would evict a client already attached for that terminal,
  truncating a measurement someone is in the middle of.
- **`-u` on the attach.** `TmuxBridge.viewerAttachCommand` passes it. UTF-8
  handling changes the byte stream, so an unmatched flag means the two clients
  are not receiving the same thing.
- **`-f ignore-size`.** The external client never pushes its dimensions, so
  attaching cannot reflow TBD's panel mid-measurement and both clients see one
  stream cut for one geometry. Reflow is a confound the design deletes rather
  than models. The client stays writable — this is not `-r`, which would also
  make it read-only.
- **`destroy-unattached on`, chained onto the attach and never onto the
  setup.** It reclaims the session as soon as the last client leaves. Its
  placement is load-bearing and must not be tidied back into the setup block:
  setting the option while the session is still detached is by itself enough
  for tmux to collect the session on that server tick, before the attach even
  starts, and the attach then fails with `can't find session`. Measured against
  tmux 3.6a, 0 of 20 attempts attached when the option was set beforehand — the
  behavior is deterministic, not a timing race. Isolated with no client
  involved: a created-and-linked session sits there client-less until the
  `set-option` line, which destroys it, while a sibling session without the
  option survives. Chaining it onto the attach attaches cleanly, leaves the
  option set, and still self-destroys the session on detach. See "Reclamation"
  for why the option is not the whole answer.
- **`&&` between setup and attach.** Two bare statements would attach
  regardless of whether the setup worked. With a window that died between the
  daemon's probe and the paste, that put a client on the throwaway `/tmp` shell
  with one line of tmux stderr — immediately scrolled away by the attach's
  redraw — as the only signal.

Verification happens after the session is built and before any client attaches,
which is the placement that matters: composing a correct command does not
establish that the client will land on the right window. Window-id equality is
sufficient as the check because tmux allocates window ids from a monotonic
counter and never reuses one within a server's lifetime (measured: killing `@2`
and creating a window yields `@3`, not `@2`). A window that died and was
recreated therefore carries a new id, the comparison fails, and the rebuild's
`link-window` fails against the vanished window rather than silently attaching
somewhere plausible.

### Constraints the command must satisfy

- **It must never move `main`'s current-window pointer.** The daemon holds a
  control-mode (`-CC`) connection attached to `main`. A client attached
  straight to `main` shares that pointer, and moving it out from under the
  control-mode connection reopens the class of problem that flow control was
  added to fix. The private single-window session satisfies this by
  construction: the one `select-window` in the command targets that session,
  never `main`, and a pointer nothing else observes is not a shared pointer.
- **It must address the window by its stable identifier.** `@<win>`, never a
  window index or pane coordinate. Reused numeric coordinates have already sent
  daemon keystrokes into an unrelated live session; the composer additionally
  verifies identity before emitting anything (below).

## Where the command comes from

A new daemon RPC, `terminal.attachCommand`, composes it. Both surfaces call it,
so there is one source of truth. The daemon has to be the composer for two
reasons:

- **The socket path must come from the environment that created the server.**
  The CLI runs in the user's shell, whose `TMUX_TMPDIR` may differ from the
  daemon's. A CLI-side `tmux -L <server> display-message -p '#{socket_path}'`
  would answer for the wrong path — or start a new server to answer at all. The
  daemon resolves it from its own environment.
- **The pair must agree before either is trusted.** A terminal whose own
  `worktreeID` disagrees with the one in the params is refused rather than
  resolved in favour of either. The pair names a server and a window between
  them, so a mismatch would aim one repo's socket at another repo's window.
  Checked before the probe runs.
- **The window must be verified before it is named.** The daemon runs the same
  pane probe `terminal.send` runs before it types anything, reading
  `#{pane_id}`, `#{pane_dead}`, `#{window_id}` and the `@tbd_terminal_id` pane
  option. Four states refuse, each naming itself rather than composing a
  command aimed at a stranger's session: a missing window, a dead pane, a pane
  answering with a different terminal's id, and a pane living in a different
  window than the row records. Refusal requires positive disagreement — an
  unstamped pane composes as before, matching how send and wake already behave.
  This is a different check from the script's own window-id equality, which
  runs later, on the user's machine, against the session actually built.

The result carries the socket path, session name, window id, **pane id** and
terminal id, plus the rendered script. A caller can therefore paste the script,
rebuild its own variant, or ignore the attach entirely and drive a different
tmux instrument with the same coordinates.

## Surfaces

**`tbd terminal attach <worktree> [--terminal <id>] [--print] [--json]`** is the
load-bearing surface. Without `--print` it execs tmux, replacing itself, so
running it from an external emulator puts you straight into the session. It
refuses when `$TMUX` is set, pointing at `--print`, rather than nesting a tmux
client inside a tmux pane. When `--terminal` is omitted it resolves to the
worktree's only terminal; a worktree with several is an error listing the
candidates, never a guess. With `--print` it writes the script to stdout and
exits — which is what makes the comparison scriptable, and what lets a
non-interactive timestamping consumer be attached in place of a human eyeballing
two windows. It is run from a tty as `sh -c "$(tbd terminal attach <wt>
--print)"`, or equivalently under `eval` — both keep the caller's terminal as
stdin. **Piping the script into `sh` does not work and must not be documented
as though it does**: `tmux attach` requires a tty on stdin, a shell reading its
script from a pipe leaves stdin as that pipe, and the attach dies with `open
terminal failed: not a terminal`. The setup half has already created the
session by then, and `destroy-unattached` rides the attach that just failed, so
a piped attempt also leaves a client-less session for the reconciler. The exec
path exits non-zero when the attach fails, so a harness can tell a failed
attach from an empty measurement.

**`--json` emits the coordinates instead of a script**: socket path, `@window`,
`%pane`, and terminal id. This matters more than it looks. The sharper
instrument for the byte-burst question is `tmux pipe-pane -o`, which needs a
pane id and a socket path and never attaches a client at all — so without a
machine-readable form, the better instrument would be the one thing this CLI
could not drive. The daemon already resolves every one of those values on the
way to composing the script, `paneSendTarget` reads `#{pane_id}` as it goes,
and emitting them makes `tbd terminal attach` the general entry point for
instrumenting a TBD terminal rather than only an attach helper.

`terminal` is a thirteenth verb on an already busy noun, but every verb there
acts on a terminal and so does this one; a new top-level word would sit
confusingly beside the unrelated `tbd pr attach`.

**"Copy Attach Command"** on the terminal tab context menu, beside the existing
Copy Path and Copy Link, is the convenience half. It targets that tab's
terminal, so there is no ambiguity about which session you get. If scope has to
be cut, this is the half that gets cut.

No keyboard shortcut and no worktree-row item. A worktree with several
terminals would need a rule for which one it means, and the tab menu already
expresses the choice unambiguously.

## Reclamation

A `tbd-ext-*` session is a durable external resource, so it gets a named
reconciler. Three mechanisms, in order of who acts first:

- **`destroy-unattached on`** reclaims the ordinary case the instant the last
  client detaches, including a client that dies without detaching cleanly.
- **A terminal-keyed name** bounds the population at one session per terminal
  even when the option does not take effect, because the script reuses or
  rebuilds under that name rather than minting a new one.
- **`WorktreeLifecycle.reclaimExternalAttachSessions()`**, driven by the
  daemon's hourly orphan maintenance inside the `gcEnabled` gate, kills
  `tbd-ext-*` sessions that have been client-less past a 60-second grace. This
  is the named reconciler for the PR description.

It is deliberately not folded into the `reapOrphanTmuxResources` flag, which
gates the destructive window and server pass, and it takes the per-server
resource lock of its own accord because its reconcile-path sibling runs under a
lock the coordinator does not re-enter.

**The grace clock lives on the tmux session, not in daemon memory.** A
client-less session is stamped with a `@tbd_ext_clientless_since` session user
option, read back in the same `list-sessions` format string that counts its
clients. Daemon-side state was the obvious alternative and is wrong three ways
at once: it is empty at every daemon start, so a restart resets every clock; it
never learns that a session vanished by some other route, so its entries leak;
and because session names are deterministic per terminal, a leaked expired
stamp reaps the *next* session of the same name on its first observation, with
no grace at all. State stored on the session dies with the session, survives a
daemon restart, and cannot outlive what it describes.

**A never-attached session needs no stamp.** The create-to-attach orphan — the
one that actually leaks — has been client-less since `#{session_created}`, which
tmux already records, so a single observation decides and no second sweep is
needed.

**`#{session_last_attached}` is not the clock**, though it is tempting as one.
It records the last attach and does not move on detach: measured on tmux 3.6a, a
session attached at t=591 whose client was killed at t=606 still reported its
original attach time two seconds after the detach. Reaping off it would destroy
a just-detached session with zero grace — worse than the gap it was meant to
close. It is used only for the question it answers reliably: whether a client
attached since the stamp was written, which retires a spent stamp when an
attach and detach both happened between two sweeps.

**The kill is conditional inside tmux, not in the daemon.** Listing sessions and
then killing one as a separate subprocess is a decide-from-a-snapshot,
act-without-re-verifying shape, and `kill-session` does not spare an attached
session — so a user attaching between the two calls would be disconnected
mid-measurement. The reap is issued as one queued unit,
`if-shell -F -t <session> '#{==:#{session_attached},0}' 'kill-session …'
'display-message -p …'`, with a sentinel on the else branch because `if-shell`
exits 0 either way and the daemon must not log a kill that did not happen.

Worst case, a never-attached orphan is reclaimed in about an hour, and one that
was attached and then outlived its `destroy-unattached` in about two — one sweep
to stamp, a later one to act. Hourly is defensible for a backstop when the fast
path reclaims instantly and the population is bounded by construction. The sweep
logs a line naming each session it reaps, so a truncated run is detectable
afterwards rather than indistinguishable from a quiet one — this investigation's
signature failure is a run that emits plausible-looking partial data, and a
session reaped mid-measurement would do exactly that.

The create-to-attach gap is why `destroy-unattached` is chained onto the attach
rather than set during setup — see "The command". A live-tmux test pins both
halves: that the composed script attaches, and that setting the option on a
still-detached session destroys it. The second test documents the mechanism, so
an edit that moves the option back into the setup block fails rather than
silently disabling the feature.

## Measurement guidance

The comparison this feature exists for has three conditions:

- **TBD alone** — the baseline, and the normal state with nothing attached.
- **Both clients attached** — the experiment. Machine load on a developer box
  swings wildly within minutes, and a sequential comparison would be confounded
  by exactly the variable that dominates the noise; this investigation has
  already produced one wrong conclusion that way, chasing a coalescing defect
  that A/B/A testing showed was entirely load.
- **External alone** — reachable by switching TBD's tab away from that
  terminal, which kills its viewer client.

Each condition bounds a different thing, and B is only interpretable with both
of the others. A/B/A bracketing bounds what the external client costs TBD.
Condition C bounds what TBD's client costs the external one — and there is no
other test for it. The back-pressure mechanism below runs in both directions:
if SwiftTerm's client drains its socket slowly, it delays the single-threaded
tmux server's writes to every client on that window, including the external
one. So an external client that is smooth alone and jerky alongside TBD, at the
same geometry, is a finding in its own right, and a more actionable one than
anything else this instrument can produce.

**A second client is not a neutral observer, so runs must be A/B/A bracketed.**
tmux writes to its attached clients from a single-threaded server, so an
external client that is slow to drain its socket can back-pressure the server
and delay writes to TBD's client. The perturbation is not guaranteed
symmetric, and the failure mode is the worst available one here: attaching the
instrument could manufacture the very jerkiness in TBD that the instrument
exists to detect, and the result would read as "SwiftTerm is the problem".
Simultaneous attachment remains right for the load-confound reason above, but
it is not sufficient alone. Every run therefore brackets — TBD alone, both
attached, TBD alone again — and the two bracketing measurements must agree
before the middle one is interpreted at all. If they disagree, the second
client perturbed the system and that run is void.

**`ignore-size` protects the geometry only while TBD's client is attached.**
Measured on tmux 3.6a: with a normal 100x30 client and an `ignore-size` 180x45
client both attached, the window holds at 100x29 — the flag works. Detach the
normal client and the window immediately becomes 180x44. tmux honors
`ignore-size` while another client is contributing a size and falls back to the
ignoring client's dimensions when it is the only one left. Two consequences:
attaching never disturbs a measurement in progress, which is what the flag was
chosen for; but "external alone" runs at a different geometry than "both
attached", so its stream is cut for a different width and the two conditions
are not directly comparable. Treat the third condition as a separate
observation, not as the same experiment with one client removed.

**Match the external window to TBD's panel dimensions exactly** whenever
condition C is in play. The measurement above gives the reason directly: the
window follows the `ignore-size` client's dimensions once it is the only one
left, so an external client sized exactly like TBD's panel resizes the window
to the size it already had, and B and C share a geometry. Both readings showed
window rows at client rows minus one, consistently, so equal client sizes yield
equal window sizes in both states. Larger is acceptable when running only A and
B. **Smaller is never acceptable**: in the both-attached condition the window
keeps TBD's dimensions, so a narrower external window makes the emulator wrap
or clip a stream cut for a wider window, which would make the external client
look worse than it is and fake a result in TBD's favour. Exact sizing satisfies
that anti-clipping goal too, so it is strictly better guidance rather than a
trade — it is merely fiddly to hit by hand, which the CLI's help text should
say out loud.

None of this is enforced. Enforcing it would mean the daemon reasoning about a
window size it does not own, to protect an experiment the command cannot see.

**Hiding a tab does not pause the session.** The third condition depends on
this and it holds: `TmuxBridge`'s hide path only kills the panel's viewer
session, and auto-hibernate is driven by an idle-time window with a settle
delay, not by panel visibility. One adjacent hazard is worth knowing rather
than assuming: a terminal watched quietly for a long stretch is exactly the
idle-at-rest shape the sweep looks for, so a long measurement on an idle
session can be hibernated out from under the observer where auto-hibernate is
enabled. It has been default-off since it was force-disabled in `v50`, so this
is a hazard for someone who deliberately turned it on — which is a fair
description of someone running a long measurement.

## Testing

- **Composition is a pure function.** Given a socket path, window id and
  terminal id, the rendered script is asserted whole — the composed output,
  not a scattering of substrings.
- **Identity refusal.** A window whose pane reports a different
  `@tbd_terminal_id` yields an error naming the state; a missing window, a dead
  pane, and a pane living in a different window than the row records each yield
  their own; an unstamped pane still composes.
- **Nesting guard.** With `$TMUX` set, the exec path refuses and names
  `--print`; with it unset, it execs. Both branches, per the repo's rule for
  gating conditionals.
- **Reclamation.** The reconciler pass kills a `tbd-ext-*` session that has
  been client-less past the grace period, leaves one inside the grace period
  alone, leaves one with a client alone, and touches neither `tbd-view-*` nor
  `main`. A reap emits its log line. A session recreated under the same
  terminal-keyed name is not reaped on its first observation. The hourly
  orphan-maintenance cadence actually reaches the pass — a test that calls
  reconcile by hand proves wiring, not cadence, and wiring without cadence is
  how this shipped unreclaimable the first time.
- **Coordinate output.** `--json` carries socket path, `@window`, `%pane` and
  terminal id, and the pane id it reports is the one the identity probe
  verified — not a separately resolved value that could disagree with it.
- **The composed script actually attaches**, and **the create-to-attach gap**:
  setting `destroy-unattached` on a still-detached session destroys it, which
  is why the option rides the attach. The second is asserted directly, with no
  client involved, so the mechanism is pinned rather than inferred from an
  attach failure. Both live against a real tmux server, per the repo's
  live-tmux discipline: bounded deadlines, rc-free bootstraps, and a fenced
  `TMUX_TMPDIR` so the run cannot leave a socket behind. Keep the fenced
  directory directly under a short `/tmp` root, or the socket path outgrows
  darwin's `sun_path` limit.
- **The failure modes that produce a wrong attach**, live: a user's
  `base-index 1`, a window that vanished between composition and paste, and a
  surviving session holding the wrong window. Each must refuse rather than put
  a client somewhere plausible, and the reuse control confirms a session
  holding the *right* window is not rebuilt — which would evict a client
  mid-measurement. A companion test pins the tmux rule three of these guards
  rest on: a `\;` chain stops at its first failing command.
- **The geometry behavior** the measurement guidance rests on, in the same
  live test: with both clients attached the window holds TBD's dimensions, and
  when the normal client detaches the window takes the `ignore-size` client's
  dimensions. Pinning it guards the guidance against a future tmux changing
  the rule underneath it.

## No feature flag

Small additive UI and a new CLI verb need none.

The reconciler pass is the arguable part: it is a background sweep that kills
tmux sessions, which touches two of the doctrine's triggers for a default-off
flag. The judgment here is that it needs no flag, because it is scoped to sessions
TBD itself mints — names matching `tbd-ext-` plus eight hex digits exactly, not
merely carrying the prefix — that have zero attached clients. Its precedent is
`OrphanGC.sweep()`, which reclaims on an hourly cadence behind `gcEnabled` and
carries no flag of its own; this pass runs on that same cadence and behind that
same gate. The destructive window-and-server pass in
`WorktreeLifecycle+Reconcile` is deliberately kept off the hourly timer, so it
is the weaker analogy despite being the nearer neighbour in the source. The reasoning is written down so a reviewer can
disagree with it explicitly rather than having to infer that the question was
considered.

## Deferred

**An explicit "detach TBD's client" affordance.** The third measurement
condition is reachable today only as a side effect of switching tabs, because
`TmuxBridge` kills a panel's viewer session when the panel is hidden — there is
no "tab open, nothing attached" state. A deliberate control would need that
state to render, persist, and recover, and to interact sanely with hibernation
and suspend. The two conditions the comparison actually rests on both work
without it, so it is recorded here rather than built. Note that building it
would not by itself make the third condition comparable to the second: the
window resizes when TBD's client leaves regardless of how it leaves, so the
geometry difference is a property of tmux's sizing rule and not of the missing
affordance.

**Surfacing the attach command in `tbd terminal list`.** A column or a
`--attach-command` flag would save a second call when scripting across many
terminals. Not needed for one-at-a-time comparison.

## Rejected alternatives

**Attaching straight to `main`.** No new session, no new resource, no
reclamation question — and the smallest diff. Rejected because the client would
share `main`'s current-window pointer with the daemon's control-mode
connection, so an external convenience could move a pointer an internal
mechanism depends on. `ignore-size` protects geometry; no flag gives a private
pointer inside a shared session.

**A session grouped to `main` (`new-session -t main`).** Shares the repo's
whole window list with an independent pointer, so tmux's own next/prev-window
walks every terminal in the repo. Rejected as an instrument: it is not the
recipe a TBD panel uses, which weakens it as a control, and it lets an external
client wander into a sibling worktree's agent and type there with no UI saying
where it is.

**A grouped session that persists after detach**, reclaimed only by the sweep.
Re-attaching would restore the current window and copy-mode position. Rejected
because that continuity is worth less than not creating an orphan, and it would
put a background killer in charge of a session a person may have deliberately
left sitting.

**A read-only attach (`-r`, i.e. `read-only,ignore-size`).** Zero impact on
TBD, but it cannot drive a session. Attaching a keyboard is part of the point,
and `ignore-size` alone already provides the non-disturbance that `-r` was
attractive for.

**Enforcing a minimum external window size.** See "Measurement guidance".
