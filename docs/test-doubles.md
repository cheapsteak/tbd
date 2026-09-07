# Test doubles: stand-ins for external dependencies and TBD's own state

TBD's development loop leans on four fakes. Three replace an external
dependency and one replaces TBD's own state; each answers a different question,
and picking the wrong one wastes an afternoon, so this is the index. Two test
**harnesses** follow them: not fakes of anything, but the rig that mounts the
real SwiftUI views where a test can measure and photograph them.

- **Fake model API** — `scripts/claude-stub.py`, documented in
  [`fake-model-api.md`](fake-model-api.md). Fakes the Anthropic Messages API on
  loopback and runs the **real** `claude` CLI against it, headless or in the
  interactive TUI, for zero tokens and without a real API key. Reach for it
  when you need a genuine live agent session but not a genuine answer: terminal
  rendering and resize behavior, hook wiring, session files, spawn plumbing.
  The server itself is `stub_server.py` under
  `.github/workflows/claude-review-v2/tests/e2e/`, where it also scripts the
  PR-review gate's e2e scenarios.
- **UI mock harness** — `scripts/mock.sh`, documented in
  [`mock-harness.md`](mock-harness.md). Fakes TBD's *own* state: an isolated
  daemon and app pair seeded from a committed scenario file, under a scratch
  `TBD_HOME`. It spawns no agent and talks to no model. Reach for it for UI
  work and staged screenshots — sidebar, dialogs, badges, transcript pane —
  where what matters is the state the app renders.
- **Dummy remote provider** — `scripts/dev/dummy-remote-provider.sh`. Fakes a
  remote agent backend, implementing the v1 provider contract
  ([`remote-provider-contract.md`](remote-provider-contract.md)) against plain
  JSON files in a temp directory: no network, no auth. Register it in
  `~/tbd/agent-providers.json` and hand-edit a session file to drive the
  remote-backend UI through states a real provider would take hours to reach.
- **tmux executable fixture** — `Tests/TestSupport/TmuxExecutableTestFixture.swift`.
  Fakes the `tmux` binary itself for Swift tests: a stub executable that
  reports a known version and logs each invocation, plus a resolver pinned to
  it. Reach for it when a test's behavior turns on the tmux version and must
  not depend on the host's `PATH` or the developer's saved fallback — a live
  tmux is the other tool, and slower.

## Harnesses for the app's own views

- **Offscreen GUI host** — `Tests/TBDAppTests/Support/OffscreenHost.swift`, with
  the composer-specific fixtures beside it in `ComposerHarness.swift`. Mounts a
  real SwiftUI view in a real, borderless `NSWindow` placed far off every
  display, and gives a test the four things only a mounted view has: laid-out
  frames in window coordinates, a bounded pump that drives both AppKit's run
  loop and SwiftUI's `.task`, the accessibility tree a GUI driver would see, and
  a drawn bitmap. Reach for it when the question is *where something landed* or
  *what a driver can reach* — `CompletionOverlayPlacementTests` and
  `ComposerAccessibilityIdentifierTests` are the worked examples.
  - **Two things it does not prove**, both measured rather than assumed.
    AppKit-versus-SwiftUI compositing does not reproduce offscreen: SwiftUI
    already orders its overlay above a representable sibling declared before it,
    with or without the `.zIndex` production states, so a capture guards the
    outcome and never discriminates a stacking modifier. And nothing about
    elapsed time: waits are bounded by pump count, so an animation or a
    real-clock debounce does not finish here.
  - **The accessibility tree costs something to ask for.** SwiftUI builds none
    until a client sets `AXEnhancedUserInterface`, which is process-wide and
    changes AppKit's own behavior while it is on. `withAccessibilityBridge`
    scopes it to one body and restores it; every suite that turns it on, and
    every suite that would be misled by it, is nested under the serialized
    `AccessibilityBridgeSerialized`.
- **Composer render harness** — `Tests/TBDAppTests/ComposerRenderHarness.swift`.
  Env-gated on `TBD_COMPOSER_SHOTS_DIR`: inert during a normal run, and with the
  variable set it writes `1-menu.png`, `2-attachment.png`, `3-not-running.png`
  and `4-blocked.png` at 2x into that directory, one per state the composer can
  be in.

        TBD_COMPOSER_SHOTS_DIR=/tmp/composer-shots scripts/test.sh \
            --filter ComposerRenderHarness

  Reach for it for the half of a UI assertions are bad at — a banner colliding
  with its message, a thumbnail off the baseline. Its predecessor caught the
  completion list covering the words being typed (#829) before that shipped.
  Each shot asserts its own capture is not a flat field before writing it, so a
  view that never laid out fails rather than handing over a plausible white
  rectangle.
