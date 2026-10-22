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

Everything below applies only while the toggle is on. With it off, TBD
behaves exactly as it does today.

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
  toggle, so both terminal surfaces honor the same modifiers.
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

### What stays TBD's

A press with Cmd held belongs to TBD. Cmd is TBD's modifier for opening paths
and links, and SGR mouse encoding has no bit for it, so a Cmd press forwarded
to a program would reach it as a plain click. While a program holds the mouse
— reporting on, and a mouse mode on — `TBDTerminalView.mouseDown` keeps every
Cmd-modified press from SwiftTerm's reporting: no press, no drag motion and no
release reaches the program. The rule lives in `TBDTerminalView`, so it holds
for remote-attach terminals too. With reporting off, a Cmd press goes to
SwiftTerm's local handling, which never reaches the program either.

- **Cmd+click on a path** – `TBDTerminalView.mouseDown` opens it
  (`handleCommandClick`) and consumes the press.
- **Cmd+click on a link** – an OSC 8 hyperlink, or a URL SwiftTerm detects in
  the text, opens on release. TBD hands the release to SwiftTerm only when
  SwiftTerm's mouse-up will open a link there (`linkForClick`), which it does
  before it would report the release. A Cmd release that opens nothing — Cmd
  let go before the button, a drag, plain text — is consumed.
- **The window-activating click** – consumed in `mouseDown`, unless it is a
  Cmd+click on an OSC 8 link, which opens on release like any other.
- **File drag-and-drop**, find, and paste – separate AppKit paths.

### The scroll wheel

The wheel stays on TBD's monitor and `ScrollWheelAccumulator` in both states
of the toggle. The monitor claims every wheel event while a mouse mode is on,
so SwiftTerm's own `scrollWheel` never runs for those events. That matters:
at the pinned SwiftTerm revision, the native handler sends 1, 3, 10 or
`max(rows, 20)` reports for a single event (`calcScrollingVelocity`), the
amplification `ScrollWheelAccumulator` removes.

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

- **Key** – `forwardMouseToAppsEnabled`, read through a static
  `AppState.forwardMouseToAppsEnabled(defaults:)` that returns
  `defaults.object(forKey:) as? Bool ?? forwardMouseToAppsDefault`. An absent
  key means nobody chose, so graduating is a one-line change to the default
  constant and keeps every explicit opt-out.
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
  Through `AppState(userDefaults: UserDefaults(suiteName:))`, never the real
  `.standard`.
- **Live application** – flipping the key updates an open panel's
  `allowMouseReporting` and `optionBypassesMouseReporting`.
- **The no-double-forward guarantee** – the existing
  `clickPassthroughActive(allowMouseReporting:)` cases still hold.
- **Cmd stays TBD's** – with a program holding the mouse, a Cmd+click on an
  OSC 8 link, on a printed URL, on a path and on plain text, a Cmd-drag, and a
  Cmd+click whose Cmd is let go before the button each send the program no
  report, while each link and path opens once.
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

## Flag and rollout

- **Flag** – `forwardMouseToAppsEnabled`, default off.
- **Soak** – turn on Settings → Terminal → Experimental → "Send clicks and
  drags to apps that use the mouse" and use it day to day, running the
  checklist above once at the start.
- **Graduation** – once the checklist passes and day-to-day use turns up no
  double-forwarded clicks and no lost selections, set
  `forwardMouseToAppsDefault` to true, and delete the flag in a later change.
  The tmux branch of the decision goes when the tmux transport does.

## Rejected alternatives

- **Turn reporting off for one press in TBD, instead of a SwiftTerm setting.**
  `TBDTerminalView.mouseDown` could flip `allowMouseReporting` off while Option
  is held and back on at mouse-up, with no fork change. It mutates a public
  property in the middle of a gesture that TBD's own click forwarding reads
  during the same press, and a release outside the view, a focus change or a
  new reader added later can each break that pairing silently. A predicate
  SwiftTerm checks per event has no such window.
- **Hand the wheel to SwiftTerm as well.** It would make TBD's monitor
  unnecessary in this mode, but at the pinned revision SwiftTerm's handler
  amplifies wheel input into the same report flood TBD just removed.
  Upstream has since bounded it
  ([migueldeicaza/SwiftTerm#657](https://github.com/migueldeicaza/SwiftTerm/pull/657),
  `WheelReportBudget`), but the fork is 151 commits behind upstream and does
  not carry it.
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
- Remote-attach terminals have no wheel monitor and use SwiftTerm's native
  handler, so they still carry the wheel amplification. Bringing the fork up
  to upstream, or porting #657, fixes them. That is a bug fix of its own,
  outside this design.
