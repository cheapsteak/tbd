# Brainstorming gate: inverted default, and reachability from Codex

**Status:** designed 2026-07-31; supersedes the trigger wording in
[`2026-07-26-brainstorming-gate-design.md`](2026-07-26-brainstorming-gate-design.md), which otherwise stands
**Date:** 2026-07-31

## Why

PR #561 (`feat: add Continue in Codex handoffs`) shipped a new daemon subsystem, a new RPC, a new
CLI verb, a new on-disk store, and a bespoke transcript-parsing heuristic — with no spec. It is the
first substantial test of the gate that shipped five days earlier, and the gate did not fire. Two
independent causes, one social and one mechanical.

**Cause 1 — the escape hatch accepted "the design already happened elsewhere."** The PR states:

> The design was already constrained by the six successful live prototypes and the supplied parity
> report; this PR implements that bounded MVP without adding a separate brainstorming spec.

That is not a trigger-matching error. The author gave a substantive reason, and the rule's text
permits any reason ("if a trigger fires but a brainstorm is genuinely unnecessary, say so in the PR
description"). But it is precisely the failure the gate exists to prevent: the 2026-07-26 design's
own Why section condemns design thinking that "lived in a session scratchpad." Six prototypes and a
parity report are a session scratchpad by another name — none of that material is in this repo, so
no reviewer of #561 could inspect the decisions it encodes.

The concrete cost is visible in the diff. `DeterministicCodexHandoffGenerator` decides that a
Claude session's context is best represented by the last 64 KB of its JSONL, filtered to `user` and
`assistant` entries with non-empty text, truncated to 8 KB. Nothing else in TBD parses transcripts
this way. On a real 2.7 MB session that tail is 2.3% of the file and yields a mid-thought fragment,
while the JSONL's own typed fields — `ai-title`, `last-prompt`, `file-history-delta`, `pr-link` —
are discarded. Whether that is the right trade is arguable either way; the problem is that it was
never written down anywhere it could be argued with.

**Cause 2 — the gate is unreachable from Codex, and #561 was written from Codex.** See
"Reachability" below. `/tbd-brainstorming` does not exist in a Codex session. The rule instructs
Codex readers to invoke a skill they cannot invoke.

## Rule changes

Three edits, replacing the `### Blast-radius work starts with a brainstormed spec` section of
`CLAUDE.md`.

- **State the purpose.** The rule opens with why it exists: decisions about product behaviour and
  architecture must be inspectable by reviewers separately from the code that implements them. A
  purpose is something an author can reason *from*; the previous trigger list was something to
  match against.
- **Invert the default.** From "required when one of four triggers fires" to "required unless this
  is a bug fix or a minor UI change." Refactors leave the exemption list: "wholesale-replaces a
  load-bearing path" and "this is just a refactor" describe the same diff from two angles, and the
  refactor label is the easiest place to hide blast radius.
- **Close the prior-design hole.** Design done in prototypes, a report, another repo, or an earlier
  session makes the spec a cheap transcription — not an unnecessary one. Reviewers here cannot read
  that material, so those decisions are the ones that most need writing down.

New text:

```markdown
### Work starts with a brainstormed spec

Decisions about product behaviour and architecture must be inspectable by reviewers separately
from the code that implements them. So anything that is not a bug fix or a minor UI change runs
`/tbd-brainstorming` **before** implementation and commits the spec to
`docs/specs/<date>-<topic>-design.md`. If it needs a flag, it needs a spec.

**Prior design does not exempt.** Thinking done in prototypes, a report, another repo, or an
earlier session makes the spec a cheap transcription — not an unnecessary one. Reviewers here
cannot read that material, so those decisions are the ones that most need writing down.

**A human answers the brainstorming questions.** An agent may not answer its own. If none is
available, stop — do not proceed on assumed answers. Agents, including the nightwatch desk, may
not originate feature work; file it for a human instead.

Bug fixes and minor UI changes need no spec. If a larger change genuinely needs none, say so in
the PR description. This is convention, not a gate — no linter can see whether thinking happened.
Claude Code: use `/tbd-brainstorming`, not `superpowers:brainstorming`; a guardrail redirects the
wrong one. Codex has no slash command for it — read
`.claude/skills/tbd-brainstorming/SKILL.md` and follow it directly.
```

### Deliberate choices

- **The heading drops "Blast-radius."** That framing named the trigger list; with an inverted
  default the rule covers all work, so the word would contradict the body.
- **The default-off-flag rule keeps its own four triggers, unchanged.** Today the brainstorm rule
  opens "Work that trips the triggers above," coupling the two. #561's Scope paragraph shows the
  hazard: a sound flag-exemption argument sits adjacent to a spec-exemption argument and lends it
  credibility. Decoupled, the one-way link survives as "if it needs a flag, it needs a spec."
- **The free-form escape hatch stays.** Narrowed by the prior-design clause, which rules out the
  specific argument #561 used, but still open to arguments we have not anticipated. Requiring
  authors to name a category from a closed list was considered and not adopted; it is close to the
  PR-time check the 2026-07-26 design rejected.
- **Companion artifacts move in the same commit.** `.claude/skills/tbd-brainstorming/SKILL.md`
  carries the trigger list twice — in its frontmatter `description:` and in its "When this is
  REQUIRED in TBD" section. The description is what the model matches when deciding whether to
  invoke the skill at all, and the 2026-07-26 design's Known Gaps warns skill descriptions are
  truncated in a crowded roster. Inverting `CLAUDE.md` while the skill still advertises itself as
  blast-radius-only leaves the invocation trigger narrow. `brainstorming_skill.py`'s docstring and
  deny message also say "blast-radius triggers" and should stay accurate.

## Reachability

### What a Codex session actually sees

Measured with `codex debug prompt-input`, which renders the model-visible prompt as JSON without
running a model turn — no quota, no side effects. This is the cheapest way to answer "what does an
agent actually receive here," and is worth reaching for before theorising.

- **`CLAUDE.md` reaches Codex.** `.codex/config.toml` sets
  `project_doc_fallback_filenames = ["CLAUDE.md"]`, and the rule text appears in the rendered
  prompt. It appears **even in a TBD worktree**, which is absent from the `[projects.*]
  trust_level` list in `~/.codex/config.toml`. This closes the 2026-07-26 design's "Codex trust
  gating is unverified" known gap with a positive result.
- **No brainstorming skill of any kind is reachable.** The catalog in this repo is `imagegen`,
  `openai-docs`, `plugin-creator`, `skill-creator`, `skill-installer`, `agent-channels:channels`,
  `cua-driver-rs`, `find-skills`, `open-prose`. `tbd-brainstorming` is absent because
  `.claude/skills/` is a Claude Code mechanism. `superpowers:brainstorming` is *also* absent,
  despite `[plugins."superpowers@openai-curated"] enabled = true` in `~/.codex/config.toml`.
- **The redirect guardrail cannot fire.** `.claude/hooks/guardrails/rules/brainstorming_skill.py`
  is a Claude Code `Skill`-matcher wired through `.claude/settings.json`. Codex runs its own hook
  system and never sees it.

So the current sentence — "Use `/tbd-brainstorming`, not `superpowers:brainstorming`; a guardrail
redirects the wrong one" — is actively misleading to a Codex reader. It names a skill that does not
exist, forbids one that also does not exist, and promises a guardrail that cannot run. A
conscientious Codex session following it has no legal move.

### The fix in this change

Tell Codex to read the file. `CLAUDE.md` already reaches Codex, the skill is a tracked repo file,
and reading it is exactly what a skill invocation does anyway — the SKILL.md is self-contained
prose with a checklist. This travels with the repo, needs no machine setup, works in every
worktree and for every contributor, and leaks nothing into other repos.

### Rejected here

- **Ship the skill in TBD's Codex plugin** (`CodexPluginWriter`, which already writes
  `skills/tbd/SKILL.md`). That plugin installs into every TBD user's `~/.codex`. TBD's brainstorming
  gate is a convention of *this repo*, not of TBD-the-product; shipping it globally is the
  multi-tenant leak `CLAUDE.md` forbids.
