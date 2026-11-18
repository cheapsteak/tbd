# Transcript prompt rail

## Problem

A long Claude session buries its own structure. The prompts the user typed are the chapter breaks of the conversation, but in the transcript pane they sit between screens of assistant prose and tool activity. Finding "where I asked about X" means scrolling and reading. Nothing on screen says how far into the session the reader is, or how many prompts came before.

Document and chat viewers solve this with an outline rail. Claude desktop's markdown viewer shows a narrow column of short dashes at the left edge, one per heading, with the current heading's dash accented. Hovering the column opens a card listing every heading, and clicking one jumps to it. Claude Code's own session view uses the same pattern, one tick per chapter. Codex desktop's transcript viewer offers a similar affordance.

## Decision

Every transcript pane gets a **prompt rail**: a 20pt column at its leading edge with one notch per prompt, each notch as long as its turn was busy, the current prompt's notch accented. Hovering the rail magnifies the notches near the pointer into readable rows of first line and time ([`2026-11-18-prompt-rail-lens-design.md`](2026-11-18-prompt-rail-lens-design.md)); clicking one jumps the transcript to it. ⌥⌘↑ and ⌥⌘↓ jump to the previous and next prompt.

- **It appears in all three transcript surfaces**: the live pane, Session History and the Remote pane. All three render through `TableTranscriptView`, so the rail is built once.
- **It is always on, with no setting.** It acts on nothing by itself, so the default-off flag rule does not apply.
- **It is built in AppKit, inside the table's own view.** The transcript is an AppKit table, and the rail sits beside its scroll view in the view `TableTranscriptView` hands SwiftUI.
- **It lives entirely in TBDApp.** There is no daemon, RPC, schema or durable-resource change.

## Prior art: Claude desktop's rail

These parameters describe the rail in Claude desktop's Code-tab file viewer. The design below adopts most of them.

- **Ticks** – one per heading, stacked at a fixed 8px pitch rather than placed by scroll position. A dash is 14px wide and 2px tall at the top level; the active heading's dash is 18px wide, 3px tall and accent-colored. When the ticks overflow, the rail scrolls itself to keep the active tick in view with a 40px margin, behind fade masks.
- **Active heading** – the last heading whose top is above a probe line 20% down the viewport; the first heading at the very top; the last heading within 8px of the bottom. After a jump, the target stays active until it moves.
- **Card** – opens 80ms after the pointer enters the ticks, fading in over 150ms. It is anchored so its dashes sit exactly over the rail's ticks. Rows are 22px tall with 13px text, truncated to one line. When the list is longer than the card, the row for the hovered tick is scrolled to sit under the pointer.
- **Jump** – instant, with the heading placed 16px below the top of the viewport.

## What gets a notch

A pure builder, `PromptOutline`, turns the table's render nodes into rail entries. Each entry carries the node ID, a kind (prompt or peer, with the peer's sender), a first line and a timestamp. The builder reads only node data and never touches a table cell.

- **Typed prompts** – every `.userPrompt` node, including prompts queued mid-turn.
- **Slash commands** – the parser already flattens these into a `.userPrompt` reading `/name args`, so they get a notch with no special case.
- **Peer messages** – every `.peerMessage` node. Another session sent it, not the user, but it steers the session the way a prompt does.

Three kinds of `.userPrompt` node were not typed by anyone and get no notch:

- **Image bookkeeping lines** – the follow-up `isMeta` line whose text is only `[Image: source: …]` markers. The image already belongs to the prompt above it.
- **Interrupt markers** – `[Request interrupted by user]` and `[Request interrupted by user for tool use]`.
- **Compaction summaries** – the continuation message that begins "This session is being continued from a previous conversation".

The parsed items do not carry the JSONL's `isMeta` or `isCompactSummary` flags, so these are recognised by their text. The test lives in `UserMessageClassifier`, which is already the single home for user-message heuristics, as a new function that only the rail calls. What the transcript itself renders does not change. This reads the transcript JSONL, a machine interface, so the rule against screen-scraping does not apply.

