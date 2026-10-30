# herdr: history, community signal, workspaces/worktrees and notifications

*Researched 2026-10-30 as a read-only survey of the source of `herdrdev/herdr` at ee5bfb50 (2026-10-29; 1,880 commits, 2026-03-23 to 2026-10-29), `herdrdev/herdr-core` at 9edb39d (44 commits since 2026-10-23) and `herdrdev/herdr-app` at 8180cbe (146 commits since 2026-10-23), plus GitHub issues, PRs and discussions: read-only `gh` queries against `herdrdev/herdr` covered 2,747 issues, 596 merged PRs, 535 PRs closed unmerged and 1,771 discussions. It covers herdr's history, community signal, workspace and worktree model, and notifications. Citations use `path:line` for code and `herdrdev/herdr#N` for issues, PRs and discussions. TBD paths are relative to the repo root. [`README.md`](README.md) in this folder is the index and synthesis.*

Short version: herdr went from a single-process TUI to a persistent server with a client-rendered shell, then to multi-machine, in about 200 days and 56 releases. In late October 2026 it split into "Herdr 2": `herdr-core` (`hc`, a runtime that draws nothing and takes status only from OSC 7501) and `herdr-app` (a native GPUI desktop app where most UI is user-editable JavaScript "mods"). Herdr 1's biggest recurring bug class was misdetected agent state from screen scraping. Herdr 2 bans screen detection outright, which matches TBD's no-TUI-scraping rule. On worktrees, herdr users keep asking for things TBD already has: pre-remove teardown hooks, cleanup of closed checkouts, detection of worktrees created outside herdr, deletion that doesn't block the UI. herdr refused all of them. Code reading found two likely TBD gaps, neither yet reproduced live. The app's Archive appears to throw away uncommitted work with no prompt, though the CLI refuses. And a worktree that is visible in TBD appears to get its notifications swallowed even when TBD is not the frontmost app.

---

## (a) Timeline

Release cadence: 0.1.0 (2026-03-27) to 0.9.5 (2026-10-14), 56 tagged releases, many of them hotfixes. Issue intake per month: 36 (Apr), 238 (May), 239 (Jun), 563 (Jul), 600 (Aug), 621 (Sep), 448 (Oct, through the 30th).

### Eras

