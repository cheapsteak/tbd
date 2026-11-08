# Terminal engine: SwiftTerm or libghostty

*Evidence record gathered 2026-11-06, the day `libghostty-vt` 1.0.0 was tagged,
against TBD at `43a009132`, with a proof of concept run on 2026-11-07 against
TBD at `5891dd294`. A/B runs of TBD's opt-in libghostty engine were taken on
2026-11-08 against TBD at `ac44edb9d`, a release build. Sources are the
library's announcement, its documentation and headers at the `vt-1.0.0` tag,
Ghostty's release notes, its maintainer's public statements, the repositories
and write-ups of projects that embed libghostty, TBD's own tree, the proof of
concept on the branch
[`spike/libghostty-vt-poc`](https://github.com/cheapsteak/tbd/tree/spike/libghostty-vt-poc/spikes/libghostty-vt),
and the A/B runs. Statements carrying a date are evidence about that date. The
record makes a recommendation; it changes no behavior.
Companion record:
[`docs/perf/2026-08-25-terminal-engine-options.md`](../perf/2026-08-25-terminal-engine-options.md),
which surveys the same options as of 2026-08-25 in more depth, including prior
art and migration paths this record only summarizes.*

## Answer

TBD's default terminal engine is SwiftTerm, and it stays the default.

TBD also has an opt-in libghostty engine for holder and LocalPTY terminals
([design](../specs/2026-11-07-libghostty-terminal-engine-design.md)). The flag
`useGhosttyTerminalEngine` turns it on, and the flag is off by default. Its
toggle is in Settings ▸ Terminal ▸ Experimental. Terminals that run through
tmux stay on SwiftTerm, and so does the daemon.

The first A/B of the two engines found no clear win, and libghostty had a
longer draw wait ("A/B of the opt-in engine"). Under heavy output, libghostty
used about half the app CPU in Claude Code's full-screen mode, with latency
within 1 ms ("A/B under heavy output"). App CPU during a workload is not one of
the spec's measures. So the spec's graduation rule is not met, and the engine
stays opt-in.

The proof of concept measured what libghostty costs and what it gains ("Proof
of concept"):

- **Cost** – about 9,400 lines of renderer and view code for TBD to own, plus an
  estimated 1,000 to 2,000 lines to close the gaps it found. Both come before
  any work on TBD's transport and handover. The opt-in engine carries this
  cost: its target held about 11,900 lines of Swift at `ac44edb9d`.
- **Gain** – parsing 1.1 to 6.3 times as fast as TBD's SwiftTerm fork, and about
  4 times as fast on real Claude Code output. Half the memory for idle
  terminals, which is about 12 MB per 100 terminals. A full scrollback 15%
  smaller, or under 2 MB after a compress that the host calls.

Neither gain answers a problem TBD has. The terminal lag that first raised the
question was traced to causes outside the engine ("Why TBD has stayed on
SwiftTerm").

The library itself is ready: `libghostty-vt` 1.0.0 was tagged on 2026-11-06
with a declared ABI promise. Reopen the question of the default when one of
these becomes true:

1. **The Ghostty project publishes a Swift renderer package for
   `libghostty-vt`.** That would remove most of the code TBD owns for the
   engine. No package was found on 2026-11-06, and the 1.0 announcement does
   not mention one.
2. **A measured TBD problem lives in the engine.** Examples are parse time in a
   profile of real use, memory held by many long scrollbacks, or defects in
   TBD's SwiftTerm fork that cost more to fix than a move would.

Either way, the default changes only under the spec's graduation rule: a clear
win in two A/B/B/A runs, a soak with no libghostty crash, and no open daily-use
gap ("Before a move").

## Two embedding surfaces

Ghostty exposes two C APIs. Whether a claim about "libghostty" holds depends on
which one it is about.

- **`ghostty.h`** – the whole terminal, renderer included. A surface spawns its
  own process: its input is keys, mouse and IME, and no call writes externally
  read bytes into it. Ghostty marked this API as not for external embedding on
  2026-08-10, and neither the 1.4.0 notes nor the 1.0 announcement revisits
  that. The Swift packages that feed bytes into a `ghostty.h` surface do it by
  patching Ghostty's Zig source: `Lakr233/libghostty-spm` adds a
  `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED` backend from its `Patches/ghostty/`
  directory, and `termio-sh/libghostty-swift` carries an equivalent host-managed
  IO patch.
- **`libghostty-vt`** – the supported API, and the only one that reached 1.0.
  `ghostty_terminal_vt_write` takes bytes, a terminal is created with no command
  and no pty, and the library ships render state (dirty rows, for a renderer the
  embedder writes), snapshots, selection, search, key and mouse encoders, and a
  formatter that writes a screen back out as plain text, HTML or VT. Each
  release publishes an xcframework, so no Zig toolchain is needed to consume it.
  It contains no renderer: upstream declined on 2026-05-12 to ship one inside
  it. The Swift renderer announced on 2026-07-02 is a separate package (see "The
  Swift renderer").

A third route avoids patching `ghostty.h` by letting the surface own a pty
whose command is an attach client to the embedder's own session daemon; one
embedder's September 2026 write-up describes exactly that. For TBD it would put
a relay process back between every keystroke and the session's pty, which the
holder transport exists to avoid: today the app writes keystrokes straight to
the session's pty master.

## What TBD needs from an engine

Two emulators read every holder-backed session, and they hand screens to each
other.

- **The daemon's headless emulator** – `HolderReader`
  (`Sources/TBDDaemon/Holder/HolderReader.swift`) drains the session's pty
  master into a headless SwiftTerm `Terminal`. Screen reads, mode readings such
  as bracketed paste (`TerminalModeCapture`), and OSC 7501 program status come
  from it.
- **The app's viewer** – `TBDTerminalView` subclasses SwiftTerm's
  `TerminalView` and is fed bytes from a `dup` of the pty master that the
  daemon passes over the FD sidecar (`HolderAttachClient`). It reads the grid
  through `withTerminal`, answers the OSC 7501 probe inside the parse,
  suppresses SwiftTerm's OSC 9;4 progress bar, and lets Option-drag bypass mouse
  reporting (turned on by `TerminalPanelView`). Several of those depend on
  commits in TBD's SwiftTerm fork, which
  `Package.swift` lists with the reason for each.

Neither emulator sits behind tmux. Holder-backed sessions are the default
(`Config.ptyHolderDefault`), so an engine is not ruled out for expecting to own
the pty or for being unable to speak to a tmux client.

### Two emulators, one snapshot format

On attach, the daemon writes its screen out as an escape-sequence preamble
(`TerminalSnapshotWriter`, in `Sources/TBDTerminalSerialization/`), and the
viewer replays it before any live output. When the viewer detaches, it hands a
preamble back the same way (`HolderHandback`). Each preamble is written from
one emulator's grid and parsed by the other. Both are SwiftTerm, so writer and
reader share one parser. The holder transport design
(`docs/specs/2026-08-30-pty-holder-session-transport-design.md`) rejects a
third-party headless VT for the daemon for that reason: SwiftTerm there gives
one parser for the daemon's screen reads and for the viewer's picture.

Moving only the viewer puts two VT implementations on either side of the
format. The proof of concept tested that at byte level, in 213 states:

- **Daemon to viewer** – TBD's unchanged writer, read by a fresh `libghostty-vt`
  terminal, gives the same screen as a fresh SwiftTerm in 211 states. The other
  2 are grapheme differences that also appear when the two engines read the raw
  stream.
- **Viewer to daemon** – `libghostty-vt`'s VT formatter, read by SwiftTerm,
  keeps the screen in 210 states. The other 3 hold content that SwiftTerm
  cannot represent.

So the format does not force both sides to change at once, and the viewer can
move first. That costs three things:

- **A reset before each preamble** – a reused viewer must be reset before it
  reads a preamble.
- **A writer on the viewer side** – the formatter covers the active screen and
  all its scrollback, but only the active screen. On an alternate screen, the
  writer formats a snapshot copy that has left the alternate screen, then adds
  the alternate screen. It must also send `?25l` after `?1049h`, because
  SwiftTerm shows the cursor on every switch to an alternate screen.
- **Two parsers in use** – while only the viewer has moved, the daemon's screen
  reads and the viewer's picture can differ where the engines differ, such as
  grapheme clustering or `CSI S` on the primary screen ("Proof of concept").

The proof of concept did not run the live attach and detach flow. The opt-in
engine runs it through the real daemon and app.

`libghostty-vt` fits the daemon's side with no renderer at all. The renderer is
the cost of the viewer's side alone.

Its binary snapshots look like a natural replacement for the preamble. A
snapshot holds the terminal's complete state, including unfinished parser input
and scrollback, and can restore in pieces so a viewer draws before old history
arrives. The ABI promise excludes them, though: the snapshot functions are part
of the C ABI, "but the bytes they produce and accept may change in any release",
and "Snapshot format version 1 is a work in progress and doesn't carry a
binary-compatibility guarantee." In the proof of concept, a binary snapshot
kept all 213 states between two `libghostty-vt` terminals of the same version.

The daemon and the app can run different builds, because `scripts/restart.sh
--app` restarts only the app, from whatever binary is on disk. A static library
ties each build to its own version, so a binary snapshot could reach a build
that cannot read it. The preamble therefore stays VT text unless a spec designs
a fallback.

## What TBD has in place

At `ac44edb9d`, the app has the opt-in libghostty engine
([design](../specs/2026-11-07-libghostty-terminal-engine-design.md)). Its
`TBDGhosttyTerminal` target holds the view and the renderer, about 11,900 lines
of Swift. A `TerminalEngine` protocol separates both engines from their
callers. The daemon has no libghostty code.

At `43a009132`, the shipped tree had no libghostty code:

- **No engine boundary** – 17 source files imported SwiftTerm, 9,963 lines in
  all, as did 32 test files. `withTerminal` appeared 21 times, 12 of them in
  `TBDTerminalView.swift`. No protocol separated the engine from its callers.
- **No flag** – nothing gated an engine change. `useMetalTerminalRenderer`
  chose a renderer inside SwiftTerm only.
- **A proof of concept, outside the build** – `spikes/libghostty-vt/` on the
  branch `spike/libghostty-vt-poc` (commit `4bc474f59`) holds a headless engine
  check (`check/`) and a standalone window (`view/`). The branch never merges.
  Its recorded sessions are git-ignored, and its `vtcheck corpus` command
  records them again.

## Why TBD has stayed on SwiftTerm

- **Every route to libghostty costs a fork or a renderer.** `ghostty.h` cannot
  be fed bytes without patching Ghostty. `libghostty-vt` can, but leaves TBD to
  write a Metal or CoreText renderer and the view work around it: keyboard and
  IME input, selection, mouse, scrolling and accessibility. The proof of
  concept sized that work: a renderer and view adapted from tkzmux, an
  MIT-licensed macOS app on `libghostty-vt`, of which TBD would own about 9,400
  lines. `Aqothy/ghost-swiftly` shows the scale another way: its Swift port of
  Ghostty's renderer, with its views and bindings, is about 520 KB of source
  before bundled fonts, some of it generated tables.
- **The performance motive is gone.** The terminal lag that raised the question
  was traced to three causes, none of them in the engine:
  - SwiftUI view-graph flushes stalling the main thread, fixed by per-property
    `@Observable` tracking (#724).
  - Scroll-wheel amplification, where one flick became hundreds of repaints
    (#1226).
  - A utility QoS clamp on the daemon's launch that every session inherited,
    which kept agents on the efficiency cores (#1228).

  Enabling SwiftTerm's Metal renderer (#725, default off) measured flat, and
  SwiftTerm never appeared in a main-thread hang stack. TBD's fork tracks
  upstream SwiftTerm's `main`, whose display-link `FrameDriver` replaces the
  fixed 16.67 ms repaint timer and moves Metal rendering off the main thread.
  Against TBD's fork, `libghostty-vt` parses 1.1 to 6.3 times as fast. That is
  well below the 6 to 21 times that `side-terminal-bench` measured against stock
  SwiftTerm, because the fork is already much faster than stock.
- **Embedders of `ghostty.h` have reported serious defects.** These were
  gathered on 2026-08-25 from those projects' own trackers and are recorded
  in the companion record, except where another date is given:
  - **Occlusion** – marking a surface occluded left it permanently
    unfocusable. TBD keeps up to eight terminals alive in a hidden pager.
  - **Scale** – thirty tabs with twenty-nine surfaces reached 564–806% CPU and
    5.2 GB resident, ending in an allocator out-of-memory.
  - **Lifecycle** – feeding a surface before its first tick deadlocked the main
    thread. A session lock held across a blocking write produced an app-wide
    three-thread deadlock in the bytes-fed path.
  - **Data loss** – several hundred bytes of prompt output dropped, leaving
    blank panes.
  - **API gaps** (September 2026 write-up) – `read_text` cannot address deep
    scrollback, `close_surface` can re-enter the host's teardown synchronously,
    and the child-exited action reported exit code 0 every time on macOS.
  - **Cost in practice** – termio, a shipping macOS agent terminal on a patched
    `ghostty.h`, recorded "four production-grade bugs in a few weeks, and every
    one of them lives in the dependency."

  These concern `ghostty.h` surfaces. A `libghostty-vt` embedder writes its own
  renderer and surface lifecycle, so it inherits neither these defects nor
  anyone's fixes for them.

## Proof of concept

Run on 2026-11-07 on the branch `spike/libghostty-vt-poc`. It used the official
`libghostty-vt` 1.0.0 xcframework through a SwiftPM `binaryTarget`, with no
fork, no patches and no Zig, against TBD's SwiftTerm fork at `c6b544f8`. The
machine was shared, and other work ran throughout.

**What ran.**

- **Engine check** – the same bytes went through both engines: six synthetic
  streams of 16 to 36 MB, and four recordings. Two recordings are of the real
  Claude Code TUI on the fake model API, and two are of `vim` and `less`.
  Screens were compared cell by cell at 432 checkpoints. The check also replayed
  213 handover states in each direction, and fed each sequence TBD relies on to
  both engines.
- **Window** – a standalone macOS window that draws `libghostty-vt` with a Metal
  renderer and runs a real command in a real pty.

**Speed.** Each ratio is the median of 7 runs, at the same grid and scrollback.
Two more runs under heavier load gave the same order.

| workload | `libghostty-vt` ÷ SwiftTerm fork |
|---|---|
| TUI redraws | 6.3 |
| Unicode text | 5.1 |
| Claude Code, classic renderer | 4.4 |
| Claude Code, fullscreen renderer | 3.9 |
| Colours | 3.7 |
| `vim` | 3.0 |
| `less` | 2.7 |
| Scrolling | 1.7 |
| ASCII text | 1.2 |
| Cursor movement | 1.1 |

**Memory.** At 200 by 60 with a 10,000-line limit, `libghostty-vt` used 0.64 of
the fork's memory for one idle terminal, and 0.48 to 0.50 for 20 or 100. That
saves about 12 MB per 100 terminals. One full scrollback used 0.85 to 0.87. A
compress that the host calls took that scrollback from about 17 MB to between
0.7 and 1.9 MB. The cost of reading compressed history back was not measured.

**Same screen.** Most of the corpus matched at cell level, and every difference
has a named cause. Where the engines disagreed, SwiftTerm was wrong more often.
For example, `CSI S` on the primary screen pushes rows into scrollback on
`libghostty-vt`, as on xterm, and not on SwiftTerm. Two kinds of grapheme
cluster could not be ruled either way: Devanagari conjuncts, and VS16 at the
right edge. Which one suits a program depends on that program's own width
calculation.

**Handover.** See "Two emulators, one snapshot format".

**TBD's signals.** OSC 7501 reports and the OSC 7501 support query both work.
Once the host sets the callback, the library answers the query itself during
parsing, which is the timing Claude Code needs. OSC 777, titles, OSC 7, OSC 8,
OSC 52, BEL, DECRQM, device attributes, cursor reports, Kitty keyboard flags and
synchronized output all reach the host.

**Real use.** The real Claude Code TUI ran in the window with typing, a streamed
answer, Shift+Return, paste, wheel scrolling, selection and resize. 120 resizes
while streaming lost none of 4,481 lines. 20 panes kept up with paced output.
Real key events posted through AppKit reached `zsh`.

**Gaps the window found.** Most are for the renderer or the host to close:

- Ctrl-I, Ctrl-M and Ctrl-[ reach a shell as CSI u sequences. The key encoder
  does this on purpose, following the fixterms specification, so the host has to
  send the C0 byte when no Kitty keyboard flags are active.
- The wheel does nothing in `less` or `vim`, because alternate scroll (mode
  1007) is not handled.
- Powerline and Nerd Font glyphs draw as empty boxes with Menlo.
- IME composition text is invisible while typing.
- Kitty image commands are answered `OK` and never drawn.
- Overline, blink, ligatures and BiDi are absent.

**Library settings a host must get right.**

- **Scrollback** – the default `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES` is
  10,000 bytes, and it wins over any line limit. Set it first.
- **Retained rows** – the count can fall below the line limit: 4,792 at a limit
  of 5,000. Ask for more lines than are needed.
- **Grapheme clustering** – turning mode 2027 on matches SwiftTerm, whose
  clustering is always on.
- **ABI** – the getters and setters take `void*`, so the compiler cannot see a
  type change. One happened between tkzmux's pin and 1.0.0, to the
  `GRAPHEMES_BUF` getter. Pin a tag and read each header diff.

**Not tested.**

- A frame seen on the screen. The screen was locked during the live run, so
  every picture is an offscreen render.
- Real mouse events, a real input method, and dragging the window edge.
- Key-to-paint latency.
- Attach and detach through TBD's real daemon and app.
- Long real sessions. The recordings are three turns on the fake model API.

**Defects found in TBD.** With no Ghostty involved, the check found defects in
TBD's own handover and in its SwiftTerm fork:

- **Rows shift on reattach** – the cell walk dropped trailing blank rows even
  with history above them, so the replayed screen landed too low and the cursor
  pointed at the wrong line. It hit 6 of 24 checkpoints in a Claude Code
  recording. Fixed in #1393.
- **Background colour lost on blank cells** – a blank cell with only a
  background colour was trimmed from the end of its line. Fixed in #1393.
- **Hidden cursor shown again** – the writer sent `?25l` before `?1049h`, on
  both the holder and the tmux attach paths. Fixed in #1392.
- **No tab stops past column 80** – on a SwiftTerm terminal created wider than
  80 columns, which is how the daemon creates its terminal. Fixed in #1394.
- **Colour lost after 65,535 styles** – the fork's style table never reclaimed
  entries, so new styles fell back to the default. Fixed in #1394.

The check also found state that TBD's writer never carries, such as a cursor
left in pending wrap. It bounds what any viewer can show after attach.

## A/B of the opt-in engine

Run on 2026-11-08 against a release build of TBD at `ac44edb9d`. This is the
first A/B round that the spec's "A/B and rollout" section calls for. It covers
two of the spec's four measures: typed echo latency and the draw wait.

The round had two runs, because libghostty always draws with Metal and
SwiftTerm has two renderers. In one run SwiftTerm drew with Metal
(`useMetalTerminalRenderer` on). In the other it drew with CoreGraphics
(`useMetalTerminalRenderer` off when the SwiftTerm panel was built).

**Setup.**

- **Machine** – a 12-core Apple silicon laptop, with 8 performance cores and 4
  efficiency cores.
- **Terminals** – two holder shell terminals that ran `cat`, in one scratch
  worktree. One was pinned to the dock at the side of the window, so both
  stayed on screen and mounted for the whole run. The two panes had different
  sizes. The two runs swapped which engine was in which pane.
- **The SwiftTerm arm** – with the libghostty flag on, Switch Terminal Engine
  (⌃⌘E) moved one terminal to SwiftTerm.
- **The probe** – `scripts/diag/terminal-latency-probe.py` in engine mode, with
  600 samples per arm and 250 ms between requests. It interleaved the arms
  A/B/B/A, sample by sample. A sample counts as idle when the 1-minute load
  average is 8 or less.
- **Load** – each run had about 2.5 minutes at idle, at a 1-minute load of about
  4 to 7. For the rest of the run, 12 `yes` processes ran, one per core, at a
  1-minute load of about 47 to 54. A watcher checked every 2 seconds and saw no
  compiler or build process during either run.
- **Engine check** – the probe's check passed before and after both runs. Each
  arm's latest "engine active" log line named its engine, and the flag was a
  boolean true.

**The two measures.**

- **Echo** – the probe writes a token into the terminal's outbound path, after
  the engine's own key handling. The app stamps the token's first copy when it
  comes back at the feed seam, before either engine parses it. So the echo is
  the same loop on both arms, and it leaves out the engine's key handling. In
  engine mode it is the check that the arms match, not the comparison.
- **Draw wait** – for each draw, how long the oldest undrawn chunk waited, from
  the feed seam to the start of the draw. It includes the parse. It is the
  comparison measure.

**Echo at p90.** Times are in milliseconds, with the sample count in brackets.
The ratio is libghostty ÷ SwiftTerm.

| SwiftTerm renderer | band | libghostty | SwiftTerm | ratio |
|---|---|---|---|---|
| Metal | idle | 0.098 (300) | 0.109 (301) | 0.899 |
| Metal | load | 0.075 (300) | 0.084 (299) | 0.893 |
| CoreGraphics | idle | 0.099 (303) | 0.110 (303) | 0.900 |
| CoreGraphics | load | 0.078 (297) | 0.076 (297) | 1.026 |

Echo p50 was about 0.06 ms on both arms, in both bands of both runs.

**Draw wait, with SwiftTerm on CoreGraphics.** Times are in milliseconds.

| | libghostty, idle | SwiftTerm, idle | libghostty, load | SwiftTerm, load |
|---|---|---|---|---|
| p50 | 6.608 | 1.726 | 5.042 | 1.274 |
| p90 | 9.383 | 2.724 | 8.928 | 2.822 |
| max | 12.954 | 7.863 | 12.744 | 8.741 |
| samples | 304 | 306 | 296 | 315 |

At p90, libghostty ÷ SwiftTerm was 3.445 at idle and 3.164 under load. The
latency tap timed 1,072 chunks on libghostty and 1,083 on SwiftTerm. Its ring of
chunk timestamps never overflowed, so no chunk was left out of a draw wait.

**Draw wait, with SwiftTerm on Metal.** SwiftTerm's Metal renderer writes no
draw lines, so this run has no draw comparison. libghostty alone had a p50 of
6.246 ms and a p90 of 9.121 ms at idle (302 samples). Under load it had a p50
of 4.595 ms and a p90 of 8.633 ms (301 samples).

**What the numbers show.**

- **The arms shared one loop and one load** – the two arms' echoes agreed
  within about 10% in every band. So the arms saw the same transport, and
  neither engine kept the app's main or reader thread busy enough to show in
  the echo. libghostty's echo p90 was about 10% lower at idle in both runs.
  That is below the spec's 20% bar, and the echo does not measure engine work,
  so it is not a win.
- **Pane size is not ruled out** – the echo cannot show whether the draw
  comparison was fair in other ways. The panes had different sizes, and the
  only draw comparison comes from one run. So the pane swap between the runs
  did not cancel out pane size for the draw wait.
- **SwiftTerm drew sooner** – on the draw wait, SwiftTerm on CoreGraphics was
  3.2 to 3.4 times shorter at p90.
- **The engines start a draw at different points** – both engines stamp the
  draw line when a draw begins. But the two draws begin at different points
  relative to the screen's frame.
  - libghostty builds a frame only on a display-link tick. Its `CADisplayLink`
    stays paused until there is output. Output resumes the link, and the frame
    is encoded inside the next tick (`renderTick` and `renderNow` in
    `GhosttyTerminalView.swift`). So the oldest chunk waits for the next screen
    frame. libghostty's waits spread fairly evenly from 0 to about 10 ms. That
    fits a wait for the next frame of a 120 Hz display (8.3 ms), plus a small
    hop to the main thread.
  - SwiftTerm's frame driver also has a display link. But when output arrives
    while that link is paused, the driver ticks at once, at most once in 16 ms,
    and does not wait for the next frame. The CoreGraphics path then marks the
    view for display, and the draw begins at the next main-loop commit. That
    commit is not tied to the screen's frame. The link pauses after 8 idle
    ticks, so with 250 ms between samples it was most likely paused when each
    echo arrived.

  The code shows where each draw starts. That this accounts for the whole gap
  is a reading of the code, not a measurement.
- **The gap on screen is not measured** – on both engines, pixels reach the
  screen at a compositor frame. So the gap on screen is likely smaller than the
  gap in draw wait: by this reasoning, at most about one frame. No TBD
  instrument measures pixels, so this gap is not measured.
- **The CPU load did not slow either arm** – under load, the echo p90s were 0.69
  to 0.79 times their idle values, and the draw-wait p90s were 0.95 to 1.04
  times. Hypothesis: the app's main thread runs at a higher QoS than the `yes`
  processes, and a busy CPU runs at a higher clock. If so, this load band says
  little about the build-heavy load that has made TBD's terminals lag.
- **The graduation rule is not met** – the rule asks for at least 20% at p90 on
  one measure, repeated in two A/B/B/A runs, with no regression beyond noise on
  the others. No measure showed a 20% win in either run, and the draw wait is a
  regression as measured. Under the spec's "flat A/B" outcome, the engine stays
  opt-in.

**Not measured in this round.**

- **A large stream** – the time to paint about 50 MB sent to a visible
  terminal. "A/B under heavy output" measures it.
- **Footprint** – app CPU and memory footprint with 8 and with 24 terminals
  open.
- **A repeat** – the graduation rule needs a result repeated in two
  A/B/B/A runs. The two runs here compared libghostty with two different
  SwiftTerm renderers. Panes of equal size, or a pane swap with the same
  SwiftTerm renderer, would rule out pane size.
- **Pixels** – an on-screen measure. Only that can settle the draw-wait
  question.
- **SwiftTerm on Metal** – a draw-wait comparison against it. Its renderer
  writes no draw lines today.

One question follows from the mechanism and stays open: should libghostty
build a frame when output arrives, instead of on the next tick? This record
does not answer it.

## A/B under heavy output

Run on 2026-11-08 against the same release build at `ac44edb9d`, on the same
laptop as the first round. It measured two heavy workloads: a 50 MB stream,
which is the third of the spec's four measures, and Claude Code in full-screen
mode. It also measured the app's CPU time during each workload. That is not
one of the spec's measures: the spec's CPU measure is taken with 8 and with 24
terminals open.

**Setup.**

- **Terminals** – two holder terminals, one on each engine, as two tabs in the
  same pane. Each run selected its arm's tab, which rebuilt the panel, so both
  arms drew into a pane of the same pixel size.
- **Two phases** – SwiftTerm drew with CoreGraphics in phase 1 and with Metal
  in phase 2. SwiftTerm's Metal renderer writes no draw lines, so phase 2
  compares CPU only.
- **Order** – one engine at a time, in A/B/B/A order: 12 runs in each phase for
  the stream, and 8 for Claude Code.
- **App CPU** – the change in the app process's CPU time, read with `ps`,
  across a window.
- **Draw lines** – captured live with `log stream`. As in the first round, each
  line marks the start of a draw and gives the wait of the oldest undrawn chunk.
- **Load** – the Claude Code driver read the 1-minute load average at the start
  of each run: 3.5 to 11.3. The stream driver did not record load.
- **Replies** – Claude Code queries the terminal at startup. Both engines
  answered XTVERSION, the Kitty keyboard query, and DECRQM for modes 2026 and
  1016 alike. They differed on the Kitty graphics query `a=q`: SwiftTerm
  replied OK, and libghostty stayed silent.
- **Grid** – the engines' cells differed in size: 14 by 34 pixels on SwiftTerm,
  15 by 32 on libghostty. So the pane held 102 by 50 cells on SwiftTerm and 95
  by 53 on libghostty. The cell counts are within 1.3% of each other, but
  libghostty received about 4% more bytes in each scroll run. A fix that gives
  libghostty SwiftTerm's cell size is open (#1420), and the grids differed
  throughout these runs.

**The 50 MB stream.** Each run sent a 52,428,897-byte file of coloured log
lines with `cat` into a shell in the pane. Paint time runs from the run's first
draw line to its last. The table gives medians of phase 1's six runs on each
engine, with SwiftTerm on CoreGraphics. For the draw wait, each cell is the
median of the runs' own percentiles.

| | SwiftTerm | libghostty |
|---|---|---|
| paint time, s | 0.455 | 0.447 |
| `cat` wall time, s | 0.44 | 0.43 |
| frames per second | 123 | 121 |
| draw wait p50, ms | 8.29 | 8.33 |
| draw wait p90, ms | 8.64 | 8.37 |
| app CPU, s | 0.78 | 0.62 |

- **Delivery set the pace** – both engines painted the stream in about the
  time `cat` took to write it: 0.43 to 0.44 s at the median, or about 120 MB/s.
  libghostty parses faster than TBD's SwiftTerm fork ("Proof of concept"), yet
  the paint times matched. So the limit lay upstream of both engines. That is a
  reading, not a measurement.
- **Draw wait** – about 8.3 ms at p50 on both, one frame at 120 Hz.
  libghostty's p90 was steadier: 8.36 to 8.38 ms in every run, against 8.54 to
  8.69 ms on SwiftTerm.
- **App CPU** – libghostty used 21% less than SwiftTerm on CoreGraphics.
- **SwiftTerm on Metal** – in phase 2, SwiftTerm on Metal had a median of
  1.21 s of CPU over five runs, and libghostty 0.59 s over six, 51% less. The
  three Metal runs outside the slow cluster below used 0.96 to 1.21 s, more
  than any SwiftTerm run on CoreGraphics (0.76 to 0.83 s). So on this workload
  SwiftTerm's Metal path used more CPU than its CoreGraphics path. libghostty's
  median paint time in phase 2 was 0.44 s.

  Phase 2's first SwiftTerm run is not counted as Metal. Its panel had not been
  rebuilt since the renderer setting changed, so it still drew with
  CoreGraphics: it wrote draw lines, which only that path does, and it used
  0.76 s.
- **Outliers** – one libghostty run in phase 1 used 1.08 s of CPU and took
  1.54 s to paint, while `cat` took 1.51 s. In phase 2, runs 7 to 9 were slow on
  both engines, with `cat` taking 2.0 to 5.5 s: libghostty used 1.16 s, and
  SwiftTerm on Metal 3.60 and 4.78 s. The driver did not record load, so the
  cause is unknown. Apart from phase 2's first SwiftTerm run, the medians
  exclude nothing.

**Claude Code in full-screen mode.** Claude Code 2.1.319 ran with
`CLAUDE_CODE_NO_FLICKER=1`, which TBD sets by default. It was the real CLI,
talking to the repository's zero-token fake model API (`scripts/claude-stub.py`),
which streamed the answer as 40-character deltas every 25 ms. Each run had
three parts:

1. **Stream** – a 10 KB answer, about 11.5 s long, in about 75 frames and about
   180 KB of terminal output.
2. **Scroll** – 112 steps, 150 ms apart: the wheel 25 steps up and 25 down,
   PageUp 6 times and PageDown 6 times, then the wheel 25 up and 25 down. Each
   step makes Claude Code repaint the whole viewport in one synchronized frame
   (DEC mode 2026).
3. **Exit** – Ctrl-C twice.

- **Input path** – the driver sent the scroll bytes through a pass-through
  relay in front of Claude Code. `tbd terminal send --text` wraps its text in
  bracketed paste while mode 2004 is on, which full-screen Claude Code turns
  on, so a wheel report sent that way would reach the composer as pasted text.
  The relay passes keystrokes and output through unchanged, with one extra copy
  each way on both arms. It logged no other input to Claude Code in any
  measured window.
- **Steps counted** – the first step of each of the six segments starts or
  reverses the scroll, where Claude Code draws an extra frame, a "Jump to
  bottom" hint. Those steps are left out, which leaves 106 steps per run and 424
  per arm in each phase.
- **Measures:**
  - **App CPU while streaming** – from submitting the prompt until the app went
    quiet after the answer ended.
  - **App CPU per scroll step** – the app's CPU time across the scroll part,
    divided by the 109 steps that produced output.
  - **Input to draw start** – from the driver's write to the step's first draw
    line.
  - **Claude Code's own time** – from the driver's write to the first output
    byte at the relay.

**App CPU.** Medians of four runs per arm. The ratio is libghostty ÷ SwiftTerm.

| SwiftTerm renderer | measure | SwiftTerm | libghostty | ratio |
|---|---|---|---|---|
| CoreGraphics | streaming, s | 0.87 | 0.37 | 0.43 |
| CoreGraphics | per scroll step, ms | 12.6 | 5.2 | 0.41 |
| Metal | streaming, s | 0.72 | 0.39 | 0.54 |
| Metal | per scroll step, ms | 11.2 | 5.0 | 0.44 |

Every libghostty run used less CPU than every SwiftTerm run, on both measures
in both phases. While streaming, runs ranged from 0.85 to 0.90 s on
CoreGraphics, 0.70 to 0.76 s on Metal, and 0.30 to 0.40 s on libghostty. Per
scroll step they ranged from 12.2 to 12.7 ms on CoreGraphics, 10.6 to 11.6 ms on
Metal, and 4.5 to 5.7 ms on libghostty.

**Latency, with SwiftTerm on CoreGraphics.** Pooled over 424 steps per arm, in
milliseconds.

| | SwiftTerm p50 | libghostty p50 | SwiftTerm p90 | libghostty p90 |
|---|---|---|---|---|
| input to draw start | 9.0 | 9.6 | 14.8 | 15.7 |
| draw wait | 5.3 | 5.7 | 8.4 | 8.9 |

Claude Code's own time had per-run medians between 2.0 and 4.4 ms on both arms.
Every counted step drew exactly one frame on both engines. With SwiftTerm on
Metal, libghostty's input to draw start was 9.2 ms at p50 and 14.3 ms at p90.

**What the numbers show.**

- **libghostty used much less app CPU** – in Claude Code's full-screen mode it
  used 0.41 to 0.54 of SwiftTerm's app CPU on either renderer, while it received
  about 4% more bytes per scroll run. On the 50 MB stream it used 0.79 of
  SwiftTerm's on CoreGraphics and 0.49 on Metal.
- **Latency was within 1 ms** – in Claude Code, libghostty's draws started
  0.6 ms later at p50 and 0.9 ms later at p90. On the stream, the paint times
  matched.
- **SwiftTerm waits for Claude Code's frames** – on CoreGraphics its draw-wait
  p90 was 8.4 ms here, against 2.7 ms after a typed echo in the first round. So
  the first round's gap of 3.2 to 3.4 times does not appear with Claude Code's
  synchronized frames. The wait is not output trickling in: each step's output
  reached the relay within 0.5 ms of its first byte at p90. Why SwiftTerm waits
  for these frames and not for an echo was not established.
- **The graduation rule is not met** – app CPU during a workload is not one of
  the spec's four measures. Its CPU measure is app CPU and memory footprint
  with 8 and with 24 terminals open, which has not been run. On the spec's
  measures, this round adds the 50 MB paint time and two draw-wait
  comparisons, and none came near the 20% bar. The largest difference, 8%, was
  libghostty's longer draw wait at p50 in Claude Code. So these results do not
  by themselves meet the rule. The first round's draw wait after typed echo
  also stands: 3.2 to 3.4 times longer at p90 on libghostty, which the code
  traces to frames encoded only on display-link ticks. So do the open daily-use
  gaps.
- **Parity fixes** – the measured build predates two libghostty fixes that have
  since merged: the sRGB colour space (#1419) and stroke weight (#1416). Fixes
  for macOS line-editing shortcuts (#1421) and for cell size, baseline and wide
  glyphs (#1420) are open.

## Ghostty on 2026-11-06

**The library, per the 1.0 announcement and the `vt-1.0.0` tree.**

- "The 1.0 release means both the library itself and the C ABI are now stable."
- "1.0 means `libghostty-vt` follows semantic versioning and has strict ABI
  compatibility promises".
- A minor release may add functions, types, enum values, and fields at the end
  of a sized struct. "Nothing is removed, resized, reordered or re-typed."
- The library has its own `vt-X.Y.Z` tags and release cycle, separate from the
  Ghostty application.
- `libghostty-vt` is MIT licensed, and the announcement reports no copyleft code
  in its dependency tree.
- The stated direction is to "focus on stability while implementing as many
  terminal protocols as exist". The announcement says nothing about a renderer.
- Named adopters include JetBrains IDE terminals, Herdr, cmux, Ghostel and
  OrbStack, with a Neovim pull request pending a tagged release.

**Consuming it from Swift.**

- Each release publishes `ghostty-vt-VERSION.xcframework.zip`. At 1.0.0 it holds
  a static macOS library with arm64 and x86_64 slices, iOS and simulator
  libraries, and a module map. The zip is 16 MB and the macOS library 26 MB.
- A source build requires Zig 0.17.x exactly. Consuming the xcframework does not
  need Zig.
- The announcement says the xcframework "drops straight into Xcode or Swift
  Package Manager". `PACKAGING-LIBGHOSTTY.md` does not mention SwiftPM, but the
  tree has one first-party example, `example/swift-vt-xcframework`, a
  `binaryTarget` that makes direct C calls.
- Checked on 2026-11-06: a Swift program built with `swiftc` 6.2.4 against the
  macOS library created a terminal, wrote VT to it and read it back through the
  VT formatter. The binary was 2.8 MB. The release's `.minisig` signature was
  not verified.

**TBD's needs against the 1.0 headers.**

- **OSC 7501** – `GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS` delivers each report to a
  callback, and the terminal stores none of them. The library answers the
  support query itself ("Proof of concept"). TBD implements the protocol
  already (`docs/specs/2026-10-10-program-status-protocol-design.md`).
- **Pty replies** – `GHOSTTY_TERMINAL_OPT_WRITE_PTY` carries them. Without it,
  queries go unanswered.
- **OSC 9;4** – the library draws nothing, and the progress callback can be left
  unset, so no patch is needed at this layer. A renderer package may differ.
- **Input** – key encoders cover the legacy and Kitty protocols, and mouse
  encoders cover X10, UTF-8, SGR, URxvt and SGR-Pixels.
- **Screen access** – `render.h`, `selection.h`, `search.h` and `modes.h`.
- **Images, a gap** – graphics go through the Kitty protocol. Sixel appears in
  the headers only as a device-attribute feature bit, and OSC 1337 only for
  `CurrentDir` and `Copy`, so neither Sixel nor iTerm2 inline images has an API.
  SwiftTerm handles both, and `TBDTerminalView` notes that they share the cell
  payload.

**The maintainer, on Hacker News on 2026-10-27:**

- "a single empty terminal now takes 90% less memory. And at scale I've proven
  10,000 active (input/output happening) terminals on a Linux server with 4
  cores and 8 GB of RAM."

**Numbers that belong to the Ghostty app, not the library.** The 1.4.0 notes
report these for the GUI. Some may come from code the library shares, but the
notes do not say which.

- **Empty terminal** – about 16 KiB of terminal page memory on macOS, down from
  128 KiB in 1.3.1.
- **Hidden tabs** – they release their GPU resources: one visible tab and
  twenty hidden ones went from about 385 MiB of GPU memory to 18 MiB, with a
  rebuild under a millisecond. This is renderer behavior. An embedder with its
  own renderer gets it only by building it, which matters for TBD's pager.
- **Parsing** – plain ASCII went from 128 MB/s to 725 MB/s in parser
  benchmarks.

**The Swift renderer.** On 2026-07-02 the maintainer wrote: "I've got a pure
Swift Metal renderer and bindings for libghostty-vt. This will enable
libghostty users to basically drop a package into their Swift/Xcode projects
and get a full blown terminal (emulation, rendering, or both). Coming soon..."
No package or repository for it was found on 2026-11-06. `ghostty-org` lists six
repositories, none of them Swift. The 1.0 announcement counts Swift among its
community bindings and names no first-party one. A web search found only the
announcement itself.

**Third-party Swift packages:**

- **`Lakr233/libghostty-spm`** – `ghostty.h` with patches, including the
  host-managed IO backend, tracking upstream `main`. Recent tags take the form
  `upstream.<commit>`. On 2026-10-28, tags `1.4.0` through `1.4.13` and `1.5.0`
  had been withdrawn.
- **`Aqothy/ghost-swiftly`** – unpatched `libghostty-vt` behind a Swift actor,
  with a Swift port of Ghostty's Metal and CoreText renderer and AppKit, UIKit
  and SwiftUI views. It has tags through `0.3.3`, was created on 2026-10-19, and
  has one contributor. It cannot be a dependency as it stands: it carries
  Ghostty's MIT text but no licence for its own code, and it pins a Ghostty CI
  build 339 commits before `vt-1.0.0`.
- **`caelyreth/libghostty-vt-spm`** – a `libghostty-vt` wrapper that returns
  incremental frames for a host-written renderer. Tags run through `0.2.1`, and
  its last push, on 2026-07-25, predates 1.0.

## When the renderer might ship

No evidence supports a date. The announcement said "Coming soon..." on
2026-07-02, and the 1.0 announcement's stated direction does not include it. The
C API underneath is stable, so an ABI break is not a reason to hold it back.

If it never ships, the alternative is the renderer that TBD adapted on
`render.h` for its opt-in engine, path B in the companion record. Making that
engine the default needs a motive. The A/B rounds found none that meets the
spec's graduation rule. Their clearest difference, about half the app CPU under
Claude Code's full-screen output, is not one of the spec's measures.

## Before a move

A move here means making libghostty the default. The opt-in engine has done
the first steps, as its
[design](../specs/2026-11-07-libghostty-terminal-engine-design.md) records:

- **Spec and flag** – the engine ships behind `useGhosttyTerminalEngine`, off
  by default.
- **Engine boundary** – the holder and LocalPTY coordinators talk to one
  `TerminalEngine` protocol, with one implementation for each engine.
- **First trial of one viewer** – the viewer runs on libghostty behind the
  flag, and the daemon stays on SwiftTerm. Attach, detach and resize go through
  the real daemon and app.

These stay open:

- **The A/B** – app CPU and memory footprint with 8 and with 24 terminals
  open, a second A/B/B/A run of any measure that shows a win, and the pixel
  and SwiftTerm-on-Metal comparisons that "A/B of the opt-in engine" lists as
  not measured in its round.
- **Daily-use gaps** – among them ligatures and right-to-left text, which the
  Settings toggle names as unsupported, and the two open fixes that "A/B under
  heavy output" lists.
- **A renderer package** – if Ghostty publishes one, check its licence, its
  version pin against `libghostty-vt`, and what it covers of IME, selection,
  scrolling and accessibility.
- **What has to move with the daemon, later** – `TerminalSnapshotWriter` and
  `SGREncoder`, or libghostty's VT formatter in their place, and the mode
  readings that holder sends depend on.
- **Images** – decide whether losing Sixel and iTerm2 inline images is
  acceptable.
- **The pager** – check that the libghostty renderer releases GPU resources for
  hidden views. The 1.4 GUI does.

## Sources

- libghostty 1.0 announcement – https://mitchellh.com/writing/libghostty-1-0
- libghostty documentation – https://lib.ghostty.org/
- Stability and ABI rules – https://github.com/ghostty-org/ghostty/blob/vt-1.0.0/dist/doxygen/pages/stability.md
- Snapshots guide – https://github.com/ghostty-org/ghostty/blob/vt-1.0.0/dist/doxygen/pages/guides/snapshots.md
- Packaging guide – https://github.com/ghostty-org/ghostty/blob/vt-1.0.0/PACKAGING-LIBGHOSTTY.md
- Headers at `vt-1.0.0` – https://github.com/ghostty-org/ghostty/tree/vt-1.0.0/include/ghostty/vt
- Swift example at `vt-1.0.0` – https://github.com/ghostty-org/ghostty/tree/vt-1.0.0/example/swift-vt-xcframework
- Ghostty 1.4.0 release notes – https://ghostty.org/docs/install/release-notes/1-4-0
- The maintainer's comment on the 1.4 Hacker News thread – https://news.ycombinator.com/item?id=50262760
- The Swift renderer announcement – https://x.com/mitchellh/status/2072724957902381319
- "What it takes to embed libghostty in a Swift app: six months of lessons" – https://dev.to/yuu1ch13/what-it-takes-to-embed-libghostty-in-a-swift-app-six-months-of-lessons-1m64
- `Lakr233/libghostty-spm` – https://github.com/Lakr233/libghostty-spm
- `Aqothy/ghost-swiftly` – https://github.com/Aqothy/ghost-swiftly
- `caelyreth/libghostty-vt-spm` – https://swiftpackageregistry.com/caelyreth/libghostty-vt-spm
- `termio-sh/libghostty-swift` – https://github.com/termio-sh/libghostty-swift
- The proof of concept – https://github.com/cheapsteak/tbd/tree/spike/libghostty-vt-poc/spikes/libghostty-vt
- tkzmux, the source of the proof of concept's renderer – https://github.com/tkz0/tkzmux
- `side-terminal-bench` – https://github.com/gazishahi/side-terminal-bench
