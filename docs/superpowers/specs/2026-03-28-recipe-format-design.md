# Recipe Format Design

## Manifesto: Code Is Rasterized Intent

Code has always been a lossy transformation. An idea becomes a design, a design becomes implementation, and at each step something is lost — the reasoning, the tradeoffs, the alternatives considered and rejected. We've always known this, but it was tolerable when code was expensive to write and cheap to read.

Agentic coding inverts this. Code is now cheap to write and cheap to read — for machines. What's expensive is the *intent* that produced it. An agent can generate a thousand lines in seconds, but it can't recover why those lines exist, what jobs they serve, or which constraints shaped the decisions.

We've been preserving the pixels and discarding the vectors.

Software should be captured as **recipes**, not as code. A recipe describes the jobs the software does, the constraints it operates under, and the techniques worth knowing — the transferable, composable essence that survives a rewrite, a new language, a different team.

Code is a dish. Recipes are how dishes travel.

**Principles:**

1. **Capture why, not what.** A recipe is organized around jobs to be done, not features implemented. Features are ephemeral; jobs are durable.
2. **Techniques over implementation.** When the "how" matters, capture it as a reusable technique — a solution to a recurring constraint, not a description of specific code.
3. **Composability over completeness.** Recipes reference other recipes. You don't explain braising every time you use it. Some techniques you always "buy" (use a library); others you "make" (implement yourself). Both are valid.
4. **Living documents, geological history.** A recipe evolves as understanding deepens, but the evolution is preserved — not as changelog noise, but as a record of how reasoning changed.
5. **Automation keeps recipes honest.** Drift between recipe and code is the silent killer. Recipes must be wired into the development workflow so that forgetting to update them is harder than updating them.

---

## Format

### Directory Structure

```
recipe/
  recipe.md                # The dish — what, why, jobs index
  constraints/
    invariant-name.md      # System-wide invariants
  jobs/
    job-name.md            # Jobs to be done
  techniques/
    technique-name.md      # Reusable solutions to recurring problems
  evolution.md             # AI-generated reasoning history (current)
  evolution-archive.md     # Archived entries after compaction (created on first compact)
```

Flat by default. Optional subdirectory grouping within `jobs/` and `techniques/` when a directory exceeds ~15 items. `recipe.md` is always the authoritative index regardless of nesting.

### recipe.md — The Dish

Frontmatter:

```yaml
---
format: recipe/v1
---
```

Body: what this software is, why it exists, and a structured index of its jobs, constraints, and techniques. This is what someone reads first. Keep it short — it's a map, not the territory.

Example:

```markdown
---
format: recipe/v1
last-audit: 2026-03-28
---

# TBD

A macOS native worktree and terminal manager for multi-agent
Claude Code workflows.

## Why it exists
Managing multiple AI coding agents on the same repo requires
juggling git worktrees, terminal sessions, and status monitoring.
TBD makes this invisible — agents get isolated workspaces,
humans get a single pane of glass.

## Jobs
- [Set up a multi-agent session](jobs/setup-session.md)
- [Monitor agent progress without context-switching](jobs/monitor-agents.md)
- [Resume work across sessions](jobs/resume-sessions.md)
- [Review and integrate agent work](jobs/review-integrate.md)

## Constraints
- [Daemon owns all state](constraints/daemon-owns-state.md) — Invariant
- [Crash resilience](constraints/crash-resilience.md) — Invariant
- [No agent cooperation required](constraints/no-agent-cooperation.md) — Strong

## Key Techniques
- [Grouped tmux sessions](techniques/grouped-tmux.md)
- [One tmux server per repo](techniques/tmux-per-repo.md)
- [SQLite with WAL mode](techniques/sqlite-wal.md) (Buy: GRDB)
```

**Minimum viable recipe:** `recipe.md` and 2-3 job files is a valid starting point. Add constraints and techniques as they emerge. When two or more jobs share the same constraint, extract it to a constraint file.

### constraints/*.md — System-Wide Invariants

Cross-cutting rules that constrain all jobs. Constraints have an ordinal **weight** indicating how firm they are:

- **Invariant** — violating this is a bug. Non-negotiable. ("Daemon owns all state.")
- **Strong** — bends only under significant pressure, and bending must be recorded in evolution.md. ("Status must be fresh within 60s.")
- **Preference** — the default direction; acceptable to trade off against other constraints. ("Minimize external API calls.")

When constraints conflict, higher-weight constraints win. If two constraints at the same weight conflict, the resolution belongs in the job file that encounters the tension, and warrants an evolution.md entry.

