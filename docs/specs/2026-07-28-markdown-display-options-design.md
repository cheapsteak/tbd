# Markdown Display Options (File Viewer)

**Date:** 2026-07-28
**Status:** Approved design, pending implementation plan
**Scope:** The markdown file viewer only. The transcript renderer is explicitly out of scope.

## Problem

TBD renders `.md` files through `CodeViewerPaneView`'s private `MarkdownUI.Theme.codeViewer`
(`CodeViewerPaneView.swift:20`). Every display choice is hardcoded: a 13pt base font, heading
scale as `.em()` literals, and twelve `Color` constants. Users cannot change colors, fonts, or
sizes.

The request was to make display configurable by extending an existing open standard rather than
inventing knobs.

## Research findings

Six research agents surveyed the field. The results overturned the initial approach twice, so
the conclusions are recorded here to prevent re-litigation.

**No cross-tool standard for markdown display exists.** SchemaStore carries no schema for
markdown typography or rendering config. CommonMark scopes presentation out explicitly. Every
vocabulary found — glamour, base16, tinted8, tmTheme, VS Code's `markdown.preview.*` — is
tool-private.

**The one portable answer is CSS.** VS Code (`markdown.styles`), JetBrains (custom CSS), Nova
(stylesheet), and Obsidian (snippets) all converge on "point us at a stylesheet." Native
rendering cannot consume CSS, which is why the first design round routed around it.

**Semantic theme formats cover colors but never typography.** Glamour's 32 element keys map
almost 1:1 onto swift-markdown-ui's `Theme`, but it has no font-family or font-size concept at
all, because terminals have one font. The same is true of tmTheme, Helix, Zed, and base16.

**`<details>`/`<summary>` exist only as raw HTML.** CommonMark and GFM have no disclosure-widget
syntax, so "safe by default" and "keeps `<details>`" are mutually exclusive in every library
surveyed. This is not an oversight in any of them.

**Apple's `swift-markdown` `HTMLFormatter` is unsafe on untrusted input.** Built and executed
against the pinned 0.7.3: raw HTML passes through byte-for-byte, plain text is not escaped, and
link/image destinations are interpolated into quoted attributes with no escaping, so
`[click](<" onmouseover="alert(1)>)` injects an arbitrary attribute. That last defect is present
on `main` as well. The cause is structural — swift-markdown walks its own AST rather than calling
cmark's renderer, so `CMARK_OPT_SAFE` is unreachable. **Do not use `HTMLFormatter`.**

**GitHub layers four defenses for mermaid, not one.** Rendering happens in a sandboxed iframe on
a separate origin (`viewscreen.githubusercontent.com`) under `script-src 'self'; default-src
'none'`, at `securityLevel: "antiscript"`, after which GitHub re-sanitizes the output SVG with
its own DOMPurify allowlist. The isolation comes from the separate origin, not from sandbox
origin-opacity — the iframe carries `allow-same-origin`. OSV lists 11 mermaid advisories, four
landed simultaneously on 2026-05-11 affecting versions current at the time.

**`decidePolicyFor` never sees subresource loads.** Navigation policy cannot block `<img>` or CSS
`url()` fetches. Only `WKContentRuleList` operates at the loader level. This matters for anyone
who later wants to block egress.

## Measurements

Taken on this machine, 2026-07-28, against comrak 0.54 with `default-features = false`
(which drops syntect), `opt-level = "z"`, LTO, `panic = "abort"`, `strip = true`.

| Measurement | Value |
|---|---|
| Cold build (17 crates) | 8.4 s |
| No-op rebuild | 0.05 s |
| `libcomrak_ffi.a` (staticlib) | 5.71 MB |
| Linked contribution to binary | ~715 KB |
| `libcomrak_ffi.dylib` (cdylib) | 0.59 MB |
| Cargo `target/` per worktree | 30 MB |
| Active worktrees, this repo | 16 |

The static archive is large because it is pre-link: 360 object files, most discarded by the
linker. Its contribution to the shipped binary is comparable to the dylib's size.

## Decisions

### Render to HTML in a hardened WKWebView

Replace the viewer's markdown path with markdown → HTML → `WKWebView`. Three independent
justifications:

1. **Main-thread safety.** SwiftUI markdown lays out on the main thread — the shape behind the
   #129 freeze class. WebKit lays out in a separate process on its own threads.
