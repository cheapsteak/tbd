# Stand-ins for external dependencies

TBD's development loop leans on four fakes. Each replaces a different external
dependency, and picking the wrong one wastes an afternoon, so this is the
index.

- **Fake model API** — `scripts/claude-stub.py`, documented in
  [`fake-model-api.md`](fake-model-api.md). Fakes the Anthropic Messages API on
  loopback and runs the **real** `claude` CLI against it, headless or in the
  interactive TUI, for zero tokens and with no API key. Reach for it when you
  need a genuine live agent session but not a genuine answer: terminal
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
