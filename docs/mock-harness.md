# Mock Data Harness

Launch an isolated, hand-seeded daemon+app pair for UI development and staged
screenshots — without touching your real `~/tbd` state or the running instance.

## Usage

    scripts/mock.sh up [scenario]   # build, seed, launch an isolated daemon+app (default scenario: "default")
    scripts/mock.sh shot <name>     # screenshot the mock window -> artifacts/mock/<name>.png
    scripts/mock.sh restart [scen]  # rebuild, then reseed + relaunch
    scripts/mock.sh down            # kill the mock pair, remove its scratch home

The mock instance runs under `TBD_HOME=/tmp/tbd-mock/home` with its own socket
and database. It is launched by direct-exec of this worktree's
`.build/debug/TBD.app` binary, so it never touches `/Applications` or the
`tbd://` deep-link registration your real instance owns.

The mock daemon has a pty-holder registry like any daemon, so `up` builds
`TBDHolder` beside it. A session opened in the mock window starts a real holder
under the mock's `TBD_HOME`, and `down` kills any such holder by its rendezvous
socket, never by name.

## Scenarios

Committed under `Tests/Fixtures/mock-state/`:

- `scenario-<name>.json` — repos, worktrees (status, PR badge, conflicts,
  parent/child, archived), and terminals (kind, activity state, transcript).
  Each seeded terminal is a pty-holder row with no holder behind it, so the
  daemon's startup adoption finds no holder and reads the session as ended.
- `transcripts/*.jsonl` — transcript fixtures referenced by `transcriptFixture`.

Add a scenario by copying `scenario-default.json` to `scenario-<name>.json` and
running `scripts/mock.sh up <name>`. Use only placeholder repo names
(`acme` / `acme-prod`).

## Scope

Tier 1: sidebar, transcript pane, dialogs, toolbars, PR badges. Terminal
*scrollback* panes are not populated (no live holder behind a seeded row) —
that is a deferred Tier 2 follow-up. Seeding spawns no live `claude`/`codex`
process.

This harness fakes TBD's own state, not the model; to run a real `claude`
against a fake model API for zero tokens, see
[`fake-model-api.md`](fake-model-api.md).