2. **CSS becomes available**, which is the only genuinely portable display-config format.
3. **"Open in Browser" becomes nearly free**, satisfying the requirement to read documents
   outside TBD.

It also retires `swift-markdown-ui` from this path, which is in stated maintenance mode (last
release v2.4.1, October 2024).

### comrak (Rust) for markdown → HTML

comrak in **safe mode** (raw HTML clobbered to `<!-- raw HTML omitted -->`, unsafe URL schemes
emptied), with extensions: table, strikethrough, tasklist, autolink, tagfilter, footnotes,
alerts.

Chosen over cmark-gfm — which is already vendored and would cost nothing — for GitHub alerts
(`> [!NOTE]`), footnotes, active maintenance, and memory safety on untrusted input. cmark-gfm's
own ecosystem describes it as no longer actively maintained.

Verified by execution: `<details>` became `<!-- raw HTML omitted -->`,
`[bad](javascript:alert(1))` rendered as `href=""`, and alerts produced
`<div class="markdown-alert markdown-alert-note">`.

**No sanitizer is required**, because safe mode emits no raw HTML and therefore offers no vector
for injected attributes. This holds only while safe mode holds; enabling `unsafe_` would require
an allowlist sanitizer and re-opens the `onerror`/`onload` class.

Accepted cost: `<details>`/`<summary>`, `<kbd>`, `<br>`, and `<img align>` do not render.

### Freeform CSS as the configuration format

The stylesheet is the config format. No settings file, no key vocabulary, no invented knobs —
font size is already a CSS property.

- The default stylesheet ships as a bundled app resource.
- User stylesheets live in `~/tbd/markdown-themes/*.css`.
- Settings offers a picker and a reveal-in-Finder button.
- The selected theme ID persists to `UserDefaults`, mirroring `AppearanceSettings.schemeID`.
- Light and dark are handled inside one stylesheet via
  `@media (prefers-color-scheme: dark)`. TBD injects no theme attribute and defines no CSS
  variable contract.

Scope is global. No per-repo override and no repo-local config file.

### Security posture

> **Amended 2026-07-28** by
> [`2026-07-28-mermaid-rendering-proposal.md`](2026-07-28-mermaid-rendering-proposal.md).
> JavaScript is no longer unconditionally disabled: it is **enabled when the
> `renderMermaidDiagrams` flag is on**, so that mermaid can render in-page. With that flag off,
> the posture below applies unchanged. The nested-iframe alternative that would have preserved
> an always-JS-free display was proven mechanically impossible — `allowsContentJavaScript =
> false` strips `srcdoc` and blocks scripting in every frame.
>
> Consequence: comrak's safe mode becomes the single layer preventing script injection from
> markdown when mermaid is enabled, rather than one of two. It remains the load-bearing layer in
> both designs.

The display webview uses a `.nonPersistent()` data store, installs **no script message
handlers**, and denies in-place navigation — link clicks route to `NSWorkspace`. JavaScript is
disabled (`allowsContentJavaScript = false`) unless `renderMermaidDiagrams` is enabled.

**Remote subresources are allowed.** Badges and remote images load normally. The accepted
consequence is that opening an unaudited README issues requests to whatever hosts it names,
leaking the viewer's IP. This is the behavior of most local markdown viewers and is judged
acceptable for a single-user developer tool.

Because remote loads are permitted, no CSP or `WKContentRuleList` is needed. If that decision is
ever revisited, note that navigation policy alone is insufficient — only a content rule list
blocks subresource loads.

### Local file resolution

> **Superseded 2026-07-28** by
> [`2026-07-28-mermaid-rendering-proposal.md`](2026-07-28-mermaid-rendering-proposal.md).
> **The `tbd-md://` scheme handler is not implemented.** Because JavaScript is enabled when
> mermaid is on, a registered scheme handler would be reachable from any script running in the
> page, so it is dropped entirely rather than made conditional. Repo-local images are inlined as
> `data:` URIs during document assembly instead, in both flag states, giving one image path
> rather than two.
>
> New requirement this creates: `data:` URIs have no streaming path for large images, so a size
> cap is needed. **Decided 2026-07-28: 2 MiB per image, 16 MiB total inlined per document.**
> An image over the per-image limit, or any image once the document budget is exhausted, renders
> as a placeholder showing the filename with a click-to-open affordance rather than being
> inlined. Two MiB of image is roughly 2.7 MiB of base64, so the document budget is the binding
> constraint on image-heavy READMEs.
>
> These numbers are invented, not copied: **GitHub strips `data:` URIs entirely** — it renders
> `<img>` with no `src` at all — so there is no GitHub behavior to match here. The nearest
> analogue is camo's per-image limit, verified in production at 5 MiB, which we deliberately
> undercut because inlining and proxying have different cost profiles.
>
> The record below is retained because the spike result is sound and would be the right design
> if the display view were ever returned to a permanently JS-free posture.

