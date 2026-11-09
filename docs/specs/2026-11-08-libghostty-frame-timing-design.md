# Frame timing for the libghostty engine

TBD's opt-in libghostty engine
([design](2026-11-07-libghostty-terminal-engine-design.md)) draws a frame only on a
display-link tick, so output that arrives between ticks waits for the next one. This design
draws small output at once when the screen has had no output frame for a refresh interval,
and keeps bulk output at one frame per refresh. It also reads DEC 2026 holds from
libghostty's own callback, and it stops the main thread from blocking on the GPU. SwiftTerm
does not change.

## Goal

- **Goal** – after typed echo, libghostty's draw wait matches that of SwiftTerm's default
  CoreGraphics renderer, and libghostty keeps its lower app CPU under heavy output.
- **Not goals:**
  - a win toward graduation. Parity removes a regression. It does not meet the engine's
    graduation rule.
  - any change to SwiftTerm's timing
  - frames that no output causes: the cursor blink, focus, selection and viewport scrolling.
    They keep going through the display link.
  - live resize, which keeps drawing from `setFrameSize` as it does today
  - drawing the frame that a hold started with ("Deferred and rejected alternatives")

## Evidence

**The regression.** The migration record,
[`docs/research/2026-10-28-terminal-engine-libghostty.md`](../research/2026-10-28-terminal-engine-libghostty.md),
holds the A/B rounds. Its first round ("A/B of the opt-in engine") measured the draw wait:
how long the oldest undrawn chunk waits, from the feed seam to the start of the draw. The
round had two runs. In the run with SwiftTerm on CoreGraphics, the p90s in milliseconds were:

| | idle | load |
|---|---|---|
| libghostty | 9.383 | 8.928 |
| SwiftTerm, CoreGraphics | 2.724 | 2.822 |
| libghostty ÷ SwiftTerm | 3.445 | 3.164 |

So libghostty waited 3.2 to 3.4 times longer at p90. Typed echo matched: in every band, the
two arms' echo p90s agreed within about 10%. In the other run SwiftTerm drew with Metal. Its
Metal renderer writes no draw lines, so that run has no draw comparison. libghostty's p90
there was 9.121 ms idle and 8.633 ms under load.

**The cause, from the code on `main`:**

- The IO thread feeds `GhosttyTerminal`, which parses under its lock and then calls the
  view's render signal. `RenderSignalRelay` folds any number of signals into at most one
  main-queue hop.
- On main, the delivery calls `requestFrame()`. That sets `needsUpdate` and resumes the
  paused `CADisplayLink`. Nothing draws yet.
- The next tick runs `renderTick(now:)`, which checks mode 2026 and calls `renderNow()`.
  Outside a live resize, and apart from `drawFrameNow()`, which tests and instruments call,
  nothing else draws.
- So output waits for the next tick: up to 8.3 ms on a 120 Hz screen, plus the hop.
  libghostty's draw waits spread evenly from 0 to about 10 ms, which fits.
