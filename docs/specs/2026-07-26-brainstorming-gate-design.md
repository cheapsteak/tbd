# Brainstorming gate: qualifying work starts with a checked-in spec

**Status:** implemented on `tbd/brainstorm-gate` (2459991f, 163900c5, cf497a94, f4bb0859, c14d4ee4, 31b3e4b7); nightwatch desk-prompt follow-up still outstanding, see Sequencing
**Date:** 2026-07-26

## Why

Design thinking in TBD is real but not durable. The 2026-07-25 Watch Desk relay bug had two
independent design passes, reconciled, with a failure-mode table — and all of it lived in a
session scratchpad. Nothing structurally stopped the work from going straight from diagnosis to
implementation, and nothing preserved the reasoning for the next reader.

The mandate here is on the **process**, not on the artifact and not on who approves. The
`superpowers:brainstorming` skill forces a human to think through purpose, constraints, and
alternatives up front; the committed spec is evidence that the interrogation happened. The failure
this prevents is not "no spec" but **a spec the human never actually thought through** — an agent
that asks and answers its own brainstorming questions produces a perfectly spec-shaped document
containing zero human judgement, which is worse than nothing because it looks like diligence.

## The rule

Proposed `CLAUDE.md` section, in house voice. Target ≤12 lines; trim on first draft review.

```markdown
### Blast-radius work starts with a brainstormed spec

Work that adds a subsystem, adds or changes a feature flag or `config` column, a database migration, or that
wholesale-replaces a load-bearing path (rendering, input routing, persistence) runs
`/tbd-brainstorming` **before** implementation and commits the spec to
`docs/specs/<date>-<topic>-design.md`. Same triggers as the default-off-flag rule above: if it
needs a flag, it needs a spec.

**A human answers the brainstorming questions.** An agent may not answer its own. If no human is
available, stop — do not proceed on assumed answers. Agents, including the nightwatch desk, may
not originate feature work; file it for a human instead.

Not required for bug fixes, small additive UI, or refactors. If a trigger fires but a brainstorm is
genuinely unnecessary, say so in the PR description. This is convention, not a gate: there is no
lint rule, because "was this brainstormed?" is not a property a linter can see. Use
`/tbd-brainstorming`, not `superpowers:brainstorming` — a guardrail redirects the wrong one.
```

### Scope decisions

- **Trigger is blast-radius, not feature-vs-bugfix.** Deliberately mirrors the existing
  default-off-flag rule so there is one judgement call, not two.
- **Trigger covers changing a flag or column, not just adding one.** A default flip changes
  behavior without adding anything, so "adds" alone would let it slip through — that is exactly
  what happened with `auto_hibernate_enabled`, whose default flip needed a forcing `UPDATE`
  migration (see the cautionary precedent in the default-off-flag rule).
- **This exempts the incident that motivated it.** The desk-relay bug touched no subsystem, flag,
  migration, or load-bearing path. Accepted knowingly: the rule targets the class of work where
  design debt compounds, not every case where a spec would have been nice.
