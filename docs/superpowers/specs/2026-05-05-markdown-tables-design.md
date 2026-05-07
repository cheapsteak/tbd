# Markdown tables (and other block elements) in chat bubbles

## Problem

The transcript pane renders Claude assistant messages as chat bubbles. Inline markdown is parsed via Apple's `AttributedString(markdown:)` with `interpretedSyntax: .inlineOnlyPreservingWhitespace`. Inline syntax — `**bold**`, `*italic*`, `` `code` ``, `[links](url)` — and plain prose render fine today. The parser is deliberately inline-only, so block constructs are not interpreted; in practice:

- **Tables** are the main visible breakage — they degrade into pipe-delimited soup that's unreadable. Claude responses frequently use tables for span-kind summaries and comparison grids, so this hurts often.
- Headings / lists / blockquotes / thematic breaks are not formatted as blocks either, but they read acceptably as literal markdown (a `- item` list still scans visually) and rarely appear in chat content. Lifting them is a nice byproduct, not the driver.

## Goal

Make tables render as proper grids inside chat bubbles by adopting the `MarkdownUI` package — already a project dependency via `Package.swift` (added with the code-viewer pane in commit `1b880cf`). Block-level elements (headings, lists, blockquotes, thematic breaks) come along for free; the explicit success criterion is tables.

Out of scope:

- Tool cards (`BashCard`, `EditCard`, `WriteCard`, etc.) — they render plain text or pre-formatted code; markdown is not relevant.
- Refactoring the existing `Theme.codeViewer` in `CodeViewerPaneView.swift`. It stays as is.
- Code-fence rendering. Fences continue to flow through `MarkdownSegments` → the existing `codeBlock(language:content:)` view, which does syntax-highlight headers and language tagging.

## Approach

Minimal-churn integration:

1. Keep `MarkdownSegments.split(_:)` in front of every bubble. It already cleanly partitions text into ordered `.prose` and `.code(language:content:)` segments.
2. For each `.prose` segment, replace the current `Text(attributedProse(p))` call with `Markdown(p).markdownTheme(.chatBubble).textSelection(.enabled)`.
3. For each `.code` segment, route through the existing `codeBlock(...)` view unchanged.

This means MarkdownUI **never sees a fenced code block in normal flow**, because `MarkdownSegments` strips them upstream. If a malformed/unterminated fence ever leaks into a prose segment, MarkdownUI's default `.codeBlock` styling is acceptable as a safety net.

## Theme strategy

Build a new dedicated `Theme.chatBubble` as a `private extension MarkdownUI.Theme` in `ChatBubbleView.swift` (mirroring how `Theme.codeViewer` is `private` to its file). Starting point: `Theme.basic`, override only what's needed.

Critical preserves vs. today's bubble:

- Prose font matches `.font(.body)` (system 13pt regular on macOS 15).
- Foreground is `.primary` (today's default), so it inherits dark/light mode and bubble-background contrast.
- Text remains selectable.
- Inline `code` keeps a monospaced style with a subtle background tint.

Theme overrides:

- `.text` — `ForegroundColor(.primary)`, default font properties (let SwiftUI's `.body` flow through).
- `.code` — `FontFamilyVariant(.monospaced)`, `FontSize(.em(0.92))`, low-opacity secondary background.
- `.paragraph` — `markdownMargin(top: 0, bottom: 0)`. Vertical separation between prose blocks comes from the surrounding 6pt `VStack` spacing, not internal MarkdownUI margins. This is the single most important preserve: today's bubble has no per-paragraph 16pt gutter, and adopting one would visually regress every existing assistant message.
- `.listItem` — `markdownMargin(top: .em(0.15))` for compact list spacing.
- `.blockquote` — leading rule (rounded rectangle, `.secondary` color), `.em(1)` horizontal inset, secondary text color.
- `.heading1`/`.heading2`/`.heading3` — semibold + modest em scale (1.4 / 1.2 / 1.05). Headings are rare in chat content; keep them subtle so they don't dominate the bubble.
- `.heading4`/`.heading5`/`.heading6` — semibold only.
- `.table` — `markdownTableBorderStyle(.init(color: .secondary.opacity(0.3)))`, alternating row tint at low opacity that reads on both bubble backgrounds (user accent-tinted, assistant `controlBackgroundColor`), `markdownMargin(top: 0, bottom: 0)`.
- `.tableCell` — header row (row 0) bold, vertical padding 4, horizontal padding 8.
- `.thematicBreak` — thin `Divider` with `.em(0.25)` margin.
- `.codeBlock` — left at `Theme.basic` defaults (defensive only; production flow excludes fences via `MarkdownSegments`).

## Implementation plan

Single file: `Sources/TBDApp/Panes/Transcript/ChatBubbleView.swift`.

Edits:

1. Add `import MarkdownUI` to the top of the file.
2. Replace `Text(attributedProse(p))` (current line 64) and its `.font(.body).textSelection(.enabled)` chain with:
   ```swift
   Markdown(p)
       .markdownTheme(.chatBubble)
       .textSelection(.enabled)
   ```
3. Delete `attributedProse(_:)` (current lines 104–109) — no remaining callers.
4. Append the new `private extension MarkdownUI.Theme { static let chatBubble = ... }` near the bottom of the file.
5. Add a `#Preview` block (if not already present) that exercises the new rendering with a mix of plain text, a table, a list, a blockquote, a heading, inline code, and a fenced code block.

No changes to:

- `MarkdownSegments.swift`
- `Package.swift` / `Package.resolved`
- Any other file in `Sources/TBDApp/`, `TBDDaemon`, `TBDShared`, or `TBDCLI`.

## Verification

This is a UI-only change with no obvious unit-test surface.

1. `swift build` succeeds cleanly.
2. `scripts/restart.sh` (worktree-relative — never the absolute path to the main project per `CLAUDE.md`).
3. Verify exactly one TBDDaemon and one TBDApp from the worktree path: `ps aux | grep -E "\.build/debug/TBD" | grep -v grep`.
4. Open the app and either:
   - Find a real Claude session whose transcript contains a markdown table (try `grep -l '|.*|.*|' ~/.claude/projects/*/conversation*.jsonl`), navigate the tab, and visually confirm the table renders as a grid; OR
   - Drive the SwiftUI `#Preview` from Xcode and confirm the rendered output matches expectations.
5. **Regression check (most important)**: existing assistant prose — the common case of plain text with inline `**bold**`, `*italic*`, `` `code` ``, and `[links]` — must look indistinguishable from before. This is the path that *already works* today; the swap mustn't degrade it. If line spacing, paragraph gaps, font size, or inline styling has shifted, tighten the theme's `.text`, `.code`, and `.paragraph` overrides until parity is restored.

## Risk and rollback

- Risk: MarkdownUI's default rendering pipeline can introduce subtle typographic differences (line height, leading, paragraph spacing) that aren't obvious in a single-message preview but show up in long transcripts. Mitigation: explicit `paragraph` margin reset; visual A/B against an existing transcript before committing.
- Risk: `Markdown(...)` is a heavier view than `Text(...)`. For long conversations this could affect scrolling perf in the transcript pane. Mitigation: the transcript pane already uses `LazyVStack` (per the surrounding code in `TranscriptPane`); off-screen bubbles aren't rendered. If perf regresses noticeably, fall back to the inline-only path for prose segments containing no block-level markers (cheap heuristic: regex `^\\s*(\\||#|>|[-*+] |\\d+\\. )` per line).
- Rollback: revert the single commit. No schema, no daemon, no shared models, no migrations.

## Suggested commit shape

One commit:

```
feat: render markdown tables and block elements in chat bubbles

Swap Apple's inline-only AttributedString(markdown:) parser for
MarkdownUI on .prose segments produced by MarkdownSegments. Adds a
chat-bubble-tuned Theme that preserves today's body-font, .primary
color, and per-segment spacing, while enabling tables, lists,
blockquotes, headings, and thematic breaks. Fenced code blocks remain
on the existing custom code-block path.
```
