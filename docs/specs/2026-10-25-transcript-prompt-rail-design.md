# Transcript prompt rail

## Problem

A long Claude session buries its own structure. The prompts the user typed are the chapter breaks of the conversation, but in the transcript pane they sit between screens of assistant prose and tool activity. Finding "where I asked about X" means scrolling and reading. Nothing on screen says how far into the session the reader is, or how many prompts came before.

Document and chat viewers solve this with an outline rail. Claude desktop's markdown viewer shows a narrow column of short dashes at the left edge, one per heading, with the current heading's dash accented. Hovering the column opens a card listing every heading, and clicking one jumps to it. Claude Code's own session view uses the same pattern, one tick per chapter. Codex desktop's transcript viewer offers a similar affordance.

## Decision

Every transcript pane gets a **prompt rail**: a 20pt column at its leading edge with one notch per prompt, the current prompt's notch accented. Hovering the rail opens a card listing the prompts by first line and time; clicking one jumps the transcript to it. ⌥⌘↑ and ⌥⌘↓ jump to the previous and next prompt.

- **It appears in all three transcript surfaces**: the live pane, Session History and the Remote pane. All three render through `TableTranscriptView`, so the rail is built once.
- **It is always on, with no setting.** It acts on nothing by itself, so the default-off flag rule does not apply.
- **It ships in two renderers behind a temporary switch** so the two can be compared in a running build: an AppKit rail inside the table's view hierarchy, and a SwiftUI rail beside it. Everything except the view layer is shared. Once one is chosen, a follow-up deletes the other and the switch.
- **It lives entirely in TBDApp.** There is no daemon, RPC, schema or durable-resource change.

## Prior art: Claude desktop's rail

These parameters were read from the shipped claude.ai web bundle that renders Claude desktop's Code-tab file viewer. The design below adopts most of them.

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

**Time.** Today's prompts show the short local time (`14:02`); earlier ones show the abbreviated date (`Oct 24`). Both use the user's locale. A node without a timestamp shows none.

**Peers.** A peer notch is drawn in `AttentionAmber`, the tint the peer bubble already uses. Its card row reads "*sender*: first line" with the sender in amber.

## The rail

### Geometry

- **Gutter** – a fixed 20pt column on the leading edge of the transcript area, running from the top of the table to the top of the composer. It exists from the moment the table is created, with zero prompts as with two hundred, so the table's width never changes on its account.
- **Notches** – stacked from 12pt below the top of the rail, leaving 12pt free at the bottom. The pitch is the free height divided by the prompt count, clamped between 4pt and 8pt.
  - An inactive notch is a 14×2pt dash in the tertiary label color, 2pt from the rail's leading edge.
  - The active notch is 18×3pt in the accent color.
  - A peer notch is amber at reduced opacity, and full amber at 18×3pt when active.
- **Overflow** – at the 4pt floor a 600pt rail holds 144 notches. Past that, the rail offsets its notches to keep the active one at least 40pt from either end, and fades the clipped edges over 24pt. The rail never scrolls under the wheel; the card is where the whole list is browsed.

### The active prompt

- It is the last entry whose row top lies above a probe line 20% down the viewport.
- Within 8pt of the bottom, the last entry is active. A prompt just sent sits low on screen, and the reader is reading its exchange.
- When no entry lies above the probe line, the first entry is active.
- After a jump, the target stays active until the reader scrolls or a new prompt arrives. This covers prompts near the end, which cannot be scrolled to the top. The coordinator's own tail-follow is not a reader scroll: it ends the jump's pin, since the two would fight, but leaves the target active.
- With no entries, the rail is empty and nothing is active.

A reader scroll, here and under Jumping, is any change to the clip view's bounds that the coordinator did not make itself.

The coordinator recomputes the active entry on the clip view's bounds notification, which it already observes. A binary search over the entries' row rectangles finds it, and `rect(ofRow:)` builds no cells. The rail is told only when the active entry changes.

## The card

- **Opening** – 80ms after the pointer enters the rail, the card fades in over 150ms, easing out.
- **Closing** – 100ms after the pointer leaves both rail and card, so a jittery pointer does not snap it shut. Escape, a click on a row and app deactivation close it at once; hover alone cannot be the only dismissal, because a backgrounded app receives no pointer-exit event. After Escape or a click, hovering does not reopen it until the pointer has left the rail.
- **Placement** – anchored at the rail's top-left, its dash column lined up over the rail's notches. It is 320pt wide, capped at the pane's width minus 24pt, and at most as tall as the rail. A longer list scrolls inside the card behind 24pt edge fades. On opening, the list is scrolled so the row for the notch under the pointer sits under the pointer, or as close as the list's ends allow.
- **Rows** – 22pt tall, 13pt system text: an 18pt dash column, an 8pt gap, the first line truncated at the tail, and the time right-aligned in the secondary label color with monospaced digits.
  - The active row is medium weight, with its accent or amber dash.
  - The row under the pointer gets a quaternary-fill background with a 6pt corner radius.
  - A truncated row shows the prompt's first 500 characters as a tooltip.