- **0.1–0.2, launch (Mar 27 – Apr 1).** Single-process TUI. Agent state comes from screen heuristics plus foreground-process detection. Releases added sound alerts (0.1.1), toasts and first-run onboarding (0.1.2), and workspace identity derived from the root pane's repo or folder (0.1.2). 0.2.0 added the Unix socket API, CLI wrappers, event subscriptions and `wait`, plus the two-section sidebar that splits workspace triage from per-agent detail.
- **0.3–0.4, structure and engine (Apr 3 – Apr 16).** Tabs inside workspaces (0.3.0). "Authoritative hook-driven state reporting" for pi, Claude Code, Codex and opencode (0.3.0). The Ghostty VT engine replaced vt100 (0.4.0). `done` became a first-class API status (0.4.5). 0.4.11 switched from silent background updates to manual `herdr update`, to avoid mixed-version states ahead of persistence.
- **0.5.x, persistence (Apr 21 – May 19).** The headless server with thin clients became the default (0.5.0, herdrdev/herdr#40). Later releases added named sessions (0.5.3), terminal and OS notification delivery (0.5.1, 0.5.9), `herdr --remote` over SSH (0.5.6) and a mobile layout (0.5.5). Almost every release bumped the protocol version and forced a server restart.
- **0.6.x, workflow features (May 20 – Jun 11).** Keybinding v2, a breaking change (0.6.0). Git worktree groups with native create, open and remove (0.6.1, herdrdev/herdr#137), and worktree CLI/API (0.6.2). Native agent session restore (0.6.3, on by default from 0.6.7). The session navigator, copy mode and live handoff. A preview update channel (0.6.7). Remotely updated detection manifests and `herdr agent explain` (0.6.9).
- **0.7.x, extensibility (Jun 15 – Jul 21).** Plugins v1 with GitHub install and a marketplace (0.7.0). `pane.move`. Stable short IDs `w1`, `w1:t1`, `w1:p1` (0.7.0, herdrdev/herdr#569). Popup panes, token-based sidebar row layouts, and terminal `observe`/`control` streams for bridge clients (0.7.2). A live-agent CLI facade, `agent start/prompt/send-keys/wait` (0.7.5).
- **0.8.x, opening up (Aug 3 – Aug 19).** Relicensed from AGPL-3.0 to Apache-2.0 (herdrdev/herdr#1340). Moved to the `herdrdev` org. Windows reached general availability. Added window-title sync, tab-bar status entries and `herdr --skill`. The unsolicited-PR gate closed in the same weeks (see d).
- **0.9.x, re-architecture and robustness (Sep 7 – Oct 14).** The client now renders the shell (herdrdev/herdr#3487), with stable endpoint generations (herdrdev/herdr#3509). Several SSH machines in one window (herdrdev/herdr#3670). Independent per-client views (herdrdev/herdr#3526). Native Kitty graphics replaced the custom graphics API (herdrdev/herdr#4561). Agents can report their own resume command (herdrdev/herdr#4687). Robustness work: 48 layout snapshots, atomic saves, and saving before OS shutdown.
- **Herdr 2 (from Oct 23).** Two new repositories:
  - `herdr-core`, "a runtime, not a multiplexer" (`herdr-core/AGENTS.md`). Status comes only from OSC 7501. Agents start child agents, which report back to them.
  - `herdr-app`, a GPUI desktop app with a small core where "everything else is mods" (`herdr-app/AGENTS.md`).

  herdr-core's rule for contributors: "Fresh code. Do not copy from Herdr 1… Read it for ideas, lessons and edge cases."

### Features added, then removed or reworked

- **Agent state authority.** This reversed twice.
  - 0.3.0 made hook reports "authoritative".
  - 0.6.7 cut the Claude Code, Codex, Copilot, Droid, Kimi and Qoder integrations back to reporting session identity, with state "from Herdr's screen detection". The stated reasons: hooks "do not provide complete lifecycle coverage" (Copilot, 0.6.7) and "do not cover every permission cancellation and user interrupt transition" (Devin, 0.7.0). Before that came a run of stale or out-of-order hook bugs (herdrdev/herdr#198, 23 comments; stale-report rejection in 0.5.8; subagent hooks reviving idle panes in 0.5.2 and 0.6.0).
  - Hermes followed in 0.7.x. Codex turn hooks were dropped in 0.9.5 (herdrdev/herdr#5278).
  - A maintainer PR for a hot-updatable agent detection registry (herdrdev/herdr#3964, 23k lines) was closed unmerged on 2026-10-05.
  - herdr-core then dropped screen detection entirely: "Status comes only from OSC 7501. No screen detection, no agent registry, no vendor-specific logic. This is the one most likely to be helpfully added; don't." (`herdr-core/AGENTS.md`).
- **Updates.** Silent background install became manual `herdr update` (0.4.11), stated reason "upgrade safety… avoids mixed-version states". 0.9.0 then let a client update leave compatible servers running.
- **Single-process mode.** `--no-session` was kept as an escape hatch in 0.5.0 and removed in 0.9.0.
- **Agents panel scope filter.** Added in 0.4.2, defaulted to "all" in 0.5.6, removed in 0.7.1 in favour of always-all plus an optional priority sort (herdrdev/herdr#318).
- **Custom pane graphics API.** Added on 2026-08-08 (herdrdev/herdr#2523, 6.7k lines). Removed six weeks later on 2026-09-24 for standard Kitty graphics, as a breaking change (herdrdev/herdr#4561).
- **Spinner animation.** Restored in 0.2.1, replaced by static marks in 0.8.0 to stop continuous rendering.
- **Release notes.** Auto-opened on startup from 0.3.x; stopped in 0.6.0.
- **Experimental settings.** Removed from the Settings TUI in 0.8.0; they now live in config only.
- **Plugins.** Per-session in 0.7.0, global per user in 0.7.5.
- **Event subscriptions.** Lifecycle subscriptions replayed history until 0.9.0, then switched to live-only, with "subscribe before snapshot" guidance.
- **Version policy.** Strict build-version rejection was replaced by negotiated endpoint generations (herdrdev/herdr#3509).
- **License and contributions.** AGPL became Apache-2.0. The open PR gate became maintainer- and approved-contributor-only.

---

## (b) Biggest merged PRs (by lines changed)

- **herdrdev/herdr#3906 – libghostty upgrade (+109k/−16k, mostly vendor).** Replaced local patches with upstream APIs and kept two patches, each recorded in a patch index with its removal condition. It reports CPU deltas per workload rather than claiming a speedup. Both hosted review bots refused it as too large (Greptile limit 500 files, CodeRabbit 300), so the description says so and lists the local reviews instead.
- **herdrdev/herdr#3487 – render the shell in the client (+50k/−64k).** Moved chrome, keybindings, menus, notifications, copy mode and composition into each client. PTYs, topology, terminal state and persistence stay authoritative on the server. Removed the legacy full-app and `--no-session` paths. Measured "61–83% less total CPU" on visible workloads, and remote pane input went from two round trips to one.
- **herdrdev/herdr#40 – persistence (+33.6k/−19.2k).** Headless server plus thin client became the default, with detach/reattach and multi-client attach. The same PR split oversized modules.
- **herdrdev/herdr#3670 – many SSH machines from one client (+17.9k).** Answered the most-upvoted discussion (herdrdev/herdr#515, 104 upvotes). The maintainer turned down community implementations ("a big change i want to tackle myself") and waited until the server/client architecture could carry it. The PR thread records "accepted risks, not code fixes" explicitly in replies to the bots.
- **herdrdev/herdr#4561 – native Kitty graphics replace the custom graphics API (breaking).**
- **herdrdev/herdr#5212 – CLI and API share one command declaration.** It replayed 1,276 recorded CLI invocations from master plus about 140 probes to show that no previously working command changed.
- **herdrdev/herdr#3509 – stable client endpoint compatibility.** Frozen generation-1 codecs, advertised optional methods, and "a missing optional feature must disable only that action, not reject the connection".
- **herdrdev/herdr#3526 – independent multi-client tab views.**
- **herdrdev/herdr#4400 – keep session layouts across shutdown and restore failures.** Keeps up to 48 layout snapshots. A pane whose saved directory or shell is missing is kept with a visible error rather than dropped. Pane history is replayed only when it matches the saved layout exactly.
- **herdrdev/herdr#4457 – tell agent completion apart from startup and session changes.** Fixes false "done" on startup, restore and Pi `/new` (herdrdev/herdr#3338, herdrdev/herdr#3916, herdrdev/herdr#3990). Clears stale completion attention when a pane changes agent.
- **herdrdev/herdr#4964 – keep agent sessions while the agent is suspended.** Ties process identity to pid plus start time plus session/tty, rechecked every 5 s, so a reused pid is caught.
- **herdrdev/herdr#4687 – agents report their own `resume_argv`.** The reported command takes precedence over the built-in resume table.
- **herdrdev/herdr#1842 – stop repeated workspace git discovery.** Idle CPU went from 16.6% to 1.51% with 14 workspaces. Refreshes are demand-driven and deduplicated per checkout.
- **herdrdev/herdr#4492 – worktree lookups off the server loop.** "Slow Git operations… could freeze input."
- **herdrdev/herdr#3506 – reliably submit delayed agent prompts.** Text and Enter go out as one sequenced PTY operation. `--wait` requires observed `working` or `blocked`, with an `agent_prompt_stalled` gate after 5 s.
- **herdrdev/herdr#3973 – protect integration configs from failed writes.** Staged replacement, because a failed write had erased OpenCode preferences.

Across these PRs the maintainer's agents follow a consistent shape: failing tests first, `just check` counts, real-process smokes in throwaway sessions, scaling numbers at 1 and 15 panes, and an explicit "Limits" section.

---

## (c) Top issues and recurring bug classes

### Most-reacted and most-discussed issues

- **herdrdev/herdr#1134** – updates capped at 60 Hz (32 reactions, open). Measured input latency rises under background pane output.
- **herdrdev/herdr#1340** – the relicensing request (29 reactions, 39 comments). "Engineers… want to run herdr at work, and they can't. Their company's open-source policy rejects AGPL outright."
- **herdrdev/herdr#261** – `{repo_parent}`-style placeholders in `[worktrees].directory` (24 reactions, 13 comments). Closed as not planned, with no reason given; details in (e).
- **herdrdev/herdr#1170** – agents run over plain `ssh` don't show in the agents list (18 reactions). Closed with the `HERDR_AGENT=claude ssh -t host claude` hint.
- **herdrdev/herdr#198** – status stuck on `working` after a turn ends (23 comments). Hook races (`PostToolUse` arriving after `Stop`) plus stale integration versions.
- **herdrdev/herdr#808** – a detached or handed-off macOS server has no grantable app identity, so panes lose Local Network access and TCC consent (19 comments, open). The workaround is wrapping the server in a `.app`.
- **herdrdev/herdr#4506** – the server burned 10+ cores with about 20 idle Claude panes, in futex contention.
- **herdrdev/herdr#1217** – Claude Code waiting on a background Monitor or shell task shows idle/done. Commenters argue this is a missing state, not a misdetection.
- **herdrdev/herdr#1797** – can't delete a worktree that has submodules (16 comments). Git refuses without `--force` and herdr offered no forced retry. Fixed in 0.9.1.
- **herdrdev/herdr#4649** – Codex 0.157's shared app-server daemon runs hooks with the environment of whichever pane started it. `SessionStart` then reports to the wrong pane, "even on a different herdr server" (open).
- **herdrdev/herdr#4787** – every attached client plays its own sound. With 8 clients, 8 `afplay` processes started at once, and `coreaudiod` reached 225–330% CPU and 2.2 GB.
- Top discussions: herdrdev/herdr#515 (multiple servers, 104 upvotes, shipped). herdrdev/herdr#864, "Mark unread" for agents (51 upvotes, open). herdrdev/herdr#1620 and herdrdev/herdr#1953, grouping spaces into folders (45 and 22). herdrdev/herdr#2209 and herdrdev/herdr#480, Jujutsu workspaces (37 and 33). herdrdev/herdr#5073, OSC 7501 support (23). herdrdev/herdr#625, click a system notification to focus its pane (22). herdrdev/herdr#1428, non-blocking worktree deletion (19).

### Recurring bug classes

Counts are title-keyword matches over all 2,747 issues, so they overlap.

- **Keyboard, input and IME – 549.** Labels: `input` 248, `kitty-protocol` 52. Prefix keys, Shift+Enter, Option/Alt, CJK IMEs, and mouse reports leaking into pane input. This is the cost of sitting between a host terminal and a pane terminal. TBD avoids most of it by being a native app, but the same class shows up wherever TBD forwards keys.
- **Agent state misdetection – 391.** Label `agent-detection`: 139. Claude Code appears in 168 titles and Codex in 94. Sub-patterns:
  - False "done" on startup, restore, `/new`, or while background subagents or tasks run (herdrdev/herdr#3338, herdrdev/herdr#3916, herdrdev/herdr#3990, herdrdev/herdr#1217, herdrdev/herdr#5024, herdrdev/herdr#4329).
  - States latched by hook races (herdrdev/herdr#198).
  - Detection broken by wrappers such as nix, devenv or ssh (herdrdev/herdr#803, open, 18 comments).
  - Foreign tools running Claude hooks: Cursor CLI executes Claude Code hooks (herdrdev/herdr#2832).
- **Windows – 318.** 150 merged PRs came from one Windows-focused contributor, who is now listed in `.github/MAINTAINERS`.
- **Session restore and resume – 316.** Lost flags and environment on resume (herdrdev/herdr#1080), nested sessions overwriting the owning pane's session (herdrdev/herdr#511, herdrdev/herdr#1789), saves lost to shutdown or crashes (herdrdev/herdr#3415, herdrdev/herdr#5150).
- **SSH and remote – 267.**
- **CPU, lag and freezes – 171.** Frequent root cause: synchronous git or filesystem work on the event loop (herdrdev/herdr#1842, herdrdev/herdr#4492, herdrdev/herdr#1428, herdrdev/herdr#4578).
- **Clipboard and paste – 158.**

---

## (d) Rejected requests and product philosophy

### What maintainers refuse

- **Feature requests in the tracker.** 316 issues were labelled `feature-req` and 310 were closed as not planned. Every one is redirected to Ideas discussions. The bot's stated test is that a request "would add new behavior rather than repair existing behavior". The worktree rejections:
  - herdrdev/herdr#3849 – a pre-remove plugin hook for `docker compose down`, ddev or nix teardown.
  - herdrdev/herdr#4317 – reclaiming checkouts after their workspace closes, and bulk cleanup.
  - herdrdev/herdr#2981 – detecting worktrees an agent created with `git worktree add`.
  - herdrdev/herdr#5042 – a native base chooser and PR-stack sidebar.
  - herdrdev/herdr#1518 – `--env` on `worktree create`.
  - herdrdev/herdr#4374 – a configurable branch-name word list.

  On notifications:
  - herdrdev/herdr#5695 – toast duration and stacking.
  - herdrdev/herdr#5568 – event-driven lifecycle callbacks, closed as a duplicate of the existing `events.subscribe`.
- **Mass cleanups.** 108 issues were closed on 2026-10-01 as reports from before 0.9 ("a lot changed… open a new issue… against the current version"). A monthly `stale-close.yml` closes issues without outside engagement; 79 went on 2026-10-28.
- **Unsolicited PRs.** `CONTRIBUTING.md`: "Herdr does not accept unsolicited pull requests… many new pull requests came from people asking an agent to find anything it could change so they could become a contributor… The problem is whose agent." 535 PRs were closed unmerged, versus 596 merged. Git history shows the gate tightening:
  - 2026-04-08: issue-first gate added.
  - 2026-07-26: unapproved PRs restricted to bug fixes.
  - 2026-07-29: approved-contributor bypass removed.
  - 2026-08-06: approved-contributor gate restored. 76 names are now listed in `.github/APPROVED_CONTRIBUTORS`.
- **Big features built by the community.** For herdrdev/herdr#515 the maintainer kept the work and waited for the architecture. herdrdev/herdr#1209 (20k-line multi-host) and herdrdev/herdr#1029 (exclusive SSH integration) were closed by the gate.
- **Bug reports that propose fixes.** `CONTRIBUTING.md` bans root-cause analysis, implementation plans and patches from bug reports. The template is "roughly one screen long", and the maintainer's agent asks bounded follow-up questions.

### How they run the project with agents

- **Two maintainer-controlled bots.**
  - `akbash-bot` (128 merged PRs) is the issue agent. It reproduces, deduplicates with a linked rationale, asks one bounded question, closes after a 7-day reporter timeout (marker `kennel:reporter-timeout`), and opens fix PRs.
  - `kangal-bot` enforces the issue template, runs the PR gate, triggers AI reviews, and posts `pending-release` and `released:vX` comments (`.github/workflows/label-next-release-issues.yml`).
- **Maintainer agent workflow** (`herdr/AGENTS.md:96-130`). Task worktrees live at `../herdr-worktrees/<slug>` with branches `issue/<id>-<slug>`. Before opening a PR, rebase on `origin/master`. Treat Greptile and CodeRabbit "as part of CI" and answer every finding. "Never merge a pull request; [the maintainer] performs the final merge." Commit messages are proposed before committing. A "roundtable" is required for broad refactors.
- **Multiplicative performance paths** (`herdr/AGENTS.md:38-64`). For any work reachable from render, parsing, detection or client fan-out, first state its frequency and cardinality ("per byte, event, or render × panes, tabs, or workspaces × attached clients"). Profile with 1 and with 15 populated panes and report the scaling delta. Prefer deterministic architecture tests to wall-clock limits.
- **Refactor risk** (`herdr/AGENTS.md:157`). A change counts as refactor-risk when it touches two or more core surfaces, persisted state, IDs or restore. Name characterization tests first and run test-only invariants over "adversarial identity state".
- **Frozen wire contracts** (`herdr/AGENTS.md:83-94`). "Never update a generation-1 expectation merely to [accept] a wire change; create and negotiate a new codec or method." An appended enum variant is invisible to digest tests, so enums are reviewed as append-closed.
- **Vendored-patch index** (`herdr/AGENTS.md:207-215`). Each local libghostty patch records why it exists, the issue, its upstream status, verification, and "the exact removal condition". CI checks that every patch reverse-applies.
- **Detection testing** (`herdr/AGENTS.md:197-205`). "Unit-test Herdr's detection engine, not individual CLI agents' screen or title conventions." Agent-specific behaviour is checked with live smokes that record the CLI version.
- **Changelog curation.** Feature commits never touch the changelog. At release time a human curates entries from the `refs #N` inventory, and released issues are closed by release CI.

### Philosophy, in their own words

- "Herdr is opinionated. Its interaction patterns, layout, mouse behavior, terminology, and technical boundaries are deliberate. A working implementation is not enough when it moves the product in a direction maintainers did not choose." (`CONTRIBUTING.md`)
- "Lean, KISS, always… No abstraction before a second real caller, no config for things nobody asked to configure." and "Every action reports what was observed, never what was assumed." (`herdr-core/AGENTS.md`)
- "Core is a runtime, not a multiplexer. If a feature only makes sense with a layout or a workspace to return to, it does not belong here." (`herdr-core/AGENTS.md`)
- herdr-app's gate on growing the app core asks three questions: does the app itself act on it; can only the app see it; can mods not do it correctly even with care. "If all three are no, it belongs in mods… even at the price of some repetition." (`herdr-app/AGENTS.md`) This is the same rule as TBD's "Compile only what user-land cannot do well". In herdr-app, worktree management and toasts are now shipped mods (`herdr-app/defaults/mods/worktree/main.js`, `herdr-app/defaults/mods/toast/main.js`).

---

## (e) Workspace and worktree model compared with TBD

### herdr 1

- **Hierarchy.** Session → workspaces ("spaces") → tabs → split panes. `Workspace` (`src/workspace.rs:176-207`) has a stable public ID, an optional `custom_name` override, and cached git data (branch, ahead/behind). Its label is derived live from the first tab's root-pane cwd and follows the shell as you `cd` (CHANGELOG 0.1.2 and 0.3.0; `src/workspace.rs:61-74`). A workspace is a view onto wherever its shell happens to be, not a durable record.
- **Worktree as provenance.** A worktree is an ordinary workspace with an optional `WorktreeSpaceMembership { key, label, repo_root, checkout_path, is_linked_worktree }` (`src/workspace.rs:32-39`). The sidebar nests children under the parent repo workspace and keeps the group packed while reordering (0.8.0, herdrdev/herdr#1873).
- **Creating a worktree.**
  - The "New worktree" dialog is bound to `prefix+shift+g` (`src/config/model.rs:346-351`).
  - The generated branch is `worktree/<adjective>-<noun>-<hex4>` (`src/worktree.rs:21-32`).
  - The path is `<directory>/<repo>/<branch-slug>` (`src/worktree.rs:171-173`). One global `[worktrees].directory` defaults to `~/.herdr/worktrees` (`src/config/model.rs:870-873`, `:1193`).
  - If the branch already exists locally it is checked out. Otherwise `git worktree add -b <branch> <path> <base|HEAD>` runs (`src/worktree.rs:239-322`). The CLI takes `--base REF` (`docs/next/.../cli-reference.mdx:179`).
  - Git runs with `LC_ALL=C` so English error strings can be classified (`src/worktree.rs:324-344`).
  - There are no built-in setup hooks. Setup happens through plugins subscribed to `worktree.created`; the example plugin is `worktree-bootstrap` (`socket-api.mdx:488-505`).
- **Opening.** `worktree open` lists `git worktree list --porcelain` (`src/worktree.rs:425-525`) and focuses or opens a checkout. Opening a second repo root no longer nests under the first (0.9.4).
- **Closing.** Closing a workspace only drops herdr state and never deletes the checkout or branch. Closing a parent with open children requires `--group` (0.9.0, herdrdev/herdr#2874).
- **Removing.**
  - Runs `git worktree remove`. On a dirty or submodule refusal it asks before retrying with `--force` (`src/worktree.rs:194-199`; `configuration.mdx:111`). Branches are never deleted.
  - If git has forgotten the worktree but the folder remains, the folder is deleted only when its `.git` gitdir points into this repo's `worktrees/` directory (`src/worktree.rs:346-398`).
  - There is no archive, no revive, no orphan sweep, and no import of external worktrees.
  - The herdr-app mod adds warnings for uncommitted changes and for submodule commits that "aren't pushed anywhere: they will be lost" (`herdr-app/defaults/mods/worktree/main.js:334-335`).
- **Bug history.**
  - Synchronous git blocked typing (herdrdev/herdr#4492). Blocking delete dialogs on large repos (herdrdev/herdr#1428, 10 s to 10 min; herdrdev/herdr#4578, `endpoint_busy` locks the client).
  - Bare repos (herdrdev/herdr#497, herdrdev/herdr#2657, herdrdev/herdr#2323). Reftable branch names (herdrdev/herdr#384).
  - Submodules (herdrdev/herdr#1797). `--base "--orphan"` passed to git without `--` (herdrdev/herdr#5219, open).
  - Group-close cascades (herdrdev/herdr#3236, herdrdev/herdr#3483). The sidebar branch shows `main` for every linked worktree (herdrdev/herdr#4227, open).

### TBD

- **Model.** The worktree is the primary durable entity: a DB row with status `.creating/.active/.archived/.main`, a parent lineage pointer, PR binding and terminals.
- **Create** is two-phase (`Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift`). It uses `NameGenerator` and always bases on `origin/<default>` then `<default>` (`WorktreeLifecycle+Create.swift:719-731`), with collision retry.
- **Location.** Worktrees live at `~/tbd/worktrees/<slot>/<name>` (`Sources/TBDDaemon/Lifecycle/WorktreeLayout.swift:80-98`).
- **Hooks.** `preSession` blocks the agent until it finishes; `setup` runs alongside it; `archive` runs before removal (`docs/worktree-hooks.md`). Hooks resolve through a five-level priority chain.
- **Archive and recovery.** Two-phase archive through a rename-based deletion queue, then revive from the archived branch, plus adopt and reconcile against `git worktree list`. `OrphanGC` sweeps orphans, and auto-archive-on-merge is available.

### Where they differ, and what the herdr evidence says

- **TBD already has what herdr refused.** Every one of these was asked for in herdr and closed as a feature request:
  - pre-removal teardown (herdrdev/herdr#3849) – TBD's `archive` hook;
  - cleanup of orphaned checkouts (herdrdev/herdr#4317) – OrphanGC and `tbd cleanup`;
  - adopting externally created worktrees (herdrdev/herdr#2981) – reconcile and adopt;
  - deletion that doesn't block (herdrdev/herdr#1428, 19 upvotes) – two-phase archive and the deletion queue.

  This supports TBD's choice of worktree-as-entity with reconcilers.
- **herdr's most-wanted worktree setting is one TBD built but never exposed.** herdrdev/herdr#261 wanted per-repo or sibling locations for direnv, other filesystems and bare layouts. TBD has `Repo.worktreeRoot` (`Sources/TBDShared/Models.swift:19`) and `RepoStore.updateWorktreeRoot` (`Sources/TBDDaemon/Database/RepoStore.swift:309-319`, commented "Primarily used by tests"), and `WorktreeLayout.basePath` honours it (`WorktreeLayout.swift:80-83`). No CLI or UI sets it. Option F in `docs/worktree-location-design.md:69` is half-shipped.
- **Base branch.** herdr's CLI has `--base`; TBD has no equivalent. TBD's "New worktree from branch" only checks out an existing branch (`Sources/TBDApp/Sidebar/RowActionMenuActions.swift:209-217`).
- **Dirty-tree safety.** herdr asks before `--force`. TBD's CLI refuses but its app does not; see idea 1 in (g).
- **Workspace labels follow cwd in herdr.** That doesn't fit TBD, whose worktree names are stable.

---

## (f) Notifications and attention

### herdr 1 mechanics

- **States.** `working`, `blocked`, `idle`, `unknown`, plus `done`, which means idle with an unseen completion. A completion is Working or Blocked going to Idle (`src/app/actions.rs:22-25`). `done` becomes `idle` only on an explicit focus; reads do not acknowledge it (akbash-bot on herdrdev/herdr#3912).
- **Suppression.** A notification is suppressed only when the pane is in the active tab and the outer terminal is focused: `active_tab_suppresses_notifications(is_active_tab, outer_terminal_focus)` (`src/app/actions.rs:38-43`). 0.5.3 added this "so active work does not go quiet just because you switched to another app". 0.5.4 marks a pane seen when you come back.
- **Sound.** `Request` plays for every new `blocked`, even in the active tab. `Done` plays only for completions that aren't active-and-focused (`src/app/actions.rs:45-63`, `:136-147`). Built-in mp3s play through `afplay` on macOS. Custom mp3s can be set per kind, sounds can be muted per agent (Droid is muted by default, 0.1.1), and `HERDR_DISABLE_SOUND` turns them off (`src/sound.rs:30-63`).
- **Debounce with recheck.** With `delay_seconds > 0`, a notification is held. At its deadline it is delivered only if the pane is still in the expected state and still has the same agent label (`src/app/actions.rs:1862-1930`, `:1932-1960`, `:2019-2055`). This filters flicker.
- **Delivery.** Three channels:
  - an in-app toast, one at a time, with fixed durations of 8 s for attention and 5 s for finished (`src/app/api.rs:743-757`);
  - terminal notifications: OSC 9 for Ghostty, iTerm2 and WezTerm, OSC 99 for Kitty, wrapped for tmux (`src/terminal_notify.rs:11-56`);
  - OS notifications via `terminal-notifier`, `osascript` or `notify-send`. Windows notifications are actionable and jump to the pane (0.9.4).
- **Navigation.** Clicking a toast jumps to its pane, and `keys.open_notification_target` does the same from the keyboard.
- **Sorting.** The attention order is blocked > unseen done > working > seen idle (`src/app/api_helpers.rs:1-9`). It drives sidebar rollups and the optional priority sort (herdrdev/herdr#318).
- **API.** `notification.show` lets plugins and agents post notifications, with a rate limit (0.6.9).

### Herdr 2

- Toasts are a replaceable mod (`herdr-app/defaults/mods/toast/main.js`). The app adds a Priority view of agents, pinned agents and foldable groups (herdr-app CHANGELOG 0.1.4).
- `hc` routes attention to agents as well as to people: "hc itself notifies you when a child cannot report (blocked, error, exited)" (`herdr-core/crates/herdr-core/src/SKILL.md`).

### What users complained about

- **False "done".** On startup, restore, `/new`, or while background subagents, Monitor or shell tasks run: herdrdev/herdr#3338, herdrdev/herdr#3916, herdrdev/herdr#3990, herdrdev/herdr#1217, herdrdev/herdr#5024, herdrdev/herdr#4329, herdrdev/herdr#1017, herdrdev/herdr#3530.
- **Losing track of finished work.** A glance or an accidental focus marks it seen, and there is no way back. herdrdev/herdr#864, 51 upvotes:
  - "The pane finished while I was away, herdr had focus, so the completion was consumed… I never read a word of it."
  - Proposals: a sticky Mark unread, and a 1 s focus dwell before marking seen.
- **Duplicates and leftovers.** Duplicate sounds per client (herdrdev/herdr#4787). Stale Done badges on a newly attached client (herdrdev/herdr#4418). A toast that never went away (herdrdev/herdr#1827). Linux toasts piling up as separate cards (herdrdev/herdr#4596).
- **Delivery identity.** `osascript` banners show as "Script Editor" (herdrdev/herdr#916, herdrdev/herdr#1157). A click opens Finder (herdrdev/herdr#5066). `notify-send` sets no app name (herdrdev/herdr#3638).
- **Requests.** Per-tab mute (herdrdev/herdr#5689) and click-to-focus from system notifications (herdrdev/herdr#625, 22 upvotes).

### TBD today

- **Types.** `NotificationType` has a severity ranking: error 4, attention/focus/limit 3, task 2, response 1 (`Sources/TBDShared/Models.swift:2441-2462`).
- **Banners.** Posted through `UNUserNotificationCenter` under the bundle identity, with the sound attached to the banner so Focus and Do Not Disturb silence both. They show even when TBD is frontmost, and a click navigates to the terminal (`Sources/TBDApp/Services/MacNotificationManager.swift:86-206`).
- **Unread tracking.** Per worktree, with background-tab bolding (`Sources/TBDApp/AppState.swift:3675-3678`). The Cmd-K Jump menu sorts unreads by recency (`Sources/TBDApp/JumpMenu/JumpMenuViewModel.swift:81-95`). `tbd terminal focus` performs a loud activation.

TBD avoids herdr's delivery-identity and multi-client problems by construction. The gaps are covered in ideas 2, 5 and 6 below.

---

## (g) Ranked ideas for TBD

1. **Give the app's Archive the uncommitted-changes guard the CLI already has.**
   - TBD now:
     - `tbd worktree archive` runs `git status --porcelain` and refuses unless `--force` (`Sources/TBDCLI/Commands/WorktreeCommands.swift:500-555`).
     - The app's row menu and archive shortcut (`Sources/TBDApp/Sidebar/RowActionMenuActions.swift:219-221`, `Sources/TBDApp/AppState+Worktrees.swift:696-716`, `:1751-1757`) call the daemon directly. In the daemon, `beginArchiveWorktree`'s `force` only skips the active-children check and the hook (`Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Archive.swift:44-61`). Removal is `git worktree remove --force` (`Sources/TBDDaemon/Git/GitManager.swift:823-831`), and the deletion queue drains immediately (`docs/specs/2026-08-10-worktree-deletion-queue-design.md`, the passage near line 272).
     - Auto-archive-on-merge takes the same path (`Sources/TBDDaemon/PR/AutoArchiveOnMergeCoordinator.swift:97-120`).
     - The GC's interrupted-archive reap does keep dirty trees (`Sources/TBDDaemon/GC/DeletionQueueCollector.swift:226-244`). The remote-lane spec says local archive "refuses on uncommitted changes" (`docs/specs/2026-08-16-remote-lane-archive-design.md:96`), but that is true only for the CLI.
     - I found no dirty check on the app path. Confirm with a live repro before acting.
   - herdr: asks before forcing removal of a dirty checkout (`src/worktree.rs:194-199`). Herdr 2 also warns about unpushed submodule commits.
   - Why: this is the one irreversible step in TBD's lifecycle. Moving the check into the daemon gives the app, CLI and auto-archive one guard, with "Archive anyway" as the confirmation. It restores a documented behaviour, so it is bug-fix sized. Auto-archive needs a separate decision (skip and notify, perhaps).
2. **Only suppress notifications for a visible worktree while TBD is the active app.**
   - TBD now: `handleNotificationDelta` returns before posting a banner whenever the worktree is selected or pinned (`Sources/TBDApp/AppState.swift:3680-3681`, `visibleWorktreeIDs` at `:729-735`). `refreshNotifications` auto-marks those worktrees read (`:4558-4580`). Neither checks `NSApp.isActive`, although the app already observes activation for git cadence (`:2620-2650`). So when an agent finishes in the selected worktree while you're in another app, you get no banner, no sound and no unread.
   - herdr: suppresses only when the tab is active and the outer terminal is focused (`src/app/actions.rs:38-43`, 0.5.3). That fix came from this exact complaint, and herdrdev/herdr#864 shows the cost when it goes wrong.
   - Why: small, deterministic, and consistent with the intent "don't notify about what the user is looking at". Gate both the early return and auto-mark-read on app activity, and run the mark-read on `didBecomeActive`.
3. **Expose the per-repo worktree root TBD already has.**
   - TBD now: the `worktreeRoot` column, the `updateWorktreeRoot` store method and `WorktreeLayout` support all exist, but only tests use them (see e).
   - herdr: one global directory. The placeholder request (herdrdev/herdr#261) is its most-reacted worktree issue, closed without explanation. Users wrote plugins (herdr-worktrunk, herdr-repo-worktrees). Herdr 2 made the root a constant in an editable mod.
   - Why: per-repo roots answer direnv/`.envrc` inheritance, monorepos on other volumes, and sibling layouts, at almost no compile cost. A CLI `tbd repo set-worktree-root` plus a Settings field is enough; placeholders aren't needed when the setting is per repo. It is a new user-facing setting, so it needs a short spec with a human answering the questions. Also decide whether existing worktrees stay where they are (they should) and check that reconcile and GC prefixes follow (`WorktreeLayout.legacyAndCanonicalPrefixes`).
4. **Let the user pick the base ref for a new worktree (`--base`).**
   - TBD now: always bases on `origin/<default>` (`WorktreeLifecycle+Create.swift:719-731`), even for nested lineage children.
   - herdr: has `worktree create --base REF` (`src/worktree.rs:239-259`). The native base chooser and stack context were requested (herdrdev/herdr#5042) and refused.
   - Why: stacked PRs are a first-class TBD workflow (the `stacked-prs` skill, lineage pointers). Exposing the git argument through the CLI, and defaulting a nested worktree's base to its parent's branch, fits the user-land placement rule. Needs a spec for the default and conflict-scan semantics. Validate the ref (herdrdev/herdr#5219 shows the injection risk) and pass it after `--`.
5. **A sticky "Mark unread" on a worktree, plus a short focus dwell before auto-read.**
   - TBD now: selection clears unread (`Sources/TBDApp/ContentView.swift:571-579`) and nothing can re-flag it.
   - herdr: this is its most-upvoted open notification idea (herdrdev/herdr#864, 51 upvotes; also herdrdev/herdr#691).
   - Why: with many agents, the unread mark is a work queue, and a glance shouldn't drop an item from it. A small additive menu item and an RPC that writes a synthetic unread row. The dwell, about 1 s before auto-mark-read, also guards against accidental Cmd-K hops.
6. **Order the Jump menu by attention priority, then by recency.**
   - TBD now: recency only (`JumpMenuViewModel.swift:81-95`), although severity is already modelled.
   - herdr: blocked > unseen done > working > seen idle (`src/app/api_helpers.rs:1-9`). It shipped as the Herdr 2 Priority view with pinning.
   - Why: a cheap, pure-function change. Blocked agents cost the most per minute of delay.
7. **Use OSC 7501 to make prompt delivery report what it observed.**
   - TBD now: parses OSC 7501 (`Sources/TBDShared/ProgramStatus.swift`), but a send or queued first message has no machine-observed submit confirmation. The scrape-based check from PR #398 was removed.
   - herdr: `agent prompt --wait` requires observed `working` or `blocked` and reports `agent_prompt_stalled` after 5 s (herdrdev/herdr#3506). It refuses prompts to agents that are blocked on a dialog (0.8.2, herdrdev/herdr#2788). herdr-core: "Every action reports what was observed, never what was assumed."
   - Why: closes the "said it sent, agent never started" class using a machine interface rather than the screen. Needs a spec.
8. **Keep the reconcilers, hooks and deletion queue; they are the competitive edge, so document them as such.**
   - herdr evidence: every worktree feature herdr refused is one TBD has (see e).
   - One small follow-up: the `archive` hook's 60 s timeout (`docs/worktree-hooks.md`) is tight for `docker compose down -v`, the herdrdev/herdr#3849 use case. Consider the `preSession`-style 600 s timeout or a per-repo override.
9. **Verify TBD against herdr's history.** No changes until a check finds a problem.
   - **Codex shared app-server daemon (herdrdev/herdr#4649).** Hooks run with the starting pane's environment. TBD's Codex hooks identify the terminal by `$TBD_TERMINAL_ID` (`Sources/TBDDaemon/Codex/CodexHomeManager.swift:59`, `Sources/TBDCLI/Commands/SessionEventCommand.swift:41`), and `CODEX_HOME` is per repo, so two worktrees of one repo could share a daemon and misbind sessions.
   - **macOS identity for a server spawned outside the app (herdrdev/herdr#808).** TBD's app spawns the daemon (`Sources/TBDApp/DaemonClient.swift:247-255`) and `docs/tcc-signing.md` already covers signing. But the handover restart spawns the daemon from a shell (`scripts/restart-bundle-lib.sh:1011`), and `Resources/TBDApp.Info.plist` has no `NSLocalNetworkUsageDescription`. Check Local Network access from a pane after a handover.
   - **False completion classes.** Test `responseComplete` against wake and revive of parked sessions, `/clear`, and turns that end with background Monitor or shell tasks still running (herdrdev/herdr#3990, herdrdev/herdr#3916, herdrdev/herdr#1217).
10. **Process ideas worth borrowing for CLAUDE.md or skills.** Low cost; no product change.
    - The multiplicative-path rule: state frequency × cardinality, and profile at 1 and 15 panes (`herdr/AGENTS.md:38-64`).
    - Frozen wire fixtures and append-closed enums for the daemon RPC (`herdr/AGENTS.md:83-94`). TBD's stale-daemon and schema-skew incidents are the same failure class.
    - A vendored-patch index with explicit removal conditions for the SwiftTerm forks (`herdr/AGENTS.md:207-215`).
    - Characterization tests plus adversarial identity invariants before identity refactors (`herdr/AGENTS.md:157`).
11. **Not recommended now.**
    - An issue-triage bot or closing the PR gate. herdr built these for thousands of agent-generated issues and PRs, and TBD's intake doesn't need them yet.
    - cwd-derived workspace labels: they conflict with TBD's stable worktree names.
    - Notification debounce: TBD's notifications come from discrete hook events. Revisit only if TBD starts notifying from OSC 7501 state flips.
