# Rich Transcript Rendering — Tool Calls, Thinking, and System Activity

**Date:** 2026-05-05
**Status:** Design approved; awaiting implementation plan
**Predecessor:** `docs/superpowers/specs/2026-05-04-claude-tab-live-transcript-design.md`

## Problem

The live transcript pane and the history pane currently render only user prompts and Claude's prose responses. Everything else — tool calls (`Read`, `Edit`, `Bash`, …), thinking blocks, system reminders, slash command envelopes, and tool results — is filtered out at parse time. A Claude turn that's mostly tool work shows up as silence on the user side and a one-liner on Claude's side. You can't audit what Claude actually did from the transcript view; you have to fall back to the terminal.

## Goals

- One reading view that captures the full picture of a Claude session — prompt, prose, every tool call, every result, every injected system block — without needing to switch to the terminal.
- Tool calls render as discrete activity rows with curated layouts for the high-frequency tools (`Read`, `Edit`, `MultiEdit`, `Write`, `Bash`, `Grep`, `Glob`); a generic fallback for everything else (MCP, custom skills, `Task`, etc.).
- "Audit by default" body density: cards show real content (diffs, command + output, file paths), bounded by a single truncation cap with on-demand "Show full output."
- Thinking, system reminders, and slash commands are visible inline at low contrast — no toggle, no jumping around.
- Chat bubbles (user prompts and assistant prose) render markdown — inline emphasis (`**bold**`, `*italic*`, `` `code` ``), links, and fenced code blocks — so responses read as Claude formatted them rather than as raw markdown source.
- Subagent (sidechain) conversations dispatched via the `Task` tool are renderable inline as a nested timeline beneath the parent `Task` card. Collapsed by default; expanding shows the subagent's full activity (its own tool calls, prose, thinking) using the same renderers, recursively (subagents that dispatch subagents nest further).
- Both panes (live `LiveTranscriptPaneView` and historical `SessionTranscriptView`) get the upgrade simultaneously through shared rendering primitives.

## Non-goals

- Rich rendering for tools we haven't seen yet beyond the generic card. Curated renderers can be added incrementally as use cases warrant.
- Streaming / token-by-token live updates. The polling cadence stays 1.5 s; the daemon parses committed JSONL lines.
- Persisting per-card expand/collapse state across pane re-opens. State lives in `@State`; closing and reopening resets.
- Daemon → app push notifications. The polling architecture from the prior design carries over.
- Block-level markdown beyond fenced code blocks: lists (bulleted / numbered), headings, tables, blockquotes, HTML inline tags, LaTeX math. Inline emphasis, inline code, links, and triple-backtick code blocks are in scope (see "Chat bubble formatting"); richer block-level markdown is not — those constructs render as plain inline text with their syntax visible. Adding them would require a third-party SwiftUI markdown library.

## Design

### Data model and parsing

The current `ChatMessage` (one role + one text) can't carry tool calls or non-prose content. Replace the transcript payload with a structured `TranscriptItem` enum, parsed daemon-side.

```swift
public indirect enum TranscriptItem: Codable, Sendable, Identifiable {
    case userPrompt(id: String, text: String, timestamp: Date?)
    case assistantText(id: String, text: String, timestamp: Date?)
    case toolCall(id: String, name: String, inputJSON: String,
                  result: ToolResult?, subagent: Subagent?, timestamp: Date?)
    case thinking(id: String, text: String, timestamp: Date?)
    case systemReminder(id: String, kind: SystemKind, text: String, timestamp: Date?)
    case slashCommand(id: String, name: String, args: String?, timestamp: Date?)
}

public struct Subagent: Codable, Sendable {
    public let agentID: String           // matches the subagent JSONL file name
    public let agentType: String?        // from meta JSON, e.g. "feature-dev:code-explorer"
    public let items: [TranscriptItem]   // recursive — subagents may have their own .toolCall(subagent:)
}

public struct ToolResult: Codable, Sendable {
    public let text: String         // primary display text, truncated per body cap
    public let truncatedTo: Int?    // total original char length when truncated, else nil
    public let isError: Bool
}

public enum SystemKind: String, Codable, Sendable {
    case toolReminder, hookOutput, environmentDetails, slashEnvelope, other
}
```

