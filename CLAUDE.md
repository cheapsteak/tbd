# TBD

macOS native worktree + terminal manager for multi-agent Claude Code workflows.

Use the `tbd-project` skill for architecture, conventions, and file reference.

## ⚠️ Public repo, multi-tenant product

**This repository is public, and TBD is used by people across different organizations.** Never commit private context — real employer, org, repo, host, account, person, or ticket names, internal URLs, or machine-specific paths (use `acme` / `acme-prod` placeholders). **Whatever a session is working on elsewhere — product features, roadmaps, ticket and task descriptions — is likely confidential to that org and must not leak here**, in docs, specs, tests, fixtures, or commit messages. Never build or document for one repo, one project, or one person's workflow: features, defaults, and docs must generalize.

## Nightwatch is being replaced — two paths until cutover

The fleet-supervision subsystem ("Nightwatch"/"Daywatch") is being redesigned
from scratch. The target design is
[`docs/specs/2026-07-26-fleet-supervision-design.md`](docs/specs/2026-07-26-fleet-supervision-design.md)
(requirements: [`docs/specs/2026-07-26-fleet-supervision-requirements.md`](docs/specs/2026-07-26-fleet-supervision-requirements.md)).
The redesign builds a second path alongside the existing implementation;
cutover happens when the new path holds up, and both paths are live until
then. New supervision features should ideally land in both: in the existing
implementation where they're needed now, and in the new design's structures —
where the new-path half is usually user-land (a playbook, sweep-program, or
wake-program change) rather than compiled (see "Compile only what user-land
cannot do well" below).

## Main Session Agent

The main chat session agent should not write code directly. Delegate all implementation work to suitable subagents (Agent tool). The main session focuses on planning, coordination, and reviewing subagent results.

## Workflow

- Only stage and commit files you actually changed — never commit unrelated or other agents' modifications.
- Always commit after completing work. Don't wait to be asked.
- Use conventional commit messages: `feat:`, `fix:`, `docs:`, `refactor:`
- Banned words — never use these in code or in PR titles, descriptions, or commit messages: "blessed", "golden"
- No prose tables in markdown docs — use lists (bolded lead term, en-dash, prose; nested bullets when a row has several fields). A table is acceptable only when its cells are mostly short numerical or scannable values: counts, defaults, thresholds, old→new line numbers. Prose crammed into cells gets squished and unreadable.
- Spec and doc edits must leave a document that stands alone for a first-time reader. Never write revision history into prose: no "Amended \<date\>" notes, no "an earlier draft…" retracing, no reversal narratives — rewrite the superseded passage to state the current design as if it were always so; git history is the archive. Keep **evidence** ("field measurement showed X"), drop **chronology** ("removed \<date\> after review Y"). A rejected-alternatives section is welcome as timeless why-not rationale — written as rationale, never as a revision log. The one exemption is an **as-built audit record** of an existing system (e.g. [`docs/nightwatch.md`](docs/nightwatch.md)): there, dated banners recording what was measured against which tree are the evidence, and the document must declare that purpose at the top.
- Verify your changes compile (`scripts/swift-safe build`) before committing.
- Run `scripts/test.sh` if you changed daemon or shared code. It fences the run
  against the developer's real `~/tbd` and `~/.claude` (see "Tests must not
  touch ~/tbd") and invokes SwiftPM through `scripts/swift-safe`, which
  serializes builds across TBD worktrees and defaults to two compiler jobs;
  raw `swift build/test/run` is blocked by the repo guardrail because
  concurrent default `-j12` builds can exhaust this development machine. The
  two wrappers are orthogonal — admission control and filesystem isolation —
  and compose rather than replace each other.
- When adding a branching conditional that gates behavior (feature flags, toggles, mode switches), add a test for each branch. Verify the gated behavior is off when the flag is off, and that ungated behavior still works.

### Compile only what user-land cannot do well

Compiled behavior is the hardest kind to change: it ships by rebuild and release, and a flagged default needs a forcing migration to flip later. User-land surfaces — CLI output, hooks, seeded reference scripts, files under `~/tbd/repos/<repoID>/` — change by editing a file. So when deciding where new behavior lives, default to exposing the facts and actuations that make it possible outside the daemon, and compile the behavior itself only when user-land cannot do it well (per-event cost across a whole fleet, liveness attestation, integrity of the record). Capability migrates inward only on field evidence, one piece at a time — the Built/Enabled ratchet in `docs/specs/2026-07-26-fleet-supervision-requirements.md`. Motivations for wanting a change differ case by case; the placement rule does not.

### Large or risky new behavior ships behind a default-off flag

New features that act autonomously or can destroy state land gated behind a flag that defaults to OFF, soak, and only then graduate (flip the default, eventually delete the flag). Required when the feature:

- acts without a user gesture — background sweeps, timers, anything "auto-"
- kills processes, deletes or mutates persisted state, or sends input to sessions
- wholesale-replaces a load-bearing path (rendering, input routing, persistence)

Not required for bug fixes, small additive UI, or refactors — don't sprawl flags.

Mechanics: daemon-side behavior gates on a `config` column added by migration (follow "Database migrations must update the shared model" below); app-only behavior may gate on a UserDefaults key (precedent: `enableTranscript`, default-off). Test both branches (see Workflow above). State the flag name, how to enable it for the soak, and the graduation plan in the PR description.

Cautionary precedent: `auto_hibernate_enabled` shipped default-ON in `v39_session_hibernation` and had to be force-disabled in `v50` once the eat-typed-input risk was understood. Because `ADD COLUMN ... DEFAULT` backfills existing rows, flipping a default later needs a forcing `UPDATE` migration (a Swift-side default change alone is a no-op for existing installs) — and after the force-off, a user's deliberate opt-in is indistinguishable from the backfilled value, so it got reset too. Shipping default-OFF first avoids all of this. Good precedents: `control_mode_enabled`, `hibernate_input_veto_enabled` (v51).

### Work starts with a brainstormed spec

Decisions must be examinable — changes to our theory of the system or the product most of all. Code expresses a theory; a diff shows what changed, not why the theory did. So anything that is not a bug fix or a minor UI change runs `/tbd-brainstorming` **before** implementation and commits the spec to `docs/specs/<date>-<topic>-design.md`. If it needs a flag, it needs a spec.

**Prior design does not exempt.** Thinking done in prototypes, a report, another repo, or an earlier session makes the spec a cheap transcription — not an unnecessary one. Reviewers here cannot read that material, so those decisions are the ones that most need writing down.

**A human answers the brainstorming questions.** An agent may not answer its own. If none is available, stop — do not proceed on assumed answers. Agents, including the nightwatch desk, may not originate feature work; file it for a human instead.

Bug fixes and minor UI changes need no spec — a bug fix restores the system to its existing theory, while the work that needs a spec is the work that revises it. If a larger change genuinely needs none, say so in the PR description. This is convention, not a gate — no linter can see whether thinking happened. In Claude Code use `/tbd-brainstorming`, not `superpowers:brainstorming`; a guardrail redirects the wrong one. Codex has no slash command for it — read `.claude/skills/tbd-brainstorming/SKILL.md` and follow it directly.

### Restart must use the worktree's own script
Always run `scripts/restart.sh` (relative, from the worktree cwd), never an absolute path to the main project's copy. Using `/Users/chang/projects/tbd/scripts/restart.sh` builds and starts binaries from the main branch, leaving old worktree processes running and causing "Unknown method" RPC errors. After any restart, verify with:
```
ps aux | grep -E "\.build/debug/TBD" | grep -v grep
```
There should be exactly one `TBDDaemon` and one `TBDApp`, both from the worktree path. If stale processes exist: `pkill -f TBDDaemon; pkill -f TBDApp` then re-run `scripts/restart.sh`.

## Critical Rules

### NEVER delete ~/tbd/state.db
The database stores worktree display names, custom config, and notification history. Deleting it orphans tmux servers (repo UUID changes → tmux server name changes → old sessions become unreachable). If you encounter DB issues, diagnose and fix the schema/code — don't wipe the DB.

### Tests must not touch ~/tbd
`TBDConstants.configDir` and `socketPath` honor two env vars so tests, CI, and concurrent `swift test` runs across worktrees never collide with the live daemon or the developer's real config:

- `TBD_HOME` redirects the base config directory (`~/tbd` by default). Every derived path (`socketPath`, `databasePath`, `pidFilePath`, `portFilePath`, `reposDir`) follows.
- `TBD_SOCKET_PATH` overrides only the socket — an escape hatch for darwin's ~104-char `sun_path` limit when `TBD_HOME` is a deep tmp path.

Integration-style tests that exercise production code paths which internally read `TBD_HOME` — and thus cannot accept an explicit env dict — may use `setenv("TBD_HOME", "/some/tmp/dir", 1)` (and optionally `TBD_SOCKET_PATH`); for all other cases prefer the injection-seam approach, and see the next paragraph for where `setenv` is permitted. Tests that mutate `UserDefaults` should construct `AppState(userDefaults: UserDefaults(suiteName:))` and tear the suite down with `removePersistentDomain(forName:)` — `UserDefaults.standard` on this unbundled executable is the developer's real `TBDApp.plist`.

For unit tests, prefer injection seams over `setenv`: pass an explicit env dict to `TBDConstants.*(environment:)`, override the themes directory via `ThemeStore(themesDirectory:)` or `AppearanceSettings(userThemesDirectory:)`, override the profile/host claude dirs via `ClaudeProfileConfigDirManager(baseDirectory:hostBaseDirectory:)` (`makeIsolatedConfigDirManager(tag:)` in `TestSupport`). **`setenv("TBD_HOME", ...)` in tests is allowed ONLY inside suites nested under `TBDHomeSerialized` in `Tests/TBDDaemonTests`.** All test targets compile into one process and Swift Testing runs suites in parallel across all targets; an unserialized `setenv` in any other target races every concurrent suite — this was the root cause of a real CI flake in `ConstantsTests.derivedPathsFollowTBDHome`.

**Run tests with `scripts/test.sh`, not bare `swift test`.** It forwards its arguments to `swift test` behind two layers. The **fence** (always on) points `TBD_HOME`, `TBD_SOCKET_PATH`, `TBD_CLAUDE_HOST_HOME` and `TBD_TEST_CODEX_HOME` at a scratch dir, and `HOME`/`CFFIXED_USER_HOME` at a second one whose `tbd`, `.claude` and `.codex` entries are mode `000`. The last two host-store legs matter as much as the first: a default-constructed `ClaudeProfileConfigDirManager` otherwise gets a scratch profiles dir and the developer's real `~/.claude` as the host store it moves subtrees around in, and `CodexHomeManager` falls back to the real `~/.codex` and writes a plugin, hooks and a profile TOML into it. The **detector** fingerprints the real `~/tbd`, `~/.claude` and `~/.codex` on either side and fails the run if any entry appeared or vanished; it is on when `$CI` is set, off otherwise, `--fingerprint` opts in locally and `--no-fingerprint` forces it off. It is CI-shaped because on a developer box a live daemon, sibling worktrees and concurrent agent sessions write to those directories legitimately throughout a run, and a guard that reddens spuriously gets disabled. The rule above had been in this file all along and the suite violated it anyway — 18k orphan profile dirs and ~2.9k fake worktrees accumulated unnoticed — because the invariant belongs to a whole run and no per-test assertion can express it. The wrapper's guards have their own mutation-checked harness, `scripts/test.test.sh` (~11 s, no build, no real store touched), wired into the `lint` CI job — edit a guard, edit its case.

Two shapes cause that leak, and both are worth recognizing:

- **A static/ambient helper that ignores its caller's injected seam.** `ClaudeProfileConfigDirManager.resolveConfigDir` was `static` and built its own manager on `TBDConstants.configDir`, so every caller's injected temp-dir manager was decorative. If a type takes an injected collaborator, its path helpers must be instance members — do not add a static twin "for convenience".
- **A path hand-built from `$HOME`.** `WorktreeLayout.basePath` composed `"\(home)/tbd/worktrees/…"` itself, so it silently ignored `TBD_HOME` and defeated the fence. Derive every TBD-owned path from `TBDConstants`.

**Teardown must restore `TBD_HOME`, `TBD_CLAUDE_HOST_HOME` and `TBD_TEST_CODEX_HOME`, never `unsetenv` them.** Unsetting does not return to the harness's scratch home — it returns to the developer's real `~/tbd`, `~/.claude` or `~/.codex`, process-wide, for every concurrently running suite. Use `setTBDHome(_:)` / `restoreTBDHome(_:)`, `setClaudeHostHome(_:)` / `restoreClaudeHostHome(_:)` and `setCodexTestHome(_:)` / `restoreCodexTestHome(_:)` from `TestSupport`, and mutate any of the three only from a suite nested under `TBDHomeSerialized`.

### Database migrations must update the shared model
When adding a DB column in `Sources/TBDDaemon/Database/Database.swift`:
1. Add the column with a `.defaults(to:)` value in the migration
2. Update the GRDB Record type in `Sources/TBDDaemon/Database/`
3. Update the Codable model in `Sources/TBDShared/Models.swift` — new fields MUST be optional or have a default value so existing JSON/rows still decode
4. All three changes in the same commit

Migrations use GRDB's `DatabaseMigrator`, numbered sequentially (`v1`, `v2`, `v3`...). Never modify an existing migration — always add a new one.

### Per-repo config: two storage patterns

- **DB columns** (`config` / `repo` tables) for small structured settings the daemon resolves at spawn time: `envOverrides`, profile override, feature flags.
- **Files under `~/tbd/repos/<repoID>/`** for user-authored editable blobs: hooks, `notes.md`, `claude-settings.json`. Path helpers live in `TBDConstants` (`hookPath`, `notesPath`, `claudeSettingsOverlayPath`) and honor `TBD_HOME`.

File-backed settings editors in the app write the file directly (no RPC) and must show the tilde-abbreviated backing path with a copy-path button — see `RepoHooksSettingsView`. Don't add a DB column for a user-authored blob (PR #452's `claude_settings_overlay` column had to be swept back out to a file).