The rail describes whatever rows the table holds. In a drilled-in subagent thread it lists that thread's prompts.

**First line.** The prompt body goes through `TranscriptPastedContent.unwrap`, the same unwrapping its bubble uses, so the line reads as the bubble does. The first non-empty line follows, with runs of whitespace collapsed. Inline `[Image #N]` placeholders stay, so an image-only prompt reads `[Image #1]`.

**Time.** Today's prompts each show their short local time (`14:02`). An earlier day's prompts are listed in order, so only the first of each day shows its abbreviated date (`Oct 24`) and the rest of that day's rows leave the column blank — the date would only repeat. Both use the user's locale. A node without a timestamp shows nothing and does not start a new day; the next prompt with a timestamp is compared with the last one that had one. VoiceOver labels keep each prompt's own date or time, since a listener hears one row at a time.

**Peers.** A peer notch is drawn in `PeerLavender`, the tint the peer bubble already uses. Its readable row reads "*sender*: first line" with the sender in lavender.

## The rail

### Length: work done

A notch's length shows how much work its turn did, so the rail reads as a profile of the session: short notches for quick answers, long ones for turns where Claude read, edited and ran a lot.

- **A turn** runs from an entry's row up to the next entry's row, or to the end of the transcript. A peer message starts a turn just as a prompt does.
- **Work** is the number of tool calls the session made in the turn's rows:
  - each standalone tool-call row counts one;
  - a collapsed activity group counts the tool calls among its members, which `ActivityGroupSummary` reports for the purpose — its existing `itemCount` counts every grouped row, not just tool calls;
  - launching a subagent is one tool call. The steps the subagent takes are recorded in its own transcript file, which the transcript pane does not read, so they do not count.

  Tool calls the transcript already hides as bookkeeping (`TodoWrite`, `TaskUpdate`, `TaskCreate`, `Skill`) are not rows, so they do not count.
- **Scale** – relative to the session's busiest turn, on a log scale: length = 4 + 12 × log(1 + n) / log(1 + busiest) points, so a turn with no tool calls is 4pt and the busiest turn so far is 16pt. When a busier turn arrives, every notch rescales.
- **Live** – the last turn's notch grows while Claude works. Counting is an integer pass over the rows, with no text read, so the coordinator redoes it on every update, including tail re-renders, and tells the rail only when a count changes. The cached first-line projection is untouched by it.

The count reads node data only, like the rest of the outline.

### Geometry

- **Gutter** – a fixed 20pt column on the leading edge of the transcript area, running from the top of the table to the top of the composer. It exists from the moment the table is created, with zero prompts as with two hundred, so the table's width never changes on its account.
- **Notches** – stacked from 12pt below the top of the rail, leaving 12pt free at the bottom. The pitch is the free height divided by the prompt count, at most 8pt for a mid-length session and at least 4pt, below which the rail windows. A short session spreads its notches wider than 8pt, up to the height the lens needs, so the column is tall enough for the lens to open without moving either end. The exact rule is in "The resting rail" in the lens spec.
  - Every notch starts 2pt from the rail's leading edge and is as long as its turn's work (4–16pt).
  - An inactive notch is 2pt tall in the tertiary label color.
  - The active notch keeps its length and is marked by thickness and color instead: 3pt tall in the accent color.
  - A peer notch is lavender at reduced opacity, and full lavender at 3pt tall when active.
- **Overflow** – at the 4pt floor a 600pt rail holds 144 notches. Past that, the rail offsets its notches to keep the active one 40pt from either end where the offset can reach that: it never scrolls past the first or last notch, so an active notch near either end of the session sits closer to the rail's end. The rail fades the clipped edges over 24pt. The rail never scrolls under the wheel: a wheel over it scrolls the transcript, so the gutter is no dead zone, and the lens is where the whole list is browsed.

### The active prompt

- It is the last entry whose row top lies above a probe line 20% down the viewport.
- Within 8pt of the bottom, the last entry is active. A prompt just sent sits low on screen, and the reader is reading its exchange.
- When no entry lies above the probe line, the first entry is active.
- After a jump, the target stays active until the reader scrolls or a new prompt arrives. This covers prompts near the end, which cannot be scrolled to the top. The coordinator's own tail-follow is not a reader scroll: it ends the jump's pin, since the two would fight, but leaves the target active.
- With no entries, the rail is empty and nothing is active.

