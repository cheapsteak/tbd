# libghostty-vt proof of concept: results

THROWAWAY. This is the verdict on the question in `README.md`. The evidence is in
`check/RESULTS.md` (engine and handover) and `view/RESULTS.md` (window).

"S" is TBD's SwiftTerm fork at `c6b544f8`. "G" is stock libghostty-vt `vt-1.0.0`.

## Verdict

**TBD could replace SwiftTerm with stock libghostty-vt, and the viewer could move
first. The gain does not yet justify the cost on its own.** The check also found real
bugs in TBD's handover, and those are worth fixing whatever happens to the engine.

- **Stock** – yes. The window and the engine check both build from the official
  xcframework, with no fork, no patches and no Zig.
- **Same screen** – mostly. Most of the corpus matches at cell level, and every
  difference has a named cause. Where the engines disagree, S was wrong more often than
  G. A few grapheme cases could not be ruled either way.
- **Handover** – holds at byte level, in the direction that matters most. TBD's
  unmodified writer, read by a fresh G, gives the same screen as a fresh S in 211 of 213
  states. So "the engine changes on both sides or neither" is false as a claim about the
  format. Going back from G to S holds in 210 of 213, but needs a new writer.
- **Speed** – G is 1.1 to 6.3 times faster, and about 4 times on real Claude bytes. That
  is well below the 6 to 21 times another project measured against stock SwiftTerm,
  because TBD's fork is already much faster than stock.
- **Memory** – G uses half of S for idle terminals, which is only about 12 MB per 100
  terminals. One full scrollback is 15% smaller. A host-called compress takes that
  scrollback to under 2 MB, which is the largest gain here, but the cost of reading it
  back was not measured.
- **Real use** – the real `claude` TUI ran in the window with typing, streaming, paste,
  wheel, selection, resize and four instances side by side. Real keystrokes also reached
  a shell through AppKit. Nobody has yet looked at a frame on screen.
- **TBD's signals** – OSC 7501 and the other sequences TBD uses all reach the host.

## What it would cost

- **Code** – about 9,400 lines to own, or about 5,900 lines of code, adapted from
  tkzmux. That is before closing the gaps and before the transport and handover work.
- **Gaps** – an estimated 1,000 to 2,000 more lines. The first to close are Ctrl-I,
  Ctrl-M and Ctrl-[, the wheel in `less` and `vim`, Powerline glyphs, IME composition
  text, and the false `OK` for Kitty images. Ligatures and BiDi are absent.
- **Handover, moving the viewer first** – a host reset before each reused viewer takes
  a preamble, and a new G-side writer for detach. Three orderings need care, and an
  alternate screen needs a snapshot-clone step. These are in `check/RESULTS.md`.
- **Process** – this replaces a load-bearing path, so it needs `/tbd-brainstorming`, a
  committed spec and a default-off flag.
- **ABI** – pin a tag and read each header diff. The compiler cannot see a type change
  behind the `void*` getters, and one such change happened between tkzmux's pin and 1.0.0.

## Bugs in TBD today

None of these need Ghostty to appear. The first and fourth were reproduced by hand
against the source, and the others come from `check/RESULTS.md`.

- **Row shift on reattach** – `TerminalCellWalk.lines` drops every trailing blank row,
  and its comment says "below the cursor", but the loop never looks at the cursor. With
  history present, the replay lands too low and the cursor points at the wrong line.
  This hit 19 of 213 states, including 6 of 24 in a real Claude recording.
- **Background colours lost** – a blank cell with only a background colour is trimmed.
  A coloured alternate screen lost 1,919 cells.
- **Hidden cursor returns** – the writer emits `?25l` before `?1049h`, and SwiftTerm's
  `?1049h` shows the cursor. This hit 47 states.
- **Tabs past column 80** – a SwiftTerm terminal built wider than 80 sends a tab from
  column 88 to the last column, not to 96. The daemon builds its terminal this way
  (`Sources/TBDDaemon/Holder/HolderReader.swift:1413`). The live effect was not observed.
- **Colour lost after 65,535 styles** – in the fork, colours fall back to the default
  once the style table is full.

## Not tested

- **A frame on screen.** The screen was locked for the live run, so the display link
  stopped and an outside capture showed a blank window. Every PNG is an offscreen render.
- **Real mouse events, a real input method, dragging the window edge.**
- **Key-to-paint latency.** No number is claimed.
- **Attach and detach through TBD's real daemon and app.** The handover evidence is at
  byte level only.
- **Long real sessions.** The recordings are three stub turns.

## Run it

From `spikes/libghostty-vt`, with the screen unlocked:

```sh
./fetch.sh
../../scripts/swift-safe build -c release --package-path view
view/.build/release/ghosttyview --cols 110 --rows 34 --option-as-alt left
```
