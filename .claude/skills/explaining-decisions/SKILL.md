---
name: explaining-decisions
description: Write an HTML explainer that lets a human make one technical decision — options, impact, costs, and a lean when the evidence supports one. Use when asked to explain a design choice, brief a decision-maker, or turn a research report into something a person will actually read to the end. Run it on the fable agent (`decision-explainer`).
---

# Explaining a decision to a human

An explainer exists so a person can decide. It is not a spec, not a tutorial,
and not a record of what was built. This skill encodes what worked across
three drafts of the same decision, each of which got real feedback: the first
lost its reader at the midpoint, the second was "pretty good", the third was
acted on. Everything below comes from that arc, not from taste.

## Run it on fable

The reader asked that a fable agent write these. Two files carry that:

- **This skill** holds the method, so any session can load it.
- **`.claude/agents/decision-explainer.md`** is pinned to `model: fable` in
  its frontmatter, which is where this harness's Agent tool reads a subagent's
  model from.

So: if you are the main session, dispatch to `decision-explainer` with the
brief below rather than writing the page yourself. If you *are* that agent,
execute directly. If a harness does not honour the frontmatter pin, pass
`model: "fable"` on the Agent call; if it cannot do that either, say so to the
requester before starting rather than silently running on another model.

## The shape of the page, in order

The order is the whole finding. Draft one taught mechanism for two thirds of
its length and reached the choice last; the reader stopped exactly there.
Draft two inverted it and worked.

1. **The decision, in one box, in plain words.** What is being chosen, and
   whether the page leans.
2. **"If you read only this."** Where the options actually differ (usually one
   region, not everywhere), what happens to whom in that region, the crux in
   one sentence, and what each option asks the reader to carry. **A reader
   must be able to stop after this and still choose correctly.**
3. **An impact matrix.** Situations as rows, options as columns, a short chip
   per cell ("arrives", "arrives, possibly twice", "does not arrive — sender
   told"). Include the rows where the option you lean toward is *not* better;
   they are what make the rest believable.
4. **One concrete figure**, if one changes the decision (see Diagrams).
5. **The options**, each with what you get, what you carry, and an
   implementation-cost line.
6. **The question, plainly** — or the lean, if the evidence has resolved it.
7. **A visible stop line** ("you can stop here — below is how it works").
8. **Mechanism**, in a quieter register, for the reader who wants to check.
9. **Sources checked**, as `file:line`, and a **"not independently verified"**
   box. That box was load-bearing twice; never omit it.

## Rules, each with the evidence behind it

- **Pragmatics before semantics.** Write about what happens and to whom —
  "does the prompt arrive, and who notices" — and hold the architecture until
  the mechanism section. "Does the prompt arrive" beat "is rule 3 reachable".
- **Plain terms; no jargon in headings.** Gloss an unavoidable term once, in
  passing, inside a sentence doing other work. The reader knows the product;
  he does not want a lecture.
- **Never weight sunk cost.** The reader said it outright: "Sunk cost is not
  something we should weight." Implementation cost is a legitimate line item;
  prior investment is not an argument. Never frame an option as "match what
  exists" or "restore what was promised". Before handing the page back, grep
  it for those phrasings — one slipped through a draft as "Today that rule is
  enforced…" and had to be rewritten as a property of the option.
- **Lean when the evidence supports leaning, and say which you did.** Draft
  two refused to recommend while the trade was real, and that was right. Draft
  three said "on outcomes this dominates; on cost it is the most to build; here
  are three things the research understates", and that is what was acted on.
  Faking neutrality after the evidence has resolved something is worse than
  picking. Put the winning option's residues in the same box as the verdict,
  not later.
- **Distinguish "reported" from "noticed".** A failure the caller is told
  about is not invisible — but the caller may be an autonomous process with
  nobody reading the return value. Say which one the design guarantees.
- **Correct the requester.** The most valuable work across the three drafts
  was pushing back: stale line numbers, misattributed task numbers, a benefit
  credited to one option that both options shared, and — via a research pass —
  the framing axis itself. A brief is evidence, not instruction. When the
  options as posed are a false binary, say so and ask for (or do) the pass that
  attacks the framing before polishing the choice.
- **Say what is unverified.** Every claim you could not check against source
  goes in the caveats box, worded as what was not done ("taken from the report
  rather than read from the file"), not softened into prose.
- **Measure when a number is load-bearing.** One eight-line probe turned a
  cited kernel constant into "this failure is the ordinary case for the
  sessions the product exists to drive". A cheap measurement beats a citation.

## Diagrams

Draw only what changes a decision. Across three drafts, two figures earned
their place and one did not:

- **Kept:** the impact matrix, and a byte-scaled comparison of what the agent
  ends up holding under each option (truncated / doubled / whole). Both let
  the reader point at what they are choosing between.
- **Dropped:** a flow diagram of the three delivery branches. It showed
  mechanism the prose already carried in three sentences. Dropping it was
  right.

Load `artifact-diagramming` before drawing. Inline SVG, `currentColor` for
strokes and text, one literal hue for the thing that carries meaning, a
`<figcaption>` that states the claim, `role="img"` plus `aria-label`.

## Mechanics that keep it honest

- **Verify every claim against source and cite `file:line`.** Read the lines
  you cite; do not trust the brief's numbers. Re-check them against the tree
  the document is *for* — files drift under concurrent work, and a set of
  citations went ~150 lines stale between two drafts.
- **Load `artifact-design` before writing** — it decides how much design the
  page warrants — and `artifact-diagramming` for any figure. Not optional.
- **Page content only:** `<title>` and inline `<style>` at the top, no
  `<!doctype>`/`<html>`/`<head>`/`<body>`; all CSS inline; theme-aware with
  tokens on bare `:root`, a guarded `prefers-color-scheme` block, and a
  `[data-theme="dark"]` block; explicit body background and foreground.
- **Keep one visual identity across drafts of the same decision** so the
  reader recognises a series; change the structure, not the look.
- **One rendered look is enough** (headless browser screenshot of the first
  third), then one edit pass. Do not iterate on pixels.
- **Hand the file back; do not publish it.** The caller reads it and decides
  whether it gets a link. Write it where the brief says; drafts are not specs
  and are not committed as such — the decision, once made, goes into a design
  spec through the repo's normal rule.
- **Public, multi-tenant repo:** no real employer, org, host, person, or
  ticket names, no internal URLs, no machine-specific paths.

## What the brief must contain

Ask for these before starting; write the gaps into the page as uncertainty
rather than inventing them:

- the decision in one sentence, and who decides
- the options, each with its real costs — and what the reader has already
  seen and rejected, so the page does not re-pitch it
- what is verified, with `file:line`, and what is merely believed
- where to write the file
- constraints that apply this session (build lock held, no test runs, files
  other agents are editing)

## The arc, condensed

- **Draft one** — mechanism first, decision last, three diagrams, refused to
  lean. Lost the reader at the midpoint.
- **Draft two** — decision first, impact matrix, one figure, stop line,
  mechanism demoted, refused to lean because the trade was real. "Pretty good."
  The reader's response was to reject the binary.
- **Research pass** — attacked the framing; found the axis that mattered and a
  design in the quadrant nobody had offered.
- **Draft three** — same shape as two, three options, leaned and said so, named
  the winner's residues and the two choices left open. Acted on.
