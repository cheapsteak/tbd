# Pane Header Context Menu — Design

**Date:** 2026-06-30
**Status:** Approved for planning

## Summary

Add a right-click context menu to the pane **header** of the code/markdown
preview pane and the live-transcript pane. The menu exposes file actions:
**Copy Path** (absolute path), **Reveal in Finder**, and an **Open With ▸**
submenu (the same candidate apps Finder offers, each with its icon).

Today the header only displays the file's last path component as static text.
The full absolute path is already in scope at the header render site, so these
actions are a thin addition over existing data.

## Motivation

Users viewing a file (markdown render, source, or a conversation `.jsonl`) often
want to act on the underlying file — copy its path to paste elsewhere, reveal it
in Finder, or open it in another app — without leaving TBD or hunting for the
path. The header is the natural anchor for those actions.

## Scope

### In scope
- Right-click context menu on the **main pane toolbar header** for:
  - `.codeViewer(_, path)` panes (markdown preview + code/source preview share
    this pane).
  - `.liveTranscript` panes (path = the session `.jsonl`).
- Three actions per menu: Copy Path, Reveal in Finder, Open With ▸.
- The live-transcript header already has a "Copy Conversation Path" context
  menu; this work **folds that into the new shared seam** and adds Reveal in
  Finder + Open With to it.

### Out of scope (YAGNI)
- The **multi-file internal headers** inside `CodeViewerPaneView` — the small
  per-file caption bars (`fileHeader(_:)`) shown only when the optional code
  viewer sidebar is enabled *and* 2+ files are selected (`selectedFiles.count >
  1`). This is an opt-in power-user mode that is off by default; adding actions
  there is a reasonable future follow-up but is a separate surface with its own
  per-file path.
- Finder's "App Store…" and "Other…" entries in Open With.
- Any new top-level menu-bar or toolbar buttons; this is right-click only.

## Current State (reference)

- **Header render site:** `Sources/TBDApp/Panes/PanePlaceholder.swift`
  - `paneLabel`, `.codeViewer(_, let path)` case (~lines 155-156) shows
    `Text(URL(fileURLWithPath: path).lastPathComponent)` — the full `path` is in
    scope.
  - The toolbar currently carries `.applyTranscriptCopyPathContextMenu(path:)`
    (~lines 528-545), a `@ViewBuilder` extension that attaches a `.contextMenu`
    with a single "Copy Conversation Path" button **only** when a transcript
    path exists (`transcriptPath`, ~lines 118-124), otherwise returns `self`.
- **Path origin:** `PaneContent.codeViewer(id:, path:)`
  (`Sources/TBDApp/Terminal/PaneContent.swift:8`). The path is constructed as an
  absolute path at click time (`FileViewerPanel.handleFileClick` ~lines 213-214;
  `ViewerRouting.routeFileClick`).
- **Established clipboard pattern:** the 2-line
  `NSPasteboard.general.clearContents()` / `setString(_, forType: .string)` is
  used in `FileViewerPanel` (`copyPathToPasteboard`, ~lines 5-8), `TabBar`
  (~lines 662-663), `SidebarContextMenu`, `HistoryPaneView`, and others.
- **Existing "Copy Path" context menus** for reference: `FileViewerPanel`
  per-row (~lines 340-344, 424-429) and `TabBar` (~lines 658-666).

## Design

### Single header context-menu seam

Replace the transcript-only `.applyTranscriptCopyPathContextMenu(path:)` on the
toolbar with **one** context-menu modifier keyed on the pane's `PaneContent`:

- `.codeViewer(_, path)` → menu with actions for `path`, copy label **"Copy
  Path"**.
- `.liveTranscript` (with a transcript path) → menu with actions for the
  `.jsonl` path, copy label **"Copy Conversation Path"** (preserves existing
  wording).
