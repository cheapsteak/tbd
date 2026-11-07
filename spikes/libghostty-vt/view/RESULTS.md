# ghosttyview results

THROWAWAY. `ghosttyview` is a standalone window that runs a real command in a real PTY, drawn by a Swift Metal renderer over stock libghostty-vt 1.0.0. It touches no TBD source. All `out/` paths below are relative to `spikes/libghostty-vt/`, which git ignores, so they exist only on the machine that ran this.

## The short answer

- **Claude ran and was seen.** The real Claude Code 2.1.319 TUI ran on the fake model API with zero tokens. Typing, a streamed 40-line answer, Shift+Return in the composer, a three-line paste, wheel scrolling, selection, and repeated resizing all worked, and each was checked on a picture.
- **The engine and renderer are not the risk.** 120 resizes during streaming lost none of 4,481 lines. 20 panes kept up with paced output at 118 frames a second per pane.
- **The worst breakage is the keyboard.** Ctrl-M and Ctrl-I do not work at a shell prompt, because the encoder sends `CSI 109;5u` and `CSI 105;5u`. In `zsh`, Ctrl-M prints `09;5u` and a later Return runs `5u` as a command.
- **Other serious gaps.**
  - The wheel does nothing in `less` and `vim`.
  - Powerline and Nerd glyphs are tofu with Menlo.
  - IME composition text is invisible while typing.
  - Kitty images are accepted and answered `OK`, then never drawn.
- **Code TBD would own.** 10,222 lines were kept (6,480 code lines). TBD would own about 9,400 of them (about 5,900 code lines), because its daemon side already owns the PTY. Closing the gaps adds an estimated 1,000 to 2,000 lines, before TBD's transport and handover work.
- **Port effort.** Small. The tkzmux pin differs from 1.0.0 by 1,275 changed code lines across 26 headers. After a header audit, the compiler found no further API errors. The real hazard is the changes the compiler cannot see.

## Revisions

- **libghostty-vt** – tag `vt-1.0.0`, official xcframework, zip SHA-256 `2c32b7409b2b6c2ef6cfd606526de357762ad458bdc27134ad074e86506a8bc2`. No Zig and no patches.
- **tkzmux** – commit `c961533ffc452e67d4e79d83b535bf50f83b5433`, MIT, which pins Ghostty `82232ecde55`.
- **Claude Code** – 2.1.319, through `scripts/claude-stub.py`.
- **Toolchain** – Swift 6.2.4, tools 5.9, Swift 5 mode, macOS 27.0.1, 12 logical CPUs, 120 Hz display.
- **Font** – Menlo 13 pt unless stated, cell 16 by 30 device pixels.

## Port change list

### The 16 names

- **Cursor styles** – both `GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_*` and `GHOSTTY_TERMINAL_CURSOR_STYLE_*` became `GHOSTTY_CURSOR_STYLE_*` on `GhosttyCursorStyle`. Values 0 to 3 are unchanged, and both old enum types are gone.
- **`GHOSTTY_RENDER_STATE_OPTION_DIRTY`** – became `GHOSTTY_RENDER_STATE_OPT_DIRTY`, and its value changed from 0 to 1 because `OPT_INVALID` now takes 0.
- **`GHOSTTY_SCROLL_VIEWPORT_DELTA` and `_ROW`** – became `GHOSTTY_TERMINAL_SCROLL_VIEWPORT_*` with the same values. `DELTA_PROMPT` (4) is new.
- **`ghostty_key_encoder_setopt[_from_terminal]`, `ghostty_mouse_encoder_setopt[_from_terminal]`** – became `_set[_from_terminal]`, and they now return `GhosttyResult`.
- **`ghostty_surface_key_translation_mods`** – only a comment. It is an apprt API that libghostty-vt does not export, so no code changed.
- **`ghostty_terminal_selection_format_alloc`** – removed. The replacement is a formatter with `GHOSTTY_FORMATTER_OPT_SELECTION`. NULL there means the whole screen, so the active selection must be read with `DATA_SELECTION` and passed in.

### Changes a symbol comparison cannot see

