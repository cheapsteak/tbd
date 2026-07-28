# Mermaid Rendering — Proposal

**Date:** 2026-07-28
**Status:** Approach chosen (**Option 7**, 2026-07-28). Secondary decisions still open — see
"Open decisions". Requires amendments to the committed markdown display spec.
**Relates to:** [`2026-07-28-markdown-display-options-design.md`](2026-07-28-markdown-display-options-design.md),
which lists mermaid as explicitly out of scope. This document works out how it comes back in.

## Constraints inherited from the committed spec

These are settled and constrain every option below.

- Markdown renders as markdown → HTML → hardened `WKWebView`, behind the default-off
  `useWebViewMarkdownViewer` flag.
- HTML comes from **comrak in safe mode**, which clobbers all raw HTML. Mermaid diagrams arrive
  as ` ```mermaid ` fenced blocks and survive as `<pre><code class="language-mermaid">`.
- The display webview runs **no JavaScript**, installs no script message handlers, uses a
  non-persistent data store, and denies navigation.
- Local images resolve through a `tbd-md://` `WKURLSchemeHandler`.
- Remote subresources are allowed.
- "Open in Browser" must produce a portable standalone file.

## Findings

Established by spikes run on this machine (macOS 26.1, WebKit 21622.2.11.11.9) unless marked
otherwise. Artifacts live in the session scratchpad, not the repo.

### Rendering works, and is fast

A **windowless** `WKWebView` — never added to any window or superview, in a bare non-`.app`
executable with `Bundle.main.bundleIdentifier == nil` — renders mermaid correctly. Flowchart,
sequence, gantt, and class diagrams all lay out with true font metrics. **The
malformed-`Info.plist` WebContent launch failure that the markdown spec flags as a risk did not
reproduce.** (VERIFIED)

Cold start is ~250–270 ms, of which the 3.5 MB bundle evaluation is a consistent 66 ms. Warm
renders are 8–22 ms per diagram; 20 flowcharts complete in 180 ms. Cost scales roughly linearly
in edge count — 300 edges took 450 ms and produced 634 KB of SVG. (VERIFIED)

### The safe configuration is load-bearing

With `securityLevel: 'strict'` and `htmlLabels: false` set at both the top level and inside
`flowchart: {}`, output SVG across all tested inputs contains **zero** `<script>`,
`<foreignObject>`, `<img>`, `<image>`, `on*` attributes, or `javascript:` URLs. A control run at
`loose` with `htmlLabels: true` reproduced both `<foreignObject>` and a surviving attacker
`<img src>`, confirming the configuration is what provides the property, not luck. (VERIFIED by
direct inspection of every spike output.)

**One survivor:** `click B href "https://evil.example"` emits a live `<a xlink:href>`. Verified
present in the output. `click A "javascript:..."` is stripped. The display webview already
denies navigation and routes clicks to `NSWorkspace`, which makes such a link exactly as
dangerous as an ordinary markdown link — i.e. within the "remote subresources allowed" decision
already taken. A policy line is still needed.

**Correction to an earlier reading:** one spike artifact appeared to contain an `onerror=`
attribute. It is not an SVG — it is the harness's error dump. Mermaid *rejected* that hostile
diagram at parse time and emitted no SVG at all.

That correction surfaces a real requirement. **Mermaid's parse errors echo the offending source
verbatim**, e.g. `... src=y onerror=alert(2)>] --> B`. Any design that surfaces those messages
in the UI is interpolating attacker-controlled text into assembled HTML. comrak never sees that
string, so **escaping it is our responsibility**, and it must be stated explicitly wherever error
display is specced.

### Displaying the result

Pre-rendered SVG displays correctly in the JS-disabled display webview, and a hand-crafted inline
`<script>` inside an SVG did not execute there. (VERIFIED)

**`NSImage` / `_NSSVGImageRep` is a dead end.** It loads mermaid SVG without error but renders
garbage: `#id`-scoped CSS is ignored, and even after flattening computed styles to attributes,
SVG `<marker>` arrowheads do not render at all. Any "just display it natively" shortcut is
closed. (VERIFIED)

### JavaScript is off in every frame, and the escape hatch is a trap

