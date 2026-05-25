# Agent overlay: markdown rendering + local file links

## Problem

The transcript overlay's Agent body (`AgentCardBody`) currently renders the
subagent **prompt** and the launch/completion **result** as plain
monospaced text. Both are authored as markdown in practice:

- The prompt is markdown the human (or upstream agent) wrote — headings,
  lists, bold, code spans.
- The result is either (a) the async-launch confirmation, which is plain
  prose containing a bare absolute path to the output file, or (b) the
  agent's final report, which is full markdown often containing bare
  absolute paths to files the agent created or modified.

Rendering as monospaced text wastes the structure and makes references
to local files inert. The user wants the modal to render markdown and
to navigate into referenced local files in place.

## Scope

Only the `AgentCardBody` overlay body. Other tool overlays (Read, Edit,
Bash, Grep, Glob, Write, GenericToolCardBody) are out of scope —
their specialised renderings (diff viewers, terminal output, file
previews) don't need markdown or file linkification.

Subagent activity (the nested `TranscriptItemsView`) is also out of
scope — each subagent item already renders with its own row body
(e.g., a nested assistant text already renders as markdown via
`ChatBubbleView`).

## Behaviour

### Markdown rendering

The two prose panels — `Prompt` and `Result` — render via
`MarkdownUI.Markdown(...)` using the existing
`MarkdownUI.Theme.chatBubble` theme already used by `ChatBubbleView`.
`.transcriptSelectableText()` is preserved for text selection. The
truncation footer ("3,189 more chars · Show full output") continues to
work as today; when the user expands, the full payload is re-rendered
as markdown.

### Local file link detection

Agent text contains references to local files in two forms:

1. **Bare absolute paths** in plain prose (the common case, e.g.
   `output_file: /private/tmp/claude-501/.../foo.output`, or
   `wrote design to /Users/chang/projects/tbd/docs/foo.md`).
2. **Explicit markdown links** the agent occasionally writes
   (`[design doc](/Users/chang/.../foo.md)` or
   `[file](file:///Users/...)`).

A small functional-core helper, `LocalFileLinker`, post-processes the
prose before handing it to `Markdown(...)`. It:

- Scans for bare POSIX absolute paths. A path token begins with `/`,
  continues across `[A-Za-z0-9._/+\-]` characters, and stops at
  whitespace, quote characters, parens, brackets, angle brackets, or a
  trailing `.`/`,`/`:`/`;`/`)` punctuation char. Tokens that already
  appear inside a markdown link, fenced code block, or inline code
  span are left alone.
- For each candidate path, checks `FileManager.default.fileExists`. If
  the file does not exist on the local disk, the path is left as plain
  text (no false-positive linkification).
- Replaces each existing-file match with a markdown link:
  `[<original-text>](tbd-file:<percent-encoded-abs-path>)`.

Inline markdown links the agent already wrote pass through unchanged.
The renderer's link-handler (below) interprets `tbd-file:` and `file:`
schemes as local files and everything else as external URLs.

This helper is pure (input string → output string) and is unit-tested
in isolation.

### Click handling

Each `Markdown(...)` is wrapped with
`.environment(\.openURL, OpenURLAction { ... })` that dispatches by
URL scheme:

- `tbd-file:` → decode the path, push a `.file(path:)` frame onto the
  overlay coordinator's stack.
- `file://` → same path, treat as a local file.
- Anything else → return `.systemAction` (system handles `https`,
  `mailto`, etc. — opens browser or default handler as today).

### File viewer body

A new `OverlayFileView` renders when the top of the overlay stack is a
`.file(path:)` frame:

- If path extension is `.md` / `.markdown` and the file is under
  ~1 MB: render with `Markdown(content, baseURL: URL(fileURLWithPath:
  path))` and the existing `Theme.codeViewer` (already defined in
  `CodeViewerPaneView.swift`; promote it to file-private-or-internal
  in the overlay module, or duplicate — TBD in plan).
- Else if the file is plain text and under ~1 MB: render as
  monospaced selectable text.
- Else: show a placeholder with the path, size, and a "Reveal in
  Finder" button (`NSWorkspace.shared.activateFileViewerSelecting`).

The viewer also installs its own `openURL` handler with the same
`tbd-file:` / `file:` dispatch, so navigating from one markdown file
to another local file works.