### Unbundled executable constraints
TBDApp runs as a bare SPM executable, not a `.app` bundle. APIs that require a bundle identifier will crash at runtime. Before using any Apple framework API, check whether it requires a bundle:
- `UNUserNotificationCenter.current()` — crashes without `CFBundleIdentifier`
- `NSApp.applicationIconImage` — must be set *after* `setActivationPolicy(.regular)`
- Any API that reads `Info.plist` keys — will return nil

Guard these with `Bundle.main.bundleIdentifier != nil` checks.

### Deep links and TBD.app bundle

`tbd://open?worktree=<uuid>` URL clicks reach the app via the `.app` bundle assembled by `scripts/restart.sh` at `.build/debug/TBD.app`. Two consequences:

- **Bundled launch is required.** `swift run TBDApp` and direct execution of `.build/debug/TBDApp` produce a process with no surrounding `Info.plist`, so LaunchServices won't deliver `tbd://` URLs to it. Always launch via `scripts/restart.sh` when testing deep links.
- **One worktree wins LaunchServices.** All TBD worktrees register the same `CFBundleIdentifier=com.github.cheapsteak.tbd`, so whichever worktree most recently ran `restart.sh` becomes the `tbd://` handler. Restart the worktree you want to receive links — others stay built but inert for URL routing.