```markdown
# Daemon owns all state

**Weight: Invariant**

The UI is a stateless client. All persistent state lives in the daemon
process. If the app crashes, no user-visible data is lost. If the daemon
crashes, it recovers from the database on restart.

## Why this matters
- Agents work in terminals independent of the UI
- The UI can be restarted without interrupting agent work
- Multiple UIs could theoretically connect to the same daemon

## What this constrains
- The app process must never be the source of truth for anything
- All state mutations go through the daemon's RPC interface
- The database schema is the daemon's responsibility, not the app's
```

Jobs and techniques link to constraints they depend on. The distinction: techniques are *how* you solve a problem; constraints are *what you cannot violate*. The weight in the constraint file is authoritative; weights shown in `recipe.md`'s index are convenience summaries.

### jobs/*.md — Jobs To Be Done

One file per job. Framed around the situation and need, not "As a ___."

```markdown
# Monitor agent progress without context-switching

When managing multiple coding agents on the same repo,
I need to see what each is doing, whether they're blocked,
and what PRs they've opened — without leaving my current context.

## Constraints
- Agents work independently; can't require them to report in
- Status must be fresh (< 60s) without manual refresh
- Must work even if the UI crashes mid-session
- [Daemon owns all state](../constraints/daemon-owns-state.md)
- [No agent cooperation required](../constraints/no-agent-cooperation.md)

## Techniques used
- [Background git fetch cycle](../techniques/background-fetch.md)
- [PR status polling](../techniques/pr-status-polling.md)

## Success looks like
- Glancing at the app tells me which agents are active, blocked, or done
- I never have to manually refresh or switch windows to check status
- If an agent opens a PR, I see it within one polling cycle

## Traps
- Don't poll GitHub too aggressively — rate limits will cut you off
- Don't try to infer agent status from terminal output parsing; use git artifacts (branches, PRs) as the signal
```

Inline constraints in job files are job-scoped context and don't carry weights. Only constraints extracted to `constraints/` files participate in the weight system.

**Job fragmentation is expected.** When a job splits as the product matures, split the file, update `recipe.md` index, add an `evolution.md` entry explaining the split. This is normal evolution, not a problem.

**System-facing jobs are fine.** The "When..." clause names the actual actor. "When the SwiftUI app reconnects after a crash..." — the reader understands the daemon is serving the app. No taxonomy of "system jobs" vs "user jobs" needed.

### techniques/*.md — Reusable Techniques

One file per technique. Each describes a problem, its solution, why alternatives were rejected, and where it applies beyond this project.

```markdown
# Grouped tmux sessions for independent panel views

## Posture: Make
This is a tmux configuration pattern, not a library dependency.
The technique is 10 lines of tmux commands. No library models
this specific multi-panel use case.

## The problem
Multiple UI panels need independent views of the same terminal
session set — different current windows, different sizes.

## The technique
Use tmux grouped sessions (not control mode). Each panel
gets its own session grouped to a shared server. Panels can
navigate independently without affecting each other.

## Why not alternatives
- Control mode: single controller, shared state, size conflicts
- Multiple servers: can't share sessions across panels

## Where this applies
Any multi-panel terminal UI that needs independent navigation.
```

**Posture** has three values:

- **Buy** — use an existing library/service. Name the category, not the specific product. Optionally name a current recommendation. ("Buy: Embedded SQLite via a Swift ORM. Currently GRDB.")
- **Make** — implement yourself. Explain why a dependency isn't worth it.
- **Wrap** — use a library behind your own interface, because you need to be able to swap it. ("Wrap: Terminal emulation. Currently SwiftTerm, behind an adapter protocol.")

The posture is about the decision, not the product. "Use GRDB" is an implementation detail. "Buy your embedded database layer" is a technique.

### evolution.md — AI-Generated Reasoning History

One file at the recipe root. Newest entries first. Records changes in reasoning, not changes in text.

**evolution.md is generated by the AI audit, not hand-written.** The audit reads git history (commits, PR descriptions, code changes) and distills reasoning shifts into evolution entries. This eliminates the double-ledger problem — git is the source of truth, evolution.md is a curated view of it. Humans can hand-edit entries to correct or enrich them, but the generation is automated.

**When the audit adds an entry:** When git history shows a change that shifted the reasoning behind a job, technique, or constraint — and a future reader looking at the current recipe state would wonder "why not the obvious alternative?"