The viewer's header shows the file name (basename) instead of the
agent tool label. The icon switches to `doc.text` for `.md` /
`.txt`, `doc.plaintext` otherwise.

### Navigation stack

The coordinator currently supports a single-step back stack
(`parentFrame: TranscriptOverlayFrame?`) used by the agent →
subagent-item push. This becomes a real `[OverlayFrame]` stack so that
sequences like `agent → subagent-item → file → another-file → …` all
back-navigate one step at a time.

The frame type generalises from `TranscriptOverlayFrame` (struct) to:

```swift
enum OverlayFrame: Equatable {
    case item(TranscriptItemRef)  // existing struct, renamed
    case file(path: String)
}
```

where `TranscriptItemRef` keeps the existing
`(terminalID, itemID, historySessionID)` fields.

Coordinator API:

- `open(item: TranscriptItemRef)` — top-level open (clears stack).
- `pushItem(itemID: String)` — push a sibling subagent item; preserves
  the active terminal/session.
- `pushFile(path: String)` — push a file frame.
- `pop()` — pop one frame; close when the stack is empty.
- `close()` — clear and close.
- `current: OverlayFrame?` — what's visible.

Tapping the same item that's at the top still toggles (the existing
"click same row to dismiss" behaviour) — this stays scoped to item
frames; file frames always push.

The header `hasBack` becomes `stack.count > 1`. `onBack` calls `pop()`.

### Failure modes

- Path no longer exists when clicked (race after detection): file
  viewer renders an error placeholder ("File not found: …"); back
  button still works.
- File read fails (permissions, encoding): error placeholder with the
  underlying error message.
- Path appears in text but file isn't there: not linkified (decision
  in detector, not at click time).
- Empty file: render an empty markdown view (the existing
  `RenderedContentView` in `CodeViewerPaneView` handles this).

## Architecture / file impact

New files in `Sources/TBDApp/Panes/Transcript/`:

- `LocalFileLinker.swift` — pure helper, `func linkify(_ text: String,
  fileExists: (String) -> Bool = FileManager.default.fileExists) ->
  String`.
- `OverlayFileView.swift` — the file viewer body.

Modified:

- `TranscriptOverlayCoordinator.swift` — frame enum + stack API.
- `TranscriptOverlayView.swift` — switch on the top frame; route to
  either the existing tool-body switch or `OverlayFileView`.
  Header label/icon dispatch on frame kind too.
- `AgentCardBody.swift` — replace the two `Text(...)` prose panels
  with `Markdown(...)` + `LocalFileLinker.linkify(...)` +
  `OpenURLAction`. Wire the open-URL action to
  `overlayCoordinator.pushFile(...)`.
- Callers that used to construct `TranscriptOverlayFrame` directly
  (TerminalPanelView, History pane, anywhere `coordinator.open(...)`
  is invoked) — update to the new `open(item:)` API. Confine the
  rename ripple to call-sites; semantics unchanged.

New tests:

- `LocalFileLinkerTests` — bare path at EOL / in parens / with trailing
  comma / followed by sentence; markdown link passthrough; fenced code
  block passthrough; inline code passthrough; nonexistent paths
  skipped; path-like-but-not (`http://...`) skipped; nested paths
  inside larger tokens; empty string; no paths.
- `TranscriptOverlayCoordinatorTests` — extend existing tests with:
  push-file then pop; push-item then push-file then pop twice;
  push-file then close; back button toggles `hasBack` correctly across
  mixed-frame sequences.
- `OverlayFileViewTests` (if testable as a pure view of the
  loaded-content state machine; otherwise skip — existing
  `RenderedContentView` in `CodeViewerPaneView` isn't unit-tested
  either).

## Out of scope

- Linkifying relative paths or `~/`-prefixed paths. Agents almost
  always emit absolutes in their reports; relatives are too ambiguous
  to resolve without a working-directory context that the overlay
  doesn't carry.
- Linkifying paths inside subagent items (those render through other
  card bodies — would be a separate change).
- Honouring `file:line:col` suffixes (e.g., `foo.swift:42`) by jumping
  to a specific line in the viewer. The viewer just renders the file
  start; selection is via the user.
- Showing a breadcrumb of the stack in the header. The back button is
  enough for the depths we expect (rarely > 3).
- Caching file contents across pop/re-push (re-read each time;
  trivially cheap for the sub-MB files we render).
