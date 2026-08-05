# Session Workbench: Narrative Transcript and Session Index

**Date:** 2026-08-01
**Status:** Approved for implementation
**Scope:** One Claude transcript session. No durable state, daemon changes, or RPC changes.

## 1. Summary

The transcript pane will distinguish durable conversation from the operations that produced it.
Assistant prose becomes the primary reading surface. Consecutive tool and system activity folds
into compact work groups. A small trailing **Session index** lists files changed, sources read,
web references, and delegated work from the current session.

The design uses TBD's existing transcript data and per-item overlay. It adds a pure presentation
projection over `[TranscriptItem]`; it does not change transcript parsing, storage, or wire types.

## 2. Problem

The current renderer presents prose and operations as a flat sequence. Assistant replies use the
same rounded-card vocabulary as prompts, so conclusions do not stand apart from intermediate
work. Tool rows are compact, but a long run still interrupts the reading path. Files, web
references, and delegated work remain scattered through the timeline.

The desired hierarchy has three levels:

1. **Conversation:** user intent and assistant conclusions carry the thread.
2. **Work:** commands, reads, edits, reminders, and other intermediate activity remain available
   without dominating the thread.
3. **References:** durable files and links remain easy to revisit without scanning backward.

## 3. Current architecture

The daemon returns `[TranscriptItem]` through the existing transcript RPC. Live and historical
panes map those items through `transcriptRenderNodes(from:)` and render them with
`TableTranscriptView`. `ChatBubbleView` renders user and assistant prose. Native
`ActivityRowCellView` rows render most tools and system activity. Clicking an activity row opens
its full content through `TranscriptOverlayCoordinator`.

This foundation already separates data from presentation and provides a detailed-view action.
The missing pieces are a semantic presentation projection, grouped activity, and a compact index.

## 4. Considered approaches

### A. Current-session workbench — adopted

Project the current session into narrative rows, activity groups, and index entries. Keep all
state in the pane. This approach delivers the full interaction with no persistence or protocol
work and can be removed without migrating data.

### B. Narrative hierarchy without an index

Restyle prose and group activity, but leave references in the timeline. This carries less layout
risk, but it omits the quick retrieval surface that makes a long session navigable.

### C. Worktree-wide durable index

Aggregate artifacts across sessions and persist the result. This could support a future control
room, but it requires ownership, retention, deduplication, privacy, migration, and RPC decisions.
It belongs in a separate design after the session-local interaction has been tested.

## 5. Product direction

The visual metaphor is a dispatcher’s field notebook. Narrative stays on the main reading line;
operational steps attach as restrained relay markers; durable references rest on a narrow bench
beside the transcript. This language suits a macOS terminal and worktree manager without copying
another chat product.

### 5.1 Visual system

Reference light colors map to dynamic AppKit semantic colors in production:

- **Paper** `#F7F7F5`: transcript reading surface.
- **Track** `#ECEDEB`: grouped operational activity.
- **Graphite** `#252623`: primary prose.
- **Relay** `#5E6B85`: the structural signal line and secondary emphasis.
- **Active:** the user's system accent color.
- **Fault:** the system error color.

SF Pro Text carries prose. SF Pro Rounded appears only in small group labels and counts. SF Mono
carries paths, commands, and other machine identifiers. The alternation between narrative and work
is carried by the rhythm of the rows themselves — filled accent bubbles for prompts, unfilled prose
for narrative, a single summary line for each run of work. Assistant prose takes no leading rule or
border: a vertical bar down every message reads as a blockquote and turns the whole transcript into
quoted matter.

### 5.2 Wide layout

At widths of 980 points or more, the session index occupies a 248-point trailing rail.

```text
┌ transcript ───────────────────────────────┬ Session index ─────────┐
│  You  [compact accent prompt]             │ CHANGED                │
│  │                                        │  report.md          2× │
│  ● Assistant narrative, full-width,       │ SOURCES                │
│  │ unfilled, readable measure             │  TranscriptItem.swift  │
│  Edited 2 files, ran 4 shell commands [>] │ WEB                    │
│  │                                        │  SwiftUI documentation │
│  ● Assistant narrative                    │ DELEGATES              │
│                                           │  Design review       1 │
└───────────────────────────────────────────┴────────────────────────┘
```

