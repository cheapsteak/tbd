# Quick Look embedded in a pane: probe

Evidence for the rejected alternative in
[`docs/specs/2026-11-03-audio-video-preview-design.md`](../../specs/2026-11-03-audio-video-preview-design.md).
It asks whether an embedded `QLPreviewView` is safe to host in TBD's file
viewer, and compares it with `AVPlayerView` on the same audio file.

`probe.swift` is a single-file AppKit program. It runs as a bare executable
with no bundle, no `Info.plist` and a nil `Bundle.main.bundleIdentifier`, the
way TBDApp runs. It opens one window holding a `QLPreviewView` and takes
commands from a FIFO, so each lifecycle step can be driven and timed. It logs
these signals:

- the time each command takes on the main thread, and main run loop stalls over
  120 ms
- CoreAudio's output state, for the default device and per process, as the
  objective playing/not-playing signal
- processes whose names suggest Quick Look or extension helpers
- the view's private `_reserved->internalState` ivar, read for diagnosis only:
  1 is activated, 2 is deactivated

## Running it

```sh
xcrun swiftc -O probe.swift -o probe
mkfifo cmd.fifo
./probe "$PWD/cmd.fifo" > probe.log 2>&1 &
echo "load /path/to/file.m4a" > cmd.fifo
```

Commands:

- `load <path>` – set `previewItem`
- `burst <ms> <path>…` – load several paths in quick succession
- `nil`, `refresh`, `close` – `previewItem = nil`, `refreshPreviewItem()`,
  `close()`
- `newview`, `freshload <path>` – replace the view; `freshload` closes the old
  one only when it is activated
- `autostarts on|off`, `closewithwindow on|off`
- `detach`, `attach` – remove the view from its superview, and re-add it
- `hide`, `show`, `contenthide`, `contentshow` – hide the view, or its parent
- `dark`, `light`, `viewdark`, `viewlight` – window or view appearance
- `closewin`, `openwin`, `mini`, `unmini`
- `state`, `ivars`, `displaystate`, `tree`, `audio`, `procs` – report
- `avplayer <path>`, `avplay`, `avpause`, `avdetach`, `avattach`, `avhide`,
  `avshow`, `avdrop` – the same steps for an `AVPlayerView`
- `ql` – switch back to the Quick Look view
- `quit`

`load` after `close`, and `close` after `closewin` with the default
`shouldCloseWithWindow`, each abort the probe by design. The two assertions are
quoted in the spec.
