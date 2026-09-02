# Does the jiggle repaint Claude Code? A measurement

**This document is a measurement record, not a design.** It reports what a real
`claude` binary wrote to a real pty when its window size changed, so that the
pty-holder design's scrollback decision rests on evidence rather than on an
assumption about how Ink renders. Its findings are pinned to one binary at one
moment — `claude 2.1.258 (Claude Code)`, measured 2026-09-01 on macOS 26.1 —
and the section on boundaries names what would change them.

## The question

[`2026-08-30-pty-holder-session-transport-design.md`](2026-08-30-pty-holder-session-transport-design.md)
replaces tmux with per-session pty holders. The daemon runs a headless
SwiftTerm emulator per session and drains the pty into it. That emulator's
scrollback is bounded, in memory, and never written to disk, so **a daemon
restart re-adopts the live pty with an empty emulator** — every line the
session had produced is gone from the daemon's copy.

The design's whole mitigation is *the jiggle*: at every reader-handoff edge,
including daemon re-adoption, nudge the tty size and put it back, forcing a
SIGWINCH so that full-screen programs repaint themselves into the fresh
emulator. iTerm2 does the same thing when it adopts an orphaned session.

Nobody had measured whether the one program that matters actually repaints.
The worry was concrete and plausible: Ink-based TUIs write their "static"
region to the terminal once and re-render only the dynamic region afterwards.
If Claude Code did that, a restarted detached session would show a composer and
a spinner with nothing above them, permanently, and "bounded, in-memory,
unpersisted" would be the wrong call.

So: **on SIGWINCH, does Claude Code rewrite only its composer, its whole
visible screen, or its whole history?**

## Method

A Python harness (`pty.fork`) runs the child on a pty at a known size, drains
the master continuously into a timestamped buffer, and can take a capture
boundary at any instant. A jiggle is two `TIOCSWINSZ` calls — away, then back —
with the bytes written after each edge captured separately.

The decisive comparison is a **screen-equivalence test**, which is the daemon
restart in miniature:

- **`screen_full`** — a fresh emulator fed the *whole* byte stream. This is what
  a terminal that had been attached the entire time shows.
- **`screen_post`** — a fresh emulator fed *only* the bytes the child wrote in
  response to the jiggle. This is what TBD's daemon shows after it restarts,
  re-adopts the pty, and jiggles.

If the two screens are identical, the jiggle reconstructs the terminal state
exactly and the restart loses nothing that was on screen. If they differ, the
difference is precisely what a restarted session loses. Both emulators are
`pyte` at the session's geometry; markers are unique greppable tokens so the
raw byte stream can be searched independently of any rendering.

A second measurement uses a scrollback-keeping emulator on the same stream to
count how many lines went *above* the viewport, which is the part no repaint
can reach.

## Instrument validation

Both controls were run before the subject, at 40x100, over 120 marker lines,
with the jiggle being rows 40 → 39 → 40.

- **Positive control — `vim -u NONE -N`, cursor at end of file.** The child
  wrote **1,441 bytes** in response to the jiggle. `screen_post` and
  `screen_full` were **identical, 0 of 40 rows differing**. The three markers
  visible on the final screen (`ZQV090`, `ZQV119`, `ZQV120`) were all present in
  the post-jiggle bytes; the four that had scrolled past the top of the file's
  visible window (`ZQV001`, `ZQV002`, `ZQV030`, `ZQV060`) were absent from them.
  The instrument detects a full-screen repaint.
- **Negative control — `bash --noprofile --norc -i`** after printing 120 marker
  lines. The child wrote **28 bytes** in response to the jiggle — readline's
  `\r ESC[K` plus a redrawn prompt. `screen_post` and `screen_full` differed on
  **40 of 40 rows**, and not one marker was reconstructed. The instrument does
  not manufacture a repaint where none happened.

The gap between 1,441 bytes with a perfect reconstruction and 28 bytes with a
total loss is the resolution the subject is read against.

