# libghostty-vt proof of concept

**THROWAWAY. This directory never merges to `main`.** It lives on the
`spike/libghostty-vt-poc` branch and nothing in `Sources/` or the root
`Package.swift` refers to it.

## The question

Can TBD replace SwiftTerm with stock `libghostty-vt` 1.0.0, with no fork and no
Zig, and what would that cost?

## What counts as an answer

- **Stock:** everything builds from the official `vt-1.0.0` xcframework, with no
  patches to Ghostty.
- **Same screen:** on the byte corpus, both engines end on the same text, style
  and cursor, and every difference has a named cause.
- **Handover:** a screen survives the trip between emulators. This is tested in
  every direction, including SwiftTerm to libghostty-vt, which decides whether
  the viewer could move before the daemon.
- **Speed and memory:** measured against the SwiftTerm fork TBD actually pins,
  not stock SwiftTerm.
- **Real use:** the real `claude` TUI runs in a window, with typing, scrolling,
  resize, paste, mouse and selection.
- **TBD's signals:** OSC 7501 and the other signals TBD reads reach the host.

## Layout

- `check/` is the headless engine check. It has no window.
- `view/` is the terminal window.
- `third_party/` holds the licences of code adapted from other projects.
- `fetch.sh` puts the official xcframework in `vendor/`, which git ignores.

Results go in `RESULTS.md`.