**When entries are skipped:** Self-evident changes (typos, additions that don't replace anything, refactors that don't change intent).

| Git change | Evolution entry? |
|--------|--------------|
| New constraint added to a job | No — the constraint is self-evident in the file |
| Polling replaced by WebSocket | Yes — why was polling insufficient? |
| Two jobs merged into one | Yes — why were they the same job? |
| A job split into sub-jobs | Yes — what fragmentation drove the split? |
| A firm constraint relaxed | Yes — what changed to make it flexible? |

Format:

```markdown
# 2026-03-26 | Pinning replaces tab-based workflow
Originally, switching between agents meant clicking sidebar items
like tabs. Users actually want 2-3 agents visible simultaneously.
Pinning with split view replaces the tab model.

# 2026-03-23 | PR status is a monitoring job, not a review job
Initially grouped PR display under "reviewing agent work."
Realized users check PR status for monitoring (is the agent
still working?) not reviewing (is the code good?).
```

---

## Drift Detection

Two layers: cheap mechanical checks that run always, and expensive semantic audits that run periodically.

### Mechanical checks (CI / pre-commit)

These are deterministic, quiet, and cheap:

- **Broken link validation** — all internal markdown links in `recipe/` resolve to existing files
- **Orphan detection** — technique or constraint files referenced by zero jobs
- **Audit staleness signal** — a visible timestamp ("last audit: 12 days ago") in recipe.md frontmatter or CI dashboard, so the team knows when the audit hasn't run

These catch structural rot without the noise problems of semantic hooks.

### Semantic audit (periodic AI)

An AI agent reads all recipe files against the current codebase and git history:

1. Flags semantic drift: jobs whose success criteria no longer match reality, techniques that have been replaced, constraints that are no longer enforced
2. Catches accidental knowledge — bug fixes and edge cases encoded in code that no recipe mentions, which may warrant a new trap or technique
3. Generates evolution.md entries from git history (see evolution.md section)
4. Proposes recipe file updates as diffs for human review

The audit runs on a schedule (weekly) or is triggered manually.

### Review gating

Recipe changes have more leverage than code changes — they guide all future generation and agent behavior. Recipe changes (in `recipe/`) should receive at least the same review rigor as code. Consider a CODEOWNERS-equivalent for the `recipe/` directory requiring review from someone who understands architectural intent.

### Audit failure modes

The system depends on the AI audit for semantic integrity. When the audit is wrong or absent:

- **Bad output:** All audit-generated changes (evolution.md entries, recipe update proposals) go through the same review gating as any recipe change. The audit proposes; humans approve. A hallucinated evolution entry or incorrect drift flag is caught at review time.
- **Missed drift (false negative):** The mechanical checks catch structural rot (broken links, orphans) even when the semantic audit misses something. For semantic drift, the `last-audit` timestamp in recipe.md makes silence visible — the team can see that the audit hasn't run, rather than assuming health from absence of warnings.
- **Audit stops running:** The staleness signal is the defense. If `last-audit` shows a date more than 2 weeks old, the recipe's integrity is unverified. This is a passive signal, not a blocker — but it's visible in the file that every recipe consumer reads first.

---

## Recipe Lifecycle

Recipes integrate with existing prose skills:

1. **Brainstorm** — conversation, design sessions, scattered thinking
2. **Synthesize** (`prose-synthesize`) — structure the thinking into draft recipe files (jobs, techniques, constraints)
3. **Overcapture** — err toward too much detail. Live with it as the code evolves.
4. **Distill** (`prose-distill`) — periodically tighten recipes. Lossless compression: remove redundancy, sharpen language, preserve all meaning.
5. **AI audit** — catch drift, generate evolution.md entries, propose recipe updates. (See [Drift Detection](#drift-detection) for details.)
6. **Compact** — fold accumulated evolution.md entries back into recipe files. The audit proposes updates to jobs, techniques, and constraints that reflect the reasoning shifts recorded in evolution.md. Folded entries are archived to `evolution-archive.md`. Recipe files become the current truth; evolution.md resets to only unfolded entries. This is like git squash for reasoning.

Phase 3→4 is the expected steady state. Overcapture first, condense when the recipe stabilizes. The compact step runs when evolution.md accumulates enough entries that the recipe files and evolution have visibly diverged — typically alongside a distill pass.

---

## Relationship to Other Artifacts

| Artifact | Purpose | Audience | Durability |
|----------|---------|----------|------------|
| Recipes | Why the software exists and what jobs it does | Anyone — current team, future team, competitors, agents | Survives a rewrite |
| CLAUDE.md | Operational rules for agents working on this codebase | AI coding agents | Tied to current implementation |
| Design specs (`docs/specs/`) | How a specific feature is implemented | Current developers | Tied to current implementation |
| Code | The implementation itself | Machines and developers | Ephemeral — can be regenerated from recipes + specs |

Recipes capture *why*. CLAUDE.md captures *what to do*. Specs capture *how it's built*. Code captures *what was built*. Each layer has different durability and different audiences.

**Recipes are not consulted during ongoing iteration** — CLAUDE.md is the operational layer that agents and developers reference while working. Recipes are the durable layer consulted when starting new work, onboarding, making architectural decisions, or regenerating from intent. CLAUDE.md may restate recipe knowledge in operational form ("never delete state.db") without needing to stay in sync — it's a downstream artifact, not a mirror.

---

## Distribution

Git-native. Recipes live in the repo's `recipe/` directory and are distributed via GitHub. No manifest, no registry, no tooling on day one.

When cross-repo composition becomes a real need (recipes referencing recipes in other repos), add a `recipe.yaml` manifest with git URL + ref references. Not before. Semver is the wrong model for intent — recipes are pinned by git ref if needed.

---

## How Recipes Differ From Existing Formats

- **vs. ADRs (Architecture Decision Records):** ADRs capture individual decisions. Recipes capture the living whole — jobs, constraints, techniques, and how they relate. An ADR is a snapshot; a recipe is a fractal, living document that evolves and self-compacts via the audit cycle. ADR history is close to what evolution.md captures, but evolution.md is generated from git, not hand-written.
- **vs. RFCs / PEPs / Design Docs:** These are proposals for specific changes, frozen at acceptance. Recipes are living documents that track the current state of intent. A design doc quickly becomes stale after implementation; a recipe stays current through the audit-compact cycle.
- **vs. README / Documentation:** READMEs describe how to use the software. Recipes describe why the software exists and what jobs it does — transferable knowledge that survives a rewrite.
- **vs. Pattern Languages (Christopher Alexander):** The closest prior art. Recipes borrow the composable, multi-scale structure of pattern languages but add the JTBD framing (organized by jobs, not by spatial/structural patterns) and the automated drift detection cycle. Pattern languages are static catalogs; recipes are living and self-auditing.
- **vs. User Stories / Epics:** Implementation scheduling artifacts. Recipes are the durable intent that stories are derived from, not the other way around.

Recipes are fractal — a technique can contain sub-techniques, a job can reference sub-jobs, and the same structure works at every scale from a single utility to an entire platform.

---

## What Recipes Explicitly Exclude

- **Tickets, epics, sprint planning** — these are implementation scheduling, not intent
- **Code** — unless the code IS the technique (a non-obvious algorithm, a critical pattern)
- **Implementation specs** — those live in `docs/specs/` as a separate, implementation-tied layer
- **Metrics and KPIs** — recipes describe behavioral success criteria, not numbers

---

## Open Questions

- **Cross-repo composition mechanics:** When `recipe.yaml` becomes necessary, what's the minimal schema? Git URL + ref + path? How are transitive dependencies handled?
- **Recipe quality criteria:** How do you know a recipe is good? Complete? At the right altitude? This may emerge from practice rather than being prescribed upfront.
- **Automation specifics:** What does the AI audit prompt look like? How does it map code to recipes without explicit annotations? This needs prototyping.

---

## Applying to TBD: Retroactive Construction

TBD (the macOS worktree + terminal manager for multi-agent Claude Code workflows) is the first test case. The existing design specs in `docs/superpowers/specs/` are the raw material — they'll be mined for jobs, constraints, and techniques.

Preliminary job candidates (to be refined during construction):
- Set up a multi-agent coding session without manual tmux/git choreography
- Monitor agent progress without context-switching
- Resume work across sessions without losing layout or state
- Review and integrate agent work (diffs, PRs, conflicts)

Preliminary constraint candidates:
- Daemon owns all state (UI is stateless)
- Crash resilience (no data loss on app crash)
- No agent cooperation required (agents don't know about TBD)

Preliminary technique candidates:
- Grouped tmux sessions for independent panel views
- One tmux server per repo for isolation
- YYYYMMDD-adjective-animal naming for uniqueness without conflicts
- SQLite with WAL mode for concurrent readers (Buy: GRDB)
- Unix domain socket + HTTP RPC for daemon communication

These will be extracted from the existing specs and codebase in the implementation phase.
