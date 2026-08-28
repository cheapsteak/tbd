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
tmux -S <socket> has-session -t tbd-ext-<tid8> 2>/dev/null || \
tmux -S <socket> \
    new-session -d -s tbd-ext-<tid8> -c /tmp \; \
    link-window -s @<win> -t tbd-ext-<tid8>: \; \
    kill-window -t tbd-ext-<tid8>:0 \; \
    set-option -t tbd-ext-<tid8> destroy-unattached on
tmux -u -S <socket> attach -t tbd-ext-<tid8> -f ignore-size
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
- **Isolated session plus `link-window`.** The same recipe `TmuxBridge` uses
  for TBD's own panels. The external client is then structurally identical to a
  TBD panel, differing only in the emulator on the other end — which is the
  control the comparison needs. The session holds one window, so there is
  nowhere to wander and nothing else to disturb.
- **`-u` on the attach.** `TmuxBridge.viewerAttachCommand` passes it. UTF-8
  handling changes the byte stream, so an unmatched flag means the two clients
  are not receiving the same thing.
- **`-f ignore-size`.** The external client never pushes its dimensions, so
  attaching cannot reflow TBD's panel mid-measurement and both clients see one
  stream cut for one geometry. Reflow is a confound the design deletes rather
  than models. The client stays writable — this is not `-r`, which would also
  make it read-only.
- **`destroy-unattached on`.** Reclaims the session as soon as the last client
  leaves. See "Reclamation" for why this is not the whole answer.
- **`has-session ||`.** Makes the script idempotent by reusing a surviving
  session rather than erroring on a duplicate name or evicting whoever is
  attached to it.

### Constraints the command must satisfy

- **It must never move `main`'s current-window pointer.** The daemon holds a
  control-mode (`-CC`) connection attached to `main`. A client attached
  straight to `main` shares that pointer, and moving it out from under the
  control-mode connection reopens the class of problem that flow control was
  added to fix. The single-window session satisfies this by construction: there
  is no `select-window` in the command at all.
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
- **The window must be verified before it is named.** The daemon already runs a
  `paneSendTarget` probe, reading `#{pane_id}`, `#{pane_dead}` and the
  `@tbd_terminal_id` pane option, before `terminal.send` types anything. The
  same probe gates this composition: a missing window, a dead pane, or a pane
  answering with a different terminal's id yields an error naming the state,
  not a command aimed at a stranger's session. Refusal requires positive
  disagreement — an unstamped pane composes as before, matching how send and
  wake already behave.

The result carries the socket path, session name, window id, **pane id** and
terminal id, plus the rendered script. A caller can therefore paste the script,
rebuild its own variant, or ignore the attach entirely and drive a different
tmux instrument with the same coordinates.

## Surfaces

**`tbd terminal attach <worktree> [--terminal <id>] [--print]`** is the
load-bearing surface. Without `--print` it execs tmux, replacing itself, so
running it from an external emulator puts you straight into the session. It
refuses when `$TMUX` is set, pointing at `--print`, rather than nesting a tmux
client inside a tmux pane. When `--terminal` is omitted it resolves to the
worktree's only terminal; a worktree with several is an error listing the
candidates, never a guess. With `--print` it writes the script to stdout and
exits — which is what makes the comparison scriptable, and what lets a
non-interactive timestamping consumer be attached in place of a human eyeballing
two windows. Its output is safe to pipe straight into `sh` — no prompts, no
interactive assumptions — and the exec path exits non-zero when the attach
fails, so a harness can tell a failed attach from an empty measurement.

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
  even when the option does not take effect, because `has-session` reuses
  rather than mints.
- **`WorktreeLifecycle+Reconcile`** gains a pass that kills `tbd-ext-*`
  sessions that have had no attached client for at least 60 seconds. This is
  the named reconciler for the PR description. It already reconciles DB rows
  against tmux windows and servers, so this extends an existing sweep rather
  than introducing a new one.

The grace period is a measurement-integrity requirement, not a politeness. A
sweep that reaped any client-less `tbd-ext-*` immediately could take the
session during a momentary detach, or inside the create-to-attach gap named
below. No work would be lost — the window is linked from `main` and survives —
but the measurement would be silently truncated and would still emit
plausible-looking partial data. That is this investigation's signature failure
mode: a run that measured an idle terminal and confidently reported a healthy
result, and sampling windows that missed the action entirely and produced a
wrong committed spec. For the same reason the sweep logs a line naming each
session it reaps, so a truncated run is detectable afterwards rather than
indistinguishable from a quiet one.

