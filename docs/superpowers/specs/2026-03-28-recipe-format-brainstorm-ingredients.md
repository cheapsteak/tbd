# Recipe Format — Brainstorm Ingredients

Raw ingredients from the brainstorming conversation that produced the manifesto and format design. Preserved so the manifesto can be revisited and distilled later.

---

## The Core Observation

- "Code" has always been a form of rasterization/reification, but agentic coding has made it more obvious
- Something is lost in the transformation, and the valuable thing to capture isn't the pixels
- The metaphor: code is rendered pixels; intent is the vector source

## The Cooking Metaphor

- A lot of software will be more like "dishes"
- "Recipes" will exist of the important parts (ideas, techniques)
- Recipes should ideally be composable
- People should be able to tweak recipes to cater to their own needs and tastes
- You can swap out ingredients (other sub-recipes, or libraries)
- Some things might never make sense to DIY — you probably always want to buy soy sauce rather than ferment your own
- But many things will make much more sense to DIY
- Especially if there exists a rich and vibrant library of other recipes to reference and build upon
- "Like npm, but for recipes"

## What Recipes Should Contain

- Primarily composed of "why" — user stories / jobs to be done
- Without the tedious "As a {x}" repetition
- Occasionally include techniques of the "how" for non-obvious things
- Architecture might be a sub-recipe that carries its own user story — architecture doesn't exist for its own sake but to solve real problems
- The "user" might not be human but machine
- Code is allowed when pragmatic — when it IS the technique. Extremism/purism is not pragmatic.

## Key Design Decisions Made During Brainstorm

### Audience: Universal
The manifesto is short enough to be universal — states the observation and implication, lets each audience (toolmakers, practitioners) draw their own conclusions.

### TBD is the first test case, not the product
The format is project-agnostic. TBD proves it out by retroactive construction.

### Two scales of recipe
A project recipe composes fragment recipes. The "dish" is the composed whole; "techniques" circulate independently.

### JTBD over other organizational models
- Story Maps: good for organizing but not framing
- Epics: arbitrary Jira buckets, no semantic meaning
- Capability Maps: niche, enterprise-oriented
- JTBD: captures the "why" — jobs are durable, features are ephemeral
- Industry consensus: JTBD has "won" the framing layer
- Tickets and epics are for implementation planning, not for distilling intent — they're rasterized too

### Granularity: Workflow-oriented, cross-cutting
- Per-architecture-decision is wrong granularity
- Per-feature is too fine for most things
- Per-workflow that cross-cuts capabilities and features is better for larger groupings
- Per-capability for medium/small granularities
- Jobs can fragment — that's expected, not a problem

### Drift is the primary fear
- Recipe drift (code evolves, recipe doesn't) is the killer — it creates false confidence
- Recipe bloat is easier to rectify — overcapture first, condense later (2 phases)
- Recipe absence is less worrying if generation is automated

### Existing specs are raw material
- Design specs in docs/specs/ are implementation-oriented
- Recipes are the transferable essence — what matters and why regardless of tech stack
- Both coexist: specs are for this dish, recipes are transferable knowledge

## Approach Selection

Three approaches were proposed and evaluated by two independent agents:

### A: Git-native (markdown in repo, no tooling)
- Lowest friction to create and consume
- No dependency management story
- Ship today

### B: npm-style (registry, semver, dependency resolution)
- Heavy infrastructure, premature
- Semver is wrong model for intent
- Registry becomes bottleneck

### C: Hybrid (markdown + recipe.yaml manifest + light CLI)
- Both agents independently recommended this
- But consensus was: start with A, grow into C when needed

**Decision: Start with A, option to evolve to C.**

## Constructive Review — Key Additions

1. `constraints/` directory for system-wide invariants that cross-cut jobs
2. `## Success looks like` and `## Traps` sections on job template
3. Buy/Make/Wrap posture on technique files
4. Evolution.md heuristic: "would a future reader wonder why not the obvious alternative?"
5. One evolution.md at recipe root, not per-directory
6. Skip deterministic drift detection → go straight to periodic AI audit
7. Format version marker (`recipe/v1`)
8. Document relationship between recipes and CLAUDE.md

## Adversarial Review — Key Challenges

1. "Code is rasterized intent" breaks down for performance-critical code, emergent/accidental knowledge, and code-as-specification (parsers, state machines) — the code IS the valuable artifact in these cases
2. JTBD fragmentation: jobs split on sprint timescales, not evolutionary ones — format must handle this gracefully
3. Drift detection is fundamentally a judgment problem — automation catches structural drift, semantic drift requires AI/human review
4. Two levels (jobs + techniques) is a simplification — constraints, aesthetic decisions, architectural invariants, NFRs, and job relationships don't fit neatly
5. The cooking metaphor is technically wrong (sequential/imperative vs declarative/incomplete) — but communicates the spirit better than "pattern language" to a general audience
6. Christopher Alexander's pattern language and 40 years of design rationale research (QOC, IBIS, DRL) are closer prior art worth studying

## Resolutions to Adversarial Challenges

- Accidental knowledge: partially captured by AI audit (reads code, surfaces undocumented edge cases)
- Job fragmentation: expected workflow — split files, update index, add evolution entry
- Inline comment drift comparison: "a thing of the past because it required human diligence; LLM diligence can solve for that already"
- Constraints directory addresses the "two levels" gap

## Recipe Lifecycle (integrating prose skills)

1. Brainstorm (conversation)
2. Synthesize (prose-synthesize) → draft recipe
3. Overcapture (live with it)
4. Distill (prose-distill) → tighten
5. AI audit → catch drift

## Sources and Prior Art Identified

- Jeff Patton — Story Maps
- Clayton Christensen, Anthony Ulwick, Alan Klement — Jobs To Be Done
- Michael Nygard — Architecture Decision Records
- Christopher Alexander — Pattern Language
- QOC, IBIS, DRL — Design rationale frameworks
- Nix Flakes, Terraform modules, Homebrew formulas — composition/distribution models
- Schema.org Recipe format — metadata about recipes
- Spec-Driven Development — specs as executable artifacts
- Rustdoc doctests, Python doctests — executable documentation
- Storybook — shared component documentation preventing drift
