# Does re-adoption need its own jiggle? A measurement

**This document is a measurement record, not a design.** It reports what a real
`claude` binary writes to a real pty across a grow-by-one geometry jiggle,
a shrink-by-one jiggle, a row jiggle, and no jiggle at all, so that the
question the pty-holder design has left open — whether daemon re-adoption
needs a jiggle of its own, and in which shape — rests on evidence. Its
findings are pinned to one binary at one moment — `claude 2.1.263 (Claude
Code)`, measured 2026-09-06 on macOS 26.1 — and the section on boundaries
names what would change them.

## The question

[`2026-08-30-pty-holder-session-transport-design.md`](2026-08-30-pty-holder-session-transport-design.md)
gives each session a headless emulator that a dedicated reader thread drains
continuously. [`2026-09-01-holder-repaint-measurement.md`](2026-09-01-holder-repaint-measurement.md)
established that Claude Code repaints its whole visible viewport, and only
that, when a jiggle fires — its whole scrollback stays lost regardless.
[`2026-09-05-child-as-contract-party-design.md`](2026-09-05-child-as-contract-party-design.md)'s
"Jiggle scoping" out-of-scope bullet names re-adoption as the one edge on
which the jiggle is load-bearing, because a bare `SIGWINCH` heals nothing on
an Ink-style runtime that only emits a resize event on a real geometry
change — and reserves re-scoping the jiggle to cover that edge for its own
spec.

Reading the code today, that edge carries no jiggle at all. The re-adoption
path — `HolderRegistry.adoptAll` → `beginAdoption` → `take`
(`Sources/TBDDaemon/Holder/HolderRegistry.swift`) — rebuilds the emulator and
starts draining, but never calls `reader.jiggle()`. The only two call sites
are `confirmAttach` (`HolderRegistry.swift:1538`, viewer attach) and
`takeBackFromViewer` (`HolderRegistry.swift:1838`, handback) — both edges the
2026-09-05 spec says the jiggle is redundant on, because a preamble screen
already exists there.

Live, on a session that survived a daemon restart with no jiggle, `terminal.output`
(`source: daemon`) showed a phantom composer line persisting 65+ seconds over
an empty composer, a status bar reduced to the single fragment
`                    4`, and a missing bottom rule. That is consistent with an
emulator that came up blank and has recovered only fragments of what a real
attach would show.

Three questions follow from that observation and from the existing jiggle's
own shape (`HolderReader.jiggle()`: `cols + 1` held for 10 ms, then restored —
the emulator's grid is deliberately never resized, per its doc comment,
because resizing it would reflow contents for nothing and the repaint would
land at a size the grid was never at):

1. Does 2.1.263 repaint its entire visible viewport on a real geometry
   change, and does that hold across more than one jiggle shape?
2. Does the existing shape — a resize the emulator's own grid does not track
   — corrupt the un-resized grid while the child believes it is a different
   width, even if the final state comes out clean?
3. With no jiggle at all, how much of the screen does a blank emulator
   recover on its own, given only ordinary idle traffic?

## Method

The same design as the prior measurement: a Python harness (`pty.fork`) runs
the child on a pty at a known size, drains the master continuously into a
timestamped buffer, and can take a capture boundary at any instant. It is not
committed. The child is driven through `scripts/claude-stub.py`'s fake model
API, so every launch answers with one canned 30-line response carrying unique
marker tokens `ZQM001`…`ZQM030`, at zero token cost.

Four jiggle shapes are compared, all at 24x80:

- **A — grow-by-one, 10 ms** (`cols 80 → 81 → 80`): TBD's exact shape, as
  written in `HolderReader.jiggle()` today.
- **B — shrink-by-one** (`cols 80 → 79 → 80`): the alternative the 2026-09-05
  bullet names — never telling the child a width the grid does not have.
- **C — row jiggle** (`rows 24 → 23 → 24`): a second axis, to check the
  finding isn't a columns-only artifact.
- **D — no jiggle**: the pty sits at 24x80 throughout; only a 15 s wait is
  applied before the capture boundary.

The decisive comparison, as before, is **screen equivalence**:

- **`screen_full`** — a fresh `pyte` emulator, 24x80, fed the whole byte
  stream from launch. What an attached terminal would show.
