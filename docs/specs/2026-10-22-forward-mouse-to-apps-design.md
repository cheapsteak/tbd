# Forward the mouse to apps that ask for it

## Summary

When a program in a TBD terminal turns on mouse reporting, TBD should give
that program the mouse, the way iTerm2 does. A plain click or drag reaches the
program, and the program does its own selection and copy. Option-drag or
Shift-drag bypasses the program and selects text in TBD, as today. The
behavior ships behind a default-off Settings toggle, applies to terminals on
the pty-holder transport, and leaves the scroll wheel on TBD's own path.

## Why

Fullscreen agent TUIs take the mouse and handle selection themselves. Claude
Code in fullscreen mode turns on modes 1000, 1002, 1003 and 1006 (any-event
tracking with SGR encoding) as it starts. Sent a press, a drag and a release
over its transcript — the bytes a terminal with mouse reporting on would
send — it highlights the range and copies the text to the clipboard with an
OSC 52 write. Measured against the real CLI through `scripts/claude-stub.py`:
the drag produced 1,145 bytes of repaint and one OSC 52 write carrying the
selected lines.

TBD does not hand the mouse over. `TerminalPanelView` sets
`allowMouseReporting = false` on every panel, so a drag over a fullscreen
agent runs SwiftTerm's local selection and the agent never sees it. TBD then
forwards two things by hand: single clicks (a synthesized press and release at
mouse-up, `TBDTerminalView.handleClickPassthrough`) and the scroll wheel (the
panel's local monitor and `ScrollWheelAccumulator`). People who use iTerm2
expect the opposite default: a plain drag belongs to the program, and a
modifier gets the terminal's selection.

## Behavior

Everything below applies only while the toggle is on, with one exception.
Remote-attach terminals report the mouse whatever the toggle says, so the
rule that a Cmd press never reaches a program holding the mouse (see "What
stays TBD's") applies there with the toggle off too. There it also closes an
orphan press: left to itself, SwiftTerm reports the press of a Cmd+click on
an OSC 8 link, opens the link on release and returns before reporting the
release, leaving the program a press with no release. Apart from that rule,
with the toggle off TBD behaves as it does without this design.

### Which terminals

- **Holder-transport panels** – `TerminalPanelView` panels whose terminal has
  `transport == .holder` set `allowMouseReporting = true`. SwiftTerm then
  reports clicks, drags and releases to the program whenever the program has
  turned a mouse mode on. When no mouse mode is on — a plain shell prompt —
  SwiftTerm keeps doing local selection, so nothing changes there.
- **Tmux-backed panels** – keep `allowMouseReporting = false`. The daemon runs
  `set -g mouse on` on every tmux server (`TmuxManager.swift`), so tmux holds a
  mouse mode permanently. Handing it the mouse would turn every drag into tmux
  copy mode rather than reach the program inside, and that transport is being
  removed.
- **Remote-attach terminals** – `LocalPTYTerminalView` already runs with
  `allowMouseReporting = true`. It gains the Option bypass under the same
  toggle, so both terminal surfaces honor the same modifiers, and the Cmd rule
  in "What stays TBD's" whatever the toggle says. This terminal has no wheel
  monitor, so its wheel goes through SwiftTerm's `scrollWheel`, and the bypass
  applies there too: an Option-modified wheel, like a Shift-modified one, over
  a program holding the mouse is not reported, and on the alternate screen
  with alternate scroll mode (DECSET 1007, on by default) set, SwiftTerm
  turns it into Up/Down arrow keys, as it does for a full-screen program that
  never turned a mouse mode on (`Terminal.alternateScrollMode`). Panels never
  reach that path: their monitor claims the wheel first.
- **Any program** that turns a mouse mode on gets the mouse: fullscreen
  Claude, Codex, vim with `mouse=a`, htop, lazygit. TBD does not special-case
  agents.

### The bypass: Option and Shift

Option-drag and Shift-drag never reach the program. They run TBD's own
selection, and Cmd+C copies it.

- **Shift** is SwiftTerm's existing bypass (`shiftBypassesMouseReportingLocked`),
  the xterm and kitty convention. It stands down when the program asks to
  receive Shift-modified events (`mouseShiftCapture`, XTSHIFTESCAPE), as it
  does today.
- **Option** is the iTerm2 convention. SwiftTerm gains it as a host setting,
  `optionBypassesMouseReporting`, off by default, checked in the same
  predicate as Shift. TBD turns it on with the toggle.

A program loses Option- and Shift-modified mouse events while the toggle is
on. Each is already withheld by a widely used terminal — Option by iTerm2,
Shift by xterm, kitty and SwiftTerm itself — so a program that depends on
either already fails somewhere.

**Known limit: the bypass is decided per event, not per gesture.** SwiftTerm
reads the modifiers afresh on each press, drag and release. Letting go of
Option or Shift before the mouse button sends the program a release it never
saw pressed, plus the drag motion after the key came up under modes 1002 and
1003. Pressing Option or Shift after a plain press leaves the program a press
with no release. Closing it means latching the bypass decision at mouse-down,
and it is to be closed before graduation.

### What stays TBD's

A press with Cmd held belongs to TBD. Cmd is TBD's modifier for opening paths
and links, and SGR mouse encoding has no bit for it, so a Cmd press forwarded
to a program would reach it as a plain click. While a program holds the mouse
— reporting on, and a mouse mode on — `TBDTerminalView.mouseDown` keeps every
Cmd-modified press from SwiftTerm's reporting: no press, no drag motion and no
release reaches the program. The rule lives in `TBDTerminalView`, so it holds
for remote-attach terminals too. With reporting off, a Cmd press goes to
SwiftTerm's local handling, which never reports it. The click passthrough
withholds a release that still carries Cmd, but it reads the modifiers at
release, so a Cmd press whose Cmd is let go before the button reaches the
program as a plain click — behavior this design leaves as it is.

- **Cmd+click on a path** – `TBDTerminalView.mouseDown` opens it
  (`handleCommandClick`) and consumes the press.
- **Cmd+click on a link** – an OSC 8 hyperlink, or a URL SwiftTerm detects in
  the text, opens on release. TBD hands the release of a withheld Cmd press
  to SwiftTerm's mouse-up with reporting suppressed for that one synchronous
  call. SwiftTerm decides whether a link is under the pointer with its own hit
  math and highlight mode (`linkForClick`) and opens it, and, suppressed, it
  cannot report the release either way: a Cmd release that opens
  nothing — Cmd let go before the button, plain text — sends the program
  nothing. TBD's own cell math is no substitute for SwiftTerm's: SwiftTerm
  snaps its cell width to device pixels and TBD's mirror
  (`TBDTerminalView.cellDimensions`) does not, so past a few dozen columns the
  two disagree by a cell or more. The suppression wraps that one call and
  nothing else; the click passthrough, which also reads
  `allowMouseReporting`, never runs inside it.
- **Cmd-drag** – the release is consumed in TBD. SwiftTerm was never handed
  the drag, so its mouse-up would open a link the drag ended on.
- **The window-activating click** – consumed in `mouseDown`, unless it is a
  Cmd+click on an OSC 8 link, which opens on release like any other.
- **File drag-and-drop**, find, and paste – separate AppKit paths.

### The scroll wheel

The wheel stays on TBD's monitor and `ScrollWheelAccumulator` in both states
of the toggle. The monitor claims every wheel event while a mouse mode is on,
and every one on the alternate screen while none is, so SwiftTerm's own
`scrollWheel` never runs for those events. The monitor already does what
SwiftTerm's handler at the pinned revision does — accumulate
`scrollingDeltaY` against the cell height and bank the remainder — and adds
a bound on the report rate that the handler lacks (#1226). On the alternate
screen with no mouse mode on, it claims the event and drops it, where
SwiftTerm's handler would turn the wheel into Up/Down arrow keys that land on
whatever is attached, a composer draft included. Handing the wheel to
SwiftTerm in one state of the toggle would add a second wheel path without
the rate bound, and gain nothing.

### Copying

A program that selects text copies it with OSC 52.
`TerminalPanelRepresentable.Coordinator.clipboardCopy` already writes that
text to the general pasteboard, except while a snapshot is being ingested, so
copy works with no new code. The program's selection also uses the program's
own highlight colors, not the TBD theme's; Option-drag or Shift-drag gives
the theme's selection.

### No click reaches the program twice

`TBDTerminalView.clickPassthroughActive(allowMouseReporting:)` already
returns false whenever reporting is on, so the hand-forwarding of single
clicks stands down exactly when SwiftTerm starts reporting. One left click
reaches the program once in either state.

### Programs that take the mouse and do no selection

Some programs turn a mouse mode on and implement no selection — htop, or a
program that crashed without turning its mouse mode off. A plain drag there
selects nothing; Option-drag or Shift-drag selects. iTerm2 behaves the same
way.

## Mechanics

### The toggle

An app-only behavior, so it gates on a UserDefaults key, following
`useMetalTerminalRenderer`:

- **Key** – `forwardMouseToAppsEnabled`. Production reads it through
  `@AppStorage` wrappers — both terminal representables and
  `TerminalSettingsView` — each defaulting to `forwardMouseToAppsDefault`.
  `AppState.forwardMouseToAppsEnabled(defaults:)`, which returns
  `defaults.object(forKey:) as? Bool ?? forwardMouseToAppsDefault`, is the
  same read for a caller outside SwiftUI and for the tests that pin its three
  states. An absent key means nobody chose, so graduating is a one-line
  change to the default constant and keeps every explicit opt-out.
- **Store** – `UserDefaults.standard` on both the Settings writer and every
  reader. The Settings toggle is an `@AppStorage`, which always targets
  `.standard`.
- **UI** – a toggle in Settings → Terminal → Experimental: "Send clicks and
  drags to apps that use the mouse", with the subtitle "Option- or
  Shift-drag still selects text in TBD."
- **Live** – changing the toggle updates every open terminal without
  reopening it. The toggle lives in the Settings window, so no press in a
  terminal is in flight when it changes.

### The decision, as a pure function

One function decides `allowMouseReporting` for a panel from the toggle and
the panel's transport: true only when the toggle is on and the transport is
`.holder`. A second decides `optionBypassesMouseReporting`: equal to the
toggle. Both are pure, so every branch is a unit test.

### SwiftTerm

SwiftTerm upstream carries this exact setting as an open pull request,
[migueldeicaza/SwiftTerm#705](https://github.com/migueldeicaza/SwiftTerm/pull/705)
("Let the host make Option-drag bypass mouse reporting, the way Shift does"),
whose maintainer has said he is "generally fine with this setting". TBD takes
that change into its fork (`cheapsteak/SwiftTerm`) verbatim — same property
name, same predicate — and moves the pinned revision in `Package.swift` to
the fork commit. Taking it verbatim means a later sync of the fork with
upstream applies cleanly whether or not #705 has merged by then.

### Placement

Compiled. The decision runs per mouse event inside the app process, between
AppKit delivering the event and SwiftTerm encoding it; no user-land surface
in [`docs/theory-placement.md`](../theory-placement.md) sits on that path.

## Testing

- **SwiftTerm fork** – the bypass predicate for Shift with and without
  `mouseShiftCapture`, Option with the setting on and off, and no modifier.
- **The decision functions** – `allowMouseReporting` for toggle on and off
  across `.holder` and `.tmux`; `optionBypassesMouseReporting` for toggle on
  and off.
- **The flag reader** – an absent key reads the default; an explicit `false`
  survives a change to the default constant; an explicit `true` reads true.
  Through `AppState.forwardMouseToAppsEnabled(defaults:)` on a
  `UserDefaults(suiteName:)` suite, never the real `.standard`. The
  `@AppStorage` wrappers production reads through share its key and default
  and cannot be inspected headlessly.
- **Re-applying the routing** – `applyMouseRouting`, called on one view with
  each toggle state and transport in turn, rewrites `allowMouseReporting` and
  `optionBypassesMouseReporting` each time. No test flips the key under an
  open panel: the tests apply the routing directly, and the `@AppStorage` →
  `updateNSView` path that carries a Settings change to an open terminal is
  verified by hand (see the checklist below).
- **The no-double-forward guarantee** – the existing
  `clickPassthroughActive(allowMouseReporting:)` cases still hold.
- **Cmd stays TBD's** – with a program holding the mouse, a Cmd+click on an
  OSC 8 link, on a printed URL, on a path and on plain text, a Cmd-drag, and a
  Cmd+click whose Cmd is let go before the button each send the program no
  report, while each link and path opens once. Past column 100, clicks aimed
  with SwiftTerm's snapped cell width at a link's first and last characters
  open it, and clicks one cell beyond either end open nothing, with no report
  either way. Under the `.always` highlight mode an OSC 8 link opens and a
  printed URL does not. A view mounted the way a remote-attach terminal is,
  with the toggle off, withholds a Cmd+click too.
- **The Claude side** – the stub probe that sends press, drag and release to
  the real CLI confirms the program selects and writes OSC 52.

Real drags cannot be synthesized headlessly, so the soak adds a by-hand
checklist, run with the toggle on:

- In fullscreen Claude, a plain drag highlights in Claude's colors and the
  text pastes elsewhere.
- Option-drag and Shift-drag select in the TBD theme's colors, and Cmd+C
  copies the selection.
- Cmd+click on a file path opens it once; Cmd+click on an OSC 8 link opens it
  once.
- A single click in Claude's composer reaches Claude once.
- In a plain shell tab, a drag selects as before.
- In vim with `mouse=a`, a click moves the cursor and a drag makes a visual
  selection.
- The wheel scrolls Claude's transcript at the same rate as with the toggle
  off.
- Flip the toggle with a fullscreen Claude tab open, and the next drag
  follows the new setting without reopening the tab.
- Let go of Option, and separately of Shift, before the mouse button at the
  end of a bypass drag over fullscreen Claude, and note whether the program
  misbehaves — the known limit under "The bypass: Option and Shift".

## Flag and rollout

- **Flag** – `forwardMouseToAppsEnabled`, default off.
- **Soak** – turn on Settings → Terminal → Experimental → "Send clicks and
  drags to apps that use the mouse" and use it day to day, running the
  checklist above once at the start.
- **Graduation** – once the checklist passes, the per-event bypass limit is
  closed, and day-to-day use turns up no double-forwarded clicks and no lost
  selections, set `forwardMouseToAppsDefault` to true, and delete the flag in
  a later change. The tmux branch of the decision goes when the tmux
  transport does.

## Rejected alternatives

- **Turn reporting off for a whole gesture in TBD, instead of a SwiftTerm
  setting.** `TBDTerminalView.mouseDown` could flip `allowMouseReporting` off
  while Option is held and back on at mouse-up, with no fork change. That
  leaves a public property changed across a gesture that TBD's own click
  forwarding reads during the same press, and a release outside the view, a
  focus change or a new reader added later can each break the pairing
  silently. Suppressing reporting for one synchronous call is a different
  thing, and the Cmd release relies on it: the property is set off and
  restored around a single `super.mouseUp`, no other event arrives inside
  that call, and the click passthrough never runs in it. The SwiftTerm
  predicate has a window of its own — it reads the modifiers per event, the
  known limit under "The bypass: Option and Shift" — which latching the
  decision at mouse-down closes.
- **Hand the wheel to SwiftTerm as well.** It would make TBD's monitor
  unnecessary on a holder panel with the toggle on, and gain nothing. At the
  pinned revision SwiftTerm's live `scrollWheel` does the arithmetic
  `ScrollWheelAccumulator` does, without its rate bound, and turns the wheel
  into arrow keys on the alternate screen where the monitor drops it; the
  monitor stays for the toggle-off state and tmux panels regardless. Handing
  the wheel over in one state would add a second wheel path with no rate
  bound. Upstream bounds that handler's rate
  ([migueldeicaza/SwiftTerm#657](https://github.com/migueldeicaza/SwiftTerm/pull/657),
  `WheelReportBudget`); the fork does not carry it.
- **Agents only.** Limiting the mode to terminals running Claude would leave
  vim, htop and every other mouse-aware program on behavior iTerm2 users do
  not expect, and would make "does this program get the mouse" depend on
  what TBD thinks is running rather than on what the program asked for.
- **Option only, or Shift only.** Shift alone leaves the iTerm2 convention
  unavailable to the people this mode is for. Option alone would start
  sending Shift-modified events to programs that never received them under
  SwiftTerm. Honoring both costs only events that a widely used terminal
  already withholds.

## Related upstream work

- [migueldeicaza/SwiftTerm#770](https://github.com/migueldeicaza/SwiftTerm/pull/770),
  open, makes Option-drag a block (rectangular) selection, as Terminal.app
  does. If it lands and the fork takes it, an Option-drag bypass produces a
  block selection, and Shift-drag a line selection. That is a change in what
  the bypass selects, not in whether it bypasses.
