# An opt-in libghostty engine for the app's terminals

TBD draws every terminal in the app with its fork of SwiftTerm. `libghostty-vt` 1.0 is
a stable C library for terminal emulation that leaves drawing to the host. This design
adds it as a second engine for the app's terminal views, behind a default-off flag. Users
who want a faster terminal can turn it on, and TBD's own instruments compare the two
engines on real work. The daemon stays on SwiftTerm.

## Goal

- **Goal** – a faster terminal for users who opt in, shown by TBD's own instruments.
- **Not goals:**
  - moving the daemon's headless terminal off SwiftTerm
  - switching tmux control-mode panels, a transport that is being removed
  - ligatures and BiDi, which SwiftTerm in TBD does not have either
  - changing the default engine before the A/B and the soak below are done

## Evidence

A proof of concept on the branch `spike/libghostty-vt-poc` (under `spikes/libghostty-vt/`,
with the verdict in its `RESULTS.md`) is the basis for this design.

- **Stock library** – the official `vt-1.0.0` xcframework builds and runs with no fork, no
  patches and no Zig. The real `claude` TUI ran in a Swift Metal view adapted from tkzmux
  (MIT), with typing, streaming, paste, wheel, selection and resize.
- **Handover holds at byte level, in both directions:**
  - TBD's unmodified snapshot writer, read by a fresh libghostty terminal, gives the same
    screen as a fresh SwiftTerm in 211 of 213 states.
  - A reused libghostty terminal needs a reset first. With `ghostty_terminal_reset()`
    ahead of the preamble, it is correct in all 213 states, after both prior lives tested.
  - A libghostty terminal handed back to SwiftTerm through a new writer keeps the screen
    in 210 of 213 states. The three misses (`combining-marks`, `vs16-at-edge`,
    `overline`) are things SwiftTerm cannot hold.
  - Live attach and detach through the real daemon and app did not run.
- **Speed and memory** – libghostty parses 1.1 to 6.3 times faster than TBD's fork, and
  about 4 times faster on recorded Claude output. Idle terminals use about half the
  memory, which is about 12 MB per 100 terminals.
