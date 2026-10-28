# Terminal engine: SwiftTerm or libghostty

*Evidence record gathered 2026-10-28, the day after Ghostty 1.4.0 shipped,
against TBD at `8655b7c11`. Sources are Ghostty's release notes, its
maintainer's public statements, the repositories and write-ups of projects that
embed libghostty, and TBD's own tree. Statements carrying a date are evidence
about that date. The record makes a recommendation; it changes no behavior.*

## Answer

Stay on SwiftTerm, and reopen the question when both of these are true:

1. **libghostty 1.0 is tagged with declared ABI stability.**
2. **The Ghostty project publishes a Swift renderer package for
   `libghostty-vt`.**

Neither is true on 2026-10-28. Until both are, every route to libghostty costs
either a fork of Ghostty or a renderer TBD writes itself, and the performance
problem that first raised the question turned out not to live in the engine.
Once both are true, the cost falls to a trial behind a default-off flag. The
move still has to cover the daemon's headless emulator and the app's viewer
together, for the reason given under "Two emulators, one snapshot format".

## Two embedding surfaces

Ghostty exposes two C APIs. Whether a claim about "libghostty" holds depends on
which one it is about.

- **`ghostty.h`** – the whole terminal, renderer included. A surface spawns its
  own process: its input is keys, mouse and IME, and no call writes externally
  read bytes into it. Ghostty marked this API as not for external embedding on
  2026-08-10, and the 1.4.0 notes do not revisit that. The Swift packages that
  feed bytes into a `ghostty.h` surface do it by patching Ghostty's Zig source:
  `Lakr233/libghostty-spm` adds a `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED`
  backend from its `Patches/ghostty/` directory, and
  `termio-sh/libghostty-swift` carries an equivalent host-managed IO patch.
