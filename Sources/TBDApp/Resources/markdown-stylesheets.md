# Writing a markdown stylesheet

TBD renders `.md` files by converting them to HTML and displaying them in a
webview. The stylesheet is the whole configuration format — there is no settings
file, no key vocabulary, and no invented knobs. Font size is already a CSS
property.

## Where stylesheets live

Stylesheets are the `*.css` files in `~/tbd/markdown-themes/`. Pick one in
**Settings → General → Markdown**; the selection is stored per user, not per
repository.

The fastest way to start is **New from Default**, which copies TBD's bundled
stylesheet into that folder, selects it, and reveals it in Finder. Note that the
copy is a snapshot: later improvements to the bundled stylesheet will not reach
it.

Edits apply as soon as you save. Any open markdown file re-renders — no restart,
no rebuild.

## There is no contract to implement

A stylesheet is free-form CSS. TBD injects no theme attribute and defines no CSS
variable contract, so nothing is required of you. This is a complete, working
stylesheet:

```css
body { font-family: Georgia, serif; font-size: 15px; }
```

The `--md-*` custom properties in the bundled stylesheet are an internal
convention that make *that* file easy to retheme. They are not an API, and your
stylesheet does not have to define them.

## What you are styling

The document is a complete HTML page. Your CSS is inlined into a `<style>`
element in the head, and the converted markdown becomes the body. Standard
elements appear as you would expect: `h1`–`h6`, `p`, `ul`, `ol`, `li`,
`blockquote`, `pre`, `code`, `table`, `thead`, `th`, `td`, `hr`, `img`, `a`,
`strong`, `em`, `del`, and `input[type=checkbox]` for task lists.

Four classes have no standard equivalent, so a stylesheet that ignores them will
render those pieces unstyled:

- `.markdown-alert` wraps a GitHub-style callout, with one of
  `.markdown-alert-note`, `-tip`, `-important`, `-warning`, or `-caution`
  alongside it.
- `.markdown-alert-title` is the label inside that callout.
- `.tbd-oversized-image` replaces an image too large to inline (over 2 MiB, or
  once the document's 16 MiB budget is spent).
- `.footnotes` wraps the footnote list at the end of the document.

## Light and dark

Handle both inside one stylesheet with `@media (prefers-color-scheme: dark)`.
TBD sets no theme attribute and does not switch stylesheets by appearance, so a
sheet without a dark block will render its light colors in dark mode.

## Things worth knowing

**Give `body` an opaque background.** A transparent background does not show the
window through it — the webview paints white underneath, so light text on a
transparent background is light text on white.

**Wide tables need a scroll container.** `overflow-x: auto` alone will not do it,
because the table box shrinks to fit instead of overflowing. The bundled
stylesheet uses `display: block; width: max-content; max-width: 100%`, which
makes the table wide enough to actually overflow and therefore scroll. Note that
`display: block` detaches the table box, so `border-spacing` stops applying —
build cell gutters from borders in the page color instead.

**JavaScript does not run.** Scripts in markdown are stripped before rendering,
and the webview disables scripting. CSS-only techniques work; anything requiring
a script does not.

**Local images are embedded**, so `img` rules apply normally. Remote images load
over the network and may not appear at all.

## Starting from the bundled stylesheet

The bundled stylesheet is the most complete reference available: it styles every
element and class listed above, and its comments explain the decisions behind the
type scale, the wide-table technique, and the palette. Use **New from Default**
to get an editable copy.