- SwiftTerm's `FrameDriver`, the comparison arm's scheduler, ticks at once when output
  resumes its paused link, at most once in 16 ms
  ([`FrameDriver.swift`](https://github.com/cheapsteak/SwiftTerm/blob/b4db5b0ecd62db7a8ebdc4dbff8b82b8ed704e9a/Sources/SwiftTerm/Apple/FrameDriver.swift)).

**Heavy output already runs at one frame per refresh.** In the second round ("A/B under
heavy output"), the 50 MB stream's draw wait was about 8.3 ms at p50 on both engines, which
is one 120 Hz frame, and the paint times matched. In Claude Code's full-screen mode,
libghostty used 0.41 to 0.54 of SwiftTerm's app CPU, with latency within 1 ms. This design
must keep both results.

**Other renderers,** read on 2026-11-08. Nine terminals whose frame scheduling is public were
read. Six draw the first frame after a quiet spell at once: kitty, iTerm2 (for echo),
Alacritty, WezTerm, foot and SwiftTerm. Three always wait for the display callback: Ghostty
with vsync on, its default; Zed; and termio. Ghostty's documentation says that vsync "may
cause input latency"
([`window-vsync`](https://ghostty.org/docs/config/reference)). termio is the closest to TBD:
a Swift macOS app that draws libghostty-vt with its own Metal renderer. Its frame loop waits
for the tick, as ours does, but this design adopts two of its other ideas: hold edges, and
dropping a frame instead of blocking.

## Design

### When output draws at once

Each render-signal delivery on main decides once whether to draw now. It draws now when all
seven of these hold:

1. **The view can build frames** – the surface is attached, the view is in a window and not
   hidden, the window is not occluded, the terminal is open, and the drawable is at least one
   pixel each way. That is `canBuildFrames` plus the size check in `renderNow()`.
2. **No live resize is in progress** – during a drag, `setFrameSize` draws each step inside
   its Core Animation transaction.
3. **No DEC 2026 hold is open** – the tick skips every frame while a hold is open, so the
   delivery leaves it to the tick.
4. **A refresh interval has passed since the last output frame** – "What counts as an output
   frame" below says which frames count.
5. **The ring has a free slot** – fewer than three of the surface's frames are in flight on
   the GPU.
6. **Fewer than two drawables await present.**
7. **The output is small, or a hold just ended** – fewer than 1,024 bytes have been fed since
   the last frame was built, or a hold ended in the chunks this delivery covers.

Otherwise the delivery calls `requestFrame()`, as it does today, and the display link
coalesces. Bulk output stays at one frame per refresh: rule 4 lets at most one output frame
through per interval, and rule 7 sends large output to the tick.

To draw now, the delivery calls the same `renderTick(now:)` that the link calls. That runs
inside the delivery that already exists, so the design adds no main-queue hop. A frame drawn
this way costs what a tick frame costs, and it replaces the tick frame that would have drawn
the same output. Idle terminals and bulk output cost what they cost today.

**One pure function.** `LeadingEdgePolicy.decide(_:)` takes a `LeadingEdgeFacts` value and
returns `.drawNow` or `.coalesce(reason)`. Each rule has one reason, checked in rule order:
`.cannotBuildFrames`, `.liveResize`, `.holdOpen`, `.withinRefreshInterval`, `.ringFull`,
`.drawablesBehind` and `.bulkOutput`. The function sits beside `DisplayLinkPolicy` and reads
no clock and no state. Its facts are:

- `canBuildFrames` and `isLiveResizing`
- `now`, `lastOutputFrameAt` (nil before the first output frame) and `refreshInterval`
- `ringHasFreeSlot` and `drawablesAwaitingPresent`
- `outputBytesSinceFrame`, `holdOpen` and `holdEnded`

Rule 3 does not change what reaches the screen. A frame drawn while a hold is open would be
skipped by the tick it calls, so the policy coalesces at once instead.

**Constants:**

- `LeadingEdgePolicy.smallOutputLimit`, 1,024 bytes – rule 7. An echo is a few bytes, and a
  prompt or status line redraw is usually a few hundred. A coloured full-screen redraw is
  several KiB, and goes to the tick unless it came inside a hold.
- `TerminalRenderer.maxDrawablesAwaitingPresent`, 2 – rule 6, which the tick also obeys. The
  layer has three drawables (`maximumDrawableCount = 3`). With two waiting and one on screen,
  `nextDrawable()` would block.
- `FrameRing.depth`, 3 – unchanged.
- `LeadingEdgePolicy.fallbackRefreshInterval`, 1/60 s – for a window with no screen, as in
  the offscreen tests.
- `DrawableTracker.presentReportTimeout`, 100 ms – see "Drop, never block".

**The refresh interval.** While the link runs, the interval is `targetTimestamp - timestamp`
from its last tick. `DisplayLinkProxy.fired(_:)` passes it with the timestamp, and
`DisplayLinkDriver` keeps it until the link pauses. While the link is paused, and before its
first tick after a resume, the interval is the window's screen's
`NSScreen.minimumRefreshInterval`. The SDK header calls this "the shortest amount of time a
frame will be present on screen", available from macOS 12, and TBD targets macOS 15. A window
with no screen uses `fallbackRefreshInterval`.

**What counts as an output frame.** A frame stamps `lastOutputFrameAt` only when it was
encoded and its build consumed program output, which means the terminal's byte counter
(below) was above zero when the frame read it. The tick, the leading edge and the live-resize
path all stamp this way, each with the `now` the frame was built for. A frame with no output
in it stamps nothing.

This rule is what keeps typing fast. A key press calls `resetCursorBlink()`. Today that call
sets the blink phase to on, which marks the surface dirty only if the cursor was in its off
phase. It then restarts the blink timer and calls `requestFrame()` whether or not anything
changed. So every key resumes the link, and a tick can draw a cursor-only frame just before
the echo arrives. If that frame stamped the window, the echo would wait for the next tick
again. It consumed no output, so it stamps nothing, and the echo draws at once.
`resetCursorBlink()` itself does not change.

**Time.** The view gains a `now: @MainActor () -> Duration` seam, which defaults to
`.seconds(CACurrentMediaTime())`. Its values are compared with display-link timestamps, which
are host time. So the seam follows the existing `renderTick(now:)` parameter, a duration
since a fixed origin, and not the repo's `Date` seam, which is for wall-clock data. The design
adds no sleep, timer or delay. The leading edge draws inside a delivery that already exists,
and every limit is checked when a frame is due.

### Where the facts come from

- **The byte counter** – `TerminalCore.outputBytesSinceFrame`, guarded by the terminal lock.
  `feed` adds the bytes it writes. `FrameBuilder.update` reads the counter and zeroes it in
  the lock hold it already takes for `ghostty_render_state_begin_update`. So the count is
  exactly the output each frame consumed.
- **The render hint** – `Aftermath` gains a `RenderHint`: the byte counter, whether a hold is
  open, and whether a hold ended during the call. A call that signals a render builds the
  hint under the lock and takes the "a hold ended" flag, reading it and clearing it. A call
  that signals no render leaves the flag for the next call that does. The render signal
  becomes `@Sendable (RenderHint) -> Void`, and `close()` passes an empty hint.
- **The relay** – `RenderSignalRelay` keeps a pending hint in place of its pending flag. A
  signal that finds a hint pending merges into it: the byte count and the open-hold flag take
  the newer value, and "a hold ended" is true if either says so. The delivery hands the
  merged hint to the view and clears it. At most one hop is in flight, as today.
- **The GPU facts** – read on main from the surface's ring and the view's drawable tracker
  ("Drop, never block"). Only main takes slots and drawables, so a check made on main stays
  true until main acts on it.

A hint can be stale, because a tick may build a frame between a signal and its delivery. If
that frame drew the output, it stamped `lastOutputFrameAt`, and rule 4 sends the delivery to
the tick, which finds nothing new. If it encoded nothing, the delivery may build a frame that
also finds nothing and skips, at the cost of one lock hold.

### DEC 2026 hold edges

libghostty reports holds through `GHOSTTY_TERMINAL_OPT_RENDER_HOLD`, whose callback type is
`GhosttyTerminalRenderHoldFn(terminal, userdata, held)`
([`terminal.h`](https://github.com/ghostty-org/ghostty/blob/vt-1.0.0/include/ghostty/vt/terminal.h)
in the `vt-1.0.0` headers that ship inside the pinned xcframework). The header says:

- A hold begins when the program sets mode 2026, "which is the only way to start a hold
  today".
- It ends when the program resets mode 2026, when the terminal is fully reset (RIS from the
  program, or `ghostty_terminal_reset()`), and when it is resized with
  `ghostty_terminal_resize()`.
- "The two calls always come in pairs." Setting the mode during a hold does nothing, and so
  does resetting it with no hold.
- "Changing the mode yourself with GHOSTTY_TERMINAL_OPT_MODE never invokes the callback."

`GhosttyTerminal.configure` installs the callback with the other effect callbacks.

- **The callback** runs inside `vt_write`, `ghostty_terminal_reset` or
  `ghostty_terminal_resize`, and TBD calls all three with the terminal lock held. So it only
  sets two values on `IOContext`, which the lock guards: `holdOpen`, and `holdEnded` when a
  hold ends. Like the callbacks already there, it never takes the lock, never calls the
  owner and never hops threads.
- **The mute does not apply to it.** The other callbacks drop their effects while the
  terminal is muted. This one records edges whatever `muted` says, because a hold is terminal
  state, not an effect for the coordinator. `prepareForPreamble()` resets the terminal while
  muted, and the end edge that reset raises must not be lost. The attach preamble is VT text
  fed through `vt_write`, so a replayed `?2026h` raises an edge just as live output does.
- **The tick reads `holdOpen`** in place of its read of mode 2026.
  `syncOutputDecision(now:)` keeps its shape and its three answers: `.render`, `.skipFrame`
  and `.forceOffAndRender`.
- **The watchdog** keeps its injected `now` and its 1 s timeout. Its input becomes `holdOpen`
  from the edges, and it still starts timing at the first tick that sees a hold. It measures
  how long ticks have seen a hold without a break. A hold that ends and another that starts
  between two ticks do not restart it. If it restarted for each hold, back-to-back holds
  could hide every frame for good, and the force-offs that the deferred item's trigger counts
  would never happen.
- **Our force-off clears `holdOpen` itself.** It turns mode 2026 off through
  `GHOSTTY_TERMINAL_OPT_MODE`, which raises no callback.
- **Attach reads the mode once.** `resetSyncOutputWatchdog()`, which the view calls when its
  surface attaches, also sets `holdOpen` from one read of mode 2026, in the same lock hold.
  The edges already cover every write, reset and resize. The read keeps `holdOpen` right even
  if something changes the mode without an edge, as `OPT_MODE` does.
- **A force-off is logged** at `.notice` on `com.tbd.app` / `terminalEngine`, with how long
  the hold was seen and how many ticks it skipped. That makes the deferred item's trigger
  visible in the A/B logs.
- **After a hold** – the call that ends a hold signals a render. When `holdEnded` is set and
  no hold is open, rule 7 lets the frame through whatever its size, because the program
  promised that a finished hold is a complete frame. Claude Code wraps its frames in mode
  2026, so this is the case that matters most for its echo and its scrolling. A chunk that
  ends one hold and starts another leaves `holdOpen` set, so rule 3 sends it to the tick.

### Drop, never block

Today a tick can block the main thread in two places. `FrameRing.acquire()` waits on a
semaphore until the GPU frees a slot, and `nextDrawable()` can wait up to a second for a
drawable. The design drops the frame instead, as termio does, and the next tick draws the
newer screen.

- **The ring** – `FrameRing.tryAcquire()` returns nil rather than waiting
  (`wait(timeout: .now())`). The ring also keeps an atomic count of slots in use. The count
  goes up at `commit` and down when a command buffer's completion releases its slot, so
  `hasFreeSlot` can be read without taking a slot. `acquire()` stays, for the live-resize
  path only.
- **The drawables** – a `DrawableTracker`, one per view, because the drawables belong to the
  view's layer and outlive a surface detach. The renderer is handed it with each frame.
  - Each drawable the renderer acquires adds an entry, with an id and the frame's `now`.
  - A presented handler, now always installed, removes the entry. It still calls
    `onFramePresented` when one is set.
  - The one path that drops an acquired drawable unpresented, a failed render encoder,
    removes the entry too. Removal is by id, so whichever of the two runs second finds
    nothing.
  - **The backstop.** An offscreen window's drawable may never be reported presented, which
    `TerminalEngineInstrumentTests` records as a known issue. A lost report would hold the
    count up and stop the view drawing for good. So an entry older than
    `presentReportTimeout`, 100 ms or about twelve 120 Hz frames, stops counting, measured
    against the frame's `now`. The first such release in a run logs a `.notice`, so a soak
    shows whether reports go missing.
  - The handler also counts presents that report a `presentedTime` of 0, which the Metal
    header documents as a frame that "has not been presented or has been skipped". A count
    that rises while typing is the sign of the shared-vsync risk under "Risks".
- **Where the limits are checked** – `renderNow()` checks both limits before it builds
  anything. At either limit it returns early, so it takes no lock and consumes no dirty
  state, and it keeps `needsUpdate` set, so the link keeps ticking until the GPU catches up.
  That last part is a change the tick needs. Today's `needsUpdate = surface.needsDisplay`
  would park the link, because output that was never built leaves the surface looking clean.
  `tryAcquire()` still guards the slot after the build. It cannot fail there, because only
  main takes slots.
- **Live resize keeps today's behaviour.** While `presentsWithTransaction` is set,
  `renderNow()` from `setFrameSize` skips both checks, blocks on the ring and always encodes.
  The flag promises Core Animation that the transaction will end with an explicit
  `present()`. A skipped frame breaks that promise, and the resize stalls until mouse-up,
  which is why the renderer already encodes every frame while the flag is set
  (`forceEncode`). The link is paused during a drag and the leading edge does not run, so
  nothing else competes for drawables there. While a drag is held still, output still waits
  for the next `setFrameSize` or the end of the drag, as it does today.

### The off switch

The whole engine sits behind `useGhosttyTerminalEngine`, which is off by default and turned
on in Settings ▸ Terminal ▸ Experimental. That flag is this design's off switch, and it meets
CLAUDE.md's default-off rule: everything this design changes runs only in terminals built on
the engine. The design adds no setting, no hidden key and no pacing mode. The
A/B already compares libghostty with SwiftTerm, so it needs no second libghostty arm, and one
frame path is less to maintain than two.

## Risks

- **A redraw split across writes** – a program that does not use mode 2026 and writes one
  screen update in several small writes can show the first part for one frame. The size
  limit and the one-frame-per-interval rule bound this to a single frame, which the next
  frame replaces. If the A/B or daily use shows it, the fallback is foot's short coalescing
  timer, 0.5 ms and reset by each chunk. That would be a new delay, on the injected clock.
- **A late leading-edge frame sharing a vsync with the next tick** – a frame drawn just
  before a vsync can miss it and land on the same vsync as the next tick's frame, which
  wastes one of them. Rule 4 limits this to a tick frame drawn from output that came later
  and was coalesced. The skipped-present count shows it. If it shows, the fix is Zed's GPUI
  rule: skip a tick that falls within a quarter of an interval of the last encode.
- **View tests that count frames** – a feed into a visible, sized view now draws inside the
  relay delivery, one main-queue turn later, without `renderTick()`. Tests that count frames
  after a feed change, and so does the fixture (see "Testing").
- **A lost present report** – the backstop covers it, and its `.notice` says how often it
  happens.

## Testing

Tests run under `scripts/test.sh`. View tests use the offscreen fixture in
`GhosttyTerminalViewTests`, with `windowVisibility = { _ in true }` and the `now` seam. The
fixture's window has no screen, so its refresh interval is `fallbackRefreshInterval`. Metal
may never report its drawables presented, so the fixture reports each one through a test seam
on `DrawableTracker`. The tests of the limits leave those reports out.

- **The policy** – one case per reason and one for `.drawNow`, plus the boundaries:
  - exactly 1,024 bytes coalesces, and 1,023 draws
  - exactly one interval since the last output frame draws, and no output frame yet draws
  - a hold that ended in the chunk lets 50 KB through
  - a hold that ended and began again in one chunk coalesces with `.holdOpen`
- **The interval** – the link's interval while it runs; the screen's
  `minimumRefreshInterval` while the link is paused and before its first tick after a resume;
  the fallback with no screen.
- **The view:**
  - Feeding `a` commits a frame after one main-queue turn, with no `renderTick()`.
  - A second feed 2 ms later draws nothing until `renderTick()`. A feed one interval after
    the last output frame draws at once.
  - After `resetCursorBlink()` and a tick that draws the cursor frame, an echo feed draws at
    once.
  - 2 KB fed in one chunk draws nothing until `renderTick()`.
  - `ESC[?2026h` plus text draws nothing. `ESC[?2026l` then draws at once.
    `ESC[?2026l ESC[?2026h` in one chunk draws nothing at once.
  - A live resize draws no leading-edge frame.
  - With the ring full, or with two drawables unreported, a tick builds nothing and keeps
    `needsUpdate`, and the view draws once the limit clears. The backstop releases an
    unreported drawable once `presentReportTimeout` of `now` has passed.
- **Hold edges, on a real `GhosttyTerminal`:**
  - setting mode 2026 opens one hold, and resetting it ends the hold
  - an in-band RIS (`ESC c`) and `reset()` each end a hold, and so does `resize`
  - a second set during a hold, and a reset with no hold, raise nothing
  - a muted feed still records edges
  - the watchdog's force-off raises no edge and clears `holdOpen`
  - attaching over a terminal whose mode 2026 is set starts with the hold open
  - a force-off logs its notice
- **The watchdog** – it still forces the mode off after 1 s of unbroken hold by injected
  `now`, including back-to-back holds that span every tick.
- **The ring** – `tryAcquire()` gives three slots and then nil, without blocking. A release
  frees one, and `hasFreeSlot` follows both.
- **The tracker** – acquiring adds an entry and the handler removes it. The drop path and the
  handler together remove it once. The timeout releases an entry.
- **The engine contract suite** – no new case. Draw timing is not part of the
  `TerminalEngine` seam, and whether SwiftTerm draws at once offscreen was not checked, so
  such a case would hold for one engine only. The suite stays green, and so do
  `TerminalEngineInstrumentTests`, which draw through `drawFrameNow()`.

## Done test

Parity is measured with the engine's existing instruments, on a release build, as the A/B
rounds in the migration record were. The numbers go into that record.

1. **Typed echo** – two A/B/B/A runs of `scripts/diag/terminal-latency-probe.py` in engine
   mode, libghostty against SwiftTerm on CoreGraphics (`useMetalTerminalRenderer` off when
   the SwiftTerm panel is built). Each run is set up as in the first round: two holder shell
   terminals running `cat`, both on screen for the whole run, and 600 samples per arm, 250 ms
   apart and interleaved sample by sample. Each run has an idle band and a band loaded with
   one `yes` process per core. The panes are the same size, which rules out pane size. The
   probe's engine check passes before and after each run.
   - **Pass** – in each band of both runs, libghostty's draw-wait p90 is at most 1.1 times
     SwiftTerm's, and the two arms' echoes agree as closely as in the first round. 10% is
     the noise that round showed between two arms on one loop: their echoes agreed within
     about 10% in every band.
2. **Heavy output** – the second round's workloads again, with SwiftTerm on CoreGraphics and
   then on Metal, as that round ran them:
   - the 50 MB stream: a file of coloured log lines sent with `cat` into a shell, with both
     arms as tabs in one pane, A/B/B/A over 12 runs
   - Claude Code in full-screen mode, talking to the repository's zero-token fake model API,
     which streams a 10 KB answer as 40-character deltas every 25 ms; then 112 scroll steps
     150 ms apart, and Ctrl-C twice; 8 runs
   - **Pass** – libghostty's app CPU stays below SwiftTerm's in every run. Each libghostty ÷
     SwiftTerm app-CPU ratio is at most 10% above the second round's: on CoreGraphics, 0.43
     while streaming, 0.41 per scroll step and 0.79 on the 50 MB stream; on Metal, 0.54,
     0.44 and 0.49. Paint time on the 50 MB stream still matches.

Reaching parity removes the draw-wait regression. It is not a win toward graduation, and this
design does not change the engine spec's graduation rule. Graduation still needs all three
of these:

- a clear win: at least 20% at p90 on one of that spec's measures, repeated in two A/B/B/A
  runs, with no regression beyond noise on the others
- a soak with no crash that has libghostty frames
- no open daily-use gap

## Deferred and rejected alternatives

- **Drawing the frame that a hold started with** – deferred. termio copies the render state
  when a hold begins, inside `vt_write`, and draws that copy until the hold ends. So a
  program that redraws hold after hold shows every finished frame. Here, back-to-back holds
  that span every tick hide frames until the watchdog forces the mode off after 1 s and draws
  a half-built screen. termio's method is not a drop-in:
  - Our lock covers only `ghostty_render_state_begin_update`, as `render.h` advises, and main
    reads the render state after the lock drops. A copy made in the callback, on the IO
    thread, would race those reads.
  - A second render state would take the dirty rows that ours relies on, because each update
    "consumes terminal/screen dirty state"
    ([`render.h`](https://github.com/ghostty-org/ghostty/blob/vt-1.0.0/include/ghostty/vt/render.h)).
  - It changes how `FrameBuilder` and `TerminalSurface` share the render state. It is not
    sized, but is likely a few hundred lines.
  - **Trigger** – A/B logs that show runs of `.skipFrame` ending in `.forceOffAndRender`
    while Claude Code streams. The force-off notice makes these runs visible.
- **termio's writer yield on the terminal lock** – deferred. termio found that `NSLock` let a
  writer looping over chunks starve its renderer for up to 34 ms, and made the writer yield
  while the renderer waits. Our loaded A/B showed no starvation, and the 50 MB stream's draw
  wait held at one frame. Neither measured the lock itself. So first measure main's wait for
  the lock in `FrameBuilder.update` during bulk output into the drawn pane. If the wait shows,
  the yield is about ten lines.
- **Presenting for a second after input, as Zed does** – deferred. A ProMotion screen lowers
  its refresh rate when frames stop, so the first echo after a pause can wait on a slower
  refresh. Zed keeps presenting for one second after input, about 120 presents a second while
  typing. First measure whether the slower refresh shows in the draw wait.
- **Any change to SwiftTerm's timing** – rejected. SwiftTerm is the default engine and the
  comparison arm, so changing it would move the baseline.
- **An on-glass number from `MTLDrawable.presentedTime` as the gate** – rejected. Only Metal
  renderers report it, so it cannot compare libghostty with SwiftTerm's CoreGraphics
  renderer, the default. It stays a diagnostic.
- **Drawing all output at once, with no size check** – rejected. Bulk output would draw a
  frame per chunk, and a redraw split across writes would flash half-drawn screens.
- **SwiftTerm's resume-tick rule, as it is** – rejected. It ticks at once only when output
  resumes a paused link, at most once in 16 ms, and its link pauses only after 8 idle ticks,
  about 67 ms. Typing faster than that keeps the link running, so each echo waits for a
  tick. Rule 4 asks only whether an interval has passed since the last output frame, whatever
  the link is doing.
- **A pacing switch inside the engine** – rejected; see "The off switch".

## Repo rules

- **Injected time** – the `now` seam above. The design adds no sleep and no timer, so
  CLAUDE.md's injected-clock rule has nothing new to cover, and `no_raw_task_sleep` gains no
  suppression.
- **Reclaiming orphans** – no new kind of durable resource: no files, processes, tmux
  objects, git refs or database rows. No reconciler changes.
- **Storage** – no migration, no `config` column and no UserDefaults key.
- **Branch tests** – every branch of `LeadingEdgePolicy` has a test. The engine flag's own
  branches are already tested by the engine's factory tests.

## Attribution

- **termio** (MIT) – hold edges from `RENDER_HOLD`, and dropping a frame instead of blocking.
  The deferred writer yield and hold-start frame are its ideas too. Each file that adapts its
  work carries a one-line source note at the top, naming termio's commit and file, as the
  files adapted from tkzmux do. termio's licence, with its copyright line, ships with the
  target as `LICENSE-termio.txt`, next to `LICENSE-tkzmux.txt`.
- **Alacritty** (Apache-2.0 or MIT) and **SwiftTerm** (MIT) – drawing at once after a quiet
  refresh interval (`FrameTimer::compute_timeout` and `FrameDriver.tickAfterResumeIfDue`). The
  file that holds `LeadingEdgePolicy` credits both in its header.
- **kitty** (GPL-3.0) and **iTerm2** (GPL-2.0) – the small-output check, as an idea only. No
  code comes from either.
- **Zed's GPUI** (Apache-2.0) – the shared-vsync fix named under "Risks", should it be needed.

## Size and order of work

About 250 lines of code and 300 of tests:

- **Drawables** – `Render/FrameRing.swift` and `Render/TerminalRenderer.swift`, plus the
  tracker in a new `Render/DrawableTracker.swift`: `tryAcquire()`, the slot count, the
  always-installed handler, the drop path and the backstop. Also the limit check and early
  return in `GhosttyTerminalView.renderNow()`. About 70 lines.
- **The terminal** – `GhosttyTerminal.swift`: the hold callback and its two values, the byte
  counter, and `RenderHint` in `Aftermath`. About 60 lines.
- **The watchdog** – `Input/InputBinding.swift`: reading `holdOpen`, the force-off that
  clears it, the attach read and the notice. About 20 lines.
- **The view** – `GhosttyTerminalView.swift` and `Render/FrameBuilder.swift`:
  `LeadingEdgePolicy`, the `now` seam, the refresh interval, `lastOutputFrameAt`, the relay's
  hint, the leading-edge draw, and reading the byte counter in the `begin_update` hold. About
  100 lines.
- **Tests** – about 300 lines.

The work runs as three PRs, split by file territory:

1. **Drawables** – the ring, the tracker, the renderer, and the limit check and early return
   in `renderNow()`. It branches from `main`. The tick stops blocking main, and nothing else
   changes. It also moves the view tests' helpers to report presents.
2. **Hold edges** – `GhosttyTerminal.swift`'s callback and values, and `InputBinding.swift`.
   It branches from `main`, independent of the first. Frames skip as they do today, but from
   edges in place of the mode read.
3. **The leading edge** – the byte counter, `RenderHint` through `Aftermath` and the relay,
   `LeadingEdgePolicy`, the `now` seam, the interval and the delivery's draw. It needs both
   others, so it starts once they merge, or stacks on them (see the `stacked-prs` skill). The
   done test runs after it merges.

## Sources

- The engine's design – [`2026-11-07-libghostty-terminal-engine-design.md`](2026-11-07-libghostty-terminal-engine-design.md)
- The migration record and its A/B rounds – [`docs/research/2026-10-28-terminal-engine-libghostty.md`](../research/2026-10-28-terminal-engine-libghostty.md)
- The latency instruments – [`2026-09-22-terminal-transport-latency-instrument-design.md`](2026-09-22-terminal-transport-latency-instrument-design.md)
- libghostty-vt headers at `vt-1.0.0` – [`terminal.h`](https://github.com/ghostty-org/ghostty/blob/vt-1.0.0/include/ghostty/vt/terminal.h) (`GhosttyTerminalRenderHoldFn`, `GHOSTTY_TERMINAL_OPT_RENDER_HOLD`, `ghostty_terminal_reset`, `ghostty_terminal_resize`) and [`render.h`](https://github.com/ghostty-org/ghostty/blob/vt-1.0.0/include/ghostty/vt/render.h) (`ghostty_render_state_begin_update`)
- termio at `8196587`, MIT – [`TermiodStreamView.swift`](https://github.com/termio-sh/termio/blob/819658751635eb298a467f4d84e793729c5242bc/Sources/termio/Terminal/Termiod/TermiodStreamView.swift), [`TermiodStreamRenderer.swift`](https://github.com/termio-sh/termio/blob/819658751635eb298a467f4d84e793729c5242bc/Shared/Sources/TermioStream/TermiodStreamRenderer.swift), [`TermiodStreamTerminal.swift`](https://github.com/termio-sh/termio/blob/819658751635eb298a467f4d84e793729c5242bc/Shared/Sources/TermioStream/TermiodStreamTerminal.swift), [design note](https://github.com/termio-sh/termio/blob/819658751635eb298a467f4d84e793729c5242bc/docs/design/20261024-client-vt-follows-the-stream.md), [`LICENSE`](https://github.com/termio-sh/termio/blob/819658751635eb298a467f4d84e793729c5242bc/LICENSE)
- SwiftTerm, TBD's fork at `b4db5b0` – [`FrameDriver.swift`](https://github.com/cheapsteak/SwiftTerm/blob/b4db5b0ecd62db7a8ebdc4dbff8b82b8ed704e9a/Sources/SwiftTerm/Apple/FrameDriver.swift)
- Alacritty – [`alacritty/src/display/mod.rs`](https://github.com/alacritty/alacritty/blob/master/alacritty/src/display/mod.rs) (`FrameTimer`)
- Ghostty – [`window-vsync`](https://ghostty.org/docs/config/reference), [`src/renderer/Thread.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/renderer/Thread.zig)
- kitty – [`kitty/child-monitor.c`](https://github.com/kovidgoyal/kitty/blob/master/kitty/child-monitor.c), [commit `b0d3d1b4c0`](https://github.com/kovidgoyal/kitty/commit/b0d3d1b4c0)
- iTerm2 – [`iTermUpdateCadenceController.m`](https://github.com/gnachman/iTerm2/blob/master/sources/PTYSession/iTermUpdateCadenceController.m)
- WezTerm – [`window/src/os/macos/window.rs`](https://github.com/wezterm/wezterm/blob/main/window/src/os/macos/window.rs)
- foot – [`render.c`](https://codeberg.org/dnkl/foot/src/branch/master/render.c)
- Zed – [`crates/gpui_macos/src/window.rs`](https://github.com/zed-industries/zed/blob/main/crates/gpui_macos/src/window.rs), [`crates/gpui/src/window.rs`](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/window.rs)
- Apple – [`presentsWithTransaction`](https://developer.apple.com/documentation/quartzcore/cametallayer/presentswithtransaction), [`maximumDrawableCount`](https://developer.apple.com/documentation/quartzcore/cametallayer/maximumdrawablecount), [`nextDrawable()`](https://developer.apple.com/documentation/quartzcore/cametallayer/nextdrawable()), [`presentedTime`](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime), [`targetTimestamp`](https://developer.apple.com/documentation/quartzcore/cadisplaylink/targettimestamp), [`NSScreen.minimumRefreshInterval`](https://developer.apple.com/documentation/appkit/nsscreen/minimumrefreshinterval)