Relative images resolve through a `WKURLSchemeHandler` registered for `tbd-md://`. The generated
document is loaded with `loadHTMLString(_:baseURL: nil)` and carries a `<base>` whose href is
`tbd-md://` plus an opaque token identifying the document's directory — the handler holds the
token-to-path mapping rather than encoding a filesystem path in the URL. Relative URLs therefore
reach the handler with no HTML rewriting, while absolute remote URLs load directly.

**Verified by spike**, with JS disabled and a non-persistent store:

```
loadHTMLString + <base href="tbd-md://doc/">
  -> tbd-md://doc/style.css
  -> tbd-md://doc/pic.png
```

The handler validates each request individually: canonicalize, require containment under the
repo root, reject `..` traversal and symlink escapes, and enforce an extension allowlist.

This is preferred over `loadFileURL(_:allowingReadAccessTo:)`, which grants the page read access
to the entire directory tree — `.env`, `.git/config`, everything.

A local HTTP server was considered and rejected: a loopback TCP port is reachable by any process
on the machine, unlike the daemon's Unix socket, and would require token auth to avoid exposing
repo files. It offers no advantage now that the scheme handler is verified.

### Rust artifact delivery

- Crate at `rust/comrak-ffi/`, exposing `tbd_markdown_to_html` and `tbd_markdown_free` over a C
  ABI.
- The built `libcomrak_ffi.a` is **committed** at `rust/comrak-ffi/lib/`.
- `scripts/build-rust.sh` regenerates it; cargo is required only for regeneration.
- Staleness is guarded by a committed `.build-stamp` holding a SHA-256 of `src/lib.rs` plus
  `Cargo.lock`, verified in CI.

Committing was chosen over the alternatives because a static library adds nothing to sign,
nothing to notarize, no `@rpath`, and is invisible to Hardened Runtime library validation. It
works on a fresh clone, in CI with no toolchain, and in all 16 worktrees with no hooks. The
committed archive is a **build input, never a shipped artifact** — its size affects clones, not
users.

Rejected: a dylib (0.59 MB, but a permanent codesign and `@rpath` step in every build); Git LFS
(fixes history growth but adds a prerequisite whose failure mode is a link error against a
pointer file, and does not reduce per-worktree disk); a shared cache with APFS clones (smallest
footprint, but makes cargo a hard prerequisite, adds rustup to CI, and requires wiring a hook
into **both** worktree revive paths); and SPM `binaryTarget(url:checksum:)`, which is the
keychain failure PR #196 removed.

### Feature flag

`useWebViewMarkdownViewer`, a `UserDefaults` key defaulting to **false**. App-only behavior, so
`UserDefaults` is correct per CLAUDE.md; precedent is `enableTranscript` and
`useTableViewTranscript`.

Graduation: soak default-off, flip the default once stable, then delete the MarkdownUI path from
the viewer. `swift-markdown-ui` stays in `Package.swift` regardless — six transcript files import
it.

## Architecture

```
FilePreviewView  (existing FileWatcher -> revision)
  |
  +- serial queue (mirrors CodeViewerHighlightService)
  |    read file -> comrak FFI (safe mode) -> assemble HTML document
  |
  +- @MainActor publish
       MarkdownWebView -> hardened WKWebView
```

### Components

- **`rust/comrak-ffi/`** — cargo staticlib; two `extern "C"` functions.
- **`Sources/CComrakFFI/`** — header and modulemap. `TBDApp` gains
  `linkerSettings: [.unsafeFlags(["-Lrust/comrak-ffi/lib", "-lcomrak_ffi"])]`. `.unsafeFlags` is
  already used in this manifest (`noWMODebugWorkaround`), and TBD declares no `products:`, so the
  consumption restriction does not apply.
