# Test Hardening — Slicing and Parallelization Plan

**Companion to:** [`2026-07-24-test-hardening-design.md`](2026-07-24-test-hardening-design.md)
**Date:** 2026-07-24
**Purpose:** define the PR boundaries, dependency edges, file ownership, and shared contracts for executing the test-hardening design across multiple parallel agent sessions.

This document is the coordination contract, not an implementation plan. Per [`docs/CLAUDE.md`](../CLAUDE.md), implementation plans stay local scratch — each slice owner writes their own. This file is committed because parallel workers in separate worktrees need one shared, versioned reference for what they own and what they must not touch.

## 1. Why sliced, not one PR

The migrations touch real timing paths (debounces, daemon sweeps, attach timers) while wearing test-improvement clothes. Three properties argue for small slices:

- **Bisectability.** A behavior regression should land `git bisect` on a ~100-line subsystem PR, not a 3,000-line omnibus.
- **Compounding CI quality.** Slice A's CI split makes every later slice's CI quieter and more trustworthy. Landing everything at once means validating the whole redesign against today's flaky CI.
- **Review-gate fit.** The PR reviewer bot performs well on a focused diff and poorly on mixed mechanical churn plus behavior change. Slice B is deliberately boring (mechanical, zero behavior change) so it approves fast and shrinks every later diff.

No feature flags are needed: `clock: any Clock<Duration> = ContinuousClock()` defaults make each migration behavior-preserving by construction. The default-off flag policy in the root `CLAUDE.md` does not apply — these are refactors and test changes, not new autonomous behavior. Every slice's PR description should say so explicitly to pre-empt the reviewer bot.

## 2. Slice inventory

Slice IDs are stable handles (`A`, `B`, `C1`…) used in channels and branch names; they are not GitHub PR numbers.

| ID | Scope | Depends on | Module surface |
|---|---|---|---|
| **A** | Stage 0: `TBDDaemonLiveTests` target, live-suite move, CI two-step split, quiet-pass count guard, assertion-hygiene rules in `Tests/CLAUDE.md` | — | `Package.swift`, `.github/workflows/test.yml`, `Tests/` (moves), `Tests/CLAUDE.md` |
| **B** | Ratchet: `swift-clocks` test-only dep, `no_raw_task_sleep` SwiftLint rule, 64 legacy suppressions, shared `TestSupport` clock helpers, clock-seam convention doc | A | `Package.swift`, `.swiftlint.yml`, all 64 sleep sites (one line each), `Tests/TestSupport/`, `docs/` |
| **C1** | Clock-seam migration: appearance debounce | B | `Sources/TBDApp` (appearance/settings) + its tests |
| **C2** | Clock-seam migration: `DaywatchRunner` | B | `Sources/TBDDaemon/Nightwatch/` + its tests |
| **C3** | Clock-seam migration: `GitManager` / subprocess timeout machinery | B | `Sources/TBDDaemon/Git/GitManager.swift`, subprocess timeout paths + their tests |
| **C4** | Clock-seam migration: `FileWatcher` | B | `Sources/TBDApp/Panes/FileWatcher.swift` + its tests |
| **D** | Clock-seam migration: control-mode / attach ready-timer (hardest; precondition for H) | B | `Sources/TBDDaemon/Tmux/ControlMode/`, attach-replay orchestration + their tests |
| **E** | `.flaky(issue:)` quarantine trait + retry-metrics JSON artifact | A | `Tests/TestSupport/` (new file), `.github/workflows/test.yml` (artifact upload) |
| **F** | Remaining suppression burn-down, mechanical batches | C1–C4, D | Whatever sleep sites remain |
| **G** | `nightly.yml`: live tmux probes, flake-ledger stress loop, quarantine audit | E | `.github/workflows/nightly.yml` (new), `scripts/` |
| **H** | Interleaving harness MVP + seed corpus wired into PR CI | D | `Tests/TBDDaemonTests/` (new harness files) |
| **I** | Nightly fuzz step wired into the existing nightly workflow | G, H | `.github/workflows/nightly.yml` |

## 3. Waves and parallelization

```
Wave 0:  A                                  (solo — blocks everything)
Wave 1:  B                                  (solo — touches every sleep site)
Wave 2:  C1 │ C2 │ C3 │ C4 │ D │ E          (6-wide, file-disjoint)
Wave 3:  F │ G                              (2-wide)
Wave 4:  H  →  I                            (sequential)
```

**Waves 0 and 1 are deliberately solo.** Both touch `Package.swift`, and B rewrites one line in 64 files across both modules — any concurrent slice would spend more time rebasing than working.

**Wave 2 is the parallelization payoff.** Six slices, mutually file-disjoint: C1/C4 are `TBDApp`, C2/C3/D are `TBDDaemon`, E is test-infrastructure only. Each removes only the suppressions inside files it already owns.

**Practical in-flight cap: 4, not 6.** Free public-repo minutes are unlimited, but the account allows at most 5 concurrent macOS jobs across all workflows and open PRs. Six simultaneous pushes would queue against each other and against any unrelated PR. Run wave 2 as 4 in flight, admitting the next slice as one merges. Ordering preference when admitting: **D first** (longest pole, unblocks wave 4), then C3, C2, C1, C4, E.

**Rebase discipline.** Wave-2 slices branch off main after B merges. Whoever merges second onto a shared file rebases — but by construction wave-2 slices share no files, so conflicts should only appear in `Package.resolved` (rare) and are trivially resolved by re-running resolution.

## 4. File-ownership map