`id` is `String` rather than `UUID` because the underlying JSONL ids are heterogeneous: user/assistant lines carry a UUID-shaped `uuid` field, but `tool_use_id` is a Claude-Code-issued opaque string (`"toolu_01Foor..."`). Modeling the union as `String` is more honest than coercing tool_use_ids into synthetic UUIDs and avoids a deterministic-hashing layer for no benefit. For multi-block assistant lines that emit several `TranscriptItem`s from one JSONL line, items derive their `id` deterministically from `<lineUUID>#<blockIndex>` so it's stable across polls.

`inputJSON` is shipped as a `String` (raw JSON text) rather than a typed `JSONValue`. Curated renderers parse it on-demand into typed structs (`EditInput { file_path, old_string, new_string, replace_all }`, `BashInput { command, description }`, etc.). Keeps shared types minimal; pays one `JSONDecoder` per curated card render — cheap.

**Daemon-side parsing responsibilities** (extends `Sources/TBDDaemon/Claude/ClaudeSessionScanner.swift`):

- Iterate JSONL lines in order. Each line emits 0..N `TranscriptItem`s.
- Assistant lines may have multiple content blocks (`thinking`, `tool_use`, `text`); emit one item per block in order, sharing the line timestamp.
- Pair `tool_use` with the matching `tool_result` (in a later JSONL line) by `tool_use_id` in a single forward pass with a dictionary. A `tool_use` without a matching result becomes `.toolCall(result: nil, subagent: nil)` (in-flight or interrupted).
- Parse user-role lines that begin with known system markers into typed `.systemReminder` / `.slashCommand` items rather than dropping them. Generic "looks-like-an-injection" fallback (text starts with `<` followed by a tag-like word) maps unknown markers to `.systemReminder(kind: .other)` so future Claude Code injections render as faint generic rows instead of getting mis-parsed as user prompts.
- For each `Task` tool_use: when its tool_result lands and contains `toolUseResult.agentId`, locate the subagent JSONL at `<projectDir>/<sessionID>/subagents/agent-<agentID>.jsonl`, recursively parse it into a `Subagent`, and attach it to the `.toolCall`. The recursive parse uses the same parser (sidechain files have the same line schema). Sibling `agent-<agentID>.meta.json` provides `agentType` if present; absent or unparseable `.meta.json` is non-fatal (`agentType: nil`).
- Apply a body-content cap (2 KB OR 30 lines, whichever hits first) per text/output field. When truncated, set `ToolResult.truncatedTo` to the original length so the app can show `… N more chars · Show full output`.

The daemon parser is the single source of truth for the JSONL contract. Render *style* lives in the app; render *structure* lives in shared types.

### Visual layout

Single vertical timeline of items in chronological order. Two visual languages:

**Chat bubbles** — only for `.userPrompt` and `.assistantText`. Same shape as the existing live transcript pane: rounded card, accent tint for user (right-aligned), neutral tint for Claude (left-aligned), role + timestamp header. Carried over unchanged.

**Activity rows** — for `.toolCall`, `.thinking`, `.systemReminder`, `.slashCommand`. Unwrapped — no bubble, no tint band. They sit flush in the timeline, full-bleed against the pane edges with a faint horizontal separator above and below. Each row has:

- A monospace **header line** with an icon, tool/kind name, and a one-line summary (tool path, command description, etc.).
- A **timestamp** on the right of the header in the existing `.absoluteShort` format.
- An **expanded body** below, scaled to its content. Bounded by the body cap.

Activity rows from the same Claude turn pack tightly (no inter-row spacing). Spacing increases when the timeline transitions back to a chat bubble, signaling the end of a turn.

**Faintness ladder (most → least prominent):**
1. Chat bubble text — `.primary`.
2. Tool card header line — `.secondary`.
3. Tool card body — `.secondary` (monospace where appropriate).
4. Thinking, system reminders, slash command echoes — `.tertiary`, smaller font, italic for thinking.