`allowsContentJavaScript = false` does more than refuse execution — WebKit's parser **strips**
scripting content. `<script>` elements never enter the DOM, `on*` attributes are removed,
`javascript:` hrefs are deleted, and **the `srcdoc` attribute itself is stripped**, leaving an
iframe at `about:blank` loading nothing. This holds for the main frame, `srcdoc` iframes, `data:`
iframes, and `sandbox="allow-scripts"` iframes alike. (VERIFIED; sourced to
`ScriptableDocumentParser`, `Element::stripScriptingAttributes`,
`HTMLFrameElementBase::isHTMLContentAttribute`.)

Per-navigation grants via `decidePolicyFor` can re-enable JS for a subframe — but
`allowsContentJavaScript` is stored as a **single per-page field**
(`WebPage::m_allowsContentJavaScriptFromMostRecentNavigation`, consulted live). Granting any
subframe therefore **retroactively re-arms scripting-content parsing for the main frame**. A
demonstrated consequence: after a granted subframe load, an `innerHTML`-injected `<img onerror>`
executed in the main frame. Frame isolation here is an artifact of navigation ordering, not a
guarantee. (VERIFIED + sourced)

`WKUserScript` and `evaluateJavaScript` still run under the flag, and DOM-API sinks
(`setAttribute('onerror', …)`, `script.textContent`, `el.onerror =`, string `setTimeout`) do
execute. Markup sunk through `innerHTML` is inert. (VERIFIED)

### Offscreen throttling

`requestAnimationFrame` never fires in any hidden configuration (zero callbacks in 8 s; sourced
to `Page::setIsVisibleInternal` → `suspendScriptedAnimations`), and DOM timers clamp to a 1 s
grid after roughly six fires. Mermaid does not need rAF, but **every JS entry point into a hidden
webview must carry a timeout race**, and multi-tick timer waits must be avoided — an early spike
hung for 120 s on exactly this. (VERIFIED)

### Memory

Measured `ps` RSS for the spike's own WebContent processes:

| Process | RSS |
|---|---|
| Working render sandbox | 104–110 MB |
| After a 300-edge diagram | **528 MB, and it did not shrink back** |

The steady-state figure is ~110 MB, not the ~200 MB initially reported; the larger "footprint"
figure could not be corroborated from the spike logs. Other WebContent entries in those logs
belong to unrelated applications — the measurement command matched every WebContent process on
the machine, not just its children.

The actionable finding is the **non-shrinking 528 MB peak**: a single pathological diagram
permanently inflates the sandbox until teardown. That argues for recycling the webview after a
large render and capping fence size, more strongly than the steady-state number argues for
anything.

Note this is a **second** WebContent process — the display webview already has one, as does
`WebviewPaneView`. WebKit additionally spawns GPU (~10–16 MB) and Networking (~6 MB) helpers,
typically shared across a process pool.

## Options

### Option 1 — Generation-time pre-render to inline SVG — **recommended**

A `MermaidRenderService` owns one lazily-created windowless `WKWebView` that is the inverse of
the display view: **JS enabled, but no scheme handler, no message handlers, non-persistent store,
`loadHTMLString(baseURL: nil)`** for an opaque origin. It loads the vendored mermaid bundle once.
During document assembly each mermaid fence is rendered to SVG via one `callAsyncJavaScript`
call, verified against an allowlist, and inlined. The display webview stays exactly as specced.

**Mechanism details.** Extract fences from the *source markdown* before comrak, substituting
opaque tokens, then substitute SVG into comrak's output. This avoids both string-surgery on
generated HTML and having to un-escape entity-encoded code content out of `<pre><code>`. The
service is `@MainActor` — calling `WKWebView` off-main crashed WebKit in testing
(`EXC_BREAKPOINT` in `WebPageProxy::launchProcess`) — and the comrak serial queue hops to it per
diagram. Only string marshalling happens on the main thread; layout is in the WebContent process,
so this does not reintroduce the #129 shape.

**Caching.** Content-addressed per block:
`SHA-256(source ‖ mermaid version ‖ theme epoch)` → SVG. In-memory LRU capped by bytes. Per-block
keying means editing prose around an unchanged diagram costs nothing.

**Verification, not rewriting.** Reject a render — falling back to source display — if the SVG
contains anything outside an allowlist. Per the project's assert-whitelist convention this is a
tripwire for future mermaid upgrades, not a sanitizer we depend on.