- **`libghostty-vt`** – the supported API. `ghostty_terminal_vt_write` takes
  bytes, a terminal is created with no command and no pty, and the library
  ships render state (dirty rows, for a renderer the embedder writes),
  snapshots, selection, key and mouse encoders, and a formatter that writes a
  screen back out as plain text, HTML or VT. Ghostty's CI publishes it as an
  xcframework, so no Zig toolchain is needed to consume it. It contains no
  renderer: upstream declined on 2026-05-12 to ship one inside it. The Swift
  renderer announced on 2026-07-02 is a separate package (see "Ghostty on
  2026-10-28").

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
(`Config.ptyHolderDefault`), so an engine is no longer ruled out for expecting
to own the pty or for being unable to speak to a tmux client.

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

## Why TBD has stayed on SwiftTerm

- **Every route to libghostty costs a fork or a renderer.** `ghostty.h` cannot
  be fed bytes without patching Ghostty. `libghostty-vt` can, but leaves TBD to
  write a Metal or CoreText renderer and the view work around it: keyboard and
  IME input, selection, mouse, scrolling and accessibility.
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
  gathered on 2026-08-25 from those projects' own trackers, except where
  another date is given:
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

## Ghostty on 2026-10-28

**The library, per the 1.4.0 release notes (2026-10-27).** libghostty "isn't
directly part of the Ghostty 1.4 release", but:

- "Over the past 6 months, the C API for libghostty-vt has grown from a parser
  and a few encoders into a complete terminal emulator API, adopted by dozens
  of free and commercial terminal emulators used by millions of people."
- "There's CMake support, Nix packaging, an xcframework, and a source tarball,
  in addition to the existing pkg-config file."
- "The API is still marked as a work in progress and broke compatibility
  several times during this cycle, so expect more breaking changes before a
  tagged release."
- "We're going to do a final pass over the C API, break ABI one more time, and
  then likely tag a libghostty 1.0 release very soon."
- "During the last release cycle, I said I aimed to tag a libghostty release.
  We haven't done that yet, but I'm confident we will do so before Ghostty
  1.5." Ghostty 1.5 "is planned for March 2027", and "libghostty will have a
  separate release cycle."
- libghostty parses the Program Status Protocol (OSC 7501), "the first terminal
  specification pioneered by the Ghostty project", which the Ghostty GUI
  ignores for now. TBD implements it already
  (`docs/specs/2026-10-10-program-status-protocol-design.md`).

**The maintainer, on Hacker News the same day:**

- "I plan on tagging libghostty 1.0 in the next few months and declaring ABI
  stability at that point!"
- "a single empty terminal now takes 90% less memory. And at scale I've proven
  10,000 active (input/output happening) terminals on a Linux server with 4
  cores and 8 GB of RAM."
- Named adopters: every JetBrains IDE terminal, the agentic terminals Herdr and
  cmux, the Emacs terminal Ghostel, and a Neovim pull request (#39773) that
  "has been verbally accepted" to replace Neovim's terminal core.

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
No package or repository for it was found on 2026-10-28, under `ghostty-org` or
elsewhere.

**Third-party Swift packages, all pre-1.0:**

- **`Lakr233/libghostty-spm`** – `ghostty.h` with patches, including the
  host-managed IO backend. Releases weekly with Ghostty pinned to upstream
  `main`. Tags `1.4.0` through `1.4.13` and `1.5.0` were withdrawn.
- **`Aqothy/ghost-swiftly`** – unpatched `libghostty-vt` with a Swift port of
  Ghostty's Metal and CoreText renderer. No tags.
- **`caelyreth/libghostty-vt-spm`** – a `libghostty-vt` wrapper that returns
  incremental frames for a host-written renderer.

## When the triggers might fire

These are estimates.

- **libghostty 1.0** – most likely January to April 2027. The stated targets
  are "in the next few months" and "before Ghostty 1.5" (March 2027), and the
  remaining work is bounded: one API pass, one ABI break, a tag. Against that,
  the 1.3.0 notes (2026-03-09) already made "stabilizing and tagging a
  libghostty release" the short-term focus and said "we hope to have a release
  soon!", and 1.4 shipped a month behind its September plan with no tag.
- **The Swift renderer** – most likely with 1.0 or after it. It has no stated
  date, and its bindings sit on a C API that is due one more ABI break, so
  shipping before that break would mean redoing them.

## When both triggers fire

- **Spec and flag** – replacing the terminal engine replaces a load-bearing
  path, so it starts with `/tbd-brainstorming` and ships behind a default-off
  flag.
- **First trial** – put both the daemon's reader and one viewer on
  `libghostty-vt` in a scratch build, replay recorded sessions through both,
  and compare the screens on attach and detach.
- **What has to move** – `TerminalSnapshotWriter` and `SGREncoder`, or their
  replacement by libghostty's VT formatter; the mode readings that holder
  sends depend on; the OSC 7501 probe and reports; OSC 9;4 suppression; mouse
  reporting, including the Option-drag bypass; selection; and every
  `withTerminal` read in `TBDTerminalView`.
- **The pager** – check that the renderer releases GPU resources for hidden
  views. The 1.4 GUI does; a Swift renderer package may not.

## One check worth running sooner

Feed the same recorded sessions to SwiftTerm and to `libghostty-vt`, and diff
the VT that each one's formatter writes. That tests `TerminalSnapshotWriter`
against an independent VT implementation, a check TBD cannot run today, and it
is useful whether or not the engine ever changes. While it pins a nightly
artifact, it belongs in a one-off script rather than in CI.

## Sources

- Ghostty 1.4.0 release notes – https://ghostty.org/docs/install/release-notes/1-4-0
- Ghostty 1.3.0 release notes – https://ghostty.org/docs/install/release-notes/1-3-0
- The maintainer's comment on the 1.4 Hacker News thread – https://news.ycombinator.com/item?id=50262760
- The Swift renderer announcement – https://x.com/mitchellh/status/2072724957902381319
- libghostty documentation – https://libghostty.tip.ghostty.org/
- "What it takes to embed libghostty in a Swift app: six months of lessons" – https://dev.to/yuu1ch13/what-it-takes-to-embed-libghostty-in-a-swift-app-six-months-of-lessons-1m64
- `Lakr233/libghostty-spm` – https://github.com/Lakr233/libghostty-spm
- `Aqothy/ghost-swiftly` – https://github.com/Aqothy/ghost-swiftly
- `caelyreth/libghostty-vt-spm` – https://swiftpackageregistry.com/caelyreth/libghostty-vt-spm
- `termio-sh/libghostty-swift` – https://github.com/termio-sh/libghostty-swift