- **`screen_post`** — a fresh emulator fed only the bytes written after the
  capture boundary (the jiggle's second edge, or the 15 s mark for shape D).
  What TBD's daemon shows after adoption.

Rows differing between the two, and which of the 17 markers then visible in
the viewport (`ZQM014`…`ZQM030`, on a 24-row screen showing the tail of a
30-line answer) survive into `screen_post`, are the measurements reported
below.

For shape A, one further comparison isolates the intra-jiggle window: the
bytes written while the child still believes it is 81 columns are read
into an 80-column emulator that has not moved (the un-resized grid, as the
live daemon would be) and separately into an 81-column emulator (a grid
that tracked the resize). The two are compared against each other and
against `screen_full` to characterize what a reader landing mid-jiggle would
see.

One `pyte` patch was required: 0.8.2 forwards `private=True` into
`select_graphic_rendition` for `CSI ? … m`, and 2.1.263 emits that sequence;
without the patch the parser raises instead of ignoring the private
parameter.

## Instrument validation

Run once at 24x80, shape B, before the subject, over 120 marker lines:

- **Positive control — `vim -u NONE -N`, cursor at end of file.** 1,767 bytes
  written post-jiggle. `screen_post` and `screen_full` were **identical, 0 of
  24 rows differing**, and all 23 markers visible on the final screen were
  reconstructed.
- **Negative control — `bash --noprofile --norc -i`**, after 120 echoed
  marker lines. 12 bytes written post-jiggle. `screen_post` and `screen_full`
  differed on **24 of 24 rows**, and no marker was reconstructed.

The gap between a full reconstruction at 1,767 bytes and a total loss at 12
bytes is the resolution the subject is read against.

## What Claude Code does

**It repaints its entire visible viewport on every geometry change measured,
regardless of shape, and the grow-by-one shape's un-resized-grid window is
real but does not survive to the end of the jiggle.**

**Shape A — grow-by-one, TBD's exact shape. Three launches.**

- A1: whole stream 10,653 B, post-boundary 5,843 B, **0 of 24 rows
  differing**, 17/17 markers, composer row 21 shows `❯`, status row 23 shows
  `  ⏸ manual mode on · ? for shortcuts · ← for agents`, rows 20 and 22 are
  full-width `─` rules. A lockstep emulator resized 81-then-80 in step with
  the tty also reconstructs exactly, 0 differing.
- A2: 10,612 B / 5,816 B post, 0 of 24, 17/17, lockstep 0.
- A3 (kept for the intra-jiggle analysis below): 10,050 B / 5,841 B post, 0
  of 24, 17/17, lockstep 0.

**Shape B — shrink-by-one. Two launches.** B1: 10,618 B / 5,831 B, 0 of 24,
17/17. B2: 10,619 B / 5,831 B, 0 of 24, 17/17.

**Shape C — row jiggle. One launch.** C1: 9,889 B / 5,679 B, 0 of 24, 17/17.

**Shape D — no jiggle. Two launches.** D1: 31 bytes written in the 15 s
window, **22 of 24 rows differing** (the two matching rows are blank in
both screens), 0 of 17 markers present. The 31 bytes are cursor motion and
one erase-to-end-of-line — `ESC[H`, `CR`, `ESC[62C`, `ESC[19B`, `ESC[K`,
`ESC[24;1H`, `ESC[22;3H` — which clears the `● high · /effort` hint and
parks the cursor; they write no content. `screen_post` is 24 empty rows: no
composer, no status bar, nothing. D2 matches: 31 bytes, 22 of 24 differing, 0
markers, blank.

**Alternate screen.** All seven launches entered the alternate screen buffer
— `ESC[?1049h` exactly once, at byte 13, and never followed by
`ESC[?1049l`. (2.1.258, in the prior measurement, took it only on some
launches; 2.1.263 took it on every one measured here.)

**The intra-jiggle window, shape A.** A3's raw stream separates the two
edges. While the child believed it was 81 columns, it wrote 2,908 bytes
carrying all 17 markers. After the restore ioctl at 80 columns, it wrote a
further 2,933 bytes, again carrying all 17 markers — and this second half
alone, fed into a fresh 80-column emulator, reconstructs `screen_full`
exactly, 0 of 24 rows differing.

Read in the middle, between the two ioctls, the un-resized 80-column grid is
corrupt: feeding the 81-wide repaint into an 80-column grid that never
tracked the resize differs from the width-tracking grid on **23 of 24
rows**. The viewport has shifted up one line — `ZQM014` is pushed off the
top — and the two full-width `─` rules wrap at 80 columns, leaving stray
fragments at the left edge: a lone `─` on row 20, and `─ ⏸ manual mode on …`
on row 23. That is the visual shape of the corruption a reader would see if
it landed inside the 10 ms window. All three shape-A launches overwrite it
completely with the second edge.

## What this means for the design

**The fix that ships with this measurement is provenance, not repair.**
`TerminalScreen.contentObserved` stays false for a re-adopted emulator for
its whole life; the hibernation pending-input rail refuses such a screen; and
`tbd terminal output` surfaces the caveat. That holds regardless of what this
measurement found, because even a perfect repaint cannot be verified from the
daemon — codex's dialog screens and shells do not repaint on a jiggle, so
there is no general test the daemon can run to confirm a given repaint
actually happened. A jiggle can repair a screen for a reader; it cannot raise
that screen's provenance.

**On repaint fidelity: the jiggle would work on this edge, in any of the
three shapes measured.** 2.1.263 reconstructs its full visible viewport
after every jiggle shape tried — columns growing, columns shrinking, rows
shrinking — 7 of 7 jiggled launches, 0 of 24 rows differing every time, all
17 on-screen markers recovered every time. Nothing here disqualifies
grow-by-one on repaint grounds; TBD's existing shape reconstructs the screen
exactly by the time the jiggle completes.

**But the un-resized grid is genuinely corrupt while the jiggle is in
flight, and re-adoption is exactly the edge where that matters most.** For
roughly the 10 ms the tty sits one column wider than the grid, the grid holds
a shifted, wrapped, wrong screen — 23 of 24 rows off, content pushed up,
rules fragmented. On the attach and handback edges the existing jiggle
already covers, that window is harmless: a preamble screen already exists,
so nobody reads the emulator mid-flight. Re-adoption has no such preamble —
the emulator is empty until the jiggle runs, so a read that lands inside the
window, or a jiggle whose restore edge is lost or coalesced (a live 221-cell
row in a 220-column pty has been observed on this codebase), leaves exactly
the shifted-and-fragmented screen this measurement produced, not a blank
one.

**With no jiggle, a re-adopted emulator does not fill itself in.** An idle
TUI writes essentially nothing on its own — 31 bytes of cursor motion and one
erase in 15 s, no content, 22 of 24 rows staying wrong. A re-adopted session
recovers nothing until the user types, and then only whatever the child
paints differentially from there — which is the mixed stale/blank/correct
screen the live daemon showed.

**Together, these point at a jiggle on re-adoption in a shape that never
puts the grid at a size it is not** — shrink-by-one, or resizing the grid in
lockstep with the tty across both edges, either of which removes the
corrupt-window risk at no cost measured here (shapes B and C reconstructed
the screen exactly, same as A). That re-scoping is what the 2026-09-05
spec's "Jiggle scoping" bullet reserves for its own spec; this measurement is
the evidence it asked for.

## Boundaries

- **One binary, one day.** `claude 2.1.263`, 2026-09-06. The behavior is a
  property of that release, not a contract; the prior measurement's binary,
  2.1.258, differed on how consistently it entered the alternate screen.
- **Uneven repetition.** Shapes A and B ran three and two launches; C and D
  ran one and two. The 7/7 and 0-of-24 figures above are exact for what ran,
  not a claim of a larger sample.
- **Every jiggle landed on an idle composer with a finished answer.** No
  trial jiggled mid-stream, during a permission prompt, or during a modal —
  the prior measurement's codex finding, that a modal state inside a
  repainting TUI can itself fail to repaint, is the standing warning for
  those states here too.
- **Rendered characters only, not attributes.** The comparison is over
  `pyte`'s screen text. Colors, styles, and cursor shape were not compared.
- **Direct pty harness, not the daemon.** Everything here runs `pyte`
  against a raw pty. `HolderReader.jiggle()`, `HolderRegistry.adoptAll`, and
  SwiftTerm's own emulator were not exercised end to end; the un-resized-grid
  finding is read from a `pyte` grid built to mimic SwiftTerm's stated
  behavior (resize the tty, leave the grid alone), not from SwiftTerm itself.
- **The fake model API.** The answer content, its 30-line length, and its
  timing are all canned by `scripts/claude-stub.py`; a real model's streaming
  cadence, and what a jiggle catches mid-stream, are unmeasured.
