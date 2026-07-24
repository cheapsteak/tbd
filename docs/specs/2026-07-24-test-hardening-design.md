# Test Hardening — Staged Design

**Date:** 2026-07-24
**Status:** Approved design, pending implementation
**Predecessors:** the 2026-07-09 testing-redesign roadmap (endorsed during the PR #415 flake investigation) and the PR #488 flake fixes (resolver wall-clock window, paste-failure `.last` coupling, `fileBytesUnmatched` error truthfulness).

## 1. Problem

The suite is healthy in the large (~3,100 tests, 15–20 s locally, strong seam culture), but CI flakes recur because three structural defects keep getting re-instantiated rather than fixed once:

1. **No clock seam as a convention.** Production code stamps `Date()` and arms real timers internally, forcing tests into wall-clock assertions ("happened within 5 s") that measure elapsed time on a loaded runner, not behavior. Each instance gets patched ad hoc; any new `Task.sleep` mints the next flake. There are currently 64 raw `Task.sleep` call sites in `Sources/`.
2. **Deadline tests share a starved machine with heavyweight tests.** All test targets compile into one process and Swift Testing runs suites in parallel across all of them, so live-tmux suites, `ps` scans, and the replay firehose contend for the same 3–4 runner cores (at `-j 2`, the OOM floor) while timeout-sensitive tests tick. Nothing marks "needs real tmux and quiet CPU" vs "pure unit test", so CI cannot schedule them apart.
3. **Assertions pin incidental facts.** `.last`-write ordering, exact counts, and freshness windows hold only when timing is quiet and were never guaranteed by the code under test.

Sharding across runners was considered and rejected: public-repo minutes are free but the real quota is the 5-concurrent-macOS-job cap, each shard re-pays the ~2 min build (SPM #7715 workaround + compile) to run a slice of a 20 s suite, and no amount of sharding fixes class 1 — a dedicated shard is still a small VM with noisy-neighbor CPU steal.

## 2. Goals and non-goals

**Goals**

- Kill the three flake classes at the source: virtual time for class 1, tier isolation for class 2, written contract rules + review enforcement for class 3.
- Make the *defaults* safe: a naive new test or new production timer gets caught mechanically (lint rule, target boundary), not by the next CI red.
- Quantify and regression-guard the attach/supersession TOCTOU residuals that today live only in orchestrator comments.
- Replace tribal rerun lore with named, audited quarantine.

**Non-goals**

- Sharding tests across runners.
- Blanket CI retries for any tier.
- Rewriting healthy tests wholesale (migration is by payoff, not completeness-for-its-own-sake).
- Touching the `-j 2` build cap (separate re-validation candidate; see the comment in `test.yml`).

## 3. Tier taxonomy

Three tiers, defined by what a test may touch:

| Tier | May touch | Scheduling | Retry policy |
|---|---|---|---|
| **1 — deterministic** (~95% of suite) | In-process state only. No real sleeps, subprocesses, tmux, network, or `~/tbd`. Time only via injected clock. | Fully parallel | **Zero.** A red tier-1 test is a bug, full stop. |
| **2 — in-process integration** | Real concurrency, real filesystem in tmp dirs, real git subprocesses. Deadlines only via bounded waits (`ciSafeDeadline` style). | Fully parallel | No blanket retry. A tier-2 test that needs one gets an explicit `.flaky(issue:)` quarantine trait (§7). |
| **3 — live-external** | Real tmux server, real `ps`, spawned processes, the replay firehose. | **Serial, on a quiet machine** | None; generous deadlines instead. |

This deviates from the original roadmap sketch ("tier 2 gets one retry") deliberately: blanket retry hides regressions, quarantine names them.

**Enforcement mechanism = target boundary.** Tier 3 physically moves to a new `TBDDaemonLiveTests` test target (all current live suites are daemon-side; other modules can grow sibling `*LiveTests` targets if ever needed). Tiers 1 and 2 stay co-resident in the existing targets — their distinction is behavioral and enforced by convention + review, since they schedule fine together. The target boundary is the load-bearing one: compiler-enforced, cannot silently zero-match like a `--filter` regex, and gives CI an unambiguous handle.

## 4. CI topology

The existing `test` job keeps one build (no extra runner drawn from the 5-job macOS pool) and splits the test run into two sequential steps:

1. **Fast parallel pass:** `swift test --parallel -j 2 --skip TBDDaemonLiveTests`
2. **Quiet pass:** the `TBDDaemonLiveTests` target run serially (no `--parallel`), with the machine otherwise idle.

Guard rails:

- The quiet pass parses the executed-test count from output and **fails if zero tests ran** (`swift test --filter` exits green on zero matches; a renamed target must not silently fall out of both passes).
- The quiet step gets an explicit `timeout-minutes` so a wedged tmux test cannot eat the job's 6 h default.

PR CI never runs randomized anything. A new scheduled `nightly.yml` workflow (§9) carries fuzzing, live probes, the flake-ledger stress loop, and the quarantine audit.

## 5. Clock standardization

Governing rule: **`Duration` is behavior, `Date` is data.**

- **Behavior** — delays, debounces, timers, polling intervals, deadlines: production types take a clock, defaulted so call sites don't change:

  ```swift
  init(..., clock: any Clock<Duration> = ContinuousClock())
  ```

  Tests inject `TestClock` from pointfree's `swift-clocks` (**test-target-only dependency**) and drive time with `await clock.advance(by:)` — no sleeping, no load sensitivity. A debounce test asserts *exact* virtual timings instead of tolerance windows.
- **Data** — timestamps that get persisted or compared (`lastUsedAt`, hibernation stamps): the existing lightweight seam, a defaulted `date: Date = Date()` / `now: @Sendable () -> Date` parameter (the `touchLastUsed(at:)` pattern). No clock object needed to stamp a row.
- **`PollerClock` stays untouched** — chunked, suspend-aware wall-deadline sleeping is a genuinely different job (Darwin's `Task.sleep` uses the suspending clock; see its doc comment) — but it stops being the template. A doc comment points new code at the standard seam.

**Enforcement is a ratchet, not a flag day.** A SwiftLint custom rule `no_raw_task_sleep` (same shape as `no_print_in_sources`) forbids `Task.sleep` in `Sources/`. The 64 existing sites get explicit per-line `swiftlint:disable:this` suppressions in the ratchet PR, so every legacy site is greppable and the count only goes down. New code cannot add an unseamed sleep without a visible suppression, which the PR review gate treats as a finding.

**Migration order (by flake payoff):**

1. Subsystems behind the known flake ledger: appearance debounce, `DaywatchRunner`, `GitManager`/`Subprocess` timeout machinery, `FileWatcher`.
2. Control-mode/attach ready-timer (precondition for the interleaving harness, §8).
3. The mechanical remainder, in small batches.

**Known failure mode:** a tier-1 test awaiting a `TestClock` sleep that nobody advances hangs forever. Mitigations: suite-level `.timeLimit` traits on migrated suites, and the convention that `advance(by:)` calls sit next to the assertion they unblock.

## 6. Assertion hygiene

Four rules, landing in `Tests/CLAUDE.md` at Stage 0 (the reviewer bot inherits them by reading the file). Each traces to a real flake:

1. **Assert contracts, not incidents.** Membership (`contains`) over `.last`/ordering unless ordering is the documented contract. (Paste-failure flake: `delete-buffer` vs follow-up keystroke are order-independent effects.)
2. **No wall-clock freshness windows.** Bracket with `[before, after]` around the call, or inject the date. (`resolve_success_bumpsLastUsedAt` blew a 5 s window by 0.11 s under load.)
3. **No bare `Task.sleep(for:)` as a synchronization primitive in tests.** Tier 1: `TestClock.advance`. Tiers 2–3: bounded polling with a deadline (`waitFor` style).
4. **Timeout errors must report observed state, not just expected.** (`fileBytesMismatch(expected: 6150, actual: 6150)` was re-reading the file after the deadline and lying; `fileBytesUnmatched(expected:observed:correctPrefix:)` is the corrected shape.)

## 7. Quarantine and retry metrics

A custom Swift Testing trait:

```swift
.flaky(issue: 501)   // issue number is REQUIRED — no anonymous quarantine
```

Semantics: re-run the test body up to 2 extra times; record a pass-on-retry event; fail outright only if all attempts fail.

Honesty mechanisms so quarantine cannot become a landfill:

- The trait requires an issue number.
- The nightly job audits the quarantine list: a `.flaky` referencing a **closed** issue, or one whose test passed first-try all week, is flagged for removal in the nightly report.

Metrics: retry events are written to a JSON artifact per CI run; the nightly job aggregates them into a single rolling tracking-issue comment. That is the entire "dashboard" — no external service.

## 8. Interleaving invariant harness

**Target:** the attach/supersession machinery — the code whose orchestrator comments document accepted TOCTOU residuals and whose hand-enumerated schedule tests were the #415 flake source.

- **Event vocabulary:** the injectable actions the existing fake-correlator seam supports — attach, detach, `%pause`, replay-begin/complete, EOF, successor-attach — plus clock advances. A seeded PRNG (the seed is the test's only input) draws a schedule of N events; the real orchestrator consumes them over the fake correlator with the §5 `TestClock` supplying time. A given seed therefore replays identically, every run, on any machine. **This is why the harness stages after the control-mode clock migration:** without virtual time, seeds aren't reproducible and the harness would be a new flake generator.
- **Invariant oracle**, checked after *every* event (so the failing step is in the failure message, alongside the seed):
  1. Exactly one `continue` per sequence.
  2. No `continue` inside a successor's pause window.
  3. Gate only after own replay.
  4. No EOF delivered to a healthy successor.
- **Failure workflow:** a failing seed is committed to a corpus file (an array of seeds, each with a comment linking the fixing PR). PR CI runs the corpus plus a handful of pinned known-nasty seeds — deterministic, fast, no randomness. The corpus grows only via reproduced failures (a fuzzer's regression corpus, in miniature).
- **Nightly fuzz:** time-boxed (~10 min) randomized-seed run. On failure the workflow opens/updates a GitHub issue containing the seed, step index, and violated invariant — instantly reproducible locally by adding the seed to the corpus.
- **Stretch goal (not MVP):** schedule shrinking via delta-debugging. Seed + step index is usually enough to diagnose.

## 9. Nightly workflow

One scheduled `nightly.yml` job (one macOS slot, off-peak; public-repo minutes are free), four steps:

1. Interleaving fuzz pass (§8) — added in Stage 4; the workflow ships earlier without it.
2. **Live tmux probes:** executable checks of behavioral claims currently trusted from memory (pane-reuse, paste-buffer semantics, control-mode quirks).
3. **Flake-ledger stress loop:** the historically flaky suites run repeatedly under induced CPU load (PID-captured cleanup per `Tests/CLAUDE.md` — never `jobs -p`).
4. Quarantine audit (§7).

Failures land as issue comments — never as PR noise.

## 10. Stage plan

Each stage is independently shippable; order front-loads flake payoff per unit effort.

| Stage | Contents | Payoff |
|---|---|---|
| **0** | `TBDDaemonLiveTests` target + two-step CI split + quiet-pass count guard + assertion rules in `Tests/CLAUDE.md` | Contention class contained; hygiene rules live for all future reviews. No production code touched. |
| **1** | `swift-clocks` test-only dep + clock-seam convention + `no_raw_task_sleep` ratchet + migrate the ledger subsystems (debounce, Daywatch, Git/Subprocess timeouts, FileWatcher) — one small PR each | Known repeat-offenders become deterministic; new unseamed sleeps impossible without a visible suppression. |
| **2** | Migrate control-mode/attach timers to injected clock; burn down remaining suppressions in mechanical batches | Wall-clock class structurally dead; harness precondition met. |
| **3** | `.flaky(issue:)` trait + retry-metrics artifact + `nightly.yml` (probes, ledger stress loop, quarantine audit; fuzz slot empty) | Rerun lore replaced by named, audited quarantine; regressions in "fixed" flakes caught nightly, not by the next unlucky PR. |
| **4** | Interleaving harness MVP + corpus in PR CI + nightly fuzz wired into the existing workflow | Attach/supersession TOCTOU residuals quantified and permanently regression-guarded. |

**Dependency edges:** Stage 4 needs Stage 2 (virtual time in the orchestrator). Stage 3's nightly workflow is extended, not created, by Stage 4. Everything else is independent — Stage 0 can land immediately, and Stage 1's per-subsystem PRs can interleave with anything.

## 11. Risks and mitigations

- **TestClock hangs on un-advanced sleeps** → `.timeLimit` traits on migrated suites; advance-next-to-assertion convention (§5).
- **Quiet pass silently runs nothing** → executed-test count guard in CI (§4).
- **Quarantine landfill** → required issue numbers + nightly audit (§7).
- **Harness becomes its own flake source** → hard dependency on virtual time (Stage 2 before Stage 4); PR CI runs only pinned seeds.
- **Lint ratchet friction** → suppressions are pre-seeded on all 64 legacy sites in one mechanical PR; developers only encounter the rule on genuinely new sleeps.