A reader scroll, here and under Jumping, is any move of the clip view's origin that neither the coordinator nor the table's own layout made. A change to the clip's size that leaves the origin where it was is not one. When row heights change, NSTableView's layout pass keeps its own choice of visible row in place by moving the clip; that move is AppKit's, and at the end of the pass the coordinator puts any held anchor back where it belongs. AppKit's row-height estimation, which would also move the origin as it swapped its guesses for real heights, is turned off for the whole process at launch. The one remaining origin move made by neither the reader nor the coordinator is the clip clamping to a document that got shorter, and that rare case counts as the reader's.

The coordinator recomputes the active entry on the clip view's bounds notification, which it already observes. A binary search over the entries' row rectangles finds it, and `rect(ofRow:)` builds no cells. The rail is told only when the active entry changes. Content streaming in at the bottom grows the document before the coordinator's tail-follow catches up with it on the next main-queue turn; the active entry is not recomputed in between, so the bottom rule does not lapse for that turn and hand the last prompt's notch to the one before it.

## Hovering

Hovering the rail magnifies it: the notch under the pointer grows into a readable row of its first line and time, rows near it grow part way, and far notches stay notches. A rounded box behind the readable rows keeps them legible over the transcript, which the gutter never widens to make room for. A click on a row jumps to its prompt. The lens, its layout, its motion and its dismissal rules are specified in [`2026-11-18-prompt-rail-lens-design.md`](2026-11-18-prompt-rail-lens-design.md).

## Jumping

`TableTranscriptView.Coordinator.jump(toNodeID:)` serves the lens, the keyboard commands and VoiceOver.

- **Placement** – it scrolls the clip at once, unanimated, so the target row's top sits 16pt below the top of the viewport, clamped to the scrollable range.
- **Pinning** – a row far from the bottom has only an estimated height until it is laid out. When rows near the target realize and correct their heights, the target would drift: a correction moves every row below it, and the table's layout keeps its own choice of visible row in place, not the target. The jump therefore holds the target as an anchor and re-pins it whenever a row above it changes height and at the end of each table layout pass. This is the mechanism the prepend path already uses for its anchor, generalised to hold a jump target as well.
  - The anchor is released when the reader scrolls, the table rebuilds, the column width changes, history is prepended, or another jump starts.
  - It survives appends and tail re-renders, which add or change rows below it and cannot move it.
- **Unknown IDs** – an ID with no row is ignored. `scrollToRow(withNodeID:)`'s fallback to the end is right for the composer hint that uses it, and wrong here.
- **Follow-tail** – a jump away from the bottom ends tail-following, as a manual scroll does, including a tail-follow already queued for content that arrived just before the jump. A jump that lands at the bottom leaves it on.
- **Remote** – a jump to the earliest loaded prompt lands near the top and so triggers the ordinary page load. The existing prepend anchor holds the reader's place, as it does when they scroll there by hand.

## Keyboard

The Go menu gains **Previous Prompt** (⌥⌘↑) and **Next Prompt** (⌥⌘↓).

- **Previous** jumps to the active prompt itself when the reader is inside its exchange, more than 16pt below its top; otherwise to the prompt before it. From the top of the first prompt it does nothing.
- **Next** jumps to the prompt after the active one. From the last prompt it scrolls to the end of the transcript.
- **Scope** – the commands act on the transcript pane whose table or composer is first responder. The table is found by walking up the view hierarchy from the first responder; a composer leads to its table through `AppState`'s existing composer and transcript focus registries, which the Remote pane joins. SwiftUI menu commands cannot observe the first responder, so the items stay enabled and do nothing when no such pane is focused. A view that claims ⌥⌘↑ or ⌥⌘↓ as its own key equivalent, as a terminal's natural text editing may, still receives it first, because AppKit offers a key equivalent to the key window's views before the menu bar.