The rail uses a separator rather than a floating card. This keeps it subordinate to the
transcript and consistent with TBD's pane system.

### 5.3 Narrow layout

Below 980 points, the rail becomes a trailing inspector button with the number of indexed
references. The button opens a popover that contains the same sections and actions. Below 680
points, prompts and assistant prose both use 12-point horizontal insets; role and color preserve
their distinction.

```text
┌ Transcript                                  [index 7] ┐
│ You [prompt]                                          │
│ ● Assistant narrative                                │
│ Edited 2 files, ran 4 shell commands [>]              │
└───────────────────────────────────────────────────────┘
```

## 6. Interaction hierarchy

### 6.1 Narrative

User prompts remain compact accent bubbles. Assistant prose becomes an unfilled, left-aligned
reading block with a restrained line length and no leading rule. Markdown and code rendering
retain their existing behavior.

### 6.2 Work groups

Consecutive non-narrative items between narrative items form one work group. A run of two or more
collapses; a lone item renders as its own row, since there is nothing to summarize. Groups start
collapsed. A summary reads as one sentence naming what was done — a clause per kind of work, joined
by commas, capitalized once: `Edited 2 files, ran 4 shell commands`. Verb tense carries execution
state, present participle while the work runs and past tense once it finishes, so a running group
needs no separate status badge.
Expanding a group reveals the existing compact activity rows. Clicking a child row continues to
open the existing item overlay.

Failures never disappear behind a neutral summary. A failed group shows its error count in text
and color and starts expanded. Items that require a human response also remain expanded.

Expansion is ephemeral pane state. A transcript poll preserves expansion for a group whose stable
identity remains unchanged.

**Open wording question (raised 2026-08-01 in review).** This paragraph says a failed group
"starts expanded" but that response-required items "also remain expanded" — and *starts* versus
*remains* can be read as two different strengths of guarantee. The implementation treats both the
same: an explicit user collapse is honored and survives polling, for failures and for
`AskUserQuestion` alike. That was true before the expansion-state fix below and is unchanged by
it; the fix only stopped a *changing default* from silently overriding the user's choice.

Nothing becomes unreachable either way — the disclosure chevron stays visible and the question is
answered by typing into the terminal, not through the card. The alternative reading, in which a
response-required group cannot be collapsed at all, would leave a chevron that refuses to work.
Recorded here rather than decided: if "remain" was meant as a hard guarantee, that is a product
call for the spec's author, and the code should then special-case `requiresResponse`.

### 6.3 Session index

The rail omits empty sections and uses these truthful categories:

- **Changed:** paths from `Write`, `Edit`, and `MultiEdit` inputs.
- **Sources:** paths from `Read` inputs.
- **Web:** `url` or `query` values from `WebFetch`, `WebSearch`, or an MCP tool whose final
  component is `browser_navigate`, `browser_open`, `browser_search`, `web_fetch`, or `web_search`.
- **Delegates:** descriptions from `Task` and `Agent` inputs.

Entries deduplicate by category and the trimmed decoded value, without changing path case. The
latest matching transcript item remains the click target, and repeated use appears as a count.
Clicking an entry opens that item's existing overlay. The index never parses result prose and
never guesses a category for an unknown tool. When no entry exists, it reads “No durable
references yet.”

## 7. Data and component boundaries

A pure `TranscriptPresentation` projection accepts `[TranscriptItem]` and returns:

- display rows containing narrative items and activity groups;
- `SessionIndexSection` values containing deduplicated entries; and
- stable group identifiers derived from the first grouped item ID and entry identifiers derived
  from category plus semantic target.

The projection owns grouping and structured input decoding. It has no SwiftUI, AppKit, daemon,
database, or RPC dependency. Malformed input produces an ordinary activity item and no index
entry.