Each file has exactly one owning slice per wave. Touching a file you don't own is the coordination failure this table exists to prevent — raise it in channels instead.

| File / directory | Owner | Notes |
|---|---|---|
| `Package.swift` | A, then B | Locked during waves 2–4; no other slice adds targets or deps. |
| `.swiftlint.yml` | B | Sole editor of the `no_raw_task_sleep` rule. |
| `.github/workflows/test.yml` | A, then E | A adds the two-step split; E appends the metrics-artifact upload only. |
| `.github/workflows/nightly.yml` | G, then I | G creates; I appends the fuzz step. |
| `Tests/CLAUDE.md` | A | Assertion-hygiene rules land once, in A. |
| `Tests/TestSupport/` | B (clock helpers), E (trait) | Separate new files — no shared file. |
| `Sources/TBDApp/**` | C1, C4 | Disjoint subtrees; C1 appearance/settings, C4 `Panes/FileWatcher.swift`. |
| `Sources/TBDDaemon/Nightwatch/**` | C2 | |
| `Sources/TBDDaemon/Git/**` | C3 | |
| `Sources/TBDDaemon/Tmux/ControlMode/**` | D | Also owns attach-replay orchestration files. |
| Live test suites | A (move), D/H (edit) | After A, tier-3 suites live in `Tests/TBDDaemonLiveTests/`. |

## 5. Shared contracts — fix before wave 2

These exist so six agents produce one coherent codebase instead of six dialects. **Slice B lands all of them**; wave-2 slices consume them and must not redefine them. This is the primary thing the orchestrator reviews plans for.

1. **Clock injection signature.** Last initializer parameter, named `clock`, defaulted:
   ```swift
   init(..., clock: any Clock<Duration> = ContinuousClock())
   ```
   Not `Clock`-generic, not stored as `some Clock`, not named `scheduler`. Existential keeps types non-generic, which matters for the actors and `Sendable` conformances these subsystems already carry.
2. **Date seam.** Two distinct shapes, not interchangeable:
   - Persisted/compared timestamps: `date: Date = Date()` parameter on the method (`touchLastUsed(at:)` precedent).
   - Repeated "what time is it now" reads: `now: @Sendable () -> Date` on the type.
3. **Test clock helpers live in `Tests/TestSupport/`**, added by B. No slice rolls its own `TestClock` wrapper, advance helper, or `.timeLimit` default.
4. **Suppression comment format** — exact and greppable, so F's burn-down is mechanical:
   ```swift
   // swiftlint:disable:next no_raw_task_sleep — legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
   ```
5. **Names are fixed:** target `TBDDaemonLiveTests`; lint rule `no_raw_task_sleep`; trait `.flaky(issue:)` taking a required `Int`.
6. **`PollerClock` is not touched** by any slice. It stays for suspend-aware wall-deadline chunking; B adds a doc comment pointing new code at the standard seam.

## 6. Open judgment call, assigned to slice A

The tier-3 inventory is the one genuine judgment call in stage 0, and a coarse grep over `Tests/TBDDaemonTests/` matches ~71–89 files (`Process()` is used far too broadly to be a signal). Slice A's owner produces a **curated** list rather than a grep dump.

**Criterion (design §3, authoritative):** a suite is tier 3 if it spawns a real tmux server, shells out to `ps`, spawns a child process racing a deadline, drives the replay firehose, or is itself a contention source rather than merely a victim of one — i.e. its runtime depends on an external process it does not fully control, or it actively degrades every sibling suite sharing the runner. (The last clause exists because of `SubprocessTimeoutStarvationTests`, which deliberately saturates the shared default-QoS GCD pool — the single worst offender a narrower reading would have left in the parallel pass.)

**Seed list** (verify each before moving): `ReplayLiveIntegrationMatrixTests`, `LimitResumeSendSequenceLiveTests`, `TerminalSendBracketedPasteLiveTests`, `HistoryLimitIntegrationTests`, `WorktreeLifecycleTests`, `HibernationOrphanDetectionTests`, `GitManagerTimeoutTests`, `SubprocessTimeoutTests`, `SubprocessTimeoutStarvationTests`, `TmuxControlConnectionIntegrationTests`, `TmuxControlCommandClientIntegrationTests`, `ControlModeInputRouterIntegrationTests`.

Under-inclusion is the safer error: a heavy suite left in the parallel pass is the status quo, whereas moving a fast deterministic suite into the serial pass slows every PR forever. Slice A reports the final list in its PR description for review.

## 7. Definition of done — every slice

- `swift build` and `swift test` green on **both** CI passes (parallel and quiet).
- `swiftlint --strict` clean.
- PR description states: which slice ID, which shared contracts it consumed, and — for C1–C4/D/F — that the change is behavior-preserving by construction (defaulted clock parameter), so no feature flag applies.
- Any new test states its tier, and tier-1 tests contain no real sleeps.
- No implementation-plan file staged (`plans-guard` enforces this in CI).

## 8. Orchestration protocol

1. Each slice runs in its own TBD worktree with its own agent session.
2. The agent reads the design spec and this document, then writes its **own** implementation plan as local scratch (never committed).
3. The orchestrator reviews each plan for cohesiveness against §5 before the agent writes code — the check is "does this consume the shared contracts as written, and stay inside its file ownership."
4. Coordination happens over agent channels: slice claim, plan-ready, blocked, merged. Cross-slice questions go to the channel rather than into a file another slice owns.
5. Wave gates are enforced by the orchestrator: wave N+1 agents are not spawned until wave N's PRs are merged.
