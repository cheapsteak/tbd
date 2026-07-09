# No TUI screen-scraping — structural guard design

**Date:** 2026-07-09
**Status:** Approved
**Branch:** `tbd/no-tui-scraping-guard`

## Problem

PR #398 added a "verify-and-retry submit" layer to `tbd terminal send --submit` that
decided whether a submit succeeded by running `tmux capture-pane` and parsing the
rendered screen: it found the bottom-most line starting with Claude's composer glyph
`❯` and checked it for the literal `[Pasted text`. A live investigation later proved
the state it defended is unreachable (Claude pins bracketed-paste mode on), and the
layer is being removed as dead code in a sibling branch.

The durable lesson: **inferring agent state by scraping the rendered TUI screen is an
anti-pattern in TBD.** It is (a) brittle — it breaks *silently* when the TUI changes a
glyph, placeholder string, or its rendering; (b) coupled to a specific TUI and version;
(c) at the wrong layer — agent state should come from machine interfaces (hooks,
transcript JSONL, control mode, exit codes), not from pixels-as-text.

This design makes it structurally hard to reintroduce the pattern.

## Definition

Capturing pane text is **fine** when the text is passed through verbatim — display,
transport (`terminal.read`), or snapshotting. It becomes **scraping** when code
*branches on the captured content* by matching UI-specific strings or glyphs to infer
agent state.

A deterministic guard cannot do that dataflow analysis, so the design approximates it
with layered mechanical checks plus visible, commented escape hatches.

## Current inventory (audited 2026-07-09)

Legitimate capture (verbatim pass-through):

- `RPCRouter+TerminalHandlers.swift:402,646` — `terminal.read` RPC returns pane text
  to the caller unparsed.
- `HibernationCoordinator.swift:269` — ANSI screen snapshot before hibernation
  (capture-for-display).
- `PaneCaptureReplay.swift` — control-mode attach/repair capture batch; reassembles
  captured lines into replay bytes verbatim for display reconstruction (post-audit
  addition, found by the rule itself during implementation).

Sanctioned scrapers (exempt now, refactor later):

- `LoginSessionCoordinator.swift:95-99` — classifies pane text (`"Run /login"`, `❯`,
  `"Select login method"`) to drive the interactive `claude /login` flow. The login
  TUI exposes no machine interface (no hooks fire pre-login).
- `HibernationSafetyChecks.swift:28-48` — `hasPendingInput(paneCapture:)` detects
  typed-but-unsent composer text (placeholders `"Ask Claude"`, `"Type a message"`,
  `"Try \""`) as a hibernation safety rail. No machine signal exists for "composer
  has pending input".
- `NightwatchSkillContent.swift` — embedded Python (`DECISION_PAT`, `RATE_PAT`, …)
  classifies fleet panes by UI strings; runs `tmux capture-pane` from Python inside a
  Swift string literal. Screen classification is its entire purpose. Longer term this
  arguably shouldn't live inside TBD at all, but TBD lacks a plugin/extensibility
  surface for custom workflows today.

The anti-pattern itself (`verifyAndRetrySubmit`, `RPCRouter+TerminalHandlers.swift:1383`)
still exists on this branch; its removal is in flight on a sibling branch. See
Sequencing.

## Design — four layers

### Layer 1: SwiftLint rule `no_tui_scraping_literals` (Rule A)

Custom rule in `.swiftlint.yml`, following the `no_print_in_sources` pattern
(severity `error`, enforced by the existing `lint` CI job and pre-push hook via
`swiftlint --strict` — zero new plumbing).

- `included`: `Sources/.*\.swift`
- `match_kinds`: `string` only. Custom-rule regexes run over raw file text, then
  filter the matched region by syntax kind: this catches literals inside ordinary
  strings *and* inside `#"""…"""#` raw heredocs (the embedded-Python case — same
  mechanism the existing `migration_use_helpers` rule uses to catch DDL in SQL
  strings), while leaving doc comments that merely *mention* a glyph legal (e.g.
  `TmuxManager.swift:303`).
- `regex`: alternation of high-signal agent-UI strings:
  `❯`, `[Pasted text`, `esc to interrupt`, `Do you want to proceed`,
  `Enter to select`, `Tab/Arrow keys`, `Select login method`, `Run /login`,
  `Ask Claude`, `Type a message`, `context used`, `until auto-compact`,
  `bypass permissions`.