**Security.** Strongest of any option, and structurally better than GitHub's. GitHub needs four
layers because its *display* surface runs JS; ours does not. Worst case — a mermaid exploit of
the kind its 11 OSV advisories describe — the attacker lands in a throwaway webview containing
only the diagram text they wrote, with no scheme handler (no repo file access), no message
handlers, no persistent state, and an opaque origin. Optional hardening: a `WKContentRuleList`
blocking all egress from the sandbox, which has no legitimate network need.

**Fidelity** identical to GitHub — it is mermaid. **Offline** fully, via a bundled resource.
**Open in Browser** is *better* than any alternative: inline SVG is self-contained, vector,
text-selectable, portable, with no extra work.

**Costs.** ~110 MB resident while active (hence idle teardown with an injected clock per
CLAUDE.md); a vendored 3.57 MB `mermaid.min.js`, which makes TBD responsible for patch latency on
a component with a substantial advisory history; and the dark-mode wrinkle below.

### Option 2 — In-page nested sandboxed iframe, GitHub-style — **dead**

Dead on verified mechanics rather than taste. As specced it does not even load: with the parent's
content JS off, a served `srcdoc` attribute is stripped and the iframe sits at `about:blank`.
`sandbox="allow-scripts"` changes nothing.

The only resurrection is a per-navigation subframe grant, which flips the page-global scripting
bit described above and retroactively re-arms the main frame. The resulting security property
would be "safe because of navigation ordering in the current WebKit," which is precisely the kind
of guarantee that rots silently.

Additionally, GitHub's actual defense — a separate origin in a separate context — does not
translate. A nested iframe shares the parent's `WKWebViewConfiguration`, process pool, and scheme
handler registrations, so a compromised mermaid would run with more reach than Option 1 grants
it, while abandoning the spec's headline invariant and breaking the standalone export.

**Scope note on that escalation.** An earlier draft claimed a compromised iframe "could fetch
repo files through the handler and exfiltrate them." That overstates it: a cross-origin `fetch()`
to a custom scheme is very likely CORS-blocked from reading the response, and a path-validating
handler with an image-extension allowlist serves nothing else. `<script src="tbd-md://…">`
remains a convoluted vector. The verdict is unchanged, but it rests on the mechanics above, not
on this.

### Option 3 — Second webview positioned inline in the document flow — **dead**

An `NSView` cannot be embedded inside a `WKWebView`'s layout; "inline" could only mean AppKit
overlays floated above placeholder rects. Obtaining placeholder geometry requires script in the
display page, which is off. Even with that granted, it means hand-synchronizing overlay frames
against asynchronous rubber-banding scroll, breaking find-in-page, selection, printing, and
export around the seams, at ~110 MB per live webview. Every property it might buy is one nobody
asked for.

### Option 4 — Native renderer

**4a. `beautiful-mermaid-swift`** is real, MIT, genuinely Craft's production code, and emits SVG
strings — so it would compose with the HTML pipeline and sidestep the `NSImage` trap. But it
covers **6 of mermaid's ~17+ diagram types** (no gantt, pie, gitgraph, mindmap, timeline, C4),
uses a hand-calibrated average-character-width heuristic for layout with real CoreText only at
draw time (a latent clipped-label risk), bans HTML labels, click, and tooltips, and pulls in an
EPL-2.0 dependency. Users will paste GitHub-rendered diagrams and ask why gantt shows an error.
As the primary renderer it is a permanent fidelity treadmill.

**4b. `mermaid-rs-renderer` (mmdr)** is the interesting dark horse: pure Rust, ~1.5k stars,
actively developed, claiming 23 diagram types with real glyph-accurate text measurement via
`fontdb`/`ttf_parser`, emitting SVG. TBD already has the committed-Rust-staticlib delivery
pattern from comrak, so it could ride that mechanism with no webview, no JS, no memory cost, no
cold start, and perfect offline and export behavior. Catches: self-described early-stage,
fidelity unverified here, and it would roughly double the committed-archive git-growth line.
**Not now — but the credible convergence target** if the sandbox cost ever becomes objectionable.

### Option 5 — Show source with affordances — **the floor, and build it regardless**

A syntax-highlighted mermaid block plus "Open in mermaid.live" and "Copy source". The
mermaid.live URL is `#pako:` plus base64url of raw-deflated JSON, which Apple's Compression
framework produces natively — no JavaScript needed. (INFERRED, cheaply spikeable.)