- any other case (or no path available) → **no menu** (returns `self`, matching
  today's behavior exactly).

Rationale: two stacked `.contextMenu` modifiers conflict (the last wins), so a
single seam that branches by pane content is both correct and the clearest place
to own "what does right-clicking a pane header do."

### Shared action builder

A single reusable `@ViewBuilder` produces the three menu items given a path and
a copy label:

```
headerFileActions(path:, copyLabel:) ->
  Button(copyLabel)          // Copy Path / Copy Conversation Path
  Button("Reveal in Finder")
  Menu("Open With") { ... }  // submenu, see below
```

- **Copy Path:** `NSPasteboard.general.clearContents()` then
  `setString(path, forType: .string)` — the established pattern. Copies the
  absolute path verbatim.
- **Reveal in Finder:**
  `NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])`.
- **Open With ▸:** see below.

### Open With submenu (with icons)

- **Candidate apps:** `NSWorkspace.shared.urlsForApplications(toOpen:)` (macOS
  12+) for the file URL. This returns the same ordered set Finder shows, default
  app first. If the list is empty (e.g. file missing), the submenu is omitted.
- **Each item:** a `Button` whose label is a `Label` with the app display name
  (derived from the app bundle / `lastPathComponent` sans `.app`) and the app
  icon via `Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))` with
  `.renderingMode(.original)`.
- **Action:** `NSWorkspace.shared.open([fileURL], withApplicationAt: appURL,
  configuration: NSWorkspace.OpenConfiguration())`.

**Known risk:** icon rendering inside SwiftUI context-menu items is inconsistent
on macOS (SwiftUI sometimes strips images from menus). The implementation
attempts `.renderingMode(.original)` icons; if they prove unreliable in the live
app, text-only app names are the acceptable fallback. App **names** are
rock-solid regardless. This must be confirmed by live visual verification (see
Testing).

### No bundle-identifier hazard

All APIs used (`NSPasteboard`, `NSWorkspace.activateFileViewerSelecting`,
`urlsForApplications(toOpen:)`, `icon(forFile:)`, `open(_:withApplicationAt:_:)`)
work in an unbundled SPM executable and do not require `CFBundleIdentifier`, so
the project's unbundled-executable constraint does not apply.

## Error Handling

- **Missing/moved file:** Copy Path still copies the string. Reveal in Finder
  and Open With degrade gracefully — `urlsForApplications` returns an empty list
  (submenu omitted), and reveal simply does nothing. No crashes, no alerts.
- **Open failure:** `NSWorkspace.open` reports asynchronously; failures are not
  surfaced with UI (consistent with the rest of the app's fire-and-forget
  open/reveal actions).
- **No path / non-file pane:** no menu is attached at all.

## Testing

Following the project rule that a behavior-gating branch gets a test per branch:

- **Pure helpers (unit, headless):**
  - Pane-content → menu-applicability: `.codeViewer` and `.liveTranscript` (with
    a path) yield actions; other cases / nil path yield none.
  - App-candidate resolution returns a list shape that the menu can consume, and
    an empty/missing-file path yields an empty list (submenu omitted).
  - Copy uses the absolute path string unchanged.
- **Live visual verify (manual, per project convention for SwiftUI menu
  visuals):** right-click each header; confirm the menu appears, Copy Path
  populates the clipboard with the absolute path, Reveal in Finder selects the
  file, and the Open With submenu lists apps — and specifically whether icons
  render (decides whether icons stay or fall back to text-only). Verified via
  screenshot + `log stream`, trusting the live app over headless numbers.

## Files Likely Touched

- `Sources/TBDApp/Panes/PanePlaceholder.swift` — replace the transcript-only
  context-menu modifier with the consolidated seam; add the shared
  `headerFileActions` builder and the Open With submenu (or a small companion
  file/helper if cleaner).
- Possibly a small new helper file for the Open With app-resolution logic (pure,
  testable) under `Sources/TBDApp/` (e.g. `Helpers/`), to keep `PanePlaceholder`
  focused and the resolution unit-testable.
- Tests under `Tests/` covering the pure helpers above.

## Open Questions

None blocking. The icons-vs-text-only decision for Open With is resolved
empirically during live verification.