`TableTranscriptPaneView` and the historical transcript view compose the table with the responsive
rail. `TableTranscriptView` remains the scrolling renderer. A collapsed group contributes one
summary row; an expanded group contributes its existing child render nodes immediately after the
summary, preserving table virtualization. The summary uses the first three unique labels from
`ActivityRowPresentation` as its representative verbs. Detailed content continues to use
`TranscriptOverlayCoordinator`.

The implementation covers both live and historical transcript panes through the shared
projection and rail components.

## 8. Accessibility and motion

- Disclosure rows and index entries use native buttons and expose explicit labels such as
  “Expand 6 actions” and “Open source TranscriptItem.swift.”
- Keyboard users can reach every disclosure and rail entry with standard focus traversal and
  activate them with Space or Return.
- VoiceOver reads the transcript first and the session index second. Counts and execution states
  appear in text; color never carries status alone.
- Dynamic semantic colors support light mode, dark mode, increased contrast, and system accent
  changes.
- Reduced Motion removes group and inspector transitions. Otherwise one short opacity and height
  transition serves disclosure; no ambient animation runs.
- Truncated paths retain tooltips and accessibility values with the full text.

### 8.1 Implementation note — keyboard reach fell short of the requirement

Added 2026-08-01 during acceptance review, against the shipped implementation.

The keyboard bullet above is only half met, and the gap is inherited rather than introduced.
Session-index entries and the inspector button are real SwiftUI `Button`s, so they are focusable
and activatable — though only once macOS Keyboard Navigation (Full Keyboard Access) is enabled,
which is off by default. **Activity-group disclosure rows are not reachable by focus traversal at
all.** They render in the `NSTableView` path, which sets `selectionHighlightStyle = .none` and
implements no key handling, so there is no focus ring to move and nothing for Return to activate.
Those rows stay operable by pointer and by VoiceOver, via
`ActivityRowCellView.accessibilityPerformPress`.

Pre-existing transcript rows had the same limitation, so this is not a regression — but the
requirement is not satisfied and should not be read as satisfied. Closing it means giving the
transcript table a real focus and selection model, which is its own change against a load-bearing
renderer and belongs in its own spec.

## 9. Performance and failure behavior

The projection runs once per transcript update, outside row bodies. It walks the item list in
linear time and bounds each JSON decode to the existing tool input string. The table receives
stable rows so unchanged narrative and groups retain their cached heights.

Malformed JSON, unsupported tools, or absent fields cannot prevent transcript rendering. They
yield ordinary activity without an index entry. A rail classification failure never changes or
hides the underlying transcript item.

Grouped rows must not contain a direct `ScrollView`; the existing transcript-card constraint still
applies. Large group contents remain virtualized as individual table rows when expanded rather
than forming one unbounded nested stack.

## 10. Validation

Automated tests will cover:

- group boundaries around narrative items;
- stable group identity across append-only polls;
- failure and human-response expansion defaults;
- malformed structured input;
- each explicit index category;
- deduplication, latest click target, and occurrence count;
- exclusion of unknown tools; and
- inline-rail versus inspector width policy.

Visual QA will use the existing headless transcript harness at wide and narrow widths in light and
dark appearances. It will check narrative measure, collapsed and expanded groups, rail density,
the narrow inspector, long paths, keyboard focus, and Reduced Motion.

## 11. Non-goals

- Worktree-wide or cross-session aggregation.
- Persistent group or rail state.
- New transcript parsing, database columns, migrations, or RPC types.
- Automatic file or browser panes opened without a user gesture.
- Inferring outputs from shell text or tool-result prose.
- Replacing the panel-surface model or transcript overlay.

## 12. Adoption boundary

This change is additive presentation work, not autonomous or destructive behavior, so it does not
need a default-off flag. The existing transcript renderer stays load-bearing; the implementation
must preserve its row virtualization, tail-first loading, polling, overlays, and narrow-window
behavior.