- **`MarkdownHTMLRenderer`** — Swift wrapper over the FFI; returns an HTML body string and frees
  the C buffer.
- **`MarkdownDocumentBuilder`** — assembles charset meta, `<base>`, resolved `<style>`, and body.
- **`MarkdownWebView`** — `NSViewRepresentable` over the hardened `WKWebView`. Reuses
  `WebviewPaneView`'s find bar and Cmd+R handling; WebKit's native
  `find(_:configuration:)` works with JavaScript disabled.
- **Settings** — a Markdown section: theme picker, reveal-in-Finder, and the soak toggle.
- **Open in Browser** — writes HTML to a temp file, then `NSWorkspace.open`. Since local images
  are already `data:` URIs in the live document and CSS is inlined at assembly, the export is
  self-contained with no re-encoding step. Remote image URLs are left untouched. When mermaid is
  enabled the export serializes the live DOM after render completes
  (`document.documentElement.outerHTML`), strips the mermaid `<script>` tag, and filters
  mermaid's leaked temp containers — so diagrams ship as inline `<svg>` and the exported file
  contains no JavaScript.

### Error handling

Existing states carry over: the 1 MB size guard and the unreadable-file path. A null return from
the FFI — invalid UTF-8 or an embedded NUL — falls back to rendering the file as plain text. An
unreadable or invalid user stylesheet falls back to the bundled default and surfaces a
non-fatal notice, following `ThemeStore.loadErrors`. A missing archive fails at link time, which
the stamp check exists to prevent.

## Testing

Tests run against the **committed** archive through the Swift boundary, so CI needs no Rust
toolchain and the tests exercise what actually ships.

- Golden-output tests: alerts, tables, task lists, footnotes, autolinks.
- Safe-mode invariants asserted explicitly: raw HTML clobbered, `javascript:` emptied.
- CSS resolution: bundled default, user stylesheet, missing-file fallback.
- Image inlining: repo-local images become `data:` URIs with correct MIME types; containment
  enforced against the document's directory; `..` traversal and symlink escapes rejected;
  oversized images fall back to the placeholder rather than being inlined.
- Webview configuration: no script message handlers installed in either state;
  `allowsContentJavaScript == false` when `renderMermaidDiagrams` is off and `true` when it is
  on; the data store is non-persistent in both.
- Browser export: CSS inlined, remote URLs untouched, and the exported file contains no
  `<script>` element.
- **Both flag branches**, per CLAUDE.md: flag off renders through MarkdownUI unchanged; flag on
  takes the webview path.

## Risks

**Two markdown engines in-process.** comrak serves the viewer while cmark-gfm remains via
`swift-markdown` for the transcript. This duplication is accepted, not resolved. Converging the
transcript onto comrak is possible future work and is not specified here.

**WKWebView in an unbundled executable.** A documented case exists of the WebContent process
failing to launch under a malformed `Info.plist`. Per CLAUDE.md's unbundled-executable
constraints, all testing must go through `scripts/restart.sh`'s bundled `.app` — never
`swift run TBDApp`.

**Git growth.** Each regeneration adds ~5.71 MB of undeltifiable blob permanently, roughly
17 MB/year at the expected cadence.

**New prerequisite.** Contributors regenerating the archive need cargo. The README already
requires `brew install tmux` and `brew install swiftlint`.

## Incidental fix

The current markdown path reads files on the main thread (`CodeViewerPaneView.swift:406`).
Commit `4fc71bcc` moved only the *code* path off-main. The new pipeline fixes this.

## Explicitly out of scope

- The transcript renderer, and any migration of it.
- Mermaid diagram rendering — **now specced separately** in
  [`2026-07-28-mermaid-rendering-proposal.md`](2026-07-28-mermaid-rendering-proposal.md), which
  amends this document's JavaScript posture and replaces the `tbd-md://` handler with `data:`
  URIs. It ships behind its own default-off `renderMermaidDiagrams` flag and graduates
  independently, so this document's flag can flip without waiting on it.
- Raw HTML support and any allowlist sanitizer.
- Blocking remote subresources.
- A local HTTP server or live browser preview.
- Per-repo markdown configuration.