## Lazy rendering

The transcript stays fast because it is lazy in three ways: the table builds cells only for visible rows, only the bottom 40 rows are measured up front while the rest carry estimates until they are laid out, and the Remote pane loads history in pages. The rail must preserve all three. These rules are requirements:

1. **The rail reads node data only.** Nothing measures or builds a cell to draw it.
2. **The gutter is fixed and present from creation.** Any change to the table's column width discards every cached height, re-measures the bottom window and reloads the table.
3. **Jumps pin; nothing pre-measures.** No pass measures the rows above a jump target. On a long transcript, measuring every row exactly took about 4 seconds where measuring the bottom window takes about 40ms.
4. **The rail never loads pages.**

## Structure

### Logic

Everything with logic in it is kept out of the views. It lives under `Sources/TBDApp/Panes/Transcript/PromptRail/`, except the coordinator additions, which extend the coordinator in `TableTranscriptView+PromptRail.swift`:

- **`PromptOutline`** – nodes in, entries and each turn's work count out.
- **`PromptRailLayout`** – pitch, notch rectangles and the overflow offset for a given count, rail height and active index.
- **`PromptRailWorkScale`** – work counts in, notch lengths out, scaled to the busiest turn.
- **`PromptRailActiveRule`** – the active-entry rule, given entry row rectangles, the viewport and the held jump target.
- **`PromptRailHoverModel`** – the open delay, close grace, Escape and click suppression, and the deactivation close. It takes `clock: any Clock<Duration> = ContinuousClock()` as its last initializer parameter.
- **Coordinator additions** – rebuilding the outline when the nodes change, tracking the active entry, `jump(toNodeID:)` and the jump anchor. The coordinator reports to a `PromptRailPresenter` – entries changed, work counts changed, active entry changed. The rail view is the presenter; the protocol lets the coordinator be tested without the views.
- **Keyboard commands** – the Go menu items and the pane registry.

### Views

`TableTranscriptView`'s view is a container `NSView`, `TranscriptContainerView`, holding the scroll view right of the 20pt gutter and the rail stacked above it. The rail view lives under `PromptRail/AppKit/`.

- **Rail** – `PromptRailNSView` is the presenter, so an active-entry change goes straight from the coordinator to the rail. It hands wheel events to the scroll view. Its drawing, hover tracking and lens are specified in the lens spec.
- **Wiring** – the container runs the Escape monitor only while the lens is on screen (open, with at least one prompt), and closes the lens when the container leaves its window or the window resigns key. The monitor is app-wide, so a lens left open in a background window would take Escape from every view in the key one.
- **Stacking** – settled by AppKit subview order: the scroll view, then the rail.

**Mounting.** The table's `promptRail` parameter says whether to build the views. The three call sites mount the rail on the table directly. A harness that drives the table alone mounts nothing and gets no gutter. Because the views live inside the table's view, a pane's `.id` that rebuilds the table, as on session rollover, rebuilds the rail with it. A pane's overlays span the gutter too, so the live pane insets its bottom-leading jump-to-bottom button by the gutter's width to keep it clear of the rail.

## Accessibility

The rail is an accessibility group labelled "Prompts", with one button per entry labelled with its first line, time and tool-call count ("fix the rail, 14:02, 40 tool calls"). Activating a button jumps to that prompt. The rail view exposes each button as an accessibility element over the band of the rail its notch owns.

## Testing

- **Pure logic**
  - `PromptOutline`: each kind of entry, each of the three skipped lines, first-line extraction through unwrapping and whitespace collapsing, and peer senders.
  - The new `UserMessageClassifier` function, against the three marker forms and against prompts that merely mention them.
  - `PromptRailLayout`: the pitch at both clamps and between them, and the overflow offset near both ends.
  - `PromptRailActiveRule`: the probe line, the bottom rule, the no-entry-above rule and the held jump target.
  - Time formatting for today, earlier days and a missing timestamp, and the time column's day boundaries: every row of today shows its time, only the first row of an earlier day shows its date, and a row without a timestamp neither shows one nor starts a day.
  - Work counts: standalone tool calls, a collapsed group's tool calls, an expanded group counted once, a peer-started turn, the last turn running to the end, hidden bookkeeping tools absent; and the length mapping at zero, at the busiest turn, and when a busier turn rescales the rest.
