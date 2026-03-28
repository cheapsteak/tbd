# Terminal emulation behind a swappable protocol

## Posture: Wrap (currently SwiftTerm)

We need terminal rendering but must isolate the app from API changes. The terminal adapter layer exists so the underlying library can be swapped.

## The problem

Terminal emulation is complex and the library landscape shifts. Committing to one library's API throughout the codebase creates expensive lock-in if a better option emerges (e.g., Ghostty's renderer).

## The technique

Abstract the terminal emulator behind a protocol (`TerminalRenderer`). The app talks to the protocol; the concrete implementation wraps SwiftTerm. The bridge between tmux control mode output and the terminal emulator is the highest-complexity component — the protocol should be designed with this bridging in mind.

## Why not alternatives

- **Direct SwiftTerm integration (no protocol):** Tightly couples the entire app to one library. Expensive to swap.
- **Building a custom terminal emulator:** Years of work. SwiftTerm and Ghostty exist for a reason.

## Where this applies

Any app embedding a terminal emulator where the library choice may change.