### NIO thread safety
All `ChannelHandlerContext` property access (`context.channel`, `context.pipeline`) must happen on the channel's event loop. Accessing from any other thread triggers a precondition crash. Always wrap in `context.eventLoop.execute { ... }` — never use `context.channel.isActive` as a pre-check outside the event loop.

### No `print()` in `Sources/`
Applies to `TBDShared`, `TBDDaemonLib`, `TBDDaemon`, and `TBDApp`. **`TBDCLI` is intentionally excluded** — its `print()` calls are user-facing CLI output (stdout for human consumption + scripting), not diagnostic logging.

Use `os.Logger` (`import os`) with one of the established subsystems (`com.tbd.app`, `com.tbd.daemon`) and a feature-shaped category. `.debug` is the right level for traces you'd previously have used `print()` for — they're silent by default and activated with `log stream --level debug`. Always pass an explicit `privacy:` argument on dynamic interpolations (default `.public` for this dev tool, `.private`/`.sensitive` for secrets). Full rationale and category taxonomy: [`docs/diagnostics-strategy.md`](docs/diagnostics-strategy.md).

This rule is enforced mechanically by SwiftLint (custom rule `no_print_in_sources`) in the dedicated `lint` CI job and the pre-push git hook, both invoking a Homebrew-installed `swiftlint --strict` directly. To lint manually: `swiftlint --strict`. Prerequisite: `brew install swiftlint`. See `.swiftlint.yml`.