This is not an alternative to Option 1; it is Option 1's **mandatory substrate** — the flag-off
state, the per-block timeout and verifier-rejection fallback, and the unsupported-diagram-type
fallback. Building it first makes Option 1 a pure enhancement over a working degradation path.

### Option 7 — In-page mermaid, JS-enabled display, no scheme handler — **CHOSEN**

Selected by Chang, 2026-07-28, over Option 1. This is the option that delivers in-page rendering
without a pre-render pipeline, once Option 2 is off the table.

**Mechanism.** The display webview enables JavaScript and loads a vendored `mermaid.min.js`. The
`tbd-md://` scheme handler is **dropped entirely**; repo-local images are inlined as `data:` URIs
during document assembly instead. Mermaid renders in-page, as on GitHub. There is no hidden
webview, no async render coordination, no SVG cache, and no second WebContent process.

**Configuration.** JS is enabled only when `renderMermaidDiagrams` is on; with the flag off the
display view keeps the JS-free posture of the markdown spec. The image strategy is uniform
(`data:` URIs) in both states, so there is one image path rather than two.

**Per-document gating (decided 2026-07-28).** Assembly already scans the source for mermaid
fences, so a document containing none loads **neither the bundle nor JavaScript**:
`allowsContentJavaScript` is set per navigation via
`decidePolicyFor(_:preferences:decisionHandler:)`, enabled only for loads whose source contains
at least one fence. Most documents therefore keep the JS-free posture even with the flag on,
recovering most of what Option 7 concedes.

Requires a spike: earlier research established that `allowsContentJavaScript` is a **single
per-page field consulted live** (`m_allowsContentJavaScriptFromMostRecentNavigation`) and that a
subframe grant retroactively re-armed the main frame. Per-main-frame-navigation toggling is the
API's intended use, but the behavior on a **reused** webview alternating between mermaid and
non-mermaid documents must be verified, not assumed.

**Bundle delivery (decided 2026-07-28).** A narrow `WKURLSchemeHandler` serves exactly one
bundled resource — the vendored mermaid asset — with **no path parameterization and no
filesystem access**. This is a categorically different object from the removed `tbd-md://`
handler, which was dangerous precisely because it was parameterized over repo paths. A
compromised page that requests this handler receives the library it is already running, so the
information gain is nil.

Rejected: inlining the 3.5 MB bundle into the document string, which pays a fresh compile per
load and leaks into the export; and `WKUserScript`, because user scripts execute **even when
`allowsContentJavaScript` is false**, which would run mermaid inside documents the gating above
declares JS-free — a sharp edge in exactly the place the design depends on JS being off.

**Security.** Weaker than Option 1, and the trade is explicit. comrak's safe mode becomes the
*single* layer preventing script injection from markdown, rather than one of two — though it is
the load-bearing one either way, and it is well tested. A mermaid exploit lands in a page with no
scheme handler, no message handlers, no persistent state, and an opaque origin
(`loadHTMLString(baseURL: nil)`); it reaches the network and the README the user is already
viewing. Dropping the scheme handler is what keeps that blast radius small, so it is a
requirement of this option, not an incidental simplification.

**Export.** Serialize the live DOM after render completes
(`document.documentElement.outerHTML`), strip the mermaid `<script>` tag, and filter mermaid's
leaked temp containers. Diagrams are already inline `<svg>` and images are already `data:` URIs,
so the result is self-contained and contains no JavaScript. No separate pre-render path is
needed. The export must await render completion or it will snapshot unrendered blocks.

**Costs.** The 3.5 MB bundle loads in the display path. `data:` URIs inflate image-heavy
documents, and unlike the scheme-handler design there is no streaming fallback for very large
local images — a size cap with a placeholder is needed. Vendoring still makes patch latency
TBD's responsibility.

### Option 6 — Mermaid as a `WKUserScript` in the display webview — **rejected**

Superficially coherent, since user scripts run even with content JS disabled and `innerHTML`-sunk
markup is inert. But mermaid and d3 construct their DOM through exactly the API sinks that are
*not* gated, which is where mermaid's advisories historically live. And it runs the vulnerable
component inside the webview holding the `tbd-md://` handler, giving it repo file access — the
same escalation as Option 2 — while saving only the second process's memory. Strictly dominated.

## Decision