- **`GRAPHEMES_BUF` changed type silently** – it now takes `GhosttyCodepointBuffer*` (pointer, capacity, length), not `uint32_t*`. The old call still compiles because the getter takes `void*`. This is the most dangerous item on the list.
- **Every `OPT` enum gained `INVALID = 0`** – values moved up by one. A recompile fixes this, but a stale header would be wrong without warning.
- **`GhosttyKey` was renumbered** – a recompile fixes this too.
- **`GhosttyStyle`** – lost `size`. Its booleans and `int underline` became `uint16_t flags`: bold, italic, faint, blink, inverse, invisible, strikethrough and overline in bits 0 to 7, underline in bits 8 to 10. The macros do not import into Swift, so the bits are restated in `GhosttyVt+Swift.swift`.
- **`GhosttyStyleColor.tag`** – is now `uint8_t`, so comparisons use `rawValue`.
- **`GhosttySelection` and `GhosttyGridRef`** – lost `size`.
- **`GhosttyFormatterTerminalOptions`** – removed. Use `ghostty_formatter_terminal_new` then `ghostty_formatter_set`.
- **`ghostty_key_event_set_utf8`** – takes one `GhosttyString`, not a pointer and a length.
- **Setters** – all key event and mouse event setters now return a result, as do `mouse_encoder_reset` and `scroll_viewport`.
- **Encode buffers** – key, mouse and focus buffers went from `char*` to `uint8_t*`.
- **`DATA_CURSOR_STYLE`** – became `CURSOR_SGR_STYLE`.
- **`FG_COLOR` and `BG_COLOR`** – now return `NO_VALUE` rather than `INVALID_VALUE`. The code tests for success, so nothing changed.
- **`vt_write_until_ground`** – became `vt_write_until`.
- **Still sized and unchanged** – `GhosttyMouseEncoderSize`, `GhosttyRenderStateColors`, `GhosttyRenderStateCursor`, `GhosttyRenderStateRowSelection`, `GhosttyPaste`, `GhosttyClipboardWriteReply` and `GhosttyClipboardReadReply`.

### How hard it was

- **Header diff** – 1,275 changed lines across 26 headers. The largest are `key/event.h` (368), `terminal.h` (269), `render.h` (91) and `formatter.h` (65).
- **Compile errors** – the only ones after the port came from my own trimming, not from the API.
- **Time** – about 4.5 minutes from the port scripts to the first correct frame. That excludes the header audit before them, which was not timed, and it is an agent's pace.
- **Following the ABI from here** – `vt.h` says the C ABI is stable from 1.0, but the stability page it refers to is not in the shipped headers. The exposure is the `void*` getters and setters, where only a test catches a type change. TBD should pin a tag and read each new header diff for those calls.

## Lines kept

Code lines exclude blank lines and lines that begin as comments.

| Area | Files | Lines | Code lines |
|---|---:|---:|---:|
| Core | 12 | 3,357 | 2,188 |
| Render | 10 | 3,458 | 2,319 |
| View | 6 | 2,452 | 1,464 |
| Metal shader | 1 | 344 | 203 |
| C shader types | 2 | 329 | 119 |
| C pty shim | 2 | 282 | 187 |
| **Total kept** | **33** | **10,222** | **6,480** |
| Spike shell, not kept by TBD | 2 | 475 | 415 |
| Test harness Swift, not kept by TBD | 1 | 330 | 292 |

- **What TBD would drop** – `Pty.swift` (537 lines) and the pty shim (282 lines), because TBD's holder and tmux transports already own the PTY. That leaves about 9,400 lines, or about 5,900 code lines.
- **What that compares against** – TBD already carries a SwiftTerm fork, which this would retire. That fork was not counted here.

## Check list

Status is **works**, **broken** or **absent**.

### Claude

