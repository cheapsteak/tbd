# Prompt rail lens

## Problem

The prompt rail ([`2026-10-25-transcript-prompt-rail-design.md`](2026-10-25-transcript-prompt-rail-design.md)) shows a long session's shape as a column of notches, one per prompt. Reading a prompt from it takes two steps. The reader rests on the rail, a 320pt card fades in over the transcript, and its list scrolls when the session is long. The card repeats the rail as a second list, and once that list scrolls, its rows no longer sit where their notches do.

A prototype built for a different app tried another way to show a long list in a fixed height: a lens. The whole list fits its panel. Rows near the pointer grow to a readable height, and far rows shrink to slivers, like a minimap. The rail's notches already are that minimap. The lens felt much slicker than a scrolling list.

## Decision

Hovering the rail magnifies the rail itself. The notch under the pointer grows into a readable row, rows near it grow part way, and far notches stay notches. A rounded box behind the readable rows keeps them legible over the transcript. The hover card goes, and with it the card's six-line row expansion and the Remote pane's "Earlier prompts not loaded" row.

- **It applies to all three transcript surfaces.** The live pane, Session History and the Remote pane all render through `TableTranscriptView`, so the lens is built once.
- **It ships without a flag.** It replaces existing UI, which the repo's rule would normally gate behind a default-off flag. Few people use the transcript panes, so the owner chose to ship it directly. This is a deliberate exception, not an oversight.
- **It is AppKit, in one view.** The rail view becomes an overlay that draws the box, the notches and the row text in one pass.
- **It lives entirely in TBDApp.** There is no daemon, RPC, schema or durable-resource change.

Everything else about the rail stays as specified: what gets a notch, notch length, the active prompt, jumping, the keyboard commands and the VoiceOver buttons.

## The resting rail

The rail at rest looks as it does today, with one change: a short session spreads its notches so the column is tall enough to hold the lens. The lens can then open without moving either end of the column.

- **The lens's need** is `T × R / 0.85`, where `T` is the peak row height and `R` the lens radius in rows (see **Strength**). At the shipped strength this is about 184pt.
- **Pitch** is `max(4, min(max(8, need / N), free / N))`, where `N` is the prompt count and `free` is the rail's height less its 12pt top and bottom insets.
  - Sessions of about 23 to 72 prompts in a 600pt rail keep today's 8pt pitch.
  - Shorter sessions rest wider apart: 12 prompts sit about 15pt apart.
  - Longer sessions shrink toward the 4pt floor as today.
  - Past the floor, the resting rail shows a window of notches around the active one, as today.

## The lens

### Strength

The lens has one fixed strength, with no setting:

- **Peak row height `T`:** 26pt.
- **Radius `R`:** 6 rows on each side of the centre.

### Opening and closing

- **Opening** – 80ms after the pointer enters the rail, the lens grows. Its open fraction `e` runs from 0 to 1 over 150ms, easing out. Each row is drawn at `rest + (lens − rest) × e`, so the rail morphs from notches into the lens without a jump.
- **Closing** – the lens shrinks back over `150ms × e`, easing out. A lens that starts closing before it is fully open shrinks from where it is.
- **Reduce Motion** – the lens opens and closes at once.
- **Staying open** – the lens stays open while the pointer is over the rail column or the box.
- **Grace** – the lens starts closing 100ms after the pointer leaves both, so a jittery pointer does not snap it shut.
- **Closing at once** – Escape, a click, app deactivation and the window resigning key close the lens at once. After Escape or a click, the lens does not grow again until the pointer has left the rail. A backgrounded app receives no pointer-exit event, so hover alone is never the only way out.

### Layout

The open lens fills exactly the resting column, from the rail's top inset to where the resting notches end (or to the bottom inset when the rail is windowed). **Neither end of the column moves** while the lens opens, moves or closes. Far notches squeeze to pay for the rows that grow.

For a lens centred on fractional row `c`:

0. **Few prompts.** When the resting pitch is already at least the peak the lens would draw for a bump in mid-column (step 1), every row keeps its resting height and shows its text. In a tall rail that is 7 or fewer prompts at the shipped strength; a short rail lowers the peak, so it covers more. Nothing moves; the steps below apply only to longer lists. Without this, the squeeze would make far rows taller than the pointed one. A windowed rail is never "few prompts": its lens squeezes as step 5 says, so it can reach every prompt.
1. **The bump.** Row `i`'s weight is `f = ½ × (1 + cos(π × d / R))` for `|d| < R`, where `d = i + ½ − c`, and 0 otherwise. `F` is the sum of the weights. The peak is `T`, lowered to `0.85 × H / F` when `T × F` would leave less than 15% of the column's height `H` for the other rows.
2. **Row heights.** Row `i` is `base + (peak − base) × f` tall. Rows whose centre lies above `c` use one base and the rest use another. Each base is at least 1pt, the **sliver floor**.
3. **Two-sided squeeze.** The lens centre sits where the resting rail draws row `c`. The upper base is solved so that the rows above the centre fill exactly the space above it. The lower base is solved so that the whole column fills exactly `H`. So the notch under the pointer stays under it as the lens opens.
4. **Near the ends.** Close to either end there is no room above or below the centre for half a bump. There, the centre is held inward, far enough that the rows on the cramped side keep at least half the squeeze they would get with the lens in the middle. So scrubbing near an end stays smooth. The cost is **edge drift**: pointing near an end opens the lens on a row a few rows nearer that end than the pointed notch. With 40 prompts, pointing at notch 8 opens on row 3, notches 12 to 24 open exactly, and notch 36 opens on row 38. This was accepted.
5. **Long sessions.** On a windowed rail, the open lens squeezes every prompt into the rail at down to the sliver floor, so the pointer can reach any prompt. The far notches rearrange as they squeeze; the notch under the pointer stays.
6. **Past the floor.** When even 1pt slivers do not fit (about 400 prompts in a 600pt rail), the column is taller than the rail. Whether a rail is past the floor is decided once for the rail, from its prompt count at the floor plus a whole bump in mid-column, never per lens position: a rail that switched between squeezing and sliding as the lens neared an end would make the column jump. It slides with the lens and is clipped behind 24pt fades at the rail's ends. The slide maps the lens centre to a height in two straight runs, from the rail's top to the notch the lens opened on and from there to the bottom. Each run is steepened near its end so the end rows come fully into view, and never drops below 0.25pt per row, so the lens cannot race through rows with no pointer movement. A rail that is not past the floor but cannot fit a whole bump beside an end lowers the peak there, so neither end of the column moves.

### Steady motion

The lens holds still while the pointer moves near its centre and follows when pushed. It does not centre on the pointer the way the macOS Dock does: that "Dock" motion was tried in the prototype and rejected.

- **Opening** – the lens opens on the centre whose own layout puts the pointed row under the pointer, found by bisection.
- **Dead zone** – while the pointer is within `0.45 × R` rows (2.7 rows) of the centre, the lens does not move.
- **Following** – past the dead zone, the centre eases toward the centre whose layout puts the pointer exactly on the dead zone's edge. The ease is time-based, with a time constant of about 130ms: 12% of the remaining distance per 60Hz frame, and the same per second of real time at 120Hz.
- **Flick freeze** – while the pointer is moving fast, the lens holds still. The speed is measured from the pointer's own moves and their event times, not from frames, so a flick that starts while the frames are paused freezes the lens at once, and a pointer that comes back after a pause is not taken for a flick. It is smoothed as `v ← 0.6 × v + 0.4 × instantaneous` per 60Hz frame's worth of time, decays toward zero while the pointer is still, and a smoothed speed above 0.45pt/ms counts as fast. This keeps the lens from smearing past the row the reader is aiming at.
- **Settling** – once the centre is within 0.002 rows of its target, it moves to the target and stops, so the settled position is the same at any frame rate.

### Drawing

Rows are drawn at their layout height, and each shows as much as its height allows:

- **Notch** – every row draws its notch at its work length, from 2pt in from the rail's leading edge. The active notch is 3pt thick in the accent colour (lavender for a peer) and the rest 2pt, as at rest. A row thinner than its notch draws it at the row's height less 1pt, at least 0.5pt; the active notch keeps at least 2pt, so the active prompt stays visible in a squeezed column.
- **Text** – a row's first line and time fade in as the row grows: opacity is `(h − 10.5) / 2.5`, clamped to 0…1, where `h` is the row height. Below 15pt the text is 10.5pt; from 15pt it is 13pt.
- **Readable row layout** – it repeats the card's row:
  - the notch as the row's dash, in an 18pt dash column;
  - an 8pt gap;
  - the first line, truncated at the tail;
  - the time, right-aligned in the secondary label colour with monospaced digits, 8pt after the first line, with 10pt trailing padding;
  - for the active row, medium weight;
  - for the row under the pointer, a quaternary-fill background with a 6pt corner radius.
  - a row taller than the peak (a few-prompts rail) draws its text, its hover fill and its share of the box in a band the peak's height, centred on the row, so the box hugs the text rather than the row's whole height. Such a row is pointed at only within its band; between bands the pointer points at no row.
- **Time column** – the time column follows the rail spec's rule: today's rows show their time, and an earlier day's first row shows its date.
- **The box:**
  - **Rows** – it spans the rows whose text shows at all, from 3pt above the first to 3pt below the last.
  - **Width** – it is as wide as the widest of those rows wants, capped at 320pt and at the pane's width less 24pt. A row's wanted width grows with its height, from the rail's 20pt at 8.5pt tall to its full width at 14pt tall, on a smoothstep. While the pointer is over the box, the box never narrows, so moving through rows with shorter titles cannot leave the pointer outside it and close the lens; it fits its rows again once the pointer leaves it.
  - **Shape** – it starts at the pane's leading edge, behind the rail column, and has 8pt corners on its trailing side. An 8pt 45° taper joins it to the rail column above and below.
  - **Look** – it is filled with the window background colour, has a 0.5pt border in the separator colour, and casts an 8pt shadow in the shadow colour at 20% opacity, resolved for the current appearance.

### Pointer and keys

- **Click on a row** – jumps to its prompt, as the card's rows did, and closes the lens.
- **Click on the bare rail** – a click on the rail before the lens has grown jumps to the pointed notch's prompt.
- **Outside the column** – a pointer above the first row or below the last points at no row: it draws no hover fill, and a click there jumps nowhere. A short session's column ends well above the rail's bottom, so this is common.
- **Wheel** – a wheel over the rail column or the box scrolls the transcript. Neither the rail nor the lens scrolls under the wheel.
- **Elsewhere** – clicks and the wheel outside the rail column and the box reach the transcript, whatever the overlay's frame covers. Once the lens starts to close, its shrinking box takes no clicks: they reach the transcript.
- **Overlays above the rail** – each transcript pane's jump-to-latest button (live, History and Remote) and the Remote pane's earlier-history header (its loading capsule and retry button) hide while the lens is open, so they never cover the lens's rows or take their clicks. Only those overlays observe the lens's state; the pane itself never does, because a pane re-render reruns the table's whole-transcript comparison (see the rail spec's "Views").
- **Keyboard** – the Go menu's Previous Prompt and Next Prompt are unchanged.
- **VoiceOver** – the "Prompts" group, with one button per entry, is unchanged.

### Live updates

- **Active prompt** – a change while the lens is open restyles the rows in place.
- **New prompt** – a new prompt adds a row, and the lens keeps its centre. On a short session the resting column grows by one pitch, so its bottom moves down with the new notch.
- **Tool calls** – a turn's tool count changes its notch length in place.

## Structure

Logic stays out of the views, under `Sources/TBDApp/Panes/Transcript/PromptRail/`:

- **`PromptRailLensLayout`** (new, pure) – row heights and tops for a prompt count, column, lens centre, open fraction and resting pitch: the bump, the two-sided squeeze, the end handling, the sliver floor and the slide.
- **`PromptRailSteadyLens`** (new, pure) – the lens's motion. Its state, the pointer's position and the elapsed time go in, and the new centre comes out. It owns the open-time solve, the dead zone, the time-based ease, the flick freeze and settling. It reads time only from what it is given.
- **`PromptRailLayout`** (changed) – gains the lens's need and the resting pitch rule above.
- **`PromptRailHoverModel`** (kept) – the 80ms open, the 100ms grace, Escape and click suppression, and the deactivation close, on its injected clock. It hears hover on two surfaces: the rail column and the box.
- **`PromptRailNSView`** (reworked) – the one view:
  - **Frame** – an overlay as tall as the rail and as wide as the box can grow. It draws the box, the notches and the rows in `draw(_:)`.
  - **Hit-testing** – it returns nil outside the rail column and the box, so the transcript keeps its clicks.
  - **Display link** – a link from `NSView.displayLink(target:selector:)`, as `GhosttyTerminalView` uses, drives the frames. It exists only while the lens is opening, moving or closing, and is released once the lens settles; the next movement makes a new one. So a settled or abandoned rail never leaves a link in the run loop. It takes its frame times from the link, through a seam that lets tests step frames by hand.
  - **Tracking** – one tracking area over the whole overlay feeds the hover model. Code, not separate areas, decides whether the pointer is over the rail column or the box. A tracking area follows geometry, not hit-testing, so the rail stays hovered under the box.
  - **Kept** – its accessibility buttons and its hand-off of wheel events to the transcript.
- **`TranscriptContainerView`** – stacks the scroll view and then the overlay. It runs the Escape monitor while the lens is open, and closes the lens when the container leaves its window or the window resigns key.
- **Deleted** – `PromptRailCardNSView`, `PromptRailRowExpansionView` and `PromptRailRowDwell`; the earlier-history plumbing in `PromptRailMount` and the Remote pane's mount; and their tests.

The coordinator, `PromptOutline`, `PromptRailWorkScale`, `PromptRailActiveRule`, jumping and the keyboard commands do not change.

## Lazy rendering

The rail spec's four lazy-rendering rules still hold:

1. **The lens reads node data only.** Nothing measures or builds a table cell to draw it.
2. **The gutter stays a fixed 20pt.** The overlay draws over the transcript and never changes the table's column width.
3. **Jumps pin; nothing pre-measures.**
4. **The rail never loads pages.** With the Load row gone, nothing on the rail loads history. The Remote pane's own "Load earlier messages" button does that, and so does a jump to the earliest loaded prompt, which starts the ordinary page load.

## Evidence from the mock

An HTML mock ported the prototype's lens onto a fake transcript with the rail's real metrics. A headless browser measured it, and the owner tried it.

- **Ends must be held.** Letting far notches keep their resting pitch grows the column when the lens opens, which pushes the bottom end, and every notch below the lens, down. Holding the column's height and squeezing far notches keeps both ends within 5e-12pt through opening, a full sweep and closing, at 12, 40 and 120 prompts. No row overlapped or left a gap of more than 2e-13pt.
- **Short sessions need a taller rest.** At an 8pt pitch, a column under about 184pt cannot hold the lens's readable rows. The alternative, growing the column's bottom only when needed, moved the bottom from 108pt to 196pt at 12 prompts.
- **A smooth outline overshoots.** A spline through each row's trailing edge pokes past the rows wherever widths jump, forming "ears" at the box's corners. A plain rounded box with a straight taper does not.
- **Steadiness.**
  - A slow sweep of 2pt per frame moved the lens at most 0.75 rows per step, and never backwards.
  - It settled within 500ms of the pointer stopping.
  - A whole-column sweep moved the centre at most 0.31 rows per step at 12 prompts, 0.78 at 40, 1.12 at 120 and 2.91 at 300.