- **Click** – jumps to the prompt and closes the card.
- **Remote, older history not loaded** – the card's first row reads "Earlier prompts not loaded" in the secondary color, with a Load button that calls the pane's existing load-earlier action, the one the "Load earlier messages" header button calls. The rail never loads history by itself.

## Jumping

`TableTranscriptView.Coordinator.jump(toNodeID:)` serves the card, the keyboard commands and VoiceOver in both renderers.

- **Placement** – it scrolls the clip at once, unanimated, so the target row's top sits 16pt below the top of the viewport, clamped to the scrollable range.
- **Pinning** – a row far from the bottom has only an estimated height until it is laid out. When rows near the target realize and correct their heights, the target would drift, because corrections carry no scroll compensation. The jump therefore holds the target as an anchor and re-pins it whenever a row above it changes height. This is the mechanism the prepend path already uses for its anchor, generalised to hold a jump target as well.
  - The anchor is released when the reader scrolls, the table rebuilds, the column width changes, history is prepended, or another jump starts.
  - It survives appends and tail re-renders, which add or change rows below it and cannot move it.
- **Unknown IDs** – an ID with no row is ignored. `scrollToRow(withNodeID:)`'s fallback to the end is right for the composer hint that uses it, and wrong here.
- **Follow-tail** – a jump away from the bottom ends tail-following, as a manual scroll does. A jump that lands at the bottom leaves it on.
- **Remote** – a jump to the earliest loaded prompt lands near the top and so triggers the ordinary page load. The existing prepend anchor holds the reader's place, as it does when they scroll there by hand.

## Keyboard

The Go menu gains **Previous Prompt** (⌥⌘↑) and **Next Prompt** (⌥⌘↓).

- **Previous** jumps to the active prompt itself when the reader is inside its exchange, more than 16pt below its top; otherwise to the prompt before it. From the top of the first prompt it does nothing.
- **Next** jumps to the prompt after the active one. From the last prompt it scrolls to the end of the transcript.
- **Scope** – the commands act on the transcript pane whose table or composer is first responder. The table is found by walking up the view hierarchy from the first responder; a composer leads to its table through `AppState`'s existing composer and transcript focus registries, which the Remote pane joins. SwiftUI menu commands cannot observe the first responder, so the items stay enabled and do nothing when no such pane is focused. A view that claims ⌥⌘↑ or ⌥⌘↓ as its own key equivalent, as a terminal's natural text editing may, still receives it first, because AppKit offers a key equivalent to the key window's views before the menu bar.

## Lazy rendering

The transcript stays fast because it is lazy in three ways: the table builds cells only for visible rows, only the bottom 40 rows are measured up front while the rest carry estimates until they are laid out, and the Remote pane loads history in pages. The rail must preserve all three. These rules are requirements:

1. **The rail and the card read node data only.** Nothing measures or builds a cell to draw them.
2. **The gutter is fixed and present from creation.** Any change to the table's column width discards every cached height, re-measures the bottom window and reloads the table.
3. **Jumps pin; nothing pre-measures.** No pass measures the rows above a jump target. On a long transcript, measuring every row exactly took about 4 seconds where measuring the bottom window takes about 40ms.
4. **The rail never loads pages.** Only the card's Load row does.

## Two renderers, one switch

### Shared core

Everything with logic in it is written once, under `Sources/TBDApp/Panes/Transcript/PromptRail/`:

- **`PromptOutline`** – nodes in, entries out.
- **`PromptRailLayout`** – pitch, notch rectangles and the overflow offset for a given count, rail height and active index.
- **`PromptRailActiveRule`** – the active-entry rule, given entry row rectangles, the viewport and the held jump target.
- **`PromptRailHoverModel`** – the open delay, close grace, Escape and click suppression, and the deactivation close. It takes `clock: any Clock<Duration> = ContinuousClock()` as its last initializer parameter.
- **Coordinator additions** – rebuilding the outline when the nodes change, tracking the active entry, `jump(toNodeID:)` and the jump anchor. The coordinator reports to a `PromptRailPresenter` – entries changed, active entry changed – and each renderer supplies its own presenter.
- **Keyboard commands** – the Go menu items and the pane registry.

