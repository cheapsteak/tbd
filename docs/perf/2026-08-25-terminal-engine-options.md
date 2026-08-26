# Terminal engine options: what was found — 2026-08-25

An evidence record for the question "should TBD keep SwiftTerm?", gathered
2026-08-25 from public sources: the engines' own repositories and headers, the
committed design documents of projects that have embedded them, and those
projects' issue trackers. Measured performance evidence lives separately in
`2026-08-25-terminal-render-cost-investigation.md`; this document is about
engine and architecture choices, and it deliberately does not decide anything.

Claims below are marked where confidence is less than direct observation.

## The constraint that shapes every option: tmux

Any option that removes tmux is unavailable, because tmux carries far more than
session persistence. Across the daemon and app, TBD drives `send-keys`,
`capture-pane`, `list-panes`, `list-windows`, `list-sessions`, `list-clients`,
`new-session`, `new-window`, `kill-window`, `kill-session`, `kill-server`,
`has-session`, `set-option`, `select-window`, and `display-message`. Those calls
back worktree reconciliation, cross-session agent messaging, the pane readers,
and pane identity for the peer registry — a session is recovered by joining on
its tmux pane when its name has drifted.

Restart survival is one consumer among many. This matters because the most
directly comparable migration resolved its difficulties by deleting tmux, an
option TBD does not have.

## TBD's current configuration, which is not what it looks like

`TBDTerminalView` subclasses SwiftTerm's **base** `TerminalView`, and TBD drives
it by owning a `LocalProcess` and hand-feeding bytes through `feed(byteArray:)`.
The command that pty runs is already `tmux attach -t <grouped-session>`.

SwiftTerm ships `LocalProcessTerminalView` — a `TerminalView` subclass that owns
the process and wires the delegate plumbing itself — and TBD contains no
reference to it.

So TBD is bytes-fed by construction rather than by necessity: the process is
local and already spawned, and only the app's manual copy of bytes from its own
pty into the view puts it in the mode below.

This matters because it is exactly the configuration another project identified
as SwiftTerm's weak spot (see "The reversal"). It does **not** follow that
switching classes would improve rendering performance: `LocalProcessTerminalView`
inherits the same draw path, so the measured costs — per-row attributed-string
rebuild, an 8-character shaped-line cache, full-viewport invalidation while
scrolled back — are identical either way. The question it bears on is
correctness, supported-configuration status, and maintenance, not throughput.
Why TBD hand-rolls the feed is not established; the plausible reasons are that
it needs the byte stream for interrupt detection, activity tracking, and the
control-mode routing switch, none of which the owning class may expose.

## Two different APIs, frequently conflated

Ghostty exposes two embedding surfaces, and confusing them inverts the
conclusion.

- **`ghostty.h`** — the full terminal, renderer included. Formally disclaimed for
  external use on 2026-08-10; the commit that landed that wording removed an
  earlier "(yet)". It exports 91 functions and **none of them writes bytes into a
  surface**: input is key, mouse, and IME only, and surface config carries a
  command and environment. A bytes-fed surface is not expressible through it
  without patching.
- **`libghostty-vt`** — the API the disclaimer redirects external embedders
  toward. It is **not** a bare parser: `ghostty_terminal_vt_write(t, bytes, len)`
  is a documented first-class entry point, `ghostty_terminal_new` takes no
  command and no pty, and it ships `render.h` (dirty-row incremental render state
  intended for custom renderers), `snapshot.h`, `selection.h`, key and mouse
  encoders, and `formatter.h`.

Ghostty officially publishes a prebuilt, signed, Swift-importable
`ghostty-vt.xcframework`, rebuilt nightly — universal macOS and iOS slices, a
proper module map, first-party. No Zig toolchain and no fork are required to
consume it. Its own example tree contains no `forkpty`, and its README names
replay tooling and log viewers as the intended use.

Upstream has **permanently declined** to ship a renderer alongside it
(2026-05-12), so a `libghostty-vt` embedder writes its own. Swift is also the
one major language without a mature binding; the reference binding the project
wrote is in Go.

## Three paths

**A — `ghostty.h` with host-managed IO.** The full engine, renderer included,
fed bytes. Requires somebody's fork: five teams have independently built the same
patch under different names, and upstream has never carried it. Well-trodden in
the sense that a 26.5k-star project drives `tmux -CC` control mode into mirrored
surfaces in production — which is close to TBD's shape. Cost: a disclaimed API,
consumed through a third party's fork, running behind upstream `main`.