## What Claude Code does

**It repaints its entire visible screen, and none of its scrollback.** Every
trial reconstructed the viewport exactly; every trial lost everything above it.

**Trial 1 — four jiggle shapes, 40x100, a 30-line answer.** The bytes written
after each resize edge were captured separately, and every one of the 30
`ZQMARKA` tokens then on screen was re-emitted at each edge:

- rows 40 → 39 → 40: **3,604 bytes**, 30 markers per edge
- columns 100 → 99 → 100: **3,598 bytes**, 30 markers per edge
- rows 40 → 20 → 40: **1,452 bytes** shrinking (12 markers — exactly what fits in
  20 rows), **1,802 bytes** growing back (30 markers)
- 40x100 → 20x50 → 40x100: **982 bytes** away, **1,802 bytes** back

In all four, the user's own prompt line — which had scrolled off the top —
appeared **zero** times. The repaint is bounded by the viewport, not by the
conversation.

**Trial 2 — screen equivalence, 40x100, a 120-line answer.** Whole stream
19,162 bytes; post-jiggle **3,421 bytes**. `screen_post` and `screen_full` were
**identical, 0 of 40 rows differing**. Markers `ZQC090`, `ZQC119`, `ZQC120` were
on both screens. `ZQC001`, `ZQC002`, `ZQC030`, `ZQC060` were in the full stream
(the first at byte 9,331) and in **neither** screen and **not** in the repaint.

**Trial 3 — a different geometry, 24x80, a 100-line answer.** Whole stream
17,498 bytes; post-jiggle **2,697 bytes**; identical, 0 of 24 rows differing.
The result is not an artifact of one window size.

**Trial 4 — how much went into scrollback.** The same 120-line experiment, read
with a scrollback-keeping emulator: **98 lines had been pushed above the
viewport**, carrying `ZQD001`, `ZQD002`, `ZQD030`, `ZQD060`. The post-jiggle
capture was **4,021 bytes** and contained only `ZQD090`, `ZQD119`, `ZQD120` —
the viewport. Screens identical, 0 of 40 rows differing. This is the loss stated
in lines: 98 lines gone, 40 recovered.

**Repeatability.** Six further launches that sent no prompt at all — three direct
at 40x100, one direct at 24x80, one through an interactive bash after 60 lines
of shell output, one through bash with no prior output — all reconstructed the
screen exactly (0 differing rows) on post-jiggle captures of 1,705 to 2,132
bytes. Ten out of ten jiggles across all trials reconstructed the viewport with
zero differing rows.

### The alternate screen buffer, and why it changes the size of the loss

Claude Code 2.1.258 **sometimes enters the alternate screen buffer** and
sometimes does not. Across 33 captures, `ESC[?1049h` appears in exactly those
runs that also played the animated startup logo, is emitted once near byte 67,
and is never followed by `ESC[?1049l` — so a run that plays the animation spends
its entire life in the alternate buffer, and a run that does not never enters it.
Six consecutive launches in one sitting all skipped it; three earlier ones took
it.

This matters because SwiftTerm's alternate buffer is constructed with
`scrollback: nil` and is permanently `hasScrollback == false`
(`Terminal.swift`, the `altBuffer` initializer). The consequence:

- **In an alternate-screen run there is no scrollback to lose.** The only durable
  terminal state is the visible screen, and the jiggle regenerates it exactly.
  A daemon restart costs such a session *nothing*.
- **In an ordinary run the scrollback is real and it is lost.** Trial 4 measured
  98 lines of it after a single answer.

Which mode a given session is in is not TBD's to choose, and it is not stable
across launches of the same binary.

## The other agent: codex

Measured on `codex 0.145.0`, same harness, 40x100. Codex **never** enters the
alternate screen buffer in any capture. Its main TUI repaints in full: **5,802
bytes** post-jiggle, screens **identical, 0 of 40 rows differing**. Its startup
*dialog* screens do not: on the update prompt and the directory-trust prompt the
jiggle drew **1,554 bytes** and left **7 of 40 rows blank** in the
reconstruction — the dialog text did not come back.