**Option 7, with Option 5 as its permanent built-in floor, behind a new default-off flag.**

Chosen 2026-07-28 over Option 1, which this document originally recommended. The deciding factor
was avoiding the hidden-webview pre-render pipeline — its lifecycle, async coordination, cache,
and second WebContent process — in exchange for accepting a JS-enabled display view.

The analysis that led to Option 1 still stands on its own terms: it has the stronger security
posture, and it keeps the "display runs no JS" invariant. **Option 7 trades that invariant for
substantially less machinery.** The trade is defensible because comrak's safe mode is the
load-bearing layer under either design, and because dropping the `tbd-md://` handler keeps a
mermaid exploit's blast radius to the network plus the document already on screen.

Options 2 and 3 are dead on verified mechanics, 4 is a fidelity treadmill, 6 is dominated by 7.

Per CLAUDE.md this is a new subsystem executing a large third-party engine against untrusted
input, so it ships behind its own default-off flag (`renderMermaidDiagrams`, `UserDefaults`),
with both branches tested, graduating only after a soak.

### Required amendments to the markdown display spec

Option 7 contradicts two settled decisions in
[`2026-07-28-markdown-display-options-design.md`](2026-07-28-markdown-display-options-design.md).
That spec must be amended before implementation:

1. **"The display webview runs no JavaScript"** becomes conditional — JS is enabled when
   `renderMermaidDiagrams` is on.
2. **The `tbd-md://` `WKURLSchemeHandler` is removed.** Repo-local images become `data:` URIs in
   both flag states. The spike that verified `<base>` resolution through a custom scheme handler
   remains valid but is no longer used.

Consequences that follow: the browser export's `data:`-URI logic moves from an export-only step
to the main assembly path, and the export gains the DOM-serialization step described above.

## Open decisions

**A human must answer these. They are not settled.**

**Direction set 2026-07-28: copy GitHub's limits rather than invent our own.** Values below were
extracted from GitHub's shipped `mermaidMarkdown-*.js` bundle and probed against production.

### Mermaid caps — copy exactly, by not overriding

GitHub's verbatim `initialize` call, from the shipped bundle:

```js
mermaid.initialize({
  startOnLoad: false,
  secure: ["secure","securityLevel","startOnLoad","maxTextSize"],
  securityLevel: "antiscript",
  flowchart: { diagramPadding: 48 },
  gantt: { useWidth: 1200 }, pie: { useWidth: 1200 },
  sequence: { diagramMarginY: 40 },
  theme: <html data-color-mode> === "dark" ? "dark" : "default"
});
```

**GitHub overrides neither cap** — it inherits mermaid's defaults, so we get the same behavior by
also not overriding them:

- **`maxTextSize` = 50,000.** Measured on the diagram source as `String.length`, i.e. **UTF-16
  code units** — in Swift that is `source.utf16.count`, not `source.count`. It does not throw: it
  replaces the diagram with a single-node flowchart reading "Maximum text size in diagram
  exceeded". That message is fixed text, not echoed source, so it is safe to display and does not
  reopen the deferred error-escaping question.
- **`maxEdges` = 500.** Flowchart diagrams only; the 501st edge throws. Sequence, class, and
  others do not enforce it.
- **Neither is raisable from inside a diagram.** Mermaid unions the `secure` arrays rather than
  replacing them, so the effective secure set covers both keys and a `%%{init}%%` directive is
  dropped with "Denied attempt to modify a secure key". (VERIFIED in shipped code.)
- **No per-file diagram-count limit.** 300 fences in one document all rendered.

**Deliberate divergence:** GitHub runs `securityLevel: "antiscript"` and leaves `htmlLabels` on.
We run **`strict` with `htmlLabels: false`**, which is stricter and is what the spike verified
produces clean output. Do not copy GitHub here — its looser config is what reproduced
`<foreignObject>` and a surviving attacker `<img src>` in the control run.

**Validation of the dark-mode approach:** GitHub switches `theme` at runtime from a DOM attribute,
exactly as this document proposes doing from `prefers-color-scheme`.

### Residual gap — GitHub's caps do not solve our memory finding

**The 300-edge diagram that peaked a WebContent process at 528 MB is within GitHub's limits**
(300 < 500 edges, and well under 50,000 characters). Copying GitHub's numbers therefore does not
address the finding that motivated the cap.