### New delays and timers take an injected clock

Anything that sleeps, debounces, polls, or times out takes the clock as its last initializer parameter, defaulted so no call site changes:

```swift
init(..., clock: any Clock<Duration> = ContinuousClock())
```

Existential, not generic — a generic parameter would infect the actor types these subsystems already carry `Sendable` conformances on. Timestamps that get *persisted or compared* use the separate date seam instead (`date: Date = Date()` on the method, or `now: @Sendable () -> Date` on the type): **`Duration` is behavior, `Date` is data.**

Enforced mechanically by the SwiftLint rule `no_raw_task_sleep` (same `lint` job and pre-push hook as `no_print_in_sources`). Pre-existing sites carry a visible `// swiftlint:disable:next no_raw_task_sleep - legacy sleep, …` suppression and are being burned down; adding a new one draws review scrutiny. `PollerClock` is a sanctioned exception for suspend-aware *wall*-deadline sleeping and is not a template. Seam details, test helpers, and the existential's `Instant` limitation: [`Tests/CLAUDE.md`](Tests/CLAUDE.md) "Clock and date seams".

### No TUI screen-scraping

Never infer an agent's state by parsing its rendered terminal screen — tmux `capture-pane` text, composer glyphs like `❯`, placeholder or status strings. Screen text is a display surface, not an API: scraping breaks *silently* when the TUI changes copy or rendering, couples TBD to one agent version, and sits at the wrong layer. Get agent state from machine interfaces instead: Claude Code hooks, transcript JSONL, tmux control-mode events, process exit codes, or TBD's own DB/RPC state. (Cautionary tale: PR #398 verified submits by scanning the composer line for `[Pasted text` — it defended an unreachable state and was removed as dead code.)

Enforced mechanically by two SwiftLint custom rules in `.swiftlint.yml` (`no_tui_scraping_literals`, `capture_pane_allowlist`), which run in the `lint` CI job and the pre-push hook. Three sanctioned scrapers predate this rule and are excluded with comments (interactive `/login` driving, the pending-input hibernation rail, the embedded Nightwatch babysitter) — they should eventually migrate off screen text. Adding a **new** exclusion requires a compelling justification in the PR description; the PR review gate treats unjustified additions as High severity.

### Changing the PR-review merge gate
`claude-review` is a required check on `main`, produced by the `claude-review` job in `.github/workflows/claude-code-review.yml` — a fan-out pipeline whose verdict is computed by scripts under `.github/workflows/claude-review-v2/` (`prepare.py`, `validate.py`, `render_comment.py`) rather than typed by the model. Before touching that workflow or those scripts, read [`docs/pr-review-gate.md`](docs/pr-review-gate.md) and the design spec [`docs/specs/2026-08-03-pr-review-fanout-design.md`](docs/specs/2026-08-03-pr-review-fanout-design.md). Three traps they document: the workflow runs on `pull_request_target` and **must** pass `github_token` (the OIDC app-token exchange 401s on that trigger); changing the workflow's *trigger event* requires a one-time **admin merge** (such a PR matches neither the old nor new event, so no review runs and the required check never reports); and branch protection matches the required check by **job name**, so exactly one job in `.github/workflows/` may be named `claude-review` — the retired single-session reviewer is kept in `claude-code-review-legacy.yml` with its job named `claude-review-legacy` and `workflow_dispatch` as its only trigger. It is a **restoration source, not a fallback you can run**: dispatching it exits at the fork gate without reviewing anything, because there is no `pull_request` payload outside a PR event; reviving it means re-adding the trigger and renaming the job. The `<!-- claude-review-v2 -->` comment sentinel and the `claude-review-v2/` directory name are live state matched verbatim on every open PR; don't rename either.

## Quick Reference

- **Build**: `scripts/swift-safe build`
- **Test**: `scripts/test.sh` (fences `~/tbd` and `~/.claude`, then runs SwiftPM through `scripts/swift-safe`)
- **Restart**: `scripts/restart.sh`
- **Install git hooks** (one-time setup after cloning): `scripts/install-hooks.sh`
- **Diagnostics**: see [`docs/diagnostics-strategy.md`](docs/diagnostics-strategy.md). Quick recipes:
  - Stream one feature area live: `log stream --level debug --predicate 'subsystem BEGINSWITH "com.tbd" AND category == "markdown"'`
  - Replay the last 5 minutes after reproducing a bug: `log show --last 5m --level debug --predicate 'subsystem BEGINSWITH "com.tbd"'` (requires `sudo log config --subsystem com.tbd.app --mode "level:debug,persist:debug"` once per subsystem to capture `.debug` rows)