- **Hover model** – against `EventDrivenTestClock`: the 80ms open, the 100ms grace, re-arming after Escape and after a click, and closing on app deactivation.
- **Coordinator, offscreen** – in `TableTranscriptHarness`:
  - the active entry follows a scroll;
  - a jump to a far row with an estimated height keeps the target within 1pt of its placement once nearby rows realize;
  - a reader scroll releases the jump anchor, and an append does not;
  - an unknown ID leaves the scroll position alone;
  - building the outline realizes no cells, which checks the first lazy-rendering rule;
  - a turn's count grows as tool calls arrive, whether appended or as a tail re-render, and the rail hears only actual changes.
- **Keyboard** – previous and next from the middle, from inside an exchange, from the first prompt and from the last.
- **Views, offscreen** – notch geometry and colours, the overflow offset and fade, the wheel handed to the transcript and the accessibility buttons. The lens's own tests are listed in the lens spec.
- **Mounting, offscreen** – a pane-shaped mount keeps the gutter inside the table's view and makes the rail the presenter; a new pane identity rebuilds the rail; a table with no mount has no rail or gutter.

## Out of scope

- A highlight flash on the target prompt after a jump.
- Wheel-scrolling the rail.
- Renaming, hiding or grouping prompts.
- A complete prompt index for the Remote pane before its history has loaded, which would need a new RPC.
- Counting a subagent's own steps toward its turn's work, which would mean reading each subagent's transcript file alongside the session's.

## Rejected alternatives

- **A prompt list in the Session index** – `SessionWorkbenchView` already shows a trailing index on panes 980pt wide or more. A Prompts section there costs little but gives no rail, nothing on narrower panes, and entries that open overlay cards instead of scrolling.
- **Notches placed by scroll position** – scrollbar-marker placement shows where long turns are, but neighbouring prompts merge into one mark.
- **A windowed rail** – showing only the prompts around the current one keeps a comfortable pitch, but the rail then stops showing how far into the session the reader is.
- **Measuring rows above a jump target** – it would make jumps exact on the first try, at the cost of the estimated heights that make long transcripts open instantly.
- **A SwiftUI rail beside the table** – a SwiftUI rail in an `HStack` beside `TableTranscriptView`, with the lens as a SwiftUI overlay, works against the framework at each point the rail depends on.
  - SwiftUI hover follows hit-testing, so once the open lens's box covers the rail, the rail hears the pointer leave and Escape and click suppression lapse with the pointer still on it. Hover has to be recomputed from the rail column's geometry by a handler on the whole pane.
  - The pane must not observe the rail's state: a pane that re-renders on every active-prompt change reruns `updateNSView`, and with it a whole-transcript comparison, in the middle of a scroll. Keeping it out takes a state object only the rail reads, with writes deferred to the next main-queue turn because the coordinator reports from inside `updateNSView`, and a separate pointer object so that a pointer moving over the rail re-renders nothing.
  - SwiftUI has no public way to forward a wheel event to the table's scroll view, so the gutter becomes a dead zone for scrolling.
  - The transcript is already AppKit. Views inside its hierarchy share its layout, stacking and event routing with no bridge between frameworks.
- **A show/hide preference** – the rail acts on nothing by itself, and each preference is another layout to test.
- **Other meanings for notch length** – time taken, context-window fill and reply size each fit the length channel. Time counts waits on the reader's answers and permission prompts as work. Context fill is cumulative, so it says more about the session than the turn, and needs the model's window size. Reply size ignores the tool activity that makes up most of a coding turn. Tool calls track what the reader means by "a big turn" most directly.
- **A fixed scale for notch length** – fixed thresholds or a fixed ceiling keep a notch's length comparable across sessions and stable after its turn ends, but a quiet session then uses only the short end and a busy one saturates at the ceiling. Scaling to the session's busiest turn always uses the whole range.
