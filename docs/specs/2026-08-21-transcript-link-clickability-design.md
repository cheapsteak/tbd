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
  the browser.
- **A bare filename links too.** `CLAUDE.md` with no slash resolves against the
  worktree root, because agents write filenames that way constantly. The cost is
  accepted knowingly: an agent discussing another repo's `settings.json` gets a
  link to this worktree's file. A wrong file opening in a viewer is a cheap
  error, and requiring a slash would miss the common case.

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

One implementation is the point: the terminal and the transcript agree on what a
path is by construction, rather than by two codebases happening to match. The
extraction is behavior-preserving — a verbatim port of rules that had no test
coverage of their own, so `ClickedPathResolverTests` is also the first thing
pinning them.

Cmd+clicking an absolute path with a `:line:col` suffix was observed to fail in
the terminal while the same suffix on a relative path worked. That defect is not
in these rules — the suffix strip is uniform, and the terminal's token widener
excludes `:` from its boundary set, so the resolver never sees a suffix at all.
It lives somewhere in the grid-to-token path and is filed separately.

## Detection

`TranscriptLinkScanner` is pure: a plain string in, candidate ranges out, no
AppKit. It strips trailing sentence punctuation — `. , : ; > ! ? " '` — so
`see docs/foo.md.` links the path and not the period, and skips any range that
already carries a `.link` attribute. Dropping `!` and `?` from that set would be
worse than cosmetic: both are legal hostname characters, so `see https://x.com!`
would parse as a link to the host `x.com!` and open somewhere else without
looking wrong.

A path token also ends at a colon not followed by a digit. That is what makes
grep and compiler output usable: `Sources/A.swift:17:let x = 1` yields
`Sources/A.swift:17` rather than swallowing the matched line into the token,
while `:17` and `:17:5` stay attached for the resolver to strip.

The token-boundary character set lives beside the resolver and is *referenced* by
both the terminal's widener and the scanner, not copied into each. Sharing the
resolver while duplicating the tokenizer would leave the two surfaces free to
disagree about where a path begins and ends — which is the same drift the shared
resolver exists to prevent, one layer down.

A closing bracket is stripped from a URL only when it is unbalanced within the
token, so `…/Foo_(bar)` survives.

Three things the pass cannot reach, all deliberate. Text inside a GFM table cell
renders as a `.table` block rather than prose, so links there are out of scope.
And a token with no slash and no extension — `Makefile`, `LICENSE` — is not a
candidate, which is what keeps every ordinary English word out of the
filesystem. A path containing a space — `/Users/x/My Documents/a.md` — is out of
reach for the same reason the terminal's cmd+click widener cannot reach it: the
shared token character set holds no whitespace, so the token ends at the space.

Keeping it free of AppKit is what makes the interesting cases testable without a
view: each case in the probe matrix below is an assertion against a string.

## Where the pass runs

A post-pass over each `.prose` `NSAttributedString` that
`MarkdownAttributedRenderer.renderBlocks` produces.

