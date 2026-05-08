# Context Usage Display in Transcript Viewer

## Goal

Show how many tokens the current Claude Code session is carrying, surfaced under the most recent assistant item in the transcript viewer. The number is reference info — diminutive, not primary content — so the user can see "session is getting big" without running `/context`.

Background and the underlying mechanism are documented in `docs/transcript-context-usage.md`. This spec covers only the implementation in TBD.

## Decisions

- **Token count only.** No window/denominator and no percent. The Claude Code transcript JSONL does not carry a context-window value, and we cannot reliably distinguish Opus 4.7's 200K and 1M variants from `message.model` alone (both write `claude-opus-4-7`). Showing a fabricated denominator would be misleading.
- **Format:** `124k tokens` — abbreviated whole-thousands, with the literal word "tokens" appended. No decimal.
- **Color thresholds:**
  - `< 190_000` → muted gray (`.secondary`)
  - `>= 190_000` → yellow
  - `>= 260_000` → orange
  - `>= 300_000` → red
- **Placement:** A single tiny line below the bubble or card of the most recent non-sidechain item that carries usage data. No badges on older items; no per-turn history; no sparkline; no status-bar version.
- **Sidechain handling:** Subagent / sidechain assistant lines (top-level `isSidechain: true`) are skipped when picking "latest." They run in a separate context window, so their usage values are not meaningful to the parent session's display. The parser already drops top-level sidechain lines (`TranscriptParser.parse` line ~126, `if skipSidechain, json["isSidechain"] as? Bool == true { continue }`), so the top-level items array is sidechain-free by construction. Subagent-nested items are reached via recursive `TranscriptItemsView` at `depth > 0` inside `SubagentDisclosure`; we suppress the badge there by gating render on `depth == 0`.
- **Scope:** Both `LiveTranscriptPaneView` (live polled session) and `HistoryPaneView` (static historical view). The single shared rendering path in `TranscriptItemsView` makes this one change.
- **Latest-item rule (A1):** If the most recent assistant turn is tool-only (no text content), the badge attaches to the tool card it produced, not to the previous text bubble. The placement always reflects the most recent API call.

## Architecture

### Data model (`Sources/TBDShared/Models.swift`)

New struct:

```swift
public struct TokenUsage: Codable, Sendable, Equatable {
    public let inputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public var contextTotal: Int {
        inputTokens + cacheCreationTokens + cacheReadTokens
    }
}
```

Extend `TranscriptItem`:

- `.assistantText` and `.toolCall` gain one new field:
  - `usage: TokenUsage?` (nil for items not derived from an assistant API call, or assistant lines that lack a `usage` block defensively)
- This is **optional** so existing serialized `TranscriptItem` values still decode — same compatibility rule the project applies to DB migrations (per `CLAUDE.md` Database section), applied here to the in-memory enum.

No `isSidechain` field is needed: the parser drops top-level sidechain lines, and subagent-nested items are filtered out at render time via the `depth == 0` gate.

### Parser (`Sources/TBDDaemon/Claude/TranscriptParser.swift`)

When processing a JSONL line where `type == "assistant"`:

1. Decode `message.usage` into a `TokenUsage`. Only the three fields we care about are mapped; the rest of the `usage` blob is ignored. Missing or malformed → `nil`.
2. Stamp the `usage` value onto every `.assistantText` and `.toolCall` item produced from that line.

The duplication is intentional and cheap: a single assistant API call can produce one text item plus several tool_use items, and stamping the same `TokenUsage` on each one keeps the model uniform without introducing a separate "metadata index." Total memory cost is bounded by transcript length × ~24 bytes per stamped item.

No changes to `TerminalTranscriptResult` or any RPC shape — usage rides with the existing items array.

### Rendering (`Sources/TBDApp/Panes/Transcript/`)

New file: `ContextUsageBadge.swift`

```swift
struct ContextUsageBadge: View {
    let total: Int
    var body: some View {
        Text("\(total / 1000)k tokens")
            .font(.caption2)
            .foregroundStyle(color(for: total))
    }

    private func color(for total: Int) -> Color {
        switch total {
        case ..<190_000:  return .secondary
        case ..<260_000:  return .yellow
        case ..<300_000:  return .orange
        default:          return .red
        }
    }
}
```

`TranscriptItemsView` changes:

- The badge is only rendered when `depth == 0` (top-level transcript). Subagent-nested rendering at `depth > 0` skips the latest-usage walk entirely, so subagent context never shows a badge.
- At the top of the `depth == 0` branch, compute `let latestUsageItemID: String? = items.reversed().first { $0.usage != nil }?.id`. This walk is over the data array, not the materialized views, so it is unaffected by `LazyVStack`. The walk is O(n) per body evaluation, which is fine for a few hundred items at the 1.5s polling cadence.
- In the per-item `ForEach`, after the existing item view (`ChatBubbleView`, `BashCard`, `ReadCard`, `EditCard`, `WriteCard`, `GrepCard`, `GlobCard`, `GenericToolCard`, `AgentCard`), conditionally render the badge:
  ```swift
  if item.id == latestUsageItemID, let usage = item.usage {
      ContextUsageBadge(total: usage.contextTotal)
          .padding(.leading, /* match bubble/card leading inset */)
  }
  ```
- The badge is leading-aligned and indented to the bubble/card's leading edge so it visually reads as a tail of the item rather than a floating element. Exact inset matches whatever the existing item view uses (likely a shared constant in `TranscriptItemsView` or `ChatBubbleView`).

`LiveTranscriptPaneView` and `HistoryPaneView` both delegate transcript rendering to `TranscriptItemsView`, so they pick up the badge with no further changes.

### Lazy-stack interaction

`TranscriptItemsView` uses `LazyVStack`. When a new assistant turn arrives:

1. The polled `[TranscriptItem]` updates.
2. `body` re-evaluates → `latestUsageItemID` recomputes.
3. On-screen items re-evaluate naturally; the previously-latest item (if visible) drops its badge, the new latest item shows one.
4. Off-screen items don't re-evaluate, but when they later scroll back into view they instantiate against the current `latestUsageItemID` and correctly do not render the badge.

The badge changes the latest item's height. With the existing scroll-to-bottom behavior, this should follow naturally if the user is anchored to bottom; if they are scrolled up reading, the change happens to an off-screen item and does not move the viewport. Worth confirming once during manual verification, not designing around.

## Testing

### Parser unit tests (`Tests/TBDDaemonTests/TranscriptParserTests.swift`)

- Assistant line with a `usage` block produces items whose `usage` is populated with the correct field values.
- Assistant line with no `usage` (defensive) produces items with `usage == nil`.
- A top-level assistant line with `isSidechain: true` produces no items at all (existing parser drop behavior — covered by an explicit test to lock it in as a regression guard for the badge logic).

These cover each branch of the parser's gating logic per the `CLAUDE.md` rule on testing branching conditionals.

### Helper unit tests

If an app-level test target exists, test `ContextUsageBadge`'s formatting and color logic:

- `formatted(0)` → `"0k tokens"`, `formatted(999)` → `"0k tokens"`, `formatted(124_300)` → `"124k tokens"`, `formatted(1_500_000)` → `"1500k tokens"`.
- `color(for:)` boundary cases: 0, 189_999, 190_000, 259_999, 260_000, 299_999, 300_000.

If no app-level test target exists in TBDApp, drop these — the formatting and color logic is too small to justify standing one up, and manual verification covers it.

### Manual verification

After `scripts/restart.sh`:

1. Open a worktree with an active long Claude Code session. Confirm the badge appears under the last non-sidechain item (whether bubble or tool card).
2. Verify color transitions. If a real high-token session is unavailable, temporarily lower the thresholds in `ContextUsageBadge` and reload to confirm yellow/orange/red render correctly.
3. Trigger a sidechain (subagent) call and confirm the badge stays on the parent session's last main-thread item — does not jump to the subagent.
4. Open `HistoryPaneView` for a past session and confirm the badge renders identically there.
5. Confirm scroll anchoring: when scrolled to the bottom, new turns + their badges keep the bottom in view; when scrolled up, new turns do not jerk the viewport.

## Out of scope

- Window/denominator display, percent display.
- Per-turn sparklines or any historical visualization of context growth.
- Hooks consuming this data (covered separately in `docs/transcript-context-usage.md`).
- Subagent context display in subagent disclosure cards. If we want to surface a subagent's own usage in the future, that's a follow-up.
- Auto-compact warnings / notifications (would be a separate hook-driven feature).