- **Gaps that stock libghostty leaves to the host:**
  - Ctrl-I, Ctrl-M and Ctrl-[ send CSI u instead of Tab, Return and Esc
  - the wheel does nothing in `less` and `vim`
  - Powerline glyphs are missing
  - IME composition text is not shown
  - a Kitty image query gets a false OK
  - there are no ligatures and no BiDi

**The risk, stated plainly.** Every terminal slowdown TBD has measured so far had its
cause outside the engine:
- a SwiftUI flush that stalled the main thread (#724)
- a utility QoS clamp on every session (#1228)
- a debug build installed in place of a release build

Feed and parse were about 2.7% of main-thread samples while scrolling
([`2026-08-25-terminal-metal-renderer-design.md`](2026-08-25-terminal-metal-renderer-design.md)),
and the A/B of SwiftTerm's Metal renderer found no noticeable improvement. So a 4 times
faster parser may not show up anywhere a user can feel it.

This design builds the engine first and measures afterwards. Measuring SwiftTerm's share
of the delay on a chosen workload would only estimate the possible gain, while the A/B
measures the gain directly. The cost of that order is that the A/B may come back flat
after the whole build.

The migration record,
[`docs/research/2026-10-28-terminal-engine-libghostty.md`](../research/2026-10-28-terminal-engine-libghostty.md),
keeps SwiftTerm as the default engine. This experiment does not change that unless it
graduates.

## Scope

- **Switched by the flag:**
  - holder-transport panels (`TerminalPanelView.swift`), which local sessions use by
    default
  - `LocalPTYTerminalView`, which remote attach and auth terminals use
- **Not switched:** tmux control-mode panels, and the daemon's headless terminal in
  `HolderReader`.
- **Parity** – a libghostty terminal hands a snapshot back on detach and answers the
  daemon's screen requests, as a SwiftTerm one does. Agents and `tbd terminal output`
  work the same on both engines.
- **Gaps closed before the toggle appears in Settings:**
  - the Ctrl-I, Ctrl-M and Ctrl-[ mapping
  - the wheel in `less` and `vim`
  - Powerline glyphs
  - IME composition text
  - the Kitty image reply

  Ligatures and BiDi stay documented gaps.

## Design

### The engine seam

The coordinators that run a terminal talk to one protocol, `TerminalEngine`, and never to
SwiftTerm or libghostty directly. These coordinators are `TerminalPanelRepresentable`'s
Coordinator and the `LocalPTYTerminalRepresentable` coordinator. An engine is an object
that owns its view. It exposes the view as an `NSView` for embedding and has four parts,
split by direction and by thread.

- **Input** – callable from any thread. The engine keeps the calls in order.
  - `feed(_:)` – live bytes from the session.
  - `prepareForPreamble()` – called before a preamble goes into a view that has been used
    before.
  - `ingestSnapshot(_:)` – feeds a preamble so that no callback, OSC event or reply to
    the pty it provokes reaches the coordinator. The rule is about that outcome, not
    timing. SwiftTerm delivers its callbacks a main-queue turn later, so its engine lowers
    the mute a turn later. libghostty fires them inside the parse, so its engine lowers
    the mute when the parse returns.
- **Locked reads** – one closure, `withScreen { reader in … }`, which runs under the
  engine's lock. Everything that reads the model goes through it, so no read can race
  `feed` or take the lock more than once. The reader offers:
  - the mouse mode and whether the alternate screen is shown
  - a line's text, and the hyperlink of the cell at a grid position
  - the screen projection and styled capture that `ViewerScreenProducer` sends to the
    daemon
  - wheel reports, sent inside the same lock hold that read the mouse mode, as the scroll
    monitor does today
- **Handback** – `handbackPreamble(maxScrollbackLines:)`, an async call on the engine
  itself. It is not a locked read, because SwiftTerm's handback first sends a DECRQM
  probe and waits a main-queue turn for the replies. libghostty reads modes directly and
  needs no probe.
- **Outbound** – a TBD-owned `TerminalEngineDelegate`, which the coordinator implements.
  Its methods are:
  - `send` – keys and paste. Called on the main thread.
  - `sizeChanged(cols:rows:)` – called on the main thread, after the engine has resized
    its own terminal.
  - bell, OSC 52 copy, OSC 777 notification and the OSC 7501 report.
  - link-open and focus.

  A reply that the parser writes, such as the OSC 7501 probe answer, is sent on the
  feeding thread before `feed` returns. TBD relies on that timing today.
- **Appearance** – font, colours and cursor style. Main thread only.

Each engine also exposes two engine-neutral instrument hooks: draw start and frame
presented.

**Implementations:**

- **`SwiftTermEngine`** – a final class that owns a `TBDTerminalView` and is its
  `TerminalViewDelegate`. It passes events on to `TerminalEngineDelegate`. Its reads run
  inside `withTerminal` and reuse `TerminalSnapshotWriter` and `TerminalScreenProjection`
  unchanged. Behaviour is identical to the code it replaces.
- **`GhosttyEngine`** – a final class that owns a `GhosttyTerminalView` and one
  `GhosttyTerminal` handle, guarded by one lock. It is marked `@unchecked Sendable`, with a
  comment saying the lock is the reason.
- **`TerminalEngineFactory`** – reads the flag once when it builds a terminal, and falls
  back to SwiftTerm if libghostty cannot start.

`TerminalViewHolder`, the lock-guarded pointer the IO thread feeds through, holds the
engine instead of the SwiftTerm view.

**What serves each requirement in libghostty.** This mapping keeps the protocol from
taking SwiftTerm's shape:

- `feed` – `ghostty_terminal_vt_write`.
- `prepareForPreamble` – `ghostty_terminal_reset`.
- `ingestSnapshot` – `ghostty_terminal_vt_write`, with the `GHOSTTY_TERMINAL_OPT_WRITE_PTY`
  callback dropping replies and the effect callbacks checking a muted flag.
- Resize – `ghostty_terminal_resize`.
- Mouse mode and alternate screen – `ghostty_terminal_get` for the modes.
- Cell text and hyperlink – `ghostty_terminal_grid_ref`, `ghostty_grid_ref_cell` and
  `ghostty_grid_ref_hyperlink_uri`.
- Screen projection – a grid walk through `ghostty_terminal_grid_ref` and
  `ghostty_grid_ref_row`.
- Handback – an in-process clone through `ghostty_snapshot_encode` and the snapshot
  decoder, then `ghostty_formatter_terminal_new` and `ghostty_formatter_format`.
- Keys, mouse and paste – `ghostty_key_encoder_*` and `ghostty_mouse_encoder_*`, both set
  from the terminal's modes, and `ghostty_paste_encode`.
- Bell, OSC 52, OSC 777 and OSC 7501 – the `BELL`, `CLIPBOARD_WRITE`,
  `DESKTOP_NOTIFICATION` and `PROGRAM_STATUS` callbacks. libghostty answers the OSC 7501
  probe through `WRITE_PTY` during the parse.
- Terminal identity – the `DEVICE_ATTRIBUTES` and `XTVERSION` callbacks.
- Appearance – the `COLOR_FOREGROUND`, `COLOR_BACKGROUND`, `COLOR_CURSOR`,
  `COLOR_PALETTE`, `DEFAULT_CURSOR_STYLE` and `DEFAULT_CURSOR_BLINK` options.
- Drawing – `ghostty_render_state_*`: update, then iterate rows and cells.
- Selection – `ghostty_terminal_select_*` and the selection gesture API.

### Package and targets

- **`GhosttyVt`** – a `binaryTarget` for the official
  `ghostty-vt-1.0.0.xcframework.zip` from `release.files.ghostty.org`, pinned by URL and
  SHA-256 checksum. SwiftPM checks the checksum on every resolve. The xcframework carries
  its own `module.modulemap`, so no shim is needed. The PR that sets or bumps the pin also
  checks the release's minisign signature and records that it did.
- **`TBDGhosttyTerminal`** – a new target under `Sources/TBDGhosttyTerminal`. It depends on
  `GhosttyVt` and a small C target for shader types, and it links `c++`. It holds:
  - `GhosttyTerminalView`, an `NSView` backed by a `CAMetalLayer`
  - the renderer: frame builder, glyph atlas and box sprites, with Powerline added
  - key and mouse encoding, selection, and IME through `NSTextInputClient`
  - `GhosttySnapshotWriter` and `GhosttyScreenProjection`

  Code adapted from tkzmux keeps a one-line source note at the top of each file, and
  tkzmux's MIT licence ships with the target.
- **`TBDApp`** – depends on `TBDGhosttyTerminal` and holds the protocol, `SwiftTermEngine`,
  `GhosttyEngine` and the factory under `Sources/TBDApp/Terminal/Engine/`.
  `TBDGhosttyTerminal` cannot import the app, so it exposes its own API and knows nothing
  of `TerminalEngine`. `GhosttyEngine` adapts that API to the protocol.
- **`TBDTerminalSerialization`** – unchanged. It reads a SwiftTerm `Terminal` and stays the
  SwiftTerm engine's writer and projection.

The handback writes VT text, which the daemon's SwiftTerm reads. No libghostty snapshot
bytes leave the app's process, so nothing relies on the snapshot format, which libghostty
1.0 does not promise to keep stable.

### Data flow

The same coordinator code runs for both engines.

- **Attach, on holder panels:**
  1. The coordinator receives the attachment: the snapshot preamble and the pty.
  2. If the view has been used before, it calls `prepareForPreamble()`. The libghostty
     engine resets its terminal. The SwiftTerm engine does nothing, because a reset in
     SwiftTerm leaves stale alternate-screen content that a later `?1049h` shows again.
  3. It calls `ingestSnapshot(preamble)`.
- **Live bytes** – `HolderStreamReader` on the IO thread, then `TerminalViewHolder.feed`,
  then `TerminalLatencyTap`, then `feed`.
  - The libghostty engine takes its lock and calls `ghostty_terminal_vt_write`.
  - OSC callbacks fire inside that call, so the OSC 7501 reply goes out on the IO thread,
    as it does today.
  - The renderer runs on the display link and reads the terminal under the same lock to
    build a frame.
- **Keys and paste:**
  - A key goes through the libghostty key encoder. TBD maps Ctrl-I, Ctrl-M and Ctrl-[ to
    Tab, Return and Esc unless the program has asked for CSI u key reports.
  - The bytes then go to `send`, `deliverOutgoing`, `OutgoingInputQueue` and the pty.
    That code is unchanged.
- **Resize** – the engine resizes its terminal first, then calls `sizeChanged`. That
  leads to `TIOCSWINSZ` and the daemon resize, in the same order as with SwiftTerm.
- **Screen requests** – `answerScreenRequest`, then `ViewerScreenProducer`, then
  `withScreen`. The libghostty reader walks the grid through the C API.
- **Detach** – `captureHandbackPreamble` awaits the engine's `handbackPreamble`. The
  daemon then resets its terminal and replays the preamble, as today.
  - The SwiftTerm engine keeps today's DECRQM probe and `TerminalSnapshotWriter`.
  - The libghostty engine's `GhosttySnapshotWriter`:
    1. clones the terminal in process;
    2. on an alternate screen, feeds `?1049l` to the clone and formats the primary screen
       with its cursor, style, protection and charset extras;
    3. appends the formatter output for the active screen;
    4. fixes four ordering defects the proof of concept found:
       - `?25l` goes after `?1049h`, because SwiftTerm's `?1049h` shows the cursor
       - only the mouse mode in effect is written, not every bit in mode order
       - DECOM is reset in the primary-screen part
       - `?7` goes before `?45`, because the fork refuses `?45h` after `?7l`
- **Remote and auth terminals** – `LocalProcess` feeds the engine, and `send` writes to the
  local pty. They have no handback and no projection, as today.

### Terminal identity

A program asks the terminal what it is once, at start-up, and a session can later move
between engines. So both engines must look the same to the program.

- **DA1, DA2 and XTVERSION** – the libghostty engine answers these through the
  `DEVICE_ATTRIBUTES` and `XTVERSION` callbacks, with the same replies as TBD's SwiftTerm.
- **OSC 7501 probe** – by itself, libghostty answers with a reply that advertises more
  states than TBD's: `?:states=idle,working,done,blocked,error:kinds=permission,question,auth`.
  A session that started under libghostty could then send states that the daemon's
  SwiftTerm, or a later SwiftTerm viewer, does not handle. So the libghostty engine must
  send TBD's own reply.
  - If libghostty offers no way to replace its reply, step 2 first changes TBD's own reply
    and OSC 7501 parser to the libghostty set, in a PR of its own.
  - The proof of concept found that the real `claude` (2.1.319) sent the same reports with
    either reply.
- **Modes a program turns on** – Kitty keyboard flags, mouse modes and the like travel in
  the preamble and the handback, so keys follow the program's request on both engines.
- **Kitty images** – the libghostty engine is configured so that a Kitty graphics query
  does not report support. A test checks the reply.

### Errors and fallback

- **libghostty cannot start a terminal** (no Metal device, an init error):
  - The factory builds a SwiftTerm terminal instead, for that terminal only.
  - It logs a `.notice` on `com.tbd.app` / `terminalEngine` saying which engine was
    requested, for which terminal, that it fell back, and why.
  - A terminal that does start on libghostty logs "libghostty engine active for <id>"
    at `.notice`. That line, not the absence of an error, is the evidence that the engine
    engaged.
  - While the flag is on, a terminal built on SwiftTerm, after a switch included, logs
    "SwiftTerm engine active for <id>" at `.notice`. So the latest of these lines for a
    terminal names its engine. With the flag off, a SwiftTerm build logs nothing. A build
    on a libghostty request logs its lines whatever the flag reads, a fallback's two lines
    included: only a libghostty request makes one, and a copy of the flag that briefly
    disagrees with the store must not hide which engine the terminal got.
  - Each change of the flag, including the first read at launch when it is on, logs
    "libghostty engine experiment turned on" or "… turned off" at `.notice`. A terminal
    rebuilt while the flag is off logs no line, so this line says when a terminal's
    latest line may no longer name its engine.
  - `TerminalEngineNotice` holds the words of all of these lines, and the factory tests
    pin them.
- **The flag changes while terminals are open** – it takes effect only when a terminal is
  created. Open terminals keep their engine until they close, or until the per-terminal
  switch below moves them. Mixed engines are safe, because the daemon is always SwiftTerm
  and every handover is VT text. Turning the flag off and reopening terminals is a full
  rollback.
- **A switch fails part way** – if the other engine cannot start, the terminal reattaches
  on SwiftTerm and logs the fallback notice, as at creation. If the detach's handback
  fails, the switch takes the handback failure path above, and the new engine then
  attaches as usual.
- **The handback fails** (the writer throws) – the detach takes today's failure path: no
  preamble, and the daemon heals by the SIGWINCH jiggle. The failure is logged with its
  reason. Like the SwiftTerm writer, the libghostty writer keeps at most
  `HolderHandback.handbackScrollbackLines` lines of scrollback.
- **A crash inside libghostty** – libghostty runs in the app's process, so this is an app
  crash, the same as a crash in SwiftTerm today. Holders keep the sessions, and the daemon
  treats it as a detach with no handback, through the liveness gate that already exists.
  The soak watches crash reports for libghostty frames.
- **Version drift** – the binary is pinned to an exact tag and checksum. A bump is a PR
  that reads the header diff, because a type change behind a `void*` getter is invisible
  to the compiler. The library is linked statically, so no version check runs at runtime.
- **The download fails** – the binary comes from `release.files.ghostty.org` when SwiftPM
  resolves. That is a new network dependency for CI and for `tbd update`. If the download
  fails, the build fails, and no partial engine ever runs.

### Flag and settings

- **Key** – `useGhosttyTerminalEngine` in UserDefaults. The behaviour is app-only, so it
  needs no `config` column, as with `useMetalTerminalRenderer`.
- **Three states** – the key is read as
  `object(forKey:) as? Bool ?? AppState.ghosttyTerminalEngineDefault`. Unset follows the
  default, and an explicit on or off survives any change to the default.
  `ghosttyTerminalEngineDefault` is `false`.
- **Before step 4** – no Settings UI. A developer turns the engine on with
  `defaults write com.github.cheapsteak.tbd useGhosttyTerminalEngine -bool true`, then
  opens new terminals.
- **From step 4** – a toggle in Settings → Terminal → Experimental. Its help text says it
  applies to terminals opened after the change, and it names ligatures and BiDi as known
  gaps. It also says that the Metal toggle affects SwiftTerm terminals only, because
  libghostty always draws with Metal.

### Comparing the engines by feel

The best comparison is the same live session on both engines, flipped back and forth in a
second or two. Two sessions opened at different times differ in content and in load.

- **Switch engine** – a command in the app's terminal commands menu, next to Close Tab,
  with a keyboard shortcut. It acts on the focused terminal, and it appears only while the
  experiment is on, which means the flag is on.
  - It runs the orderly detach, so the current engine hands its snapshot back to the
    daemon. Then it rebuilds the panel on the other engine, which attaches to the same
    session through the ordinary attach path. No new handover code is involved.
  - The choice lives in memory, as a per-terminal override in `AppState`. After a restart,
    every terminal follows the flag again. Nothing is stored, so nothing needs a
    reconciler.
  - It applies to holder panels only. Remote and auth terminals have no handback, so a
    switch would lose their screen. They follow the flag when they are created, and the
    command is disabled on them.
- **Engine label** – while the experiment is on, each terminal's tab shows a small label
  naming its engine ("libghostty" or "SwiftTerm"). That way a comparison is never a guess.

Engines that run side by side also give better numbers. TBD's latency instruments measure
each terminal separately, so two terminals on different engines, measured at the same
time, are a pair under the same load.

### Instruments

- The feed tap, `TerminalLatencyTap` in `TerminalViewHolder.feed`, stays where it is and
  serves both engines.
- The draw tap and `TerminalCommitLatencyProbe` move to the engine's draw-start and
  frame-presented hooks.
  - `SwiftTermEngine` fires them from `viewWillDraw` and `onFramePresented`, as today.
  - `GhosttyEngine` fires draw start when it builds a frame, and frame presented from the
    drawable's presented handler.
- The app's latency refusal reasons are unchanged. The `terminal-latency-probe.py`
  driver has an engine mode (`--swiftterm-terminal`, `--ghostty-terminal`). Its two arms
  are holder terminals, one on each engine, and the samples go to an arm by terminal id.
  Before and after the run, the driver confirms each arm's engine: the flag must be a
  boolean true in the app's own defaults domain, the latest "engine active" line for the
  arm's id must name its engine, and no flag line may follow that line. The driver records
  when it issued each request, and the report places each draw line in a load band by
  that time, so the draw comparison, like the echo one, is band against band. Each
  comparison prints both arms' sample counts, and gives no verdict on a band with fewer
  than ten samples on either arm.

## Testing

- **Contract suite** – one suite that runs once for each engine. It lands with step 1 for
  SwiftTerm, and libghostty must pass it from its first PR. It checks:
  - `feed` from the IO thread while `withScreen` reads
  - snapshot ingest mutes callbacks and drops replies
  - the OSC 7501 reply is written before `feed` returns
  - bell, OSC 52 and OSC 777 reach the delegate
  - the terminal is resized before `sizeChanged` is called
  - `prepareForPreamble` on a reused engine
  - appearance calls take effect
- **Handover corpus** – the proof of concept's 213 states become tests:
  - the SwiftTerm writer read by libghostty: 211 of 213
  - reused libghostty receivers after a reset: 213 of 213
  - the libghostty handback read by SwiftTerm: 210 of 213

  Each test lists its known misses exactly. A new miss fails the test, and so does a
  known miss that stops happening, so the list stays true.
- **Projection** – `ViewerScreenProducer` gives the same text from both engines across the
  corpus.
- **Identity** – both engines give the same DA1, DA2, XTVERSION and OSC 7501 probe
  replies.
- **Gaps:**
  - Ctrl-I, Ctrl-M and Ctrl-[ give Tab, Return and Esc when the program has not asked for
    CSI u, and CSI u when it has. Both branches are tested.
  - The wheel sends arrow keys on an alternate screen with `?1007` set.
  - Powerline glyphs U+E0B0 to U+E0B3 render in an offscreen frame.
  - IME marked text appears in the frame and is replaced when committed.
  - A Kitty graphics query gets no OK.
- **Flag** – with the flag off, the factory builds SwiftTerm. With it on, the factory
  builds libghostty. With an injected init failure, it falls back to SwiftTerm and logs
  the notice. The key's three states are distinguishable. The Settings toggle is absent
  before step 4 and present after it.
- **Switch** – these behaviours are tested:
  - Switching a holder terminal runs the orderly detach with a handback, then attaches
    the other engine to the same session.
  - The override survives a panel rebuild, and it is gone after `AppState` is created
    again.
  - The command is absent while the experiment is off, and disabled on remote and auth
    terminals.
  - A failed engine start during a switch lands on SwiftTerm.
  - The engine label names the engine in use, and it is hidden while the experiment is
    off.
- **No Metal device** – if a CI runner has none, render tests skip with an explicit
  reason. They never pass silently.

## A/B and rollout

**The A/B** runs in step 6, on TBD's existing instruments pointed at both engines. Runs go
A/B/B/A under matched load, and each window is checked to confirm it captured the action
before its numbers count. Where a measure allows it, both engines are measured at the same
time, in side-by-side terminals, as a pair under the same load. SwiftTerm is measured in its default CoreGraphics path and with
the Metal flag on, because libghostty always draws with Metal. The measures are:

- typed echo latency at p90, from `terminal-latency-probe.py`
- the wait of the oldest undrawn chunk, from the `draw` lines
- the time to paint a large stream, about 50 MB sent to a visible terminal, until its last
  frame is presented
- app CPU and memory footprint with 8 and with 24 terminals open

The numbers go into the migration record.

**Rollout:**

- **Graduation** makes libghostty the default by setting `ghosttyTerminalEngineDefault`
  to `true`. It needs all three of these:
  - a clear win: at least 20% at p90 on one measure, repeated in two A/B/B/A runs, with
    no regression beyond noise on the others
  - a soak with no crash that has libghostty frames
  - no open daily-use gap

  Because the key has three states, the change reaches everyone who never set it, and an
  explicit opt-out survives. No migration is needed.
- **A flat A/B** – the engine stays opt-in in Settings → Experimental for users who prefer
  it. TBD then maintains two engines and two handback writers.

## Order of work

Each step is its own PR. Nothing appears in Settings until step 4 is done.

1. **The seam** – the `TerminalEngine` protocol, `SwiftTermEngine`, the factory and the
   contract suite. SwiftTerm only, with no change in behaviour.
2. **libghostty on holder panels** – the `GhosttyVt` binary target, `TBDGhosttyTerminal`,
   `GhosttyTerminalView` with its renderer, and terminal identity. Reachable only through
   the hidden key.
3. **Handback and screen requests** – `GhosttySnapshotWriter`, `GhosttyScreenProjection`,
   the reset before a reused preamble, and the handover corpus tests.
4. **The daily-use gaps**, then the Settings toggle.
5. **Remote and auth terminals** – `LocalPTYTerminalView` builds through the factory.
6. **Instruments for both engines, the Switch engine command and the engine label, then
   the A/B.**

Estimated size, before tests:
- about 9,400 lines of view, renderer and input code adapted from tkzmux
- 1,000 to 2,000 lines for the gaps
- 600 to 1,000 lines for the handback and the projection
- about 200 lines for the seam

## Reclaiming orphans

This design creates no new kind of durable resource: no files, processes, tmux objects,
git refs or database rows. The downloaded xcframework is a build artifact under `.build`.
No reconciler changes.

## Rejected alternatives

- **A separate coordinator for libghostty** – it would leave the SwiftTerm path untouched
  byte for byte. But an estimated 2,000 lines of transport, attach, handback and OSC logic
  would be copied, and every holder fix would be needed twice. With the engine kept as an
  opt-in even after a flat A/B, the two copies would drift for as long as it exists.
- **libghostty inside `TBDTerminalView`** – `TBDTerminalView` subclasses SwiftTerm's
  `TerminalView` and gets selection, IME and mouse handling from it. Swapping its insides
  means wrapping SwiftTerm anyway, which is the seam done in a more invasive way.
- **`TBDTerminalView` adopting the protocol in an extension** – the adapter has to own
  state, because some object must take SwiftTerm's delegate callbacks and pass them on,
  and an extension cannot hold stored properties. Composition also keeps SwiftTerm types
  out of the coordinator, because the compiler sees only `TerminalEngine`.
- **One wide protocol of separate reads** – separate property reads would either race
  `feed` or take the lock many times. One `withScreen` closure states the locking rule in
  the type.
- **No handback and no screen answers on libghostty** – after a detach, the daemon's copy
  would stay frozen at the last attach. A SIGWINCH repaint heals full-screen programs but
  not plain shells. `tbd terminal output` would give stale or no output for attached
  sessions, which breaks agent tooling.
- **libghostty's binary snapshot for the handover** – its format is not covered by the 1.0
  stability promise, and the daemon and the app can run different builds.
- **libghostty in the daemon too** – the holder transport's design keeps one parser,
  SwiftTerm, for the daemon's picture. The viewer can move alone because the handover
  between them is VT text.