Inline code spans and fenced code blocks both end up inside those prose strings,
so a single pass covers both without touching the code-block renderer. The pass
lands inside the existing composed-blocks cache in `TableTranscriptView`, keyed by
`(id, contentVersion)`, so its `stat()` calls run once per row per content change
rather than once per scroll — the distinction that matters on the transcript's
measured-and-cached render path (#129). Height measurement and rendering both
draw from that one cache, so they share the identical marked string and cannot
disagree about a row's height.

### The worktree root is an input the cache key does not carry

Resolution depends on the pane's worktree root, and that root is not constant
for the pane's life: a pane restored with the panel layout renders its history
before the worktree-list RPC lands, and resolves against an empty root until it
does. So two things follow, and the second is the one that is easy to miss.

The resolver reads the root on every resolve rather than snapshotting it — the
`TranscriptCardContext` a Coordinator captures is built once, so a snapshot
would be the pane's root forever. `TranscriptLinkResolverCache` drops its memo
whenever the root it was computed against changes, so an answer computed under
the old root is never handed out under the new one.

That alone still leaves every already-composed row plain text, because the
composed-blocks cache is keyed by `(id, contentVersion)` and the resolver runs
only on a miss. The pane therefore passes its current root to
`TableTranscriptView` as an ordinary value, and the Coordinator compares it
against the root its cached rows were composed against; a transition drops the
composed blocks and reloads, so the visible rows recompose against the new root.
Measured heights are deliberately kept: linking adds `.foregroundColor` and
`.underlineStyle`, neither of which moves a glyph, so every height cache still
describes the row it was measured for.

## Styling

Prose links take `NSColor.linkColor`. Links inside code keep the code
foreground color and take a single underline instead.

The split is forced by an existing mechanism, not by taste. `CodeHighlightService`
re-applies `.foregroundColor` over code ranges asynchronously, after the row is on
screen; a link tint inside a code block would be silently overwritten a moment
after it appeared. Underline survives, because highlighting sets colors only.

The text view sets `linkTextAttributes = [.cursor: NSCursor.pointingHand]`.
That dictionary is AppKit's whole link treatment — blue, underline, and the
pointing-hand cursor together — and letting it stand would stack a second
styling on top of the attributes already in the storage. Emptying it, though,
takes the cursor with it, and the cursor is the hover affordance that tells a
reader a range is clickable before they click it. So the dictionary carries the
cursor alone. `.cursor` is a non-layout temporary attribute: it cannot move a
glyph, so the composed cache's measure == render invariant is unaffected.

The consequence is that a markdown link renders exactly like a path link — tint
only, no underline — rather than carrying AppKit's default underline. One
appearance for every link in the transcript is the intent.

## Click plumbing

`TranscriptBubbleTextView` gains a delegate implementing
`textView(_:clickedOnLink:at:)`. Resolved paths are stored as `tbd-file:` URLs
carrying the already-resolved absolute path, reusing the scheme
`OverlayFileLinkAction` already defines. Resolution happens once, during the
cached render pass, so clicking one of those does no filesystem work.

A `file://` URL is the exception, because markdown can carry one directly and no
render pass has vetted it. The delegate applies the same rule to it at click
time — it links only if it names a file that is there and is not a directory —
so one existence rule governs every path the transcript treats as clickable. A
`file://` URL that fails it is reported as unhandled and falls through to
AppKit's default handling.

The delegate calls closures threaded down from the pane, so the two render sites
choose their own destination:

- **The live transcript pane** wires a file click to `routeFileClick`, with its
  current swap semantics unchanged. Because `.liveTranscript` is viewer-class,
  a click with no code viewer already open replaces the transcript pane with the
  file. That is the accepted behavior: the pane count stays at two, and the
  toolbar toggle brings the transcript back. The cost is the transcript's scroll
  position.
- **The History pane** reveals a file in Finder and opens a URL in the browser.
  History transcripts are not panes in a layout, so there is no slot to route
  into. Revealing rather than opening is a safety decision as much as a
  navigational one: transcript text is agent-authored, and handing an arbitrary
  resolved path to `NSWorkspace.open` would *execute* it when it happens to be a
  shell script. Links look identical in both places while the destination
  differs.

## Testing

The scanner carries a case per row of the probe matrix — the same matrix used to
establish that the terminal already handles all of them:

- absolute path in prose; worktree-relative path; `~`-rooted path
- relative path with a `:line` suffix; absolute path with `:line:col`
- a path that does not exist, which must produce no link
- each of the above inside an inline code span
- each inside a fenced code block
- a bare URL, a CommonMark autolink, a bare `file://` URL
- a path followed by a sentence period, and a URL followed by `!` or `?`
- a grep/compiler line `path:line:matched text`, which must yield `path:line`
- a bare filename with no slash, and a bare directory, which must not link
- tokens that must never become candidates: `Node.js`, `v1.2.3`, `e.g.`, `and/or`

Beyond the scanner: the extracted resolver gets the first tests those rules have
ever had, including the directory rule, which is reachable only through the
real-filesystem overload; a markdown `[text](url)` link whose *visible text is
itself a path* is asserted not to be double-linked, since a link whose text
contains no candidate would pass whether or not the guard exists.

The styling split is asserted end-to-end rather than on a hand-built string. A
test that marks the code attribute itself proves only that the styling branch
works — it would stay green if the renderer never set the attribute at all,
leaving every code link tinted and then silently erased by the highlight pass.
So the inline-span and fenced-block cases assert, through `renderBlocks`, that
the link carries an underline and has kept the code foreground color.

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