`TableTranscriptView`'s view becomes a container `NSView` holding the scroll view, under both renderers. The three call sites each change once, to pass the renderer choice and, for Remote, the earlier-history state and load action.

### AppKit renderer

The container also holds the rail, an `NSView` in the 20pt gutter that draws its notches as layers, and the card, an `NSView` subview stacked above both. The presenter is the rail view itself, so an active-entry change goes straight from the coordinator to a layer update. Hover is an `NSTrackingArea` feeding the hover model. Stacking order is settled by AppKit subview order.

### SwiftUI renderer

The rail is a SwiftUI view in an `HStack` beside `TableTranscriptView`, and the card is a SwiftUI overlay. The presenter writes into an `@Observable` `PromptRailState` that only the rail and card read. The pane body must not read it: a pane that re-renders on every active-prompt change would rerun `updateNSView`, and with it a whole-transcript comparison, in the middle of a scroll. Hover is `.onHover` feeding the same hover model.

The card scrolls its list in a `ScrollView`. It lives outside the transcript's row list and is never measured as a row, so its file is added to the `excluded:` list of the `no_scrollview_in_transcript_cards` SwiftLint rule with a one-line comment saying so.

### The switch

- **Key** – the UserDefaults key `promptRailRenderer`, values `appkit` and `swiftui`, default `appkit`. It is declared as an `AppState` static with a default constant, as the other app-only keys are.
- **UI** – a "Prompt rail renderer" picker in Settings → Experimental.
- **Effect** – the renderer is part of the transcript view's identity, so a change rebuilds open transcript panes. A rebuilt pane opens at the bottom, as any freshly opened transcript does.

### Choosing

Compare the two in a running build on long sessions, a hundred prompts or more:

- **Scroll smoothness** while the active notch changes during a fast scroll or a trackpad fling.
- **Hover feel** – does the card open and close promptly, and does it ever flicker?
- **Stacking** – does the card ever paint beneath the table, or the table over the rail?
- **Code** – which renderer is smaller and simpler to change.

The follow-up that records the choice deletes the losing renderer, the key, the picker and the renderer parameter.

## Accessibility

The rail is an accessibility group labelled "Prompts", with one button per entry labelled with its first line and time. Activating a button jumps to that prompt. Each renderer provides this through its own framework.

## Testing

- **Pure logic**
  - `PromptOutline`: each kind of entry, each of the three skipped lines, first-line extraction through unwrapping and whitespace collapsing, and peer senders.
  - The new `UserMessageClassifier` function, against the three marker forms and against prompts that merely mention them.
  - `PromptRailLayout`: the pitch at both clamps and between them, and the overflow offset near both ends.
  - `PromptRailActiveRule`: the probe line, the bottom rule, the no-entry-above rule and the held jump target.
  - Time formatting for today, earlier days and a missing timestamp.
- **Hover model** – against `EventDrivenTestClock`: the 80ms open, the 100ms grace, re-arming after Escape and after a click, and closing on app deactivation.
- **Coordinator, offscreen** – in `TableTranscriptHarness`:
  - the active entry follows a scroll;
  - a jump to a far row with an estimated height keeps the target within 1pt of its placement once nearby rows realize;
  - a reader scroll releases the jump anchor, and an append does not;
  - an unknown ID leaves the scroll position alone;
  - building the outline realizes no cells, which checks the first lazy-rendering rule.
- **Keyboard** – previous and next from the middle, from inside an exchange, from the first prompt and from the last.
- **The switch** – each value mounts its own renderer, and each renderer passes an offscreen render smoke test.

## Out of scope

- A highlight flash on the target prompt after a jump.
- Wheel-scrolling the rail.
- Renaming, hiding or grouping prompts.
- A complete prompt index for the Remote pane before its history has loaded, which would need a new RPC.

## Rejected alternatives

- **A prompt list in the Session index** – `SessionWorkbenchView` already shows a trailing index on panes 980pt wide or more. A Prompts section there costs little but gives no rail, nothing on narrower panes, and entries that open overlay cards instead of scrolling.
- **Notches placed by scroll position** – scrollbar-marker placement shows where long turns are, but neighbouring prompts merge into one mark and the notches stop lining up with the card's rows.
- **A windowed rail** – showing only the prompts around the current one keeps a comfortable pitch, but the rail then stops showing how far into the session the reader is.
- **Measuring rows above a jump target** – it would make jumps exact on the first try, at the cost of the estimated heights that make long transcripts open instantly.
- **Publishing the active prompt through pane state** – the simplest SwiftUI wiring re-renders the pane on each active change and reruns the table's update in the middle of a scroll. The SwiftUI renderer scopes the state to the rail instead.
- **A show/hide preference** – the rail acts on nothing by itself, and each preference is another layout to test.
