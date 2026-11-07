# Terminal engine: SwiftTerm or libghostty

*Evidence record gathered 2026-11-06, the day `libghostty-vt` 1.0.0 was tagged,
against TBD at `43a009132`. Sources are the library's announcement, its
documentation and headers at the `vt-1.0.0` tag, Ghostty's release notes, its
maintainer's public statements, the repositories and write-ups of projects that
embed libghostty, and TBD's own tree. Statements carrying a date are evidence
about that date. The record makes a recommendation; it changes no behavior.
Companion record:
[`docs/perf/2026-08-25-terminal-engine-options.md`](../perf/2026-08-25-terminal-engine-options.md),
which surveys the same options as of 2026-08-25 in more depth, including prior
art and migration paths this record only summarizes.*

## Answer

Stay on SwiftTerm, and reopen the question when the Ghostty project publishes a
Swift renderer package for `libghostty-vt`.

A move needs two things, and one of them exists:

1. **A stable library – met.** `libghostty-vt` 1.0.0 was tagged on 2026-11-06
   with a declared ABI promise.
2. **A Swift renderer from the Ghostty project – not met.** No package was found
   on 2026-11-06, and the 1.0 announcement does not mention one.

Until the second is true, every route to libghostty costs either a fork of
Ghostty or a renderer TBD writes itself, and the performance problem that first
raised the question turned out not to live in the engine. Once it is true, the
cost falls to a trial behind a default-off flag. The move still has to cover the
daemon's headless emulator and the app's viewer together, for the reason given
under "Two emulators, one snapshot format".

TBD has written no code toward the move ("What TBD has in place"). One check is
worth running either way ("One check worth running sooner").

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
reader agree by construction.

Moving only the viewer would put two VT implementations on either side of that
format, and their disagreements would show up as screens that change on attach
or detach. The holder transport design
(`docs/specs/2026-08-30-pty-holder-session-transport-design.md`) rejects a
third-party headless VT for the daemon for this reason, and the argument runs
the other way too: the engine changes on both sides or on neither.

`libghostty-vt` fits the daemon's side with no renderer at all. The renderer is
the cost of the viewer's side alone.

Its binary snapshots look like a natural replacement for the preamble. A
snapshot holds the terminal's complete state, including unfinished parser input
and scrollback, and can restore in pieces so a viewer draws before old history
arrives. The ABI promise excludes them, though: the snapshot functions are part
of the C ABI, "but the bytes they produce and accept may change in any release",
and "Snapshot format version 1 is a work in progress and doesn't carry a
binary-compatibility guarantee."

The daemon and the app can run different builds, because `scripts/restart.sh
--app` restarts only the app, from whatever binary is on disk. A static library
ties each build to its own version, so a binary snapshot could reach a build
that cannot read it. The preamble therefore stays VT text unless a spec designs
a fallback. The VT formatter is the candidate, and its header describes it as
covering "a terminal's active screen" without saying whether that includes
scrollback, which a trial has to establish.

## What TBD has in place

Research, and no code. Measured at `43a009132`:

- **No engine boundary** – 17 source files import SwiftTerm, 9,963 lines in all,
  as do 32 test files. `withTerminal` appears 21 times, 12 of them in
  `TBDTerminalView.swift`. No protocol separates the engine from its callers.
- **No flag** – nothing gates an engine change. `useMetalTerminalRenderer`
  chooses a renderer inside SwiftTerm only.
- **No recorded sessions** – the tree holds no recorded pty byte streams, and
  both the first trial and the check below need them.
- **No comparison** – the check under "One check worth running sooner" has not
  been run.

## Why TBD has stayed on SwiftTerm

- **Every route to libghostty costs a fork or a renderer.** `ghostty.h` cannot
  be fed bytes without patching Ghostty. `libghostty-vt` can, but leaves TBD to
  write a Metal or CoreText renderer and the view work around it: keyboard and
  IME input, selection, mouse, scrolling and accessibility.
  `Aqothy/ghost-swiftly` shows the scale: its Swift port of Ghostty's renderer,
  with its views and bindings, is about 520 KB of source before bundled fonts,
  some of it generated tables.
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
  callback, and the terminal stores none of them. TBD implements the protocol
  already (`docs/specs/2026-10-10-program-status-protocol-design.md`). The
  headers read do not say whether the library answers the support query itself,
  so a trial has to test it.
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

If it never ships, the alternative is a renderer TBD writes on `render.h`, path
B in the companion record. That would be a new decision needing its own motive,
since performance is not one.

## When the renderer ships

- **Spec and flag** – replacing the terminal engine replaces a load-bearing
  path, so it starts with `/tbd-brainstorming` and ships behind a default-off
  flag.
- **The package itself** – check its licence, its version pin against
  `libghostty-vt`, and what it covers of IME, selection, scrolling and
  accessibility.
- **Engine boundary** – add one first. The companion record describes a
  runtime-switchable dual backend of about 240 lines in another project.
- **First trial** – put both the daemon's reader and one viewer on
  `libghostty-vt` in a scratch build, replay recorded sessions through both,
  and compare the screens on attach and detach.
- **What has to move** – `TerminalSnapshotWriter` and `SGREncoder`, or their
  replacement by libghostty's VT formatter; the mode readings that holder
  sends depend on; the OSC 7501 probe and reports; OSC 9;4 suppression; mouse
  reporting, including the Option-drag bypass; selection; and every
  `withTerminal` read in `TBDTerminalView`.
- **Images** – decide whether losing Sixel and iTerm2 inline images is
  acceptable.
- **The pager** – check that the renderer releases GPU resources for hidden
  views. The 1.4 GUI does; a Swift renderer package may not.

## One check worth running sooner

Feed the same recorded sessions to SwiftTerm and to `libghostty-vt`, and diff
the VT that each one's formatter writes. That tests `TerminalSnapshotWriter`
against an independent VT implementation, a check TBD cannot run today, and it
is useful whether or not the engine ever changes.

`vt-1.0.0` gives the check a stable version to pin. It starts by capturing the
sessions, because the tree holds none. It belongs in a one-off script, because
adding a binary dependency to `Package.swift` for one check is a separate
decision.

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