Empty pane / loading / no-session states: unchanged from the existing live transcript pane.

### Chat bubble formatting

`.userPrompt` and `.assistantText` bubbles render their `text` as markdown rather than plain text. Tool call bodies, thinking blocks, system reminders, and slash commands keep plain monospace / plain text — those are typically logs, JSON, or system noise where markdown would mis-render.

**Inline formatting** (built-in `AttributedString(markdown:)`):
- `**bold**`, `*italic*`, `` `inline code` ``
- `[links](https://example.com)` — clickable, use the system accent color, open in the user's default browser via `NSWorkspace.shared.open(url)`.
- Hard line breaks preserved by parsing with `.full` (rather than the default `.inlineOnly`) interpreted-syntax options where supported, falling back to `.inlineOnlyPreservingWhitespace` on older toolchains.

**Fenced code blocks** (custom split, no third-party lib):
- A small helper splits a message's `text` on `^```` fences (with optional language tag like ` ```swift `), producing an ordered array of segments: `.prose(String)` and `.code(language: String?, content: String)`.
- The bubble renders each segment in order: `.prose` segments via `Text(AttributedString(markdown:))`; `.code` segments as a monospace `Text` inside a `RoundedRectangle` with a subtle tinted background and small inset padding, using `.font(.system(.body, design: .monospaced))` and `.textSelection(.enabled)`.
- Language tag is currently informational only — no syntax highlighting in v1. The tag is shown as a small chip above the code block (`swift`, `bash`, `json`, …). Highlighting can graduate from generic fallback later.
- Unterminated fences (no closing ``` ` ```) treat the rest of the text as a single code segment.

**Where markdown does NOT apply:**
- `.toolCall` input/output bodies (always monospace plain text).
- `.thinking` (italic plain text).
- `.systemReminder` (faint plain text).
- `.slashCommand` chip and args (plain text / monospace).

**Performance:** `AttributedString(markdown:)` parsing is fast and synchronous. Re-running per render is acceptable at chat-pane scale; no caching needed for v1. The fence-splitter is a single linear pass over the string.

**Out-of-scope rendering** (lists, headings, tables, blockquotes, HTML, math) degrade to plain inline text — `# Heading`, `- bullet`, etc. show their syntax verbatim. Acceptable for v1 since these are rare in conversational responses.

### Curated tool renderers

Six tools get tailored renderers. Everything else falls through to `GenericToolCard`. Each renderer parses the tool's `inputJSON` lazily into a typed struct on render.

#### `Read`
- **Header:** `📖 Read  <relativePath>` plus `:<offset>` if `offset` is set.
- **Body:** none by default. If `offset` and/or `limit` are set, show `lines <offset>–<offset+limit>` as a faint subtitle. Result text isn't shown by default — it's the file contents and would dominate the pane. Click to expand reveals the result body bounded by the cap.

#### `Edit` / `MultiEdit`
- **Header:** `✏️ Edit  <relativePath>` (single Edit) or `✏️ Edit ×<N>  <relativePath>` (MultiEdit). `replace_all: true` adds a small `(all)` chip.
- **Body:** inline diff. Red lines for `old_string` content, green lines for `new_string`. Monospace, one column. For MultiEdit, hunks separated by a thin divider; the `replace_all` chip applies per-hunk if heterogeneous.
- **Per-hunk truncation:** if a single hunk's `old_string` or `new_string` exceeds the body cap, that hunk shows the first N lines with `… expand`; surrounding hunks remain visible.
- **Error case:** result with `isError: true` shows the error text in red instead of the diff; header gets a `❌` prefix.

#### `Write`
- **Header:** `📝 Write  <relativePath>  · <N lines>` (line count derived from the input's content string).
- **Body:** first ~15 lines of the written content in a monospace block, with `… expand` if longer. Syntax highlighting only if the file extension matches a language we already syntax-highlight elsewhere (check `CodeViewerPaneView` for the existing list); otherwise plain monospace.

#### `Bash`
- **Header:** `▶️ Bash  <description>` if `description` is present; otherwise `▶️ Bash  $(<first 60 chars of command>…)`.
- **Body, two stacked monospace blocks:**
  1. The full command (truncated at 6 lines / 2 KB with expand).
  2. The result output (truncated at 30 lines / 2 KB with expand). stderr distinguished from stdout if the JSONL splits them; merged otherwise.
- **Status:** non-zero exit, timeout, or error → red header chip with the error reason.

#### `Grep`
- **Header:** `🔍 Grep  <pattern>` plus `in <relativePath>` chip if `path` is set, plus a `<N matches>` chip from the result.
- **Body:** first ~10 result lines (`file:line:match` format), `… expand` if more.

#### `Glob`
- **Header:** `📁 Glob  <pattern>`
- **Body:** first ~10 matching paths, `… expand` if more.

**Cross-cutting behavior for all six:**
- Clicking the header toggles body expansion (collapse/expand). State is per-card `@State`, not persisted.
- File paths shown relative to the worktree root when possible; fall back to absolute. The renderer reads the worktree path via `appState.worktrees`/`appState.terminals` chain; if mismatched, absolute path is fine.
- `result == nil` (in-flight) → spinner where the icon would be, `Running…` in the body slot. Next poll's matching `tool_result` swaps the body in place using the stable `tool_use_id` as the SwiftUI `id`.

### Generic fallback

Anything not in the curated six (MCP tools — `mcp__plugin_*__*`; custom skills — `Skill` invocations carrying a `skill` key; built-in misc — `Task`, `WebFetch`, `WebSearch`, `TodoWrite`, `NotebookRead`, `NotebookEdit`, etc.) renders through one shared `GenericToolCard`:

- **Header:** `🛠 <tool.name>` with a pretty-formatted name. `mcp__plugin_foo__bar` becomes `mcp · plugin_foo · bar`. `superpowers:brainstorming` (skill names with colons) renders as-is.
- **Body, two parts:**
  1. Pretty-printed input JSON (monospace, 2-space indent), bounded by the body cap.
  2. Result text below, bounded by the cap.
- No semantic interpretation. The renderer just pretty-prints what it gets. Specific tools can graduate to curated renderers as use cases warrant.

### Truncation and "Show full output"

A single body cap (`bodyCharCap = 2000`, `bodyLineCap = 30`, whichever hits first) applies to every text/output body section: tool input JSON, tool result text, file write contents, Bash output, thinking blocks, system reminders. Implemented daemon-side in the parser.

When truncated, the card renders a faint footer: `… 4,872 more chars · Show full output`. Clicking issues a one-shot `terminal.transcriptItemFullBody(terminalID, itemID)` RPC that returns the un-truncated body string. The result is cached on the card's `@State` so subsequent renders use the full version.

The full-body RPC re-reads the JSONL for the worktree's project dir, finds the line whose `uuid` matches the requested item id, and returns its full content (the appropriate field — tool_result content, tool_use input, thinking text). If the file is gone or the line can't be found, returns a `"Output no longer available."` placeholder rather than throwing.

### Thinking, system reminders, slash commands

- **`.thinking`** — full-width activity row, `💭 Thinking` header, body text below in `.tertiary` italic. Same body cap as everything else.
- **`.systemReminder`** — full-width row with `ⓘ` icon, the `kind` rendered as a chip (`system-reminder`, `environment_details`, `tool_reminder`, `other`), body text below at `.tertiary`. The user-prompt that *contained* the system envelope still renders as a normal user bubble — the system row is a sibling, not a replacement.
- **`.slashCommand`** — chip-styled row: `/skill-name` in monospace with args truncated to one line. The corresponding user-prompt content (the prompt typed to invoke it) renders separately as a normal user bubble.

No merging of adjacent identical reminders. Rare in practice; merging would hide actual frequency.

### Subagent (sidechain) conversations

When Claude dispatches a subagent via the `Task` tool, Claude Code writes the inner conversation into a sibling file rather than inlining it into the parent session. Path scheme:

- Parent session: `~/.claude/projects/<encoded-cwd>/<sessionID>.jsonl`
- Subagent file: `~/.claude/projects/<encoded-cwd>/<sessionID>/subagents/agent-<agentID>.jsonl`
- Subagent meta: `~/.claude/projects/<encoded-cwd>/<sessionID>/subagents/agent-<agentID>.meta.json`

**Correlation.** Each `Task` tool_use has a `tool_use_id`. The matching tool_result line (in the parent file) carries a `toolUseResult` blob whose `agentId` field names the subagent's JSONL file. The parser uses that to load the subagent on demand during the parent's parse pass, recursively parsing the subagent file with the same logic so its own tool_use/tool_result pairing, multi-block messages, system blocks, and nested `Task` calls all resolve.

**Recursion.** A subagent that dispatches its own subagent has its child file at the same path scheme keyed by the inner agent's id. The recursive parser handles arbitrary depth; in practice depths beyond 3–4 are unusual.

**View.** A `.toolCall` item with `subagent != nil` renders as a `Task` card (generic-toolcard chrome) plus, in its body footer, a single affordance:

`▶ Show N subagent activities · feature-dev:code-explorer`

(`agentType` from `.meta.json` is shown after the count when present; otherwise just the activity count.)

Clicking expands the body to show the subagent's `items` rendered through the same `TranscriptItemsView`, beneath the parent card. Visual depth indicator: 24 px left indent per nesting level plus a 1 px vertical accent bar in `.tertiary` opacity along the indent guide. Re-collapsing hides the inner timeline. State is per-card `@State` (not persisted), keyed by the parent `tool_use_id`.

The collapsed parent card still shows the subagent's final return text in the `result.text` slot — that's the current behavior of the generic Task card. Expansion adds the *journey*; the *outcome* is visible without expanding.

**Recursion in the view** uses the same `TranscriptItemsView`, called recursively on `subagent.items`. Curated renderers (Edit, Read, Bash, etc.) work identically inside subagent timelines. Nested `.toolCall(subagent: .some)` rows get their own "Show subagent activities" affordance, expanding deeper.

**Edge cases:**
- *Subagent file missing or unreadable* (race during write, file deleted): `.toolCall(subagent: nil)` and the affordance doesn't appear. The parent card still shows the result text.
- *Subagent file present but parser sees no completed tool_result yet for the parent Task*: parent renders as in-flight (`Running…`); subagent body still attached and expandable since the subagent file may have its own internal activity already.
- *Empty subagent file* (just opened, before first line written): `Subagent.items == []`; affordance shows "Show 0 subagent activities" — render as a no-op disabled chip rather than hiding, so the user knows a subagent was dispatched.
- *Recursive cycle* (shouldn't happen given file naming, but defensively): the parser tracks visited agent IDs in the recursion stack and stops at a re-visit, attaching `Subagent.items: []` and a `.systemReminder(kind: .other)` noting the cycle.

**Performance.** Subagent items are shipped as part of the main transcript payload (eager), not lazy via a separate RPC. The truncation cap applies per-item across the recursion, so total size scales with total items, not depth. For unusually heavy multi-agent sessions, the lazy-fetch upgrade (a `terminal.subagentTranscript(parentToolUseID)` RPC) is a future optimization — out of scope for v1.

### In-flight tool calls and pollability

A `tool_use` JSONL line written without a matching `tool_result` becomes a `.toolCall(result: nil)` item. On the next 1.5 s poll, the parser sees the new `tool_result` line and emits a `.toolCall(result: .some)` item with the same `id` (= `tool_use_id`). SwiftUI `ForEach` keyed on the item id swaps the body in place without reordering — the row stays visually stable.

The existing equality check in `LiveTranscriptPaneView.pollOnce` (count + last-id) extends to the new payload: count + per-item id is sufficient since `id` is stable for unchanged items and changes only when the item itself changes (e.g., result lands).

### Migration

`ChatMessage` and `terminal.transcript`'s `[ChatMessage]` payload are removed. Both consumers — `LiveTranscriptPaneView` and `HistoryPaneView`'s `SessionTranscriptView` — switch to `[TranscriptItem]` and the new shared rendering layer. `appState.sessionTranscripts` becomes `[String: [TranscriptItem]]` (still keyed by sessionID).

`session.messages` (used by the History pane's archive view) gets the same payload upgrade. The existing `terminal.conversation` RPC (used by activity-tracking notifications, returns last-N `[ConversationMessage]`) keeps its current shape — different purpose, shouldn't be coupled.

No DB migration; no on-disk format changes. Daemon and shared code change requires `scripts/restart.sh` (full restart) per `Sources/TBDDaemon/CLAUDE.md`.

### Performance

Structured payload is roughly 2–3× the wire size of today's `[ChatMessage]`. For a typical session (~200 messages, mostly short prose with occasional tool calls), well under 1 MB. Polling at 1.5 s still triggers a re-fetch + diff; the count + per-item id equality check catches the no-change case and skips the @Published write. Body truncation in the parser keeps tool-heavy sessions cheap.

If a single session ever becomes large enough to make polling expensive, the upgrade is daemon-side push (file-watch + delta) — out of scope, but the data shape doesn't preclude it.

## Files affected

- `Sources/TBDShared/Models.swift` — add `TranscriptItem`, `ToolResult`, `SystemKind`; remove `ChatMessage` (and `ChatRole`).
- `Sources/TBDShared/RPCProtocol.swift` — `TerminalTranscriptResult.messages: [ChatMessage]` → `[TranscriptItem]`. `SessionMessages` result type the same. Add `terminal.transcriptItemFullBody` method, params, result.
- `Sources/TBDDaemon/Claude/ClaudeSessionScanner.swift` — replace `loadMessages` with a structured parser. New helpers for content-block iteration, tool_use/tool_result correlation, system-marker classification, body truncation, subagent file resolution + recursive parse with cycle detection.
- `Sources/TBDDaemon/Claude/UserMessageClassifier.swift` — extend to return `SystemKind` for matched markers, with a generic-injection fallback for unknown `<tag>` prefixes.
- `Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift` — `handleTerminalTranscript` returns the new payload. New `handleTerminalTranscriptItemFullBody`.
- `Sources/TBDDaemon/Server/RPCRouter+SessionHandlers.swift` — `handleSessionMessages` returns `[TranscriptItem]`.
- `Sources/TBDDaemon/Server/RPCRouter.swift` — register the new RPC route.
- `Sources/TBDApp/DaemonClient.swift` — `terminalTranscript` and `sessionMessages` return types update; new `terminalTranscriptItemFullBody` wrapper.
- `Sources/TBDApp/AppState.swift` — `sessionTranscripts: [String: [ChatMessage]]` → `[String: [TranscriptItem]]`.
- `Sources/TBDApp/AppState+History.swift` — adapt `selectSession` to the new payload type.
- `Sources/TBDApp/Panes/HistoryPaneView.swift` — `ChatMessageView` removed; `TranscriptMessagesView` becomes `TranscriptItemsView` and routes each item through the appropriate view.
- `Sources/TBDApp/Panes/LiveTranscriptPaneView.swift` — switch to `TranscriptItemsView`; polling, autoscroll, error logic unchanged.
- New directory `Sources/TBDApp/Panes/Transcript/`:
  - `TranscriptItemsView.swift` — top-level renderer that maps each item to the right view.
  - `ChatBubbleView.swift` — extracted from current `ChatMessageView`, takes a single user/assistant prose item; renders markdown via the segment splitter and `AttributedString(markdown:)`.
  - `MarkdownSegments.swift` — pure helper that splits a message's text into ordered `.prose` / `.code` segments by triple-backtick fences. Unit-testable.
  - `ActivityRowChrome.swift` — shared header (icon, title, timestamp), expand/collapse toggle, truncation footer.
  - `ReadCard.swift`, `EditCard.swift`, `WriteCard.swift`, `BashCard.swift`, `GrepCard.swift`, `GlobCard.swift` — one curated tool renderer per file.
  - `GenericToolCard.swift` — fallback.
  - `ThinkingRow.swift`, `SystemReminderRow.swift`, `SlashCommandRow.swift` — non-tool activity rows.
  - `SubagentDisclosure.swift` — the "▶ Show N subagent activities" affordance plus the indented expanded body that recursively renders the inner `TranscriptItemsView` with a depth indicator.

`Tests/`:
- `Tests/TBDDaemonTests/ClaudeSessionScannerTests.swift` — extended fixture coverage for tool_use/tool_result pairing, multi-block assistant messages, system marker classification, sidechain skipping, truncation behavior.
- `Tests/TBDDaemonTests/TerminalTranscriptHandlerTests.swift` — adapt existing tests to the new return type; add coverage for the full-body RPC.
- `Tests/TBDSharedTests/TranscriptItemTests.swift` — Codable round-trips for each case.
- `Tests/TBDAppTests/MarkdownSegmentsTests.swift` — fence-splitter coverage: prose only; one fenced block; fenced block with language tag; multiple fenced blocks; unterminated fence; adjacent fences; backticks inside prose (escaping/false-positive avoidance for inline backticks vs block fences — block fences must start at line beginning).

## Testing

Unit:
- Codable round-trip for every `TranscriptItem` case and `ToolResult`.
- Parser: tool_use/tool_result pairing across non-adjacent JSONL lines.
- Parser: in-flight `tool_use` (no matching result) → `.toolCall(result: nil)`.
- Parser: multi-block assistant message → multiple items in order.
- Parser: known system markers (`<system-reminder>`, `<command-…>`, `<environment_details>`) → typed `SystemKind`; unknown `<tag>` prefix → `.other`.
- Parser: body truncation sets `truncatedTo` correctly.
- Parser: subagent correlation — parent Task tool_result with `toolUseResult.agentId` resolves to a `Subagent` carrying recursively-parsed items.
- Parser: subagent meta.json missing or unparseable → `agentType: nil`; non-fatal.
- Parser: subagent JSONL missing → `subagent: nil`; parent card unaffected.
- Parser: recursion-cycle defensive check stops the recursion and surfaces a `.systemReminder(kind: .other)` cycle notice.
- Parser: depth-3 nested subagent (a → b → c) parses end-to-end, items reachable through `subagent.items[*].toolCall.subagent.items[*]`.
- Full-body RPC: returns full text; missing-line case returns the placeholder.

Manual / integration:
- Open a Claude tab with a recent session containing Reads, Edits, and Bash → tool cards render with curated layouts; click headers expand/collapse.
- Trigger an Edit → diff shows red/green hunks.
- Bash with multi-line output → output truncates at 30 lines with `Show full output`; clicking expands.
- An MCP or skill invocation → renders as a generic card.
- A fresh tool call before its result lands → spinner + "Running…"; next poll swaps in the result without reorder.
- History pane and live pane render identically.
- Worktree archived → both panes still display archived sessions in the new format.

## Follow-ups (out of scope for this design)

- **Daemon → app push.** Polling is fine for now; FSEvents-based push would reduce idle work, and would naturally extend to watching subagent files for live-updating nested timelines.
- **Lazy subagent fetch.** v1 ships subagent items eagerly inside the main transcript payload. If real-world sessions get very heavy, a `terminal.subagentTranscript(parentToolUseID)` RPC could fetch on expand instead.
- **Per-card persistent expand state.** Closing the pane resets expansion. Persistence (per session, in `appState`) could be added if users find themselves re-expanding the same cards.
- **Promotion of common generic-rendered tools to curated.** `Task`, `WebFetch`, `TodoWrite` are likely candidates. Note that `Task` already gets the subagent disclosure via the `subagent` field — promoting it to "curated" would mean a tailored header (agent type chip, prompt preview) on top of that.
- **Syntax highlighting for fenced code blocks** in chat bubbles. v1 shows the language tag as a chip but renders content as plain monospace.

## Open questions

None at this time. Implementation plan to follow.