That is survivable for GitHub because the diagram renders in a disposable cross-origin iframe. It
is not obviously survivable for us, because under Option 7 the memory lands in the webview the
user is reading and cannot be reclaimed without a reload that loses scroll position.

**Still open:** whether to accept GitHub parity and treat the memory peak as tolerable, or set a
tighter `maxEdges` than GitHub's 500. Recommend shipping at parity, measuring against real
documents during the soak, and tightening only if it bites — the flag is default-off precisely to
make that safe.

### `data:` URI cap — no GitHub value exists to copy

**GitHub strips `data:` URIs entirely.** `![x](data:image/png;base64,…)` renders as an `<img>`
with **no `src` attribute at all** (VERIFIED). There is no GitHub inline-image cap, because
GitHub does not support inline images.

So this number had to be invented. The nearest defensible analogue is **camo's 5 MiB per-image
limit** — verified against production: 5,237,557 bytes returns 200, 5,250,068 returns 404 with
body `Content length exceeded`, bracketing `CAMO_LENGTH_LIMIT` at 5,242,880.

**Decided 2026-07-28: 2 MiB per image, 16 MiB total per document**, deliberately undercutting
camo because inlining and proxying have different cost profiles — 2 MiB of image is ~2.7 MiB of
base64 carried in the document string. Oversized images render as a placeholder with the filename
and a click-to-open affordance. Recorded in the
[markdown display spec](2026-07-28-markdown-display-options-design.md), where image handling
lives.

### For reference — other GitHub limits found

Not needed for this document, but recorded so nobody re-researches them: the REST Markdown API
caps at exactly 409,600 bytes; the web UI gates on **rendered HTML size** (~505 KB, best estimate
512,000) rather than source size; files above ~2 MiB are not displayed at all. GitHub's
cmark-gfm carries `MAX_LIST_DEPTH` 100, `MAX_LINK_LABEL_LENGTH` 1000, `MAXBACKTICKS` 80.
**Decided 2026-07-28:**

- **`click … href` — allowed.** Rendered `<a xlink:href>` wrappers are kept. A clickable link in
  a diagram is treated exactly like a link in prose: the display view's navigation policy sends
  it to `NSWorkspace` rather than following it in place, so the reachable outcome is "opens in
  the user's browser," which markdown links already do. `click A "javascript:..."` is stripped by
  mermaid before this point, verified.
- **Error display — deferred.** Not specced in this round. The escaping requirement stands
  whenever it is: mermaid's parse errors echo attacker source verbatim, and comrak never sees
  that string, so escaping is ours. Until errors surface in the UI, a failed render falls back to
  the Option 5 source block with no mermaid-authored text displayed.

**Resolved by the move to Option 7:** dark mode. Colors no longer bake at render time — mermaid
re-initializes with a theme chosen from `prefers-color-scheme` at runtime, so diagrams follow
appearance with no dual render, no doubled bytes, and no media-gated wrappers. This was the
open question with the most UX weight under Option 1.

## To spike before implementing

Revised for Option 7. The windowless-rendering and offscreen-throttling spikes no longer apply —
mermaid runs in a visible webview.

- **Per-navigation JS toggling on a reused webview.** Load a mermaid document, then a plain one,
  then a mermaid one again, and confirm `allowsContentJavaScript` actually tracks each
  navigation — that JS is genuinely off for the plain document and genuinely on again afterward.
  This is load-bearing for the per-document gating and the field is known to have surprising
  live-consultation semantics.
- **Runtime theme switching**: mermaid re-`initialize` on a `prefers-color-scheme` change, with
  diagrams already on screen. This is what replaces the dual-render design, so it should be
  confirmed rather than assumed.
- **A real 20-diagram README end-to-end**: first-paint latency with the 3.5 MB bundle in the
  display path, and whether diagrams appearing after initial paint cause visible reflow or
  scroll jump.
- **`data:` URI cost** on an image-heavy README: document string size, parse time, memory.
- **DOM-serialization export**: confirm the snapshot is self-contained, contains no `<script>`,
  and excludes mermaid's leaked temp containers.
- **The mermaid.live deflate deep-link round-trip** (Option 5 floor).
- **Bundled-app behavior**: confirm the JS-enabled display view works inside the real
  `scripts/restart.sh`-bundled `.app`, not just a bare executable.