- `excluded` (each with a why-comment and refactor-later note): the three sanctioned
  scrapers listed above.
- `message`: infer agent state from hooks, transcript JSONL, control mode, or exit
  codes — never from rendered screen text; see CLAUDE.md.

Rationale: the tell of a scraper is the UI strings it matches against, which must
appear as literals *somewhere*, regardless of how the pane text reaches the matching
code (direct capture, injected closure, plain `String` parameter). This is what
catches `classifyPane`-style scrapers that never call a capture API.

### Layer 2: SwiftLint rule `capture_pane_allowlist` (Rule B)

Same shape. Any new file touching the capture surface trips lint; the only path
through is a visible `.swiftlint.yml` exclusion diff that Layer 3 tells the reviewer
to scrutinize.

- `included`: `Sources/.*\.swift`
- `regex`: `capturePane\w*\s*\(` (kind `identifier`) and `capture-pane`
  (kind `string`), as one alternation with `match_kinds: [identifier, string]`.
- `excluded`: `TmuxManager.swift` (defines the API), `RPCRouter+TerminalHandlers.swift`
  (verbatim `terminal.read`), `HibernationCoordinator.swift` (display snapshot),
  `PaneCaptureReplay.swift` (capture-for-replay), `NightwatchSkillContent.swift`
  (embedded Python).

### Layer 3: PR-review gate instruction

One concise paragraph added to the `Additional review instructions` block of the
`prompt` in `.github/workflows/claude-code-review.yml`. **Prompt content only — the
trigger is untouched**, so no admin merge is needed (see `docs/pr-review-gate.md`).

Content: treat as **High severity** (→ REJECT) any new logic that parses captured
terminal/screen text to infer agent state (matching TUI glyphs, prompts, placeholder
or status strings), *and* any new exclusion added to the `no_tui_scraping_literals` /
`capture_pane_allowlist` rules without strong justification. Point to the CLAUDE.md
policy section.

This layer covers what the deterministic rules cannot: structural scrapers with no
recognizable literals (e.g. matching a bare `>` prompt prefix), novel TUI strings not
yet in the denylist, and social-engineering of the allowlist.

### Layer 4: Policy doc

A short "No TUI screen-scraping" section in the repo `CLAUDE.md` — the single thing
the lint messages and the review instruction cite. States the rule, the why (brittle /
silent / wrong layer; PR #398 story in one line), the correct layers to use instead,
and the exemption process (add a commented exclusion; expect review scrutiny).

## Known residual gap

A scraper that branches only on structural features (line counts, bare `>` prefixes,
box-drawing characters) with zero denylisted literals escapes both rules. Accepted:
Layer 3 exists precisely for this; tightening Rule A's regex to catch structure would
drown in false positives.

## Sequencing

This branch still contains `verifyAndRetrySubmit`, whose `❯` / `[Pasted text` literals
correctly fail Rule A. No temporary exclusion (it would defeat the point). Instead:

1. Implement everything; run `swiftlint --strict` and confirm Rule A fires on
   `verifyAndRetrySubmit` — this is the positive acceptance test.
2. Wait for the sibling removal branch to merge to `main`, rebase, confirm zero
   violations, then open/land the PR.

## Testing

Mechanical verification via `swiftlint --strict` (or `swiftlint lint` scoped runs):

- (a) Pre-rebase tree → Rule A fires on `verifyAndRetrySubmit` (proof the rule works).
- (b) Scratch fixture files (outside the repo, linted with a copied config) exercising
  each rule and each exclusion → fire / not-fire as expected. Fixtures include: UI
  literal in a plain string; UI literal inside a raw `#"""…"""#` heredoc; glyph in a
  doc comment (must NOT fire); `capturePane…(` call in a non-allowlisted file;
  `capture-pane` argv string in a non-allowlisted file.
- (c) Post-rebase tree → zero violations.

No Swift tests: lint config is not runtime branching (CLAUDE.md's
branch-coverage-for-conditionals rule doesn't apply), and the `no_print_in_sources`
precedent ships without tests.

## Out of scope

- Refactoring the three sanctioned scrapers off screen text.
- A plugin/extensibility surface that would let Nightwatch live outside TBD.
- Guarding `Tests/` — live-tmux tests legitimately assert pane content to verify
  delivery/rendering.