**B — `libghostty-vt` with a renderer TBD writes.** Supported API, first-party
signed artifact, no fork, no Zig. At least one project demonstrates the shape
forking nothing, feeding bytes from a socket into the VT and rendering with its
own GPU code. Cost: TBD writes both the renderer and the Swift bindings.

**C — Let the terminal own the pty.** Set the surface's command to
`tmux attach-session` and stop feeding bytes at all. Four projects independently
converged here. TBD is unusually close to this already, since its pty command is
already a tmux attach — the difference is who owns the process.

## Why other products feed bytes, and why their reasons may not transfer

The two documented reasons both come from one product, stated in its own commits
and design docs.

**Fan-out and replay.** The engine's process-owning backend admits exactly one
consumer and offers no tap on the byte stream. That product needed two consumers
— a local surface and a companion device — plus a one-megabyte replay ring so a
late attacher could catch up. Owning the pty itself was how it got a stream it
could fan out.

**A daemon owning session lifetime.** Its later architecture makes a session a
first-class object living in a daemon, with every UI "a stateless client that
attaches and detaches" — pty, grid, and scrollback owned by the daemon, and
rendering, selection, and theme owned by the client. It completed that migration
on 2026-08-22 by deleting its host-managed pty implementation entirely. Its
trajectory is away from process ownership, not toward it.

Neither reason clearly binds TBD, and the difference is tmux.

The second does not apply at all: viewer-independent session lifetime is exactly
what that daemon was built to obtain, and tmux already provides it. The first may
not either — that product had no multiplexer beneath it, so the app was the only
place a tap could exist. TBD has one. Control-mode `%output` and `capture-pane`
both reach the daemon independently of whether the app ever sees a byte, so TBD's
in-app tap may be redundant with tmux's in a way that product's was not.

That is the question worth answering before choosing a path: **does anything
other than the visible terminal actually require the app to see the byte
stream?** If the answer is no, the option of letting the terminal own an attach
command is open on evidence rather than on optimism.

## The reversal, and why TBD cannot simply copy it

One project built the design TBD would be proposing, and abandoned it within a
day of shipping v0.1. Its spec first quotes the same complaint about SwiftTerm's
`feed()` path that motivated this investigation, then concludes: the engine "is
used as a renderer — just a display fed external bytes — when it should be used
as a terminal (owning the PTY)." Their remedy was to delete tmux.

TBD cannot make that trade, per the constraint above. The reversal is still the
most important evidence here, but its conclusion transfers only partially: it
argues against bytes-fed as an *architecture*, while TBD's bytes-fed-ness is a
local implementation choice sitting on top of a pty it already owns.

The problem list that reversal diagnoses is narrower than it first appears, and
the distinction matters. Its six complaints are grid mismatches between two
layout engines, pty output re-encoded to octal and decoded again, keystrokes
re-encoded through a send-keys path, state reconciliation races, a documented
incompatibility between fullscreen agent TUIs and tmux control mode, and roughly
two thousand lines of adapter code spanning a control-mode client, a command
runner, a state parser, a sync engine, an output router, and resize negotiation.

Every one of those is a property of **control mode**, not of tmux. TBD's
control-mode subsystem matches that inventory closely, but it is disabled, and
the default path carries none of those costs: no octal re-encoding, no send-keys
input path, no state reconciliation. So the reversal indicts the path TBD is not
currently using far more than the path it is.

The fullscreen-incompatibility claim in that list holds, and it is a
product-level constraint on the control-mode design that stands regardless of
which engine renders.

The hosted agent's own documentation states that its fullscreen renderer is
incompatible with a terminal's tmux integration mode — the mode entered with
`tmux -CC` — because that host renders each tmux pane itself rather than letting
tmux draw to the terminal. The documented symptoms are that the alternate screen
buffer and mouse tracking do not work correctly: the mouse wheel does nothing,
and a double-click can corrupt terminal state. Regular tmux, without control
mode, is documented as fine.

Three qualifications matter for TBD.

The incompatibility is scoped to that agent's **fullscreen** renderer, which
draws on the alternate screen. Its classic renderer keeps output in native
scrollback and is not documented as broken under control mode. So this
constrains a rendering mode, not the agent as such.

The mechanism is documented for one specific terminal's integration mode, not for
control mode as a wire protocol — neither tmux's own documentation nor that
terminal's states a general rule that alternate-screen applications break under
control mode. But the mechanism described, a host application rendering panes
from control-mode output rather than tmux drawing them, is structurally what
TBD's control mode does. The risk transfers by construction even though the
citation does not.