- **Start, prompt, answer** – works. `out/claude-1-start.png`, `out/claude-3-answer.png`.
- **Shift+Return in the composer** – works, through kitty keyboard flags. `out/claude-4-multiline.png`.
- **Wheel** – works. Claude tracks the mouse and scrolls itself, and shows its own "Jump to bottom" button. `out/u-2-wheel-up.png`.
- **Multi-line paste** – works. `out/u-4-paste.png`.
- **Reflow** – works at 70×24 and 150×44, and after a 30-step resize loop. `out/u-5-narrow.png`, `out/u-6-wide.png`, `out/u-7-after-loop.png`.
- **Selection** – works both ways. A plain drag is Claude's own and arrives by OSC 52, and Claude shows "copied 115 chars to clipboard". Shift-drag is the host's selection. `out/u-9-plain-drag.png`, `out/u-10-shift-drag.png`, `out/claude-select.log`.
- **Four instances at once** – works. `out/p4-claude.png`.
- **`/exit`** – not shown. My script left text in the composer, so it was sent as a prompt (`out/claude-5-exit.png`). This is a script fault, not a terminal fault.

### Rendering

- **`vim`, `less`, `top`** – works. `out/t-vim-*.png`, `out/t-less-*.png`, `out/t-top-*.png`.
- **Colors** – works for 256, truecolor, bold brightening, inverse, faint and invisible. `out/r-colors.png`.
- **Box drawing, blocks, quadrants** – works, drawn as sprites. `out/r-box.png`.
- **Braille** – works, through the font. `out/r-box.png`.
- **CJK wide, emoji, ZWJ, flags, VS16, keycaps, combining marks, Thai** – works. `out/r-text.png`, `out/crop-zwj.png`.
- **Bold, italic, bold-italic, all five underline styles, coloured underlines, strikethrough** – works. `out/r-styles.png`.
- **OSC 8 links** – works.
  - The links are underlined. `out/l-hover.png`.
  - Cmd-click opened `https`, revealed `file:`, and refused `javascript:`. These results are in the run's output.
  - The Cmd-hover highlight is a layer above the Metal frame, so a PNG cannot show it. It was not seen.
- **Cursor styles** – works for block, underline and bar, with a hollow block when unfocused. `out/c2/`, `out/c4/`, `out/c6/`.
- **Synchronized output (2026)** – works. Presented frames stayed at 5 through a held update, and an unterminated hold stayed at 8 until the 1 s watchdog broke it. PNGs cannot show this, because a shot renders fresh and bypasses the gate, so the evidence is the frame counter in `view/harness/sync.script`.
- **Overline** – broken. The library exposes the flag and the renderer ignores it. `out/crop-overline.png`.
- **SGR blink** – broken. The text stays static, because the renderer ignores the bit.
- **Powerline U+E0B0 onward and Nerd private-use glyphs** – broken with Menlo, shown as tofu. There are no sprites, so this depends on the font. `out/r-box.png`.
- **Legacy computing U+1FB00 and octants U+1CD00** – broken, shown as tofu. `out/r-box.png`.
- **Heavily stacked combining marks** – broken, squeezed into the cell. `out/r-text.png`.
- **BiDi and Arabic joining** – absent. Shaping is per cell, so Hebrew and Arabic appear in logical order. `out/r-text.png`.
- **Ligatures** – absent. JetBrains Mono renders every pair as separate glyphs, cleanly. Shaping is per cell, with `kCTLigatureAttributeName` set to 0. `out/ligatures.png`.

### Input