The first two are create-time cleanup, which the repo's doctrine treats as
best-effort by standing policy: every unbounded leak found in the wild sat on a
resource no sweep covered, regardless of how good its rollback path was.

**Known risk, to be settled by test.** The session is created detached and only
then attached, while tmux's unattached check runs on a server tick. In
principle `destroy-unattached` could fire in that gap and destroy the session
before the client arrives. A live-tmux test must attempt to provoke this. If it
reproduces, the option moves to after the attach and the reconciler carries the
detach case alone.

## Measurement guidance

The comparison this feature exists for has three conditions:

- **TBD alone** — the baseline, and the normal state with nothing attached.
- **Both clients attached** — the experiment. Machine load on a developer box
  swings wildly within minutes, and a sequential comparison would be confounded
  by exactly the variable that dominates the noise; this investigation has
  already produced one wrong conclusion that way, chasing a coalescing defect
  that A/B/A testing showed was entirely load.
- **External alone** — reachable by switching TBD's tab away from that
  terminal, which kills its viewer client. Read the geometry caveat below
  before comparing it against anything.

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

**Size the external window at least as large as TBD's panel.** In the
both-attached condition the window keeps TBD's dimensions, so a smaller
external window makes the emulator wrap or clip a stream cut for a wider
window. That would make the external client look worse than it is and fake a
result in TBD's favour. This is documented in the CLI's help text and here; it
is not enforced. Enforcing it would mean the daemon reasoning about a window
size it does not own, to protect an experiment the command cannot see.

**Hiding a tab does not pause the session.** The third condition depends on
this and it holds: `TmuxBridge`'s hide path only kills the panel's viewer
session, and auto-hibernate is driven by an idle-time window with a settle
delay, not by panel visibility. One adjacent hazard is worth knowing rather
than assuming: a terminal watched quietly for a long stretch is exactly the
idle-at-rest shape the sweep looks for, so a long measurement on an idle
session can be hibernated out from under the observer where auto-hibernate is
enabled.

## Testing

- **Composition is a pure function.** Given a socket path, window id and
  terminal id, the rendered script is asserted whole — the composed output,
  not a scattering of substrings.
- **Identity refusal.** A window whose pane reports a different
  `@tbd_terminal_id` yields an error naming the state; a missing window and a
  dead pane each yield their own; an unstamped pane still composes.
- **Nesting guard.** With `$TMUX` set, the exec path refuses and names
  `--print`; with it unset, it execs. Both branches, per the repo's rule for
  gating conditionals.
- **Reclamation.** The reconciler pass kills a `tbd-ext-*` session that has
  been client-less past the grace period, leaves one inside the grace period
  alone, leaves one with a client alone, and touches neither `tbd-view-*` nor
  `main`. A reap emits its log line.
- **Coordinate output.** `--json` carries socket path, `@window`, `%pane` and
  terminal id, and the pane id it reports is the one the identity probe
  verified — not a separately resolved value that could disagree with it.
- **The detach race**, live against a real tmux server, per the repo's
  live-tmux discipline: bounded deadlines, rc-free bootstraps, and a fenced
  `TMUX_TMPDIR` so the run cannot leave a socket behind. Keep the fenced
  directory directly under a short `/tmp` root, or the socket path outgrows
  darwin's `sun_path` limit.
- **The geometry behavior** the measurement guidance rests on, in the same
  live test: with both clients attached the window holds TBD's dimensions, and
  when the normal client detaches the window takes the `ignore-size` client's
  dimensions. Pinning it guards the guidance against a future tmux changing
  the rule underneath it.

## No feature flag

Small additive UI and a new CLI verb need none.

The reconciler pass is the arguable part: it is a background sweep that kills
tmux sessions, which touches two of the doctrine's triggers for a default-off
flag. The judgment here is that it needs no flag, because it is scoped to
sessions TBD itself mints under a `tbd-ext-` prefix and that have zero attached
clients — the same shape as the tmux reconciliation `WorktreeLifecycle+Reconcile`
already performs unflagged. The reasoning is written down so a reviewer can
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