- **Precedent to cite is positive, not cautionary.** The panel agent-surface work (#481) produced
  specs A, B, and C, where A and B were superseded by C *on paper* before implementation. That is
  the rule working before it existed, and the cheapest available way to be wrong.

## Artifacts

Seven new files, three edited.

| Path | Size | Notes |
|---|---|---|
| `.claude/skills/tbd-brainstorming/SKILL.md` | ~11 KB | adapted from upstream |
| `.claude/skills/tbd-brainstorming/LICENSE-superpowers` | ~1.1 KB | MIT © 2025 Jesse Vincent |
| `.claude/skills/writing-clearly-and-concisely/SKILL.md` | 2.2 KB | public domain |
| `.claude/skills/writing-clearly-and-concisely/elements-of-style.md` | 71 KB | public domain |
| `.claude/hooks/guardrails/rules/brainstorming_skill.py` + test | small | redirect rule |
| `.claude/settings.json` | +1 matcher | adds a `Skill` matcher |
| `CLAUDE.md` | ≤12 lines | the rule above |
| `docs/CLAUDE.md` | +1 line | specs-vs-plans distinction |
| `.codex/config.toml` | new, 1 key | Codex reads `CLAUDE.md` |

### Why vendor rather than depend on the plugin

The superpowers plugin cannot be assumed present. Claude Code *does* support declaring plugins at
the repo level (`extraKnownMarketplaces` + `enabledPlugins` in `.claude/settings.json`), but the
docs are explicit that this is declaration, never installation: a marketplace-trust prompt, a
plugin-install prompt, folder trust, and a network fetch. Marketplace state is stored once per
user, not per project, and the Agent SDK accepts only local filesystem plugin paths. An interactive
install prompt inside an autonomous tmux-spawned session is exactly what wedges a babysat fleet
across ~40 worktrees. Rejected.

Repo-local `.claude/skills/` is already a working channel here — `tbd-project` and
`update-project-docs` are tracked and auto-discovered with no install step.

### What gets adapted, and why it is forced

`brainstorming/SKILL.md` contains **zero** `superpowers:` cross-references; the plugin's
interdependence lives downstream of `writing-plans`. The functional minimum is one 10.4 KB file.
Required edits:

- **Spec path → `docs/specs/`** (upstream defaults to `docs/superpowers/specs/`).
- **Terminal state**: invoke `superpowers:writing-plans` when available; the plan goes to a
  gitignored plan dir and is never staged. When superpowers is absent, the skill carries a short
  inline plan step instead. We do **not** vendor `writing-plans` — its own `SKILL.md` carries the
  writing-plans header marker that `plans-guard` Rule B greps for, so vendoring it would fail that
  CI job (verified empirically). Beyond the guard, superpowers' plan format solves a different, more
  contentious problem and should not be forced on contributors.

  Note a false-positive mode worth knowing: any tracked `*.md` that *quotes* the marker trips Rule B,
  even when it is a spec discussing the guard rather than a plan. This document hit it on first
  commit. `scripts/check-no-committed-plans.sh` dodges the same trap only because Rule B's pathspec
  is `*.md` and the script is not markdown.
- **Visual companion section deleted.** Vendoring it means six more files and ~63 KB including a
  25 KB HTTP server — a separate review surface that does not affect the gate.
- **TBD context added**: the triggers above, the default-off-flag rule, and the
  migrations-update-the-shared-model rule.
- **Drift header**, matching the shape already used in `tbd-project/SKILL.md`:
  `<!-- vendored from obra/superpowers v6.1.1 @ 5a0f8953, MIT (c) 2025 Jesse Vincent -->` plus a
  next-maintainer diff command.

  **Use `5a0f8953`, not the sha the install records.** `installed_plugins.json` pins
  `8ea39819eed74fe2a0338e71789f06b30e953041`. That sha does resolve in `obra/superpowers`, but it is
  from 2026-03-19 ("Add issue templates and disable blank issues") and its `brainstorming/SKILL.md`
  differs materially from the installed 6.1.1 copy — at that sha, step 7 still dispatches a
  `spec-document-reviewer` subagent, where 6.1.1 replaced it with an inline self-review. That is why
  `spec-document-reviewer-prompt.md` is orphaned in the installed plugin. Writing the recorded sha
  into the header would make a future maintainer "fix" changes we already have.

  `5a0f8953` (2026-06-09, "offer the visual companion just-in-time; harden lifecycle guidance") is
  the commit whose blob hashes identical to the installed file (`b0d52b25`), found by walking
  upstream history for an exact content match.

  **Known drift at time of writing:** upstream `05d90ac` (2026-07-05, "fold brainstorming Key
  Principles into points of use", +1/−9) already lands after our pin. Upstream HEAD is `3dcbd5c4`
  (2026-07-23). Vendoring `5a0f8953` content is correct — it is what was reviewed here — but the
  first drift check will surface `05d90ac` immediately.

### Naming

The skill directory is `tbd-brainstorming`, not `brainstorming`. A project skill is invoked by its
directory name; naming it `brainstorming` puts it in the roster beside `superpowers:brainstorming`
with a near-identical description and lets the model pick either. That is not benign — picking
upstream yields the wrong spec path and a terminal state pointing at the guard-violating path.

### The redirect guardrail

A rule in the existing framework with `tools = {"Skill"}`, inspecting
`tool_input["skill"] == "superpowers:brainstorming"` and returning `Decision.deny` with an
instruction to use `/tbd-brainstorming`. `deny`, not `info`: the correct action is unambiguous and
the agent can immediately re-invoke.

This is a different kind of check from the one deliberately rejected below. It does not try to
infer whether thinking happened — it compares two strings. Requires adding a `Skill` matcher to
`.claude/settings.json`, which currently matches `Bash` only, plus deny and allow tests per the
framework README.

### Codex sessions

TBD spawns Codex sessions, and the repo has no `AGENTS.md`, so they currently receive no project
instructions at all. Closed with a new `.codex/config.toml`:

```toml
project_doc_fallback_filenames = ["CLAUDE.md"]
```

Confirmed against codex-cli 0.145.0: `project_doc_fallback_filenames` is a real `ConfigToml` field,
and the binary documents project-level config as *"Project `.codex/config.toml` -> trusted-repo
Codex settings."* Two caveats: the wording says **trusted-repo** and there is a sibling
`ProjectConfig`/`trust_level` structure, so this likely applies only once the project is trusted;
and `project_doc_max_bytes` can truncate a large doc — a second reason to keep the `CLAUDE.md`
addition short. `CLAUDE.md` is currently 13 KB.

## Sequencing

**This change:** the skills, the CLAUDE.md and docs/CLAUDE.md edits, the guardrail rule and tests,
and `.codex/config.toml`.

**Follow-up, after PR #506 merges** — the nightwatch desk prompt. #506 owns
`NightwatchDeskPrompts.swift` and its siblings. The sentence, decided now so it is not re-derived:

> Never originate feature work. If TBD seems to need a capability it lacks, file it for a human —
> do not dispatch an implementer. New subsystems, flags, migrations, and load-bearing path changes
> need a human-answered spec in `docs/specs/` before anyone builds them.

It goes in the Swift string constant, not the generated on-disk plugin file — `PluginDirWriter`
rewrites the installed plugin dir on every daemon start, so on-disk edits are silently reverted.
Its test should assert on composed output and whitelist the permitted context rather than asserting
absence of a forbidden phrase: a `!contains(...)` guard fails from both sides once the prohibition
itself contains the phrase.

Before writing it, confirm how much latitude the desk judge actually has to originate work — the
hole may already be closed.

## Rejected alternatives

- **A mechanical gate on whether work was brainstormed.** No linter or hook can see it. A lint rule
  claiming to detect it would be theatre.
- **A `claude-review` merge-gate check for a linked spec.** PR time is too late — the work is
  already done, so it can only produce a retroactive spec written to satisfy a check. That is
  precisely the hollow artifact this design exists to prevent.
- **A PreToolUse guardrail gating edits on spec presence.** Same inference problem; the redirect
  rule above is kept because it checks a string, not a state of mind.
- **Repo-declared plugin install.** See above.
- **Vendoring the full superpowers plugin.** ~436 KB, three files trip `plans-guard`, permanently
  stale, and it imports a competing methodology that duplicates and contradicts existing TBD rules.
- **Migrating the 90 existing `docs/superpowers/specs/` files.** Churns history and breaks
  "read the committed spec, don't re-derive" references. New specs go to `docs/specs/`; the old
  directory simply stops accumulating.

## Known gaps

- **A determined agent can still fake it.** Nothing stops a session from running the skill,
  answering its own questions, and committing a plausible spec. The redirect makes it use the right
  skill; it cannot make a human be present. Irreducible for a convention.
- **Human contributors get no enforcement.** This is an agent-side gate.
- **Drift is manual.** Upstream touches brainstorming in roughly 80% of its releases and nothing
  signals staleness. The `skill-synced-through` header is the only marker.
- **Skill-listing budget.** With 28 plugins enabled, skill descriptions are truncated to fit a
  context budget. Check `/context` after landing to confirm `tbd-brainstorming`'s trigger words
  survived.
- **Codex trust gating** is unverified — see the caveat above.
