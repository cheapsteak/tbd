# Clickable links in the transcript viewer

## Problem

The terminal already resolves clicked text into files. Cmd+click a path in a TBD
terminal and `TBDTerminalView.extractFilePath` widens the click to a path-shaped
token, `resolveAsFilePath` turns it into an absolute path, and `routeFileClick`
opens it in the panel's viewer slot. It works on absolute paths, worktree-relative
paths, `~`-rooted paths, a trailing `:line` suffix, paths wrapped in backticks, and
paths inside fenced blocks — because the terminal reads a character grid, where
backticks are just characters.

The transcript viewer renders the same text as markdown and offers none of it.
A path there is inert: to open a file an agent just wrote, you have to leave the
transcript, find the same line in the terminal pane, and cmd+click it there.

The asymmetry has a specific cause. By the time markdown reaches the screen, the
renderer has classified `` `docs/foo.md` `` as inline code and `/Users/…/foo.md`
as ordinary text, and neither classification carries any notion of a file. Only
`[text](url)` links get a `.link` attribute (`MarkdownAttributedRenderer.visitLink`).
`LocalFileLinker` exists and rewrites bare absolute paths into `tbd-file:` markdown
links, but nothing in `Sources/` calls it — only its tests do — and it explicitly
passes code spans through verbatim, so it never covered the common case anyway.

## What ships

Path-shaped and URL-shaped tokens in transcript text become links, in prose,
inline code spans, and fenced code blocks alike.

- **A path links only if it resolves.** The token must name an existing file that
  is not a directory. A path to something that does not exist stays plain text —
  the same rule the terminal applies, and the reason `/foo/bar`-shaped prose does
  not turn into a field of dead links.
- **Plain click follows the link.** Not cmd+click. Drag-selection over a link is
  unaffected: `NSTextView` distinguishes a click from a drag for `.link` ranges
  natively, which is why the ranges are marked at render time rather than resolved
  at click time.
- **Existing `[text](url)` links keep working**, and are never double-linked.
- **Clicks route by kind.** A file path goes to `routeFileClick`; a URL goes to
  `NSWorkspace`.

`:line:col` suffixes are stripped for resolution and then discarded — the code
viewer takes no line argument, so a click opens the file at the top. This matches
what the terminal does today.

## Resolution: one implementation, two callers

`resolveAsFilePath` is currently a method on `TBDTerminalView`, which mixes pure
path logic into an AppKit view and makes it unreachable from the transcript. It
moves to a pure helper — token and worktree path in, absolute path or nil out.

The rules it encodes, unchanged: `file://` URLs (including the `file://~` form,
where URL parsing otherwise swallows the tilde as a host); `~`-rooted paths;
absolute paths; otherwise a path relative to the worktree root. A trailing
`:line` or `:line:col` is stripped before the existence check. The result must
exist and must not be a directory.

One implementation is the point. The terminal and the transcript agree on what a
path is by construction rather than by two codebases happening to match, and a
defect in the rules — the terminal currently fails to resolve an absolute path
carrying a `:line:col` suffix, though the same suffix on a relative path works —
becomes a single-site fix rather than a two-site one. That defect is filed
separately and not addressed here.

## Detection

`TranscriptLinkScanner` is pure: a plain string in, candidate ranges out, no
AppKit. It reuses the terminal's token-boundary character set so the two agree on
where a path ends, strips a trailing sentence period so `see docs/foo.md.` links
the path and not the period, and skips any range that already carries a `.link`
attribute.

Keeping it free of AppKit is what makes the interesting cases testable without a
view: each case in the probe matrix below is an assertion against a string.

## Where the pass runs

A post-pass over each `.prose` `NSAttributedString` that
`MarkdownAttributedRenderer.renderBlocks` produces.

Inline code spans and fenced code blocks both end up inside those prose strings,
so a single pass covers both without touching the code-block renderer. The pass
lands inside the existing composed-blocks cache in `TableTranscriptView`, keyed by
`(id, contentVersion, width)`, so its `stat()` calls run once per row per content
change rather than once per scroll — the distinction that matters on the
transcript's measured-and-cached render path (#129).

## Styling

Prose links take `NSColor.linkColor`. Links inside code keep the code
foreground color and take a single underline instead.

The split is forced by an existing mechanism, not by taste. `CodeHighlightService`
re-applies `.foregroundColor` over code ranges asynchronously, after the row is on
screen; a link tint inside a code block would be silently overwritten a moment
after it appeared. Underline survives, because highlighting sets colors only.

The text view sets `linkTextAttributes = [:]` so AppKit does not stack its own
blue-and-underline treatment on top of the attributes already in the storage.
`NSTextView` still shows a pointing-hand cursor over link ranges, which supplies
hover feedback at no cost.

## Click plumbing

`TranscriptBubbleTextView` gains a delegate implementing
`textView(_:clickedOnLink:at:)`. Resolved paths are stored as `tbd-file:` URLs
carrying the already-resolved absolute path, reusing the scheme
`OverlayFileLinkAction` already defines. Resolution happens once, during the
cached render pass; the click path does no filesystem work.

The delegate calls closures threaded down from the pane, so the two render sites
choose their own destination:

- **The live transcript pane** wires a file click to `routeFileClick`, with its
  current swap semantics unchanged. Because `.liveTranscript` is viewer-class,
  a click with no code viewer already open replaces the transcript pane with the
  file. That is the accepted behavior: the pane count stays at two, and the
  toolbar toggle brings the transcript back. The cost is the transcript's scroll
  position.
- **The History pane** wires both file and URL clicks to `NSWorkspace`. History
  transcripts are not panes in a layout, so there is no slot to route into. Links
  look identical in both places while the destination differs.

## Testing

The scanner carries a case per row of the probe matrix — the same matrix used to
establish that the terminal already handles all of them:

- absolute path in prose; worktree-relative path; `~`-rooted path
- relative path with a `:line` suffix; absolute path with `:line:col`
- a path that does not exist, which must produce no link
- each of the above inside an inline code span
- each inside a fenced code block
- a bare URL, a CommonMark autolink, a bare `file://` URL
- a path followed by a sentence period

Beyond the scanner: the extracted resolver pins the terminal's existing behavior
so the move is provably inert; a markdown `[text](url)` link is asserted not to be
double-linked; and a link in a code context is asserted to carry an underline and
no tint, while a prose link carries a tint.

## Flag and reconciler

No feature flag. The behavior is additive UI behind a user gesture: it runs on no
timer, destroys no state, and adds a pass to the render path rather than replacing
one. Nothing here creates a durable external resource, so the named-reconciler
question does not arise.

## Rejected alternatives

**Resolve at click time, marking nothing.** Cheapest at render time — zero
filesystem work until a click — and an exact match for the terminal, which offers
no hover affordance at all. Rejected once plain click became the requirement:
`NSTextView.mouseDown` runs AppKit's modal drag-select tracking loop and does not
return until mouseUp, so click-versus-drag would have to be reconstructed by hand,
risking selection on any prose that happens to look like a path. Marking ranges
gets the same semantics from AppKit for free.

**Wire up `LocalFileLinker` as it stands.** It rewrites markdown source before
parsing, so it structurally cannot reach inside a code span — rewriting
`` `docs/foo.md` `` into a markdown link would stop it being code. It also has no
worktree path, so it cannot resolve relative paths. It should be deleted rather
than revived.

**Route a transcript click so the transcript survives** — excluding the
originating pane from swap candidates and splitting off it instead. Keeps your
place in the transcript, at the cost of a third pane appearing on a single click.
Rejected in favor of the smaller layout.