That last observation is the one to keep. A full-screen TUI is not uniformly a
full-screen repainter; a modal state inside it can be static text that a resize
does not redraw.

## What this means for the design

**The feared failure does not happen.** The premise that Claude Code writes
history once and repaints only its dynamic region is refuted for 2.1.258. A
detached Claude Code session that survives a daemon restart does not come back
as a composer over a void. It comes back with its full visible screen, byte for
byte, for the price of two to six kilobytes of repaint. On the axis the design
was most worried about, the jiggle works, and it works for the program the
product is built around.

**The loss the design already admits is the loss that is real.** Everything
above the viewport is gone and no jiggle will bring it back — 98 lines in one
short trial, and in a working session the entire earlier conversation. The
spec's own sentence, that the jiggle "heals screen *state*; it cannot recover
missing history and does nothing for scrolled-away output," is exactly right,
and this measurement puts a number on both halves rather than softening either.

**For shell sessions the jiggle buys nothing at all.** Twenty-eight bytes, forty
rows of difference, no markers. A holder-backed shell that outlives a daemon
restart is a blank screen with a prompt, and unlike an agent session it has no
transcript to fall back on. That is the case that stays unmitigated, and it is
worth being plain that it is a shell problem rather than a general one.

**So the durability question narrows.** It is no longer "do we owe sessions a
persisted screen" — the screen reconstructs itself. It is "do we owe sessions
persisted *scrollback*, given that agent sessions already have a durable
transcript on disk and shell sessions have nothing." Bounded, in-memory,
unpersisted emulator scrollback is a defensible answer for agent sessions on
this evidence. It is a weaker answer for shells, and nothing measured here makes
that weaker answer better.

**The jiggle's cost at fleet scale is small.** Observed repaints ran 1.7 KB to
5.8 KB per session. At the design's ~150 resident emulators, a daemon restart
that jiggles everything moves on the order of a quarter to one megabyte in
total — not a reason to jiggle selectively.

## Boundaries

- **One binary, one day.** `claude 2.1.258`, 2026-09-01. The behavior is a
  property of that release, not a contract. Earlier releases may well behave as
  the Ink hypothesis predicted, and a future release could regress to it without
  notice. If the jiggle is load-bearing, this measurement wants a cheap repeat
  against each `claude` upgrade rather than a one-time answer.
- **Not run through TBD.** Everything here is a direct pty harness with `pyte` as
  the emulator. The daemon path — `pty_holder_enabled`, holder adoption
  rebuilding the emulator at the pty's real geometry, the jiggle at the
  reader-handoff edge, and what `terminal.output` then returns — was not
  exercised end to end. The alternate-buffer claim in particular is read from
  SwiftTerm's source rather than observed in a running daemon.
- **Jiggles landed on an idle process.** Every capture jiggled a session sitting
  at its composer. A jiggle arriving mid-stream, during a permission prompt,
  during a subagent panel, or while a diff is being rendered was not measured —
  and codex's dialog screens showed that a modal state inside a repainting TUI
  can fail to repaint. The equivalent Claude Code states are untested.
- **Two programs.** Claude Code and codex, plus `vim` and `bash` as instruments.
  Anything else a session might be running — a pager, a REPL, a build tail, an
  interactive `git` — is unmeasured, and `bash` is the warning that
  non-full-screen programs recover nothing.
- **Screen equality, not attribute equality.** The comparison is over rendered
  characters. Colors, styles, and cursor shape were not compared, so a repaint
  that restored text but lost attributes would read here as identical.
- **The alternate-screen trigger is not understood.** It correlates perfectly
  with the startup animation across 33 captures, but why the animation plays on
  some launches and not others was not determined, so it cannot be predicted or
  relied on.