- **Key encoding** – works for letters, arrows, modified arrows, Home, End, PgUp, PgDn, F-keys, Shift+Tab and DECCKM. `out/keys-legacy.log`, `out/keys-decckm.log`.
- **Ctrl-I, Ctrl-M, Ctrl-[** – broken in legacy mode. `out/keys-ctrl.log`, `out/k-zsh.png`, `out/k-vim-1.png`, `out/k-vim-2.png`.
  - They send `CSI 105;5u`, `CSI 109;5u` and `CSI 91;5u`. Ctrl-H and Ctrl-J send plain `0x08` and `0x0a`.
  - The encoder decides this, not the host, and on purpose. `src/input/key_encode.zig` at `vt-1.0.0` leaves `i`, `m` and `[` out of `ctrlSeq` with the comment "purposely NOT handled here because of the fixterms specification", so they fall through to CSI u. With no text passed (`GV_CTRL_NO_TEXT=1`), the three chords send nothing at all (`out/keys-ctrl-notext.log`).
  - In `zsh`, Ctrl-M prints `09;5u` without submitting, and a later Return runs `5u` as a command. Ctrl-I prints `05;5u` with no completion.
  - In Vim 9.1, Ctrl-[ waits with `^[` pending and takes effect on the next key.
  - Real Ghostty is not installed, so this was not compared with it.
- **Kitty keyboard flags 1 and 31** – works, including release events and associated text. `out/keys-kitty1.log`, `out/keys-kitty31.log`.
- **Option as Meta** – works for both `both` and `never`. `out/keys-optalt.log`.
- **Bracketed paste** – works. ESC in the payload is neutralised and an unsafe paste prompts. Plain paste maps newline to CR. `out/paste-on.log`, `out/paste-off.log`.
- **Mouse reporting** – works for SGR, X10, drag (1002), motion (1003) and Shift bypass. `out/mouse-sgr.log`, `out/mouse-x10.log`.
- **Wheel in scrollback** – works. `seq 1 50000` kept about 9,744 rows against a 10,000-line limit, so the limit is page-granular. `out/i-scroll-*.png`.
- **Wheel with tracking on** – works. On the main screen it reports buttons 64 and 65 (`out/mouse-sgr.log`). On the alternate screen, `vim` with `mouse=a` scrolled the split under the pointer (`out/t-vim-3-mouse.png`).
- **Wheel in the alternate screen with tracking off** – broken. Mode 1007 is not implemented by the host, so `less` and `vim` do not move. `out/t-less-2.png` and `out/t-less-3-wheel.png` match, and so does `out/t-vim-4-altscroll.png`.
- **Focus reports** – works. `out/mouse-sgr.log`.
- **Selection and copy** – works for drag, word, line and rectangle, and copy unwraps soft wraps. `out/i-select-*.png`.
- **IME** – partly tested.
  - Commit works and wrote `日本語` to the PTY. `out/ime.log`.
  - Marked text is broken: there is no preedit overlay, so composition is invisible. `out/i-ime-marked.png`.
  - The text came from direct `NSTextInputClient` calls. No real input method was used.

### Resize while streaming

- **Scripted resize** – works, no crash. There were 120 window resizes during a coloured stream at about 320 lines a second.
- **No loss** – all 4,481 lines survived in order, with matching numbers at both ends of every line, after each later resize. This was checked by script over the whole formatted screen. `out/rs-3-done.txt`, `out/rs-4-narrow.txt`, `out/rs-5-wide.txt`.
- **Pictures** – `out/rs-1-during.png`, `out/rs-3-done.png`, `out/rs-4-narrow.png`, `out/rs-5-wide.png`.
- **Not reached** – a real drag. The script resizes with `setContentSize`, so `inLiveResize` stays false and the `presentsWithTransaction` path never ran.

### Terminal queries and events

- **Replies** – works for DA1, DA2, DA3, XTVERSION, DSR, CPR, DECXCPR, window sizes, OSC 10, 11, 12 and 4, 996, DECRQM, kitty flags, XTGETTCAP. `out/queries.log`.
- **Events** – title, bell, working directory, OSC 9 and 777 notifications, progress, OSC 52 write all arrive. OSC 52 read is refused with an empty reply, on purpose.
- **OSC 7501** – not wired in this window. The library parses it natively (`GhosttyProgramStatus`). `check/Sources/vtcheck/Signals.swift` covers it at engine level.

### Images

- **Sixel** – absent. The bytes are swallowed cleanly and the text after continues. DA1 does not claim Sixel, so well-behaved programs will not send it. `out/images.png`.
- **iTerm2 OSC 1337** – absent, swallowed cleanly. `out/images.png`.
- **Kitty graphics** – broken in a way the other two are not. The library replies `OK`, moves the cursor past an 8×2 cell hole, and the renderer paints nothing. A program believes its image appeared. `out/images.png`.

What would have to be written:

- **Kitty painting first** – the render state has an image iterator. The host needs textures, placements, z-order and scrolling. Until then, setting `KITTY_IMAGE_STORAGE_LIMIT` to 0 disables the protocol, per the header, which stops the false `OK`. That one line was not run.
- **iTerm2** – the library passes OSC 1337 to the unknown-sequence callback once `OPT_UNKNOWN_SEQUENCE` and a large `OPT_UNKNOWN_MAX_BYTES` are set. The host parses the arguments, decodes with ImageIO, and re-sends the image as kitty graphics so the library owns placement and scrollback.
  - The callback may not call `vt_write` on the same terminal, so the host must queue the image and use `vt_write_until` to keep later text in order.
- **Sixel** – the unknown-sequence callback covers only APC and OSC, not DCS. The host must slice the DCS out with the `vt_write_until` boundaries, write a Sixel decoder, re-send as kitty graphics, and advertise `4` in DA1.

This route needs no fork, but it comes from reading the headers and has not been run.

## Frame and memory numbers

CPU-side main-thread time only; GPU time was not measured. Paced and flood runs discarded the first 5 s and measured 15 s. Idle runs discarded 3 s and measured 5 s. `resize` discarded 1.5 s. `claude` includes start-up. Frames per second is the total across all panes.

| Run | Panes | Grid | Frames/s | Build ms median | Build ms p99 | Encode ms median | Encode ms p99 | Missed periods | Render busy % | Footprint MB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Idle | 1 | 80×24 | 2 | 0.00 | 0.00 | 0.07 | 0.10 | 0 | 0.0 | 146.5 |
| Idle | 20 | 36×14 | 6 | 0.00 | 0.01 | 0.04 | 0.07 | 0 | 0.0 | 179.5 |
| Paced, 200 lines/s each | 20 | 36×14 | 2,369 | 0.04 | 0.06 | 0.02 | 0.06 | 140 | 28.1 | 337.6 |
| Flood | 20 | 36×14 | 1,753 | 0.04 | 0.05 | 0.02 | 0.06 | 9,139 | 12.4 | 344.9 |
| Flood | 1 | 100×30 | 120 | 0.19 | 0.22 | 0.06 | 0.08 | 0 | 3.3 | 185.3 |
| Resize while streaming | 1 | 60–130 wide | 104 | 0.19 | 0.27 | 0.06 | 0.12 | 20 | 15.1 | 196.2 |
| Claude session | 1 | 110×34 | 4 | 0.03 | 6.68 | 0.07 | 0.62 | 24 | 0.1 | 183.0 |

- **Throughput** – flood reached about 24,000 lines a second per pane, or roughly 67 MB/s across 20 panes, with correct output. `out/p20-flood.png`. The process used about 300% CPU during flood.
- **Memory per pane** – about 1.7 MB idle at 36×14, and about 10 MB with 36-column scrollback full. A 100-column pane with full scrollback added about 39 MB. Scrollback here is capped at 10,000 lines and 24 MiB, so 20 wide panes full of history would reach about 900 MB unless the cap changes.
- **Footprint is `phys_footprint`** – from `TASK_VM_INFO`, never RSS. The 146 MB base includes Metal and the font stack. It excludes the child processes.
- **Flood frame drops** – these are not render cost. A `sample` run showed the main thread idle for 312 of 831 samples. Load average was 67 on 12 logical CPUs, with 20 flooding Python processes. I did not separate the cause further, and that sampled run's timings were discarded.
- **Machine load** – load average was between 19 and 67 throughout, so treat timing as an upper bound on a busy machine.
- **Missed periods are only meaningful under steady output** – the link parks when idle, so a short restart counts as missed. That explains the 24 on the Claude row.
- **Latency** – no number is claimed. No key-to-paint measurement was made here, and the benchmark report's corrections show how easily such numbers go wrong.
- **Against SwiftTerm** – not compared here. The engine comparison belongs to `check/`.

## Gaps TBD would have to close

Line estimates are mine and were not measured.

### Before anyone could use it

- **Ctrl-I, Ctrl-M, Ctrl-[** – send `0x09`, `0x0d` and `0x1b` from the host when no kitty flags are active. About 10 lines, plus a check of what real Ghostty does.
- **Alternate scroll (mode 1007)** – turn the wheel into arrow keys on the alternate screen when tracking is off. About 20 lines. Without it, `less`, `man` and `git log` do not scroll.
- **Powerline and Nerd glyphs** – bundle a symbols font or add sprites. About 100 lines for the Powerline shapes. Prompt themes depend on these.
- **IME preedit overlay** – draw composition text at the cursor. About 100 lines.
- **Kitty images** – disable the protocol at once with one line, then paint them later.
- **TBD's transport** – feed bytes from the holder and tmux paths instead of `Pty.swift`, and send `WRITE_PTY` output to TBD's outgoing queue. This replaces load-bearing code, so the project rules require a spec and a default-off flag.
- **Handover and snapshot** – trimmed from this window. `check/` decides whether a screen survives the trip between emulators.
- **OSC 7501 and TBD's other signals** – wire the library's callbacks into the existing reporting path.

### Soon after

- **Overline and blink** – about 50 lines together.
- **Legacy computing and octant sprites** – about 150 lines.
- **Ligatures** – run-based shaping in the frame builder. About 200 to 400 lines.
- **Trimmed tkzmux features** – file link detection, scroll indicator, runtime theme and font changes. The trimmed code exists upstream.
- **Swift 6 mode** – TBD builds with tools 6.0. I removed `isolated deinit` and `@MainActor NSTextInputClient` for Swift 5 mode, and they go back. The macOS 15 floor from `Mutex` matches TBD's.

### Only if wanted

- **Sixel and iTerm2 images** – about 500 lines together, on top of about 300 to 500 for kitty painting.
- **BiDi and Arabic joining** – neither the library nor this renderer has it. This is a large piece of work and I would leave it out.

## Limits of this evidence

- **Real keys reached the shell; the tests above did not use them.** `cua-driver` posted key events to the running process, through AppKit's normal routing, and they ran commands in `zsh`, shifted characters included. The window's offscreen render then showed the echoed result. The harness tests above call the view's handlers directly with synthesized `NSEvent`s. Real mouse events and first-responder changes were not checked.
- **Nobody has looked at a presented frame.** Every PNG here is an offscreen render read back from Metal, not a capture of the window. Link ticks (1,800 in the single-pane flood) show the frames were sent to the screen, but the only outside captures were taken with the screen locked, when the display link does not tick, and those show a blank window.
- **Right and middle mouse coordinates are harness artifacts.** Those events come from `CGEvent`, whose window is 0, so probes report screen coordinates. Button numbers are correct, as are left-button coordinates.
- **Claude ran against a stub.** Tool calls and long real sessions were not exercised.
- **Powerline with a Nerd Font was not tried.** No such font was installed.

## Live run

Run these from `spikes/libghostty-vt`, with the screen unlocked. Closing the window quits. Do not add `--stats`: it makes the run unattended, and the app then quits after about 2 seconds. Build first if `.build` is missing, from the repo root: `scripts/swift-safe build -c release --package-path spikes/libghostty-vt/view`.

A shell:

```sh
view/.build/release/ghosttyview --cols 110 --rows 34 --option-as-alt left
```

Claude on the stub, with no tokens:

```sh
mkdir -p /tmp/ghosttyview-claude && view/.build/release/ghosttyview --cols 110 --rows 34 --option-as-alt left --cwd /tmp/ghosttyview-claude --cmd "python3 $PWD/../../scripts/claude-stub.py --lines 40 --env TERM_PROGRAM=ghostty --env TERM_PROGRAM_VERSION=1.0.0 --env TERMINFO=$PWD/view/terminfo"
```

What a person should check, because no script could:

- Drag the window edge while output streams. This is the only way to reach the live-resize path.
- Type real keys, then click between panes with `--panes 4`.
- Press Ctrl-M at a prompt and Ctrl-[ in `vim`, and compare with real Ghostty if it can be installed.
- Use a real input method and confirm the composition is invisible.