The agent ships a mitigation TBD may not inherit: it detects that integration
mode and declines to start its fullscreen renderer there. That detection
presumably keys on the specific terminal, and an agent process running inside a
tmux pane has no obvious way to know that its outer client is some other
control-mode consumer. TBD could therefore meet the failure without the automatic
fallback that protects users elsewhere.

What would settle it: run a known alternate-screen application under TBD's own
control-mode pipeline and observe whether mouse reporting and the alternate
screen behave, rather than reasoning from a citation scoped to a different host.

## Confirmed hazards from projects that migrated

Reported by embedders, in their own trackers:

- **Silent data loss.** Several hundred bytes of prompt data dropped, producing
  blank panes.
- **Destructive occlusion.** Marking a surface occluded leaves it permanently
  unfocusable; at least one project ripped the call out. TBD retains up to eight
  terminals in a keep-alive pager and would meet this immediately.
- **Scale.** Thirty tabs and twenty-nine surfaces reported at 564-806% CPU,
  5.2 GB resident, ending in an allocator out-of-memory. This is the single most
  TBD-relevant report found, given TBD routinely runs far more terminals than
  that.
- **Lifecycle ordering.** Feeding a surface before it has been ticked once
  deadlocks the main thread.
- **Concurrency in the bytes-fed path specifically.** A three-thread deadlock
  between a session lock and a blocking write produced an app-wide freeze
  requiring a kill signal. Independently reported and fixed within a day.

A shipping product using this stack recorded "four production-grade bugs in a few
weeks, and every one of them lives in the dependency."

**Governance.** Embedding issues filed upstream have been auto-closed within
seconds by a vouch bot without human review. An embedder should assume it carries
its own fixes.

## The incumbent

SwiftTerm is actively maintained — roughly 395 commits over 52 weeks, 87% of the
last 30 pull requests merged with a median around 1.3 days, and another
commercial team upstreaming fixes concurrently. It ships a Metal renderer that
TBD has never enabled, and several outstanding pull requests profile a
multi-pane agent-TUI workload closely resembling TBD's. Its weaknesses are
specific and patchable rather than structural, on current evidence.

## A dual-backend seam is possible

One project maintains a genuine runtime-switchable dual backend in roughly 240
lines with a single leaky call site. Another attempted a split backend and let it
go stale, with the displaced engine becoming dead code. The first is the better
model: it makes an engine choice reversible and measurable rather than a
one-way door, and it matches how TBD already gates risky replacements.

## What would settle this

Ordered cheapest first. Each step's result determines whether the next is worth
taking.

1. **Enable SwiftTerm's Metal renderer and measure** — an afternoon, specced in
   `docs/specs/2026-08-25-terminal-metal-renderer-design.md`. It discriminates
   directly between "the CPU renderer is the problem" and "the engine is the
   problem". A comparable product's answer to the same performance problem
   appears to be simply that its engine renders on the GPU by default, which this
   tests without migrating anything.
2. **Apply the shaped-line cache** if Metal alone is flat — also aimed at the
   measured hot path, with a reported 91% draw-time reduction on a similar
   workload.
3. **Spike path B for a week** if both are flat — against the official signed
   artifact, wiring the tmux bridge's output into `ghostty_terminal_vt_write`
   with a crude renderer over the dirty-row render state. Only at this point has
   the architectural reading earned a migration's cost.

## Open questions

- **Whether the alternative was ever weighed by the products that chose bytes-fed.**
  Their reasons *for* the choice are documented (see "Why other products feed
  bytes"); no document weighs handing the terminal an attach command and rejects
  it. So the record shows why they chose what they chose, not why they declined
  the alternative — a distinction worth preserving rather than reading past.
- **Why TBD hand-feeds** rather than using the engine's process-owning class, and
  whether the hooks it needs survive the switch.
- **Whether a VT implementation swap changes replay semantics.** TBD's
  `ReplayWriter` records deliberate deviations verified against SwiftTerm as its
  only consumer. Those would have to be re-derived against any other VT. The
  `formatter.h` surface would allow diffing two implementations on identical
  replay bytes, which is a correctness check TBD cannot currently perform at all
  — worth doing even if no migration happens.
- **Whether an announced pure-Swift renderer with vt bindings ships.** Announced
  2026-07-02, not released as of this record. It would remove the renderer-writing
  cost from path B entirely.