- **Easing in row units crawls.** The prototype's ease, 22% of the overshoot counted in rows per frame, kept moving for over a second near held ends, where a row moves the bump only a couple of points. Easing toward a target centre fixed it.

## Testing

- **`PromptRailLensLayout`:**
  - No gaps or overlaps.
  - Both ends within 0.5pt of the resting column for every centre and open fraction.
  - The peak row 26pt when the column has room.
  - No base below the 1pt floor.
  - The slide once the floor is reached.
  - An open fraction of 0 reproduces the resting layout exactly.
  - In the middle of the rail, the open-time centre keeps the pointed row under the pointer.
- **`PromptRailSteadyLens`:**
  - Still inside the dead zone, easing past it.
  - The same position after the same elapsed time at 60Hz and 120Hz steps.
  - Frozen during a flick.
  - Settling below 0.002 rows.
- **`PromptRailLayout`:**
  - The resting pitch at 1, 12, 23, 40, 120 and 300 prompts.
  - The lens's need at the shipped strength.
- **Hover model** – the existing open, grace, Escape, click and deactivation tests, with the box as the second hover surface.
- **Views, offscreen**, with the injected clock and frames stepped by hand:
  - no lens before 80ms, and the lens after it;
  - the box counts as hover, and the lens closes 100ms after the pointer leaves both;
  - a click on a row jumps and closes the lens, and a click on the bare rail jumps;
  - Escape and deactivation close the lens at once and suppress regrowth until the pointer leaves the rail;
  - clicks and the wheel outside the rail and the box reach the transcript, and the wheel over the box scrolls it;
  - the display link is released once the lens settles;
  - the accessibility buttons are unchanged;
  - nothing builds a table cell.
- **Mounting, offscreen** – a pane-shaped mount keeps the gutter inside the table's view. A table with no mount has no rail.
- **Live** – the owner checks the feel on a real transcript, including a windowed rail.

## Out of scope

- A setting for the lens's strength.
- Reading more of a prompt than its first line from the rail.
- Loading earlier Remote history from the rail.
- Any change to what gets a notch, notch length or the active-prompt rule.

## Rejected alternatives

- **The lens inside the hover card** – it keeps the card's open delay, Escape and Load row, and changes only the list's layout. But reading still takes two steps, the card is a 320pt panel over the transcript, and its rows cannot line up with the notches once their heights vary.
- **Dock motion** – a lens that always centres on the pointer, as the macOS Dock does, moves under every pointer movement. The owner tried both motions in the prototype and chose the Steady lens, which holds still until pushed.
- **Growing the column's bottom for short sessions** – it keeps today's 8pt resting pitch, but the bottom end jumps when the lens opens on a short rail.
- **A lens over the resting window only** – on a windowed rail, the lens would work only on the notches already showing, so nothing outside the pointer's area moves. But a prompt outside the window would then be reachable only by pushing the window along, and the rail exists to reach any prompt.
- **A resting rail that never windows** – letting the resting pitch fall below 4pt holds about 290 prompts without a window, but packs notches into a solid smear at rest.
- **Other backdrops:**
  - *A curved bulge* that narrows smoothly to the rail.
  - *A full-height panel*, the rail's whole height and 320pt wide.
  - *A gradient fade* with no panel.

  The bulge's curve and the full panel were tried in the mock, and the owner chose the rounded box over both. The fade leaves text over moving transcript text.
- **Title-length slivers** – the prototype drew each far row as a bar as long as its title. That needs a backdrop behind every row, which only the full-height panel provides. The rail's notches already carry a length, the turn's work.
- **Keeping the six-line expansion** – a resting overlay over the lens adds a second way for a row to grow on top of the lens itself. Jumping to a prompt shows all of it.
- **Two views, or one layer per notch** – a separate lens view above the rail would interleave with it, the box behind the notches and the text beside them, and both would have to stay in step every frame. One layer per notch, as the resting rail used, would mean moving hundreds of layers and resizing text layers every frame. One draw pass of about 13 text rows and up to 600 small rectangles is simpler, and it runs only while the lens moves.