- **Symlink into `~/.codex/skills/`** from `scripts/install-hooks.sh`. `$CODEX_HOME/skills` is
  genuinely auto-discovered (verified), but this is machine-level user state a PR cannot write, so
  a contributor who never runs setup hits the same dead end that produced #561. It also pollutes
  unrelated repos on that machine, and a link into a worktree path dangles when the worktree is
  archived.
- **Add an `AGENTS.md`.** Redundant — `project_doc_fallback_filenames` already routes Codex to
  `CLAUDE.md`, and a second copy would drift.
- **A per-spawn config override.** There is none. `SkillsConfig` is `{bundled,
  include_instructions}`; no config key or CLI flag adds a skill root. "Extra roots" exist only as
  an app-server RPC (`skills/extraRoots/set`) that a tmux-spawned CLI cannot reach.

## Filed follow-up: per-spawn Codex skill overlay

Not in this change. TBD spawns Claude with `--plugin-dir`, so repo-relevant skills reach Claude
sessions only. Codex has no equivalent flag, but `CODEX_HOME` is an env var TBD sets per spawn, and
`$CODEX_HOME/skills/<name>/SKILL.md` **is** auto-discovered — verified by copying the vendored skill
into a temporary `CODEX_HOME`, after which `tbd-brainstorming` appeared in the rendered catalog.

That makes a TBD-managed `CODEX_HOME` the true `--plugin-dir` analogue: per-spawn, repo-scoped,
nothing installed at user level. It is a new subsystem and needs its own brainstorm, because the
hard part is everything else that lives in `CODEX_HOME`:

- **Auth.** A fresh `CODEX_HOME` has no `auth.json`. `cli_auth_credentials_store` accepts only
  `file | keyring | auto | ephemeral` — not a path — so the clean route depends on keyring-backed
  credentials. Symlinking `auth.json` is the obvious alternative and is fragile: atomic
  write-and-rename replaces a symlink with a regular file, silently detaching TBD sessions from the
  user's real credentials on the next token refresh.
- **What else must be mirrored** — `config.toml`, the plugin cache, marketplaces, sessions,
  history — and which of those must stay shared with the user's real home rather than forked.
- **Which skills get overlaid** — a repo's `.claude/skills/` wholesale, or an opt-in list. This is
  a generic TBD capability ("repo-defined skills reach Codex sessions too"), not a TBD-repo
  feature, and must be designed as one.

The existing Codex integration deliberately avoided an isolated `CODEX_HOME` for exactly these
reasons, choosing a profile overlay in the real `~/.codex` instead. Reversing that is a real
design question, not an implementation detail.

## Known gaps

- **Human contributors still get no enforcement.** Unchanged from 2026-07-26; this remains an
  agent-side convention. #561 is evidence that the gap has teeth.
- **A Codex session must choose to read the file.** There is no roster entry making
  `tbd-brainstorming` discoverable by description-matching the way a real skill is. The follow-up
  above is what closes this.
- **The nightwatch desk-prompt follow-up never landed.** The 2026-07-26 design left it pending on
  PR #506 and nothing in `Sources/` matches it today. Its decided text reuses "the same four
  blast-radius triggers"; whoever lands it should use the inverted definition instead.
