# Phone app stack: sandbox, framework, bundle, libraries, tests

The laptop-supplied app bundle should run in an `<iframe sandbox="allow-scripts">` whose `src` is a small static runner page on the loader's origin. The runner has its own `<meta>` CSP, receives the bundle text over `postMessage`, and starts it from a `blob:` URL that it creates itself. A `srcdoc` frame does not work: it inherits the loader's CSP, so its inline scripts and `blob:` scripts are blocked, and a stricter or looser `<meta>` inside it cannot undo that. Tests on 2026-11-07 in current WebKit and Chrome confirmed every step of the runner path: classic `blob:` scripts, `import()` of `blob:` modules, module scripts from a server that sends `Access-Control-Allow-Origin: *` (GitHub Pages does), MessageChannel transfer, Web Crypto inside the frame, and Trusted Types. They also showed one hole the sandbox does not close: a sandboxed frame can still navigate itself to any URL. The runner's CSP must name the loader origin explicitly instead of `'self'`, because WebKit changed what `'self'` means in a sandboxed document twice in 2026. For the UI, Preact 11 with htm gives a React-style component model in about 7 KB gzipped, with source that runs without a compile step. The bundle should be a committed, unminified single file built by esbuild, with a CI check that it matches the sources, so building TBD needs no Node. The minimal library set is Preact, htm and marked's lexer in the app, plus jsQR in the loader. Markdown is rendered from tokens into DOM nodes, never through HTML strings, so v1 needs no sanitizer, and Trusted Types enforce that rule in CI. Diffs and syntax highlighting are left out of v1. CI tests use Node's built-in `node:test` and Playwright on WebKit and Chromium, with shared Noise test vectors checked by both the Swift and the JS code.

Sources accessed 2026-11-07. Claims marked **(unverified)** could not be confirmed from a primary source or a test. This report builds on [phone-clients.md](phone-clients.md) and does not repeat its iOS PWA, storage and Web Crypto findings.

**How the sandbox claims were tested.** A local harness served a strict-CSP "loader" page and several sandboxed frames from `http://127.0.0.1`, with GitHub Pages' `Access-Control-Allow-Origin: *` header added. It ran in two engines. The first was the system WebKit of macOS 27.0.1, which is the engine of Safari 27.0.1, driven through `WKWebView`. The second was headless Chrome 156. Each test posted its result back to the server. Neither engine is iOS. Results for iOS 17 through 26 and for Android Chrome are **unverified** and are listed as on-device checks at the end. The harness is not committed. Its cases are described in section 1.1 so it can be rebuilt.

## 1. Running laptop-supplied code in an isolated frame

### 1.1 What the harness showed

Both engines gave the same result for every case.

- **`srcdoc` with an inline script** – Blocked. The frame inherits the loader's `script-src 'self'`.
- **`srcdoc` with its own permissive `<meta>` CSP** (`script-src 'unsafe-inline'`) – Still blocked. The inherited policy keeps applying.
- **`srcdoc` with `<script src>` from the loader origin** – Runs. The inherited `'self'` matches the loader origin.
- **`srcdoc` loading a `blob:` script** – Blocked, because the loader policy does not list `blob:`.
- **Runner page loaded by `src`, CSP naming the origin explicitly** – Its bootstrap script loads. `self.origin` is `"null"`, `isSecureContext` is true, and `crypto.subtle` works (AES-GCM encrypt succeeded).
- **Runner page loaded by `src`, CSP using `'self'`** – Also loads in these two builds. Section 1.3 explains why this is not safe to rely on.
- **Classic `<script src="blob:…">` created inside the runner** – Runs. The URL has the form `blob:null/<uuid>`.
- **`import()` of a `blob:` module that imports a second `blob:` module** – Runs.
- **`<script type="module" src="blob:…">`** – Runs.
- **Module script from the Pages-like origin, with `Access-Control-Allow-Origin: *`** – Runs.
- **The same module script without that header** – Fails, because a module fetch from an opaque origin is a CORS request.
- **Inline `<script>` added by the runner** – Blocked.
- **`new Function`** – Throws `EvalError` (no `'unsafe-eval'`).
- **Inline `<style>` element and a `style="…"` attribute** – Blocked (`style-src blob:` only).
- **Constructable stylesheet (`adoptedStyleSheets`)** – Applies. CSP does not govern it.
- **`<link rel="stylesheet" href="blob:…">`** – Applies.
- **`element.style.color = …` (CSSOM)** – Applies.
- **`fetch()` and a remote `<img>`** – Blocked by `connect-src 'none'` and `img-src data: blob:`.
- **`localStorage` and `indexedDB.open`** – Both throw `SecurityError`, as expected in an opaque origin.
- **Inline `<script type="importmap">` added by the runner** – Blocked by `script-src`, so the bare specifier failed to resolve.
- **Trusted Types** (`require-trusted-types-for 'script'; trusted-types runner`) – Enforced. A string assigned to `innerHTML` throws. A string assigned to `script.src` throws. A second policy, or a policy with an unlisted name, cannot be created. A `blob:` URL passed through the `runner` policy runs. `import()` with a string is allowed. `textContent` is unaffected.
- **`window.open` and top-level navigation** – `window.open` returns `null`. Setting `top.location` throws `SecurityError`.
- **The frame navigating itself to `/exfil?secret=demo`** – **Succeeded.** The server logged the request with its query string.

### 1.2 Why `srcdoc` does not work

- **A `srcdoc` document takes a copy of its parent's policy container**, which includes the CSP. The HTML standard says: "If responseURL is about:srcdoc: … Return a clone of parentPolicyContainer" ([HTML: determining navigation params policy container](https://html.spec.whatwg.org/multipage/browsers.html#policy-containers)). `blob:` and `data:` documents inherit from the initiator in the same way.
- **Policies only add up.** When several policies apply, "a potential connection would have to pass through both unscathed" ([CSP3 §8.1, The effect of multiple policies](https://w3c.github.io/webappsec-csp/#multiple-policies)). A `<meta>` inside the `srcdoc` can tighten the inherited policy but never loosen it. The harness confirmed this.
- **Hashes cannot help.** Each TBD build makes a different bundle. The loader is a static page, so its `<meta>` cannot list the hash of a bundle that does not exist yet. Adding a `<meta>` at runtime only adds another policy, which again can only tighten.
- **Loosening the loader instead is the wrong trade.** `srcdoc` works only if the loader's own policy allows everything the app needs: `blob:` scripts, styles and images. The loader holds the keys, so it should be the strictest page, not the most permissive one.

### 1.3 The runner page

The runner is a static `runner.html` plus `runner.js` on the loader origin. It is part of the audited loader, not part of the laptop's bundle.

- **It has its own policy.** A frame loaded by `src` gets its CSP from its own response. GitHub Pages sends no CSP header on normal pages (a test request on 2026-11-07 returned none), so only the runner's `<meta>` applies.
- **Name the origin, never `'self'`.** WebKit changed how `'self'` resolves in an opaque-origin http(s) document twice in 2026:
  - Change 314912@main fixed `'self'` handling for opaque documents. Its message says the old `schemeMatches()` "incorrectly allows HTTPS URLs to match" an opaque `'self'`. It first landed on a Safari release branch (`safari-7624.2.5.110`) ([WebKit commit 3ac584d](https://github.com/WebKit/WebKit/commit/3ac584d8fd7978a2c2751862e80687e982b5f9f7)).
  - That fix made `'self'` match nothing in a sandboxed document loaded over http(s): "Same-origin scripts, styles, images, and nested iframes all get refused." Change 315247@main repaired it on 2026-06-15 by resolving `'self'` against the response URL, and was committed to the `safari-7624.5` branch ([WebKit commit 01c89d1](https://github.com/WebKit/WebKit/commit/01c89d15c3f8e75934784f53bf7816bc6c6fb636), [WebKit bug 316847](https://bugs.webkit.org/show_bug.cgi?id=316847)).
  - Which iOS releases shipped which behavior is **unverified**. Some iOS 26 point release may have shipped the "matches nothing" version, which would break a runner that uses `'self'`. Earlier releases may have let `'self'` match any HTTPS URL, which weakens the policy. Writing `https://<org>.github.io` works under all three behaviors.
- **`blob:` URLs created inside an opaque frame used to fail in Safari.** [WebKit bug 170075](https://bugs.webkit.org/show_bug.cgi?id=170075) ("Cannot read blobs in sandboxed iframes") treated `blob:null/…` as untrustworthy content and blocked it as mixed content. It was fixed on 2021-03-04 ([commit c3c8cb4](https://github.com/WebKit/WebKit/commit/c3c8cb4b4b4f66d1a7909439cd2357025f568bb9)), with layout tests for a `blob:` URL used from an opaque-origin iframe and worker. Related fixes landed in 2021 ([bug 222312](https://bugs.webkit.org/show_bug.cgi?id=222312)) and 2022 ([commit 2953e99](https://github.com/WebKit/WebKit/commit/2953e9903dd4e68d615bdcd2047d1adbcbe2c816)). All predate iOS 17, so iOS 17 should behave like the harness. That is **unverified on a device**.
- **Do not add `allow-same-origin`.** The runner page has the loader's origin. The HTML standard warns that `allow-scripts` with `allow-same-origin` on a same-origin page "allows the embedded page to simply remove the sandbox attribute and then reload itself, effectively breaking out of the sandbox altogether" ([HTML: the iframe element](https://html.spec.whatwg.org/multipage/iframe-embed-object.html#attr-iframe-sandbox)). Without it, the frame cannot open the loader's IndexedDB. The harness confirmed `SecurityError`.
- **`blob:` beats `'unsafe-eval'`.** Both run code from text. `'unsafe-eval'` also enables every `eval`-like sink in every library, while `script-src blob:` lets only code that already runs make new scripts. Markup alone cannot create a `blob:` URL.

### 1.4 ES modules in an opaque-origin frame

- **They work, with one condition.** A module script is fetched in CORS mode, and the request's origin is `null`. The server must answer `Access-Control-Allow-Origin: *`. GitHub Pages does, as observed on 2026-11-07 on both a 200 response and a 404. The harness showed the module running with the header and failing without it.
- **`blob:` modules need no CORS.** The URL belongs to the same opaque origin that imports it. Both `import()` and `<script type="module" src="blob:…">` ran, including a `blob:` module that imported another by its absolute `blob:` URL.
- **Import maps do not fit a strict CSP.** An import map is an inline script. A runner that adds one at runtime is blocked unless the policy allows `'unsafe-inline'` or the map's hash. The harness confirmed it. External import maps are not supported. Import maps reached Safari in 16.4 ([MDN compat data for `<script type="importmap">`](https://github.com/mdn/browser-compat-data/blob/main/html/elements/script.json)).
- **A single classic script is the simplest payload.** One `blob:` URL, one `<script>` element, no module graph. Section 3 recommends producing exactly that.

### 1.5 The runner's policy

```html
<meta http-equiv="Content-Security-Policy" content="
  default-src 'none';
  script-src https://<org>.github.io blob:;
  style-src blob:;
  img-src data: blob:;
  connect-src 'none';
  base-uri 'none';
  form-action 'none';
  require-trusted-types-for 'script';
  trusted-types runner">
```

- **`default-src 'none'` and `connect-src 'none'`** – The app needs no network. All traffic goes through the loader. CSP3 notes that a policy without `default-src` "cannot mitigate exfiltration" ([CSP3 §8.6](https://w3c.github.io/webappsec-csp/#exfiltration)).
- **`img-src data: blob:`** – Remote images in markdown would leak that the user read a message, and when. The app shows a link instead.
- **Styles** – The bundle carries its CSS as text and applies it with a constructable stylesheet (`adoptedStyleSheets`, Safari 16.4 and Chrome 73, per [MDN compat data for `Document`](https://github.com/mdn/browser-compat-data/blob/main/api/Document.json)). The harness showed CSP does not govern that path. `style-src blob:` allows a `<link>` fallback. Inline `<style>` and `style=""` attributes stay blocked, but `element.style.x = …` works, and that is what Preact uses for object-valued `style` props.
- **Trusted Types** – Enforced from Safari 26 and Chrome 83, ignored by older browsers ([MDN compat data for CSP](https://github.com/mdn/browser-compat-data/blob/main/http/headers/Content-Security-Policy.json)). The runner creates the one allowed policy, `runner`, before the bundle starts, and that policy accepts only `blob:` script URLs. The bundle cannot create another policy, so every string-to-HTML sink throws. iOS 17 to 25 users get no enforcement on their device. The rule still protects them, because CI runs the same bundle under the same policy in Chromium and WebKit 27, and any code path that assigns HTML strings fails the tests.
- **Not available in `<meta>`** – `frame-ancestors`, `sandbox` and reporting directives are ignored in a `<meta>` policy ([MDN: CSP](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CSP)). The `sandbox` attribute on the `<iframe>` does the sandboxing.

### 1.6 Wiring the loader and the runner

1. **The loader creates the frame** – `<iframe sandbox="allow-scripts" src="runner.html#n=<random>">`, sized to the whole screen. No other sandbox keyword is needed. Leaving out `allow-popups`, `allow-forms`, `allow-modals`, `allow-downloads` and every `allow-top-navigation*` keyword keeps the frame from opening windows, submitting forms, showing `alert()`, downloading or moving the top page.
2. **The runner announces itself** – `parent.postMessage({ready, nonce}, '*')`. It echoes the nonce from its URL fragment. A page that later replaced the runner in that frame could not know the nonce.
3. **The loader checks the sender by identity, not by origin** – Every message from the frame arrives with `event.origin === "null"`, as the harness showed. The loader accepts a message only when `event.source === frame.contentWindow`, the nonce matches, and this is the frame's first `load`.
4. **The loader hands over a private channel** – It creates a `MessageChannel` and posts the bundle text, its SHA-256 and `port2` to the frame. The target origin must be `'*'`, because an opaque origin cannot be named. The bundle is not secret. Everything after this goes over the port. The harness confirmed port transfer in both engines.
5. **The runner starts the bundle** – It can re-check the SHA-256 with `crypto.subtle`, which works in the frame. It then wraps the text in a `Blob`, creates the URL through the `runner` policy, puts the port where the bundle can find it, and inserts one `<script>`.
6. **The loader treats a second `load` event on the frame as a fault** – It removes the frame and shows an error. See 1.7.

### 1.7 What the sandbox does not stop

- **A frame can navigate itself anywhere.** The harness frame set `location.href` to a URL with a query string, and the server received it. No sandbox keyword prevents a frame from navigating itself. CSP has no navigation directive in any shipping browser: `navigate-to` was dropped, and [MDN's compat data](https://github.com/mdn/browser-compat-data/blob/main/http/headers/Content-Security-Policy.json) lists no such directive. So the data in the app frame is protected by keeping hostile script out (CSP, Trusted Types, no HTML strings), not by the sandbox alone.
- **A tap on an ordinary link navigates the frame.** The app should never render `href` attributes. Links in the transcript become buttons that ask the loader, over the port, to open a URL. The loader shows the full URL and opens it with `noopener`. The `load` check in step 6 of 1.6 catches anything that slips through.
- **The app frame still controls agents.** It cannot read keys, but it can ask the loader to send messages to sessions, and a message to an agent can run commands on the laptop. A script injection in the app frame is therefore still serious. The sandbox removes key theft and cross-laptop access, not the need for safe rendering.
- **Denial of service stays possible.** Pathological markdown can freeze the frame (see the markdown advisories in 4.1). The laptop should cap the text it sends per item and serve the rest on request.

### 1.8 Viewport, keyboard and safe areas cross the frame boundary

- **Safe-area insets may read as zero inside the frame (unverified for iframes).** Orca's chat screen runs in a WebView, where `env(safe-area-inset-*)` "reports zero, so native publishes bar/cutout coverage in page px" ([Orca source](https://github.com/stablyai/orca/blob/c231b5d7da8cedf7c19261b756d8951550a37970/mobile/src/mobile-web-shell/bridge/bridge-safe-area-insets.ts#L7)). The CSS spec defines the insets against "the viewport" and says nothing about nested documents ([CSS Environment Variables](https://drafts.csswg.org/css-env-1/)). Design for zero. The loader reads its own insets with `viewport-fit=cover` and `env()`, and sends them over the port. The app sets them as CSS variables.
- **The keyboard shrinks the top-level visual viewport, not the frame.** On iOS, the keyboard shrinks only the visual viewport, and Chrome on Android has done the same since Chrome 108 ([Chrome blog: viewport resize behavior](https://developer.chrome.com/blog/viewport-resize-behavior)). A frame sized to the layout viewport does not shrink. The loader should listen to `visualViewport` `resize` and `scroll` and send the height and offset, and the app should place the composer from those numbers. Whether the frame's own `visualViewport` reports the keyboard is **unverified**.
- **The camera stays in the loader.** QR pairing runs in the loader, so the frame needs no `allow="camera"`.

### 1.9 Recommendation and device checks

Use a runner page loaded by `src` into `<iframe sandbox="allow-scripts">`, with the policy in 1.5, the wiring in 1.6, and the bundle started as one classic `blob:` script. Test on a real device:

- **iOS 17.x, 18.x and 26.x, both in a Safari tab and as a Home Screen app** – The runner's bootstrap loads with the explicit-origin policy. Also record whether a `'self'` variant loads, to learn which `'self'` behavior each release has.
- **Same devices** – A classic `blob:` script and an `import()` of a `blob:` module both run inside the frame.
- **Same devices** – Inline script, `new Function`, inline `<style>`, remote `<img>` and `fetch` are all blocked. `adoptedStyleSheets` applies.
- **iOS 26 and Android Chrome** – Trusted Types rejects `innerHTML` strings in the frame.
- **All devices** – MessageChannel transfer works and a 300 KB string crosses `postMessage` quickly.
- **All devices** – Focusing the composer inside the frame raises the keyboard. The loader's forwarded `visualViewport` numbers keep the composer visible. Note what the frame's own `visualViewport` reports.
- **Notched iPhone** – Record `env(safe-area-inset-*)` inside the frame, and check the forwarded values in portrait and landscape.
- **All devices** – A link tap is intercepted. A forced self-navigation fires a second `load`, and the loader tears the frame down.
- **Home Screen app** – After the app goes to the background and returns, the frame is still alive, or is rebuilt from the cached bundle.

## 2. UI framework, with no compile step for users

Sizes below were measured on 2026-11-07 from the published npm files, with `gzip -9`. Solid's files are unminified development builds, so they overstate a compiled app.

| Package (version) | File | Raw KB | Gzip KB |
|---|---|---|---|
| preact (11.2.0) | dist/preact.mjs | 12.0 | 5.0 |
| preact/hooks (11.2.0) | hooks/dist/hooks.mjs | 3.6 | 1.6 |
| htm (3.1.1) | dist/htm.module.js | 1.2 | 0.7 |
| htm/preact/standalone (3.1.1) | preact/standalone.module.js | 13.2 | 5.3 |
| lit-html (3.3.3) | lit-html.js | 7.3 | 3.2 |
| lit-core bundle (3.x) | lit-core.min.js | 15.7 | 6.1 |
| alpinejs (3.17.5) | dist/cdn.min.js | 55.9 | 19.9 |
| @alpinejs/csp (3.17.5) | dist/cdn.min.js | 72.2 | 23.9 |
| petite-vue (0.4.1) | dist/petite-vue.iife.js | 16.9 | 7.1 |
| solid-js (1.9.18) | solid.js + web.js, dev builds | 83.5 | 21.0 |

Maintenance facts come from the npm registry and the GitHub API on 2026-11-07. Advisory counts come from [OSV](https://osv.dev) for the npm ecosystem, all time.

- **Plain DOM and small helpers** – No dependency at all. The cost is code: a transcript that appends items, cards that appear and resolve, a session list that re-sorts on status changes, and a composer with its own state. Each needs hand-written update logic. That logic is easy to get wrong and hard to review. Fit: fine for the loader, which has three or four static screens. Weak for the app.
- **Preact + htm** – Preact is a React-style library with keyed list reconciliation and hooks.
  - **Size** – About 7.3 KB gzipped for Preact, hooks and htm together.
  - **License** – Preact MIT, htm Apache-2.0.
  - **Maintenance** – Preact 11.0.0 shipped on 2026-09-30 and 11.2.0 on 2026-11-06 ([releases](https://github.com/preactjs/preact/releases)). It publishes with npm provenance. htm's last release, 3.1.1, was in 2022. It is a small, finished parser with no advisories.
  - **Security** – Two Preact advisories. The recent one, [GHSA-36hm-qxxp-pg3m](https://osv.dev/vulnerability/GHSA-36hm-qxxp-pg3m), affected 10.26.5 to 10.28.1 and only apps that pass unvalidated objects where strings were expected. The lesson for TBD: validate the type of every field the laptop sends before it reaches the render tree.
  - **Format** – Preact 11 ships only ES modules: "The `.module.js`, CommonJS, and UMD bundles that Preact 10.x provided have been removed" ([Preact 11 upgrade guide](https://preactjs.com/guide/v11/upgrade-guide)). Preact 10.29.8 still has a UMD build. htm turns tagged templates into `h()` calls at runtime, so source runs in a browser without a compiler. It uses neither `eval` nor `innerHTML`, and Preact touches `innerHTML` only for `dangerouslySetInnerHTML` (checked by searching both builds). Do not use `htm/preact/standalone`, because it bundles a 2022 Preact 10.
  - **Fit** – Good. Keyed lists suit an append-only transcript. Components map one-to-one to the cards. Many contributors already know the React model.
- **Lit** – Web components with shadow DOM, or `lit-html` alone for templates.
  - **Size** – `lit-html` 3.2 KB gzipped, the full `lit-core` bundle 6.1 KB.
  - **License** – BSD-3-Clause.
  - **Maintenance** – 3.3.3 released 2026-05-14. The monorepo has 741 open issues and pull requests. No advisories.
  - **Format** – ES modules only.
  - **CSP** – `lit-html` creates a Trusted Types policy named `lit-html` and fills `<template>` elements through `innerHTML`. So the runner would need `trusted-types runner lit-html`, which weakens the "no HTML strings" rule.
  - **Fit** – Workable. Shadow DOM splits one theme across many style roots, and markdown output would need styles inside each one. It adds concepts without helping this app.
- **Alpine and petite-vue** – Attribute-driven libraries that evaluate expressions from the DOM.
  - **Alpine** – The standard build "violate[s] the 'unsafe-eval' Content Security Policy" ([Alpine: CSP](https://alpinejs.dev/advanced/csp)). The CSP build drops arrow functions, template literals, destructuring and global objects, and is 23.9 KB gzipped. MIT. Active, 3.17.5 on 2026-10-20.
  - **petite-vue** – "evaluates the expressions using `new Function()`… There is no plan to provide a CSP build" ([petite-vue README](https://github.com/vuejs/petite-vue#security-and-csp)). Its last release, 0.4.1, was in January 2022, and its issue tracker is disabled. MIT.
  - **Fit** – Poor. Evaluating expressions found in the DOM is the wrong model for a page that renders untrusted text.
- **Svelte and Solid** – Both need a compiler, so they could ship only as a committed artifact.
  - **Svelte** – 5.57.3, MIT, very active. 14 advisories, nearly all in server-side rendering, which TBD would not use. Size not measured.
  - **Solid** – 1.9.18 is stable and 2.0 is in release candidates, a major change to plan around. MIT. One advisory, fixed in 1.9.4.
  - **Fit** – Both are good at lists, but their source is not plain JavaScript, so a reviewer cannot compare it with what runs, and tests need the compiler.

**Recommendation: Preact 11.2.0 with `preact/hooks` and htm 3.1.1.** Write components as ES modules with `` html`…` `` templates and no JSX. Pin exact versions. If a regression appears in the young 11.x line, Preact 10.29.8 is a drop-in fallback for the API this app uses.

## 3. Bundle format and how it is produced

The app reaches the phone as one text payload, and building TBD must not need Node.

- **(a) Concatenate source files at TBD build time, in Swift or shell** – No generated file in git. What a reviewer reads is close to what ships.
  - **The catch** – Concatenation works only for classic scripts that share one global namespace, with no `import` or `export`. Stripping those keywords with a script is a home-made bundler built on regular expressions. It breaks on template strings and re-exports, and it cannot detect name collisions.
  - **The library problem** – Classic scripts need UMD builds. Preact 11 no longer has one (see section 2), so this choice pins the app to Preact 10.
  - **Tooling** – Editors, `node:test` and type checkers understand ES modules, not script order.
  - **Merges and reproducibility** – Merges are clean. The output is reproducible, because `cat` is deterministic.
- **(b) A committed single-file build from esbuild, with a CI freshness check** – Developers and CI run Node. TBD's build only copies the committed file into the install as a resource.
  - **Precedent** – GitHub's own template for JavaScript Actions commits a built `dist/` and runs a "Check Transpiled JavaScript" workflow that fails "if the checked-in `dist/` directory does not match what is expected from the build" ([actions/typescript-action `check-dist.yml`](https://github.com/actions/typescript-action/blob/main/.github/workflows/check-dist.yml)).
  - **Reproducibility** – esbuild treats determinism as a guarantee. Its changelog calls a cross-CPU float difference something that "breaks esbuild's guarantee of deterministic output" and fixes it ([esbuild changelog 2024](https://github.com/evanw/esbuild/blob/main/CHANGELOG-2024.md)). Pin the exact esbuild version in `package-lock.json`, and the CI check re-derives the file byte for byte.
  - **Reviewability** – Reviewers read the sources. The check proves the artifact matches them. Mark the file `linguist-generated=true` in `.gitattributes` to "keep certain files from displaying in diffs by default" ([GitHub Docs](https://docs.github.com/en/repositories/working-with-files/managing-files/customizing-how-changed-files-appear-on-github)).
  - **Merge conflicts** – Two branches that touch the phone code both change the file. Commit it **unminified**: esbuild then keeps each module as its own labelled section, so a change stays local, and git can often merge without a conflict. When a conflict does happen, rebuild and commit. Size is not a reason to minify. The bundle crosses the encrypted channel once per TBD version and is cached by hash.
  - **Supply chain** – esbuild has two advisories, both in its development server, which this flow never starts ([OSV: esbuild](https://osv.dev/list?q=esbuild&ecosystem=npm)).
- **(c) ES modules wired through an import map** – Several files, each turned into a `blob:` URL, with an import map that maps names to those URLs.
  - **Blocked by the strict CSP** – An import map is an inline script, so the runner cannot add one under the policy in 1.5. The harness confirmed this (section 1.4).
  - **The workaround is a bundler** – Rewriting import specifiers to `blob:` URLs means writing a module linker in the runner, which belongs to the audited loader.
  - **Benefit** – Keeping the files apart buys nothing on the phone.

**Recommendation: (b).** Concretely:

- **Build** – `esbuild src/main.js --bundle --format=iife --target=safari17,chrome120 --legal-comments=inline --outfile=dist/app.js`, without `--minify`. The `safari17` and `chrome120` targets are a starting point.
- **CI check** – `npm ci`, run the build, then `git diff --exit-code` on the output. Run it only when the phone directory changes.
- **Into the install** – TBD's Swift build copies `dist/app.js` as a SwiftPM resource of the target that serves it. The daemon hashes it at startup. Building TBD never runs Node.
- **Library inputs** – esbuild reads libraries from the vendored files in section 4.6, not from `node_modules`. npm then supplies only tools (esbuild and Playwright), and every byte of runtime code comes from files that are pinned in git.

## 4. Libraries

Measured like section 2. `marked` ships no minified build, and jsQR ships only an unminified one, so their numbers overstate a minified bundle.

| Package (version) | File | Raw KB | Gzip KB |
|---|---|---|---|
| marked (18.1.3) | lib/marked.esm.js | 49.7 | 15.0 |
| markdown-it (15.0.3) | dist/browser/markdown-it.umd.min.js | 100.8 | 40.6 |
| micromark (4.0.3) | esm.sh bundle, minified | 54.0 | 15.8 |
| snarkdown (2.0.0) | dist/snarkdown.umd.js | 2.1 | 1.1 |
| dompurify (3.4.17) | dist/purify.min.js | 29.8 | 11.7 |
| diff / jsdiff (9.0.0) | dist/diff.min.js | 37.2 | 9.9 |
| diff2html (3.4.56) | bundles/js/diff2html.min.js | 77.7 | 20.2 |
| prismjs core (1.30.0) | components/prism-core.min.js | 7.5 | 3.2 |
| highlight.js common (11.12.0) | highlight.min.js | 129.3 | 43.5 |
| jsqr (1.4.0) | dist/jsQR.js | 256.9 | 56.8 |
| qr-scanner (1.4.2) | main + worker | 59.8 | 15.9 |
| zxing-wasm reader (3.1.6) | JS + .wasm | 984.8 | 421.1 |

### 4.1 Markdown

The deciding design choice is to **render tokens, not HTML.** The app asks the parser for its token tree and builds Preact elements from it. Text always lands in text nodes. Raw HTML in the source is shown as literal text. A link becomes a button (see 1.7), and only `https:` and `http:` URLs are offered. No HTML string ever exists, so no sanitizer is needed, and the Trusted Types rule in 1.5 enforces this. react-markdown is built the same way and calls itself "safe by default (no `dangerouslySetInnerHTML` or XSS attacks)" ([react-markdown](https://github.com/remarkjs/react-markdown)).

- **marked** – A fast parser with GitHub-style tables and strikethrough built in. Its `marked.lexer()` returns a nested token tree that maps directly to components.
  - **Raw HTML** – There is no switch to turn it off. Raw HTML arrives as `html` tokens, which the renderer prints as text. "Marked does not sanitize the output HTML" ([marked docs](https://marked.js.org/)), which is irrelevant when `marked.parse()` is never called.
  - **License and maintenance** – MIT, very active (18.1.3 on 2026-11-02, with npm provenance). Majors come often, so pin and expect token-shape changes on upgrade.
  - **Security** – 13 advisories, mostly regular-expression denial of service. The latest is an out-of-memory recursion fixed in 18.0.2 ([GHSA-6v9c-7cg6-27q7](https://osv.dev/vulnerability/GHSA-6v9c-7cg6-27q7)).
  - **DOM use** – None: no `innerHTML` in the build.
- **markdown-it** – Strong defaults: `html: false` is the default, and its `validateLink` rejects `javascript:` and similar schemes ([README](https://github.com/markdown-it/markdown-it)). Its token stream is flat, with open and close tokens. MIT, active (15.0.3 on 2026-10-16). 8 advisories. Five were published in 2026, all denial-of-service bugs, the latest fixed in 15.0.3 ([OSV: markdown-it](https://osv.dev/list?q=markdown-it&ecosystem=npm)). At 40.6 KB gzipped it is the largest option, because it bundles an entity table, punycode and linkify.
- **micromark** – The most spec-faithful parser, with GitHub syntax as an extension. MIT, 4.0.3 on 2026-09-26, no advisories. It outputs HTML strings. Building a tree needs further packages (`mdast-util-from-markdown`). Its browser build decodes character references by assigning to `innerHTML` (visible in the bundle), which would throw under the runner's Trusted Types policy. It is published only as many small ES modules.
- **snarkdown** – 1.1 KB, but unsuitable. Text between matches is appended unescaped, so raw HTML passes straight through. Link targets are only quote-escaped, so `javascript:` URLs survive. It has no tables. Its last release was 2020, and its repository was last pushed in 2022 with 45 open issues and pull requests ([source](https://github.com/developit/snarkdown/blob/main/src/index.js)).

**Why parse on the phone and not on the laptop.** TBD's desktop transcript already parses markdown with apple/swift-markdown (cmark-gfm), but only in the app target. The daemon could send a ready-made syntax tree, and the phone would then need no parser. That would move parsing of untrusted text into the daemon, in C, inside TBD's most privileged process. The phone's sandboxed, memory-safe JavaScript frame is the better place for it, and plain text keeps the protocol small.

**Pick: marked 18.1.3, lexer only.**

### 4.2 Sanitizer

- **v1 needs none.** Under 4.1, no HTML string is produced. Trusted Types (1.5) makes any accidental `innerHTML` throw in CI and on Safari 26 or later.
- **DOMPurify, if a later feature needs HTML strings** – License `(MPL-2.0 OR Apache-2.0)`. Very active (3.4.17 on 2026-10-12). 33 advisories all time, 25 of them published in 2026 ([OSV: dompurify](https://osv.dev/list?q=dompurify&ecosystem=npm)). Judging by titles, most of the 2026 ones involve non-default modes: `IN_PLACE` sanitizing, hooks, `ADD_TAGS` and `ADD_ATTR` predicates, `SAFE_FOR_TEMPLATES`, and custom-element handling. One `IN_PLACE` advisory lists no fixed version ([GHSA-x4vx-rjvf-j5p4](https://osv.dev/vulnerability/GHSA-x4vx-rjvf-j5p4)). If it is ever added, use the default configuration with `RETURN_TRUSTED_TYPE`, never `IN_PLACE` or hooks, and keep it current. It would also need its own Trusted Types policy name in the runner's policy.
- **The Sanitizer API is not usable on iOS.** `Element.setHTML()` and `Sanitizer` shipped in Chrome 146 and Firefox 148. Safari has neither ([MDN compat data for `Element`](https://github.com/mdn/browser-compat-data/blob/main/api/Element.json), [for `Sanitizer`](https://github.com/mdn/browser-compat-data/blob/main/api/Sanitizer.json)).

### 4.3 Diffs for Edit tool calls

- **None in v1.** TBD's desktop Edit card shows `old_string` lines in red, then `new_string` lines in green, with no line diff ([`EditCardBody.swift`](../../../Sources/TBDApp/Panes/Transcript/EditCardBody.swift)). The phone can match that with no library. If a real line diff is wanted later, the laptop can compute it in Swift with the standard library's `CollectionDifference`, and the phone keeps rendering hunks.
- **jsdiff** – BSD-3-Clause, active (9.0.0 on 2026-04-13), 9.9 KB gzipped. Two advisories, the latest a denial of service in `parsePatch` and `applyPatch` fixed in 8.0.3 ([GHSA-73rr-hh4g-fpgx](https://osv.dev/vulnerability/GHSA-73rr-hh4g-fpgx)). It is the right tool if diffing ever moves to the phone.
- **diff2html** – MIT, 20.2 KB gzipped for the core, and its UI bundle is about 1 MB raw because it carries highlight.js. It produces HTML strings. No.

### 4.4 Syntax highlighting

- **None in v1.** Monospace text with horizontal scroll is enough to read code on a phone.
- **Prism** – MIT. The 1.x line's last release, 1.30.0, was on 2025-03-10. 2.0.0-alpha.1 appeared on 2026-09-08. The repository has 521 open issues and pull requests. 6 advisories, the latest a DOM-clobbering bug fixed in 1.30.0 ([GHSA-x7hr-w5r2-h6wg](https://osv.dev/vulnerability/GHSA-x7hr-w5r2-h6wg)). Its core is 3.2 KB gzipped, plus one file per language. `Prism.highlight()` returns HTML, but `Prism.tokenize()` returns tokens that can be rendered as elements, which fits the no-HTML rule. Prism core with a few languages, through `tokenize()`, is the path if highlighting is added later.
- **highlight.js** – BSD-3-Clause, active (11.12.0 on 2026-08-12), but 43.5 KB gzipped for the common bundle. Its public API returns HTML strings.

### 4.5 QR scanning inside the loader

- **`BarcodeDetector` is not on iOS.** It is behind a flag in Safari from 17, and on by default in Chrome Android from 83 ([MDN compat data](https://github.com/mdn/browser-compat-data/blob/main/api/BarcodeDetector.json)). Use it where present.
- **jsQR** – Apache-2.0. Last release 1.4.0 in April 2021, last commit August 2021, 98 open issues and pull requests. It is effectively unmaintained, with no advisories. It is a pure function from pixels to text, with no DOM or network use and readable unminified source: 256.9 KB raw, 56.8 KB gzipped, 33.2 KB with brotli. Load it only on the pairing screen, and decode a downscaled frame a few times a second.
- **qr-scanner (nimiq)** – MIT. It is built on jsQR's port of ZXing and "uses the browser's native BarcodeDetector if available" ([README](https://github.com/nimiq/qr-scanner)). It is smaller (15.9 KB gzipped with its worker) and decodes in a Web Worker. But its last release was in November 2022, its repository was last pushed in March 2024 with 119 open issues and pull requests, and it ships minified, closure-compiled code that is harder to audit.
- **zxing-wasm** – MIT. Active (3.1.6 on 2026-10-19), and the `barcode-detector` polyfill builds on it. Its reader `.wasm` is 947 KB raw and 408 KB gzipped. The loader's CSP would need `'wasm-unsafe-eval'` (Safari 16 and later), and a 947 KB binary cannot be audited by reading it. That conflicts with a loader that must stay small and readable.

**Pick: native `BarcodeDetector` when present, otherwise jsQR 1.4.0, plus a typed-code fallback.** The pairing code is short and is shown on a laptop screen, which is an easy scanning case.

### 4.6 Minimal v1 set and vendoring policy

The minimal set is:

- **App bundle** – `preact` 11.2.0 (`preact.mjs`, `hooks.mjs`), `htm` 3.1.1 (`htm.module.js`) and `marked` 18.1.3 (`marked.esm.js`). That is about 22 KB gzipped of libraries, before app code.
- **Loader** – `jsqr` 1.4.0 (`jsQR.js`), loaded only on the pairing screen. Everything else in the loader is TBD's own code.

The vendoring policy:

- **Layout** – One directory per library and version, under a vendor directory. It holds the exact distributed files, the upstream license file and any `NOTICE` file. Never a modified copy.
- **Lock file** – A `vendor.lock` lists, for each library: name, version, the registry tarball URL, the registry's `dist.integrity` value (a SHA-512 subresource-integrity string that the npm registry publishes for every version), and the SHA-256 of each vendored file.
- **Update script** – A shell script (`curl`, `tar`, `shasum`, no Node) takes a name and a version. It reads the registry metadata, downloads the tarball, checks it against `dist.integrity`, extracts the listed files, copies the license, and rewrites the lock entry. Also record whether the version carries npm provenance. `preact` and `marked` do; `htm` and `jsqr` do not.
- **Checks** – A CI step re-hashes every vendored file against `vendor.lock`. It needs no Node, so it can run in TBD's existing lint job. A scheduled job queries [OSV's API](https://google.github.io/osv.dev/api/) for each `name@version` in the lock and fails on a hit. Dependabot cannot see vendored files, so this replaces it.
- **Rules** – No CDN at runtime. No library in the loader that is not in the lock. Upgrade on any advisory. Review any upgrade of a loader library like a change to the loader itself.

## 5. Testing the phone code in CI

TBD's build stays Node-free. These jobs run only in CI and on developer machines, and only when the phone directories change. TBD's workflows already use `ubuntu-latest` for most jobs and `macos-26` for Swift.

- **Unit tests: Node's built-in `node:test`** – The test runner "is now stable" since Node 20 ([Node docs: test runner](https://nodejs.org/api/test.html)). It has mocks, fake timers and snapshots, and needs no dependency. Test pure modules with it: the message codec, the Noise state machine, the markdown token-to-element mapping (checking a plain object tree, not a DOM), and the session and transcript reducers. Pin Node with a `.node-version` file.
- **Vitest** – Capable, but a large dependency tree for this size of code. It has had three advisories in its UI and API servers ([OSV: vitest](https://osv.dev/list?q=vitest&ecosystem=npm)). Not needed.
- **Deno** – `deno test` runs the same ES modules with no `package.json`. It is a reasonable alternative to Node for unit tests. But Playwright needs Node anyway, so one runtime is simpler.
- **DOM tests: skip fake DOMs.** happy-dom has 8 advisories, including a VM-context escape to remote code execution ([GHSA-37j7-fg3j-429f](https://osv.dev/vulnerability/GHSA-37j7-fg3j-429f)) and a 2026 incomplete fix ([GHSA-834v-8h66-3h79](https://osv.dev/vulnerability/GHSA-834v-8h66-3h79)). Those matter only for untrusted code, but they reflect the project. jsdom (31.0.0) has no advisories but is heavy. Either way, a fake DOM is not WebKit. The sandbox, CSP, Trusted Types and layout behavior that matter here exist only in real engines. Do DOM-level tests in Playwright instead.
- **Browser tests: Playwright 1.65.0** – Released 2026-11-05 with WebKit 27.2, Chromium 158 and Firefox 159 ([release notes](https://github.com/microsoft/playwright/releases/tag/v1.65.0)). `@playwright/test` depends only on `playwright`, which depends only on `playwright-core`.
  - **How close WebKit is to iOS Safari** – "Playwright's WebKit is derived from the latest WebKit main branch sources," often ahead of Safari. It does not drive branded Safari. "Available media codecs vary substantially between Linux, macOS and Windows." For the closest match, run WebKit on a Mac ([Playwright: browsers](https://playwright.dev/docs/browsers)). Mobile support is emulation of viewport, user agent and touch, not iOS. No software keyboard, safe areas, Home Screen storage, or iOS scroll physics. So it is good for engine behavior (CSP, sandbox, Trusted Types, Web Crypto, modules) and useless for keyboard and viewport layout.
  - **What to run** – Two projects on `ubuntu-latest`: Chromium with a Pixel device profile and WebKit with an iPhone profile. Serve the real loader and runner from a local static server, with a scripted fake laptop on the other end of the protocol. Assert the full flows (session list, transcript, answering a prompt, sending a message, new worktree). Also run the security cases from 1.1 as regression tests: inline script blocked, `innerHTML` throws, `fetch` blocked, a second `load` tears the frame down.
- **Closer to iOS (optional, nightly)** – `safaridriver` can drive Safari in the iOS Simulator. With `platformName` set to `iOS`, "safaridriver will only create a session on a paired iOS device or simulator," and `safari:useSimulator` restricts it to Simulator hosts (`man safaridriver`, macOS 27). On a `macos-26` runner with Xcode, a small WebDriver smoke test would run the real Mobile Safari engine. Whether hosted runners include an iOS 17 Simulator runtime is **unverified**.
- **Cross-language Noise vectors** – Commit one vector file that both the Swift and the JS code must pass.
  - **Third-party vectors** – The [cacophony](https://github.com/haskell-cryptography/cacophony) vector file (Unlicense) includes `Noise_IKpsk2_25519_AESGCM_SHA256`, in the standard [Noise test-vector format](https://github.com/noiseprotocol/noise_wiki/wiki/Test-vectors): fixed static, ephemeral and PSK keys, a prologue, messages with payloads and ciphertexts, and the final handshake hash.
  - **If the spec picks another suite** – The DH names in the Noise spec are only 25519 and 448. A P-256 suite has no public vectors, so TBD would have to generate its own and should say so.
  - **TBD's own vectors** – Add vectors for TBD's framing: envelope layout, nonce counters, rekeying, and rejection of a flipped tag or a wrong PSK. Generate them once from the Swift side, commit them, and require both sides to pass.
  - **Where each side runs** – The Swift side runs in TBD's existing `scripts/test.sh` suite, with no Node. The JS side runs in `node:test` and again inside Playwright WebKit. Node's Web Crypto has algorithms Safari lacks (for example ChaCha20-Poly1305 since Node 24.7, per [Node docs: Web Crypto](https://nodejs.org/api/webcrypto.html)), so a JS crypto test that passes only in Node proves nothing about the phone.

**Lean setup:** Node (pinned) with `node:test`, `@playwright/test` 1.65.0 for WebKit and Chromium on `ubuntu-latest`, esbuild for the freshness check, and no fake DOM and no test framework beyond those.

## 6. Mobile UI patterns for an agent transcript

This section draws on Happy's Expo app, read at [`b5acacf`](https://github.com/slopus/happy/tree/b5acacffc1a6b1a8643c565e1b8a14aa8369ea81/packages/happy-app/sources), the last commit before Happy deleted it in favor of native Swift and Kotlin apps on 2026-11-05 ([`e46a907`](https://github.com/slopus/happy/commit/e46a907d269ac87e3c1836e9ff1f9f48e87cbc01)). It also draws on Orca's mobile app at [`c231b5d`](https://github.com/stablyai/orca/tree/c231b5d7da8cedf7c19261b756d8951550a37970/mobile), and on Anthropic's public docs for the Claude app's Remote Control. Orca is the closest match to TBD's plan: its phone chat screen is a web bundle served by the desktop app and shown in a WebView ([`bundled-mobile-web-bundle.ts`](https://github.com/stablyai/orca/blob/c231b5d7da8cedf7c19261b756d8951550a37970/src/main/runtime/bundled-mobile-web-bundle.ts#L16-L29)).

### 6.1 Tool calls and long output

- **Fold a finished turn** – Happy folds a finished turn's intermediate work into one "Worked 2m 13s" row above the final answer ([`useGroupedMessages.ts`](https://github.com/slopus/happy/blob/b5acacffc1a6b1a8643c565e1b8a14aa8369ea81/packages/happy-app/sources/hooks/useGroupedMessages.ts#L29-L38)). Orca turns consecutive calls into one sentence, such as "Read 3 files, ran 2 commands", with failure counts and a check mark ([`native-chat-tool-run-sentence.ts`](https://github.com/stablyai/orca/blob/c231b5d7da8cedf7c19261b756d8951550a37970/src/shared/native-chat/tools/native-chat-tool-run-sentence.ts#L11-L27)). Both fit a "finished items only" transcript well.
- **One line per call** – Orca's expanded line shows a verb, a tappable path, the exit code (red when not zero), the duration and a copy button ([`MobileNativeChatToolLine.tsx`](https://github.com/stablyai/orca/blob/c231b5d7da8cedf7c19261b756d8951550a37970/mobile/src/session/native-chat/transcript/MobileNativeChatToolLine.tsx#L219-L275)).
- **Truncate, then fetch on demand** – Orca cuts output at 4,000 characters ([`native-chat-tool-summary.ts`](https://github.com/stablyai/orca/blob/c231b5d7da8cedf7c19261b756d8951550a37970/src/shared/native-chat/tools/native-chat-tool-summary.ts#L27)). "Show full output" fetches the rest from the desktop, says "Showing X of Y" when even that is cut, and offers a retry ([`MobileNativeChatFullContent.tsx`](https://github.com/stablyai/orca/blob/c231b5d7da8cedf7c19261b756d8951550a37970/mobile/src/session/native-chat/MobileNativeChatFullContent.tsx#L117-L151)). Happy instead prints the whole output in one block on a detail page ([`CodeView.tsx`](https://github.com/slopus/happy/blob/b5acacffc1a6b1a8643c565e1b8a14aa8369ea81/packages/happy-app/sources/components/CodeView.tsx#L10-L19)), which does not scale.
- **Pitfalls** – Rows of 26 to 28 pt (Orca, Happy) are below Apple's 44 pt default. Orca's expanded group scrolls inside the chat's own scroller, which is awkward on a phone. Track expanded groups as "opened", not "closed", or each new group flashes open for a frame ([Happy: chat-list-scrolling.md](https://github.com/slopus/happy/blob/b5acacffc1a6b1a8643c565e1b8a14aa8369ea81/docs/chat-list-scrolling.md#L205-L222)).

### 6.2 Prompt and permission cards

- **Dock the card above the composer** – Orca puts the card in its own area above the composer, at most 60% of the space, so some of the conversation stays visible. It can collapse to a strip without losing half-made choices ([`MobileNativeChatPromptCard.tsx`](https://github.com/stablyai/orca/blob/c231b5d7da8cedf7c19261b756d8951550a37970/mobile/src/session/native-chat/input/MobileNativeChatPromptCard.tsx#L148-L261)).
- **Questions** – Orca shows several questions as tabs with checks, an "Other…" free-text row, a "2/3" step indicator, and auto-advance for single choice ([`MobileNativeChatAsk.tsx`](https://github.com/stablyai/orca/blob/c231b5d7da8cedf7c19261b756d8951550a37970/mobile/src/session/native-chat/input/MobileNativeChatAsk.tsx#L213-L332)). Happy's inline form has 44 pt rows and shrinks to a "Header: answer" summary once answered ([`InlineQuestionForm.tsx`](https://github.com/slopus/happy/blob/b5acacffc1a6b1a8643c565e1b8a14aa8369ea81/packages/happy-app/sources/components/tools/views/InlineQuestionForm.tsx#L101-L116)).
- **Permissions** – Copy the CLI's own option wording, as Happy does ([`_default.ts`](https://github.com/slopus/happy/blob/b5acacffc1a6b1a8643c565e1b8a14aa8369ea81/packages/happy-app/sources/text/_default.ts#L1084-L1087)). Use 44 pt buttons that wrap, with one filled primary, as Orca does ([`MobileNativeChatPermission.tsx`](https://github.com/stablyai/orca/blob/c231b5d7da8cedf7c19261b756d8951550a37970/mobile/src/session/native-chat/input/MobileNativeChatPermission.tsx#L67-L183)). Always show the full command or diff, wrapped. Happy clips a pending shell command to one line above its Allow buttons, so a user can approve what they cannot read (reading of the code, **unverified** in use).
- **Receipts and other devices** – Leave a receipt in the transcript saying where the prompt was answered ("this phone", "the computer") ([Orca](https://github.com/stablyai/orca/blob/c231b5d7da8cedf7c19261b756d8951550a37970/mobile/src/session/native-chat/MobileNativeChatResolutionReceipt.tsx#L44-L56)). Close an open card when the prompt is answered elsewhere ([Happy](https://github.com/slopus/happy/blob/b5acacffc1a6b1a8643c565e1b8a14aa8369ea81/packages/happy-app/sources/components/AgentQuestionBanner.tsx#L17-L46)). For a kind the app cannot draw, say "answer on the laptop" instead of hiding it.
- **Claude app, from public docs and bug reports** – Permission prompts and `AskUserQuestion` stay open until answered ([Remote Control docs](https://code.claude.com/docs/en/remote-control)). User reports describe the question card taking over the input area ([#103619](https://github.com/anthropics/claude-code/issues/103619)), several questions shown in reverse order ([#107108](https://github.com/anthropics/claude-code/issues/107108)), and a scroll-to-bottom button covering Submit ([#65468](https://github.com/anthropics/claude-code/issues/65468)). These are reports, **unverified**. Each is a pitfall worth avoiding.

### 6.3 Composer and keyboard

- **16 px text** – Both Happy and Orca use 16 px. Orca's comment says it is "to stay above iOS's focus-zoom floor" ([Orca `composer-input-styles.ts`](https://github.com/stablyai/orca/blob/c231b5d7da8cedf7c19261b756d8951550a37970/mobile/src/components/composer-input/composer-input-styles.ts#L4-L8)). No Apple or WebKit page documenting the zoom was found (**unverified** as a primary source), but both apps rely on it.
- **Enter makes a newline on touch** – Send with the button. Happy keeps Enter-to-send when a hardware keyboard is detected with `(pointer: coarse)` ([`AgentInput.tsx`](https://github.com/slopus/happy/blob/b5acacffc1a6b1a8643c565e1b8a14aa8369ea81/packages/happy-app/sources/components/AgentInput.tsx#L1467-L1473)). Skip keys typed during IME composition ([Orca](https://github.com/stablyai/orca/blob/c231b5d7da8cedf7c19261b756d8951550a37970/mobile/src/session/native-chat/composer/MobileNativeChatComposerField.web.tsx#L17-L125)).
- **Keyboard height** – Orca computes `innerHeight - (visualViewport.height + offsetTop)` on both `resize` and `scroll`, and ignores readings while the page is pinch-zoomed ([`keyboard-occlusion.web.ts`](https://github.com/stablyai/orca/blob/c231b5d7da8cedf7c19261b756d8951550a37970/mobile/src/platform/keyboard-occlusion.web.ts#L10-L53)). In TBD the loader computes this and forwards it into the frame (1.8).
- **Missing on iOS** – `interactive-widget` exists only in Chrome Android 108 and Firefox Android 133 ([MDN compat data](https://github.com/mdn/browser-compat-data/blob/main/html/elements/meta/name/viewport/interactive-widget.json)). The VirtualKeyboard API and `env(keyboard-inset-*)` exist only in Chrome ([MDN](https://developer.mozilla.org/en-US/docs/Web/API/VirtualKeyboard)).
- **Viewport units** – `dvh`, `svh` and `lvh` arrived in Safari 15.4 and Chrome 108 ([web.dev](https://web.dev/blog/viewport-units)). They ignore the keyboard. Size the frame with `100dvh` in the loader. Inside the app, use the forwarded numbers.

### 6.4 Scrolling the transcript

- **Scroll anchoring is new in Safari.** `overflow-anchor` reached Safari only in 27 ([MDN compat data](https://github.com/mdn/browser-compat-data/blob/main/css/properties/overflow-anchor.json)), so iOS 17 to 26 have no scroll anchoring. Do not depend on it.
- **Two workable patterns.** The first is a `flex-direction: column-reverse` scroller with `overflow-anchor: none`, as Orca uses ([`MobileNativeChatPageScroll.tsx`](https://github.com/stablyai/orca/blob/c231b5d7da8cedf7c19261b756d8951550a37970/mobile/src/session/native-chat/transcript/MobileNativeChatPageScroll.tsx#L7-L41)). The newest item sits at `scrollTop` 0 and older content at negative offsets. The second is a normal scroller that pins to the bottom only when the reader is already within a few pixels of it. Happy measured why the reversed list wins with a keyboard: in a normal list, raising the keyboard pushed the newest message 582 pt out of view, while in the reversed list it moved 0 ([chat-list-scrolling.md](https://github.com/slopus/happy/blob/b5acacffc1a6b1a8643c565e1b8a14aa8369ea81/docs/chat-list-scrolling.md#L94-L123)).
- **Pitfall** – Do not flip a list with `scaleY(-1)`. Happy had to correct reversed mouse-wheel scrolling on web ([`invertedChatWheel.ts`](https://github.com/slopus/happy/blob/b5acacffc1a6b1a8643c565e1b8a14aa8369ea81/packages/happy-app/sources/utils/invertedChatWheel.ts#L1-L8)). A collapse toggle can push the tapped row off screen. Happy adds a second toggle at the bottom of an expanded group.

### 6.5 Session list

- **Grouping** – Happy groups by machine, then project, then worktree ([`sessionDisplayOrder.ts`](https://github.com/slopus/happy/blob/b5acacffc1a6b1a8643c565e1b8a14aa8369ea81/packages/happy-app/sources/utils/sessionDisplayOrder.ts#L92-L96)). Orca can group by repo, workspace status or PR status ([`workspace-list-sections.ts`](https://github.com/stablyai/orca/blob/c231b5d7da8cedf7c19261b756d8951550a37970/mobile/src/worktree/workspace-list-sections.ts#L211-L273)). TBD's v1 plan to group by repo matches.
- **Status chips need text, not just colour** – Happy pairs colour with text ("permission required" in orange) ([`sessionUtils.ts`](https://github.com/slopus/happy/blob/b5acacffc1a6b1a8643c565e1b8a14aa8369ea81/packages/happy-app/sources/utils/sessionUtils.ts#L36-L90)). Orca draws "waiting", "blocked" and "failed" as the same 10 px red dot, and uses 10 to 11 px meta text ([`AgentStateDot.tsx`](https://github.com/stablyai/orca/blob/c231b5d7da8cedf7c19261b756d8951550a37970/mobile/src/components/AgentStateDot.tsx#L11-L82)). Avoid both habits.
- **Stale state** – Orca shows "No recent update" with a dashed ring when a heartbeat is old, rather than claiming the agent still works ([`agent-row-display.ts`](https://github.com/stablyai/orca/blob/c231b5d7da8cedf7c19261b756d8951550a37970/mobile/src/worktree/agent-row-display.ts#L38-L42)). This matters for TBD, because the phone drops its socket in the background.

### 6.6 Safe areas, tap targets and dark mode

- **Safe areas** – `env(safe-area-inset-*)` is non-zero only with `viewport-fit=cover` ([WebKit: Designing websites for iPhone X](https://webkit.org/blog/7929/designing-websites-for-iphone-x/)). Set it on the loader, and pad for the insets in one place only, because double padding is a common bug. Forward them into the frame (1.8).
- **Tap targets** – Apple's default is 44×44 pt, with 28×28 pt as the minimum ([HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)). WCAG 2.5.8 (AA) asks for 24×24 CSS px ([W3C](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html)), and 2.5.5 (AAA) for 44×44 ([W3C](https://www.w3.org/WAI/WCAG22/Understanding/target-size-enhanced.html)). Use 44 px for every primary action: Allow, Deny, send, and question options.
- **Dark mode** – Use `prefers-color-scheme` and `<meta name="color-scheme" content="light dark">`. From Safari 26, `theme-color` "is only used for installed web apps" ([MDN compat data for `<meta>`](https://github.com/mdn/browser-compat-data/blob/main/html/elements/meta.json)), which is TBD's case. The loader and the frame must agree on the background colour, or the safe-area strips show a seam. The loader should forward the scheme along with the insets.

## Recommended v1 stack

- **Isolation mechanism** – A static `runner.html` and `runner.js` on the loader's origin, loaded with `src` into `<iframe sandbox="allow-scripts">` with no other keywords. The runner's `<meta>` CSP is the one in 1.5. It names `https://<org>.github.io` explicitly, never `'self'`, and enforces Trusted Types with one `runner` policy. The loader posts the bundle text, its SHA-256 and a `MessageChannel` port, after checking `event.source` and a fragment nonce. The runner starts the bundle as one classic script from a `blob:` URL it creates itself. No `srcdoc`, no `'unsafe-eval'`, no import maps. The loader forwards insets, `visualViewport` metrics and the color scheme, opens links on request, and tears the frame down on a second `load`.
- **Loader framework** – None. Plain DOM, with ES modules served exactly as committed.
- **App framework** – Preact 11.2.0 (with `preact/hooks`) and htm 3.1.1. Templates are tagged templates, never JSX.
- **Bundle format** – One unminified IIFE file built by esbuild 0.28.2 (exact pin), committed to git, marked `linguist-generated=true`, checked in CI with `npm ci && build && git diff --exit-code`, and copied into the TBD install as a SwiftPM resource. Building TBD runs no Node.
- **Libraries (vendored, pinned, checksummed)**:
  - **preact 11.2.0** (MIT) – UI.
  - **htm 3.1.1** (Apache-2.0) – Templates.
  - **marked 18.1.3** (MIT) – Markdown, lexer only, rendered from tokens to elements.
  - **jsqr 1.4.0** (Apache-2.0) – QR decoding in the loader, used only when `BarcodeDetector` is missing.
  - **Not in v1** – No sanitizer (no HTML strings exist), no diff library (old and new blocks, as on the desktop), no syntax highlighter. If added later: DOMPurify 3.4.x with its default config, jsdiff 9.x, and Prism core through `tokenize()`.
- **Vendoring** – Distributed files, the upstream license and `NOTICE`, and a `vendor.lock` with registry `dist.integrity` and per-file SHA-256. A shell update script (`curl`, `tar`, `shasum`). A CI checksum step. A scheduled OSV query per pinned version.
- **Tests** – `node:test` on a pinned Node for pure modules. `@playwright/test` 1.65.0 with WebKit (iPhone profile) and Chromium (Pixel profile) on `ubuntu-latest`, serving the real loader and runner against a scripted fake laptop. Regression tests for every sandbox and CSP case in 1.1. No fake DOM. Noise vectors from cacophony's `Noise_IKpsk2_25519_AESGCM_SHA256` plus TBD's own framing vectors, checked by Swift in `scripts/test.sh`, by `node:test`, and inside Playwright WebKit. Optionally, a nightly `safaridriver` smoke test in the iOS Simulator on `macos-26`.
- **UI patterns** – Fold finished tool calls into one summary line per turn. Truncate output and fetch the rest on demand. Dock prompt cards above the composer with full, wrapped commands. Use 44 px primary targets, 16 px composer text, a `column-reverse` transcript or manual bottom pinning, status chips with text, and a "no recent update" state.

**On-device checks before building on this:**

- iOS 17, 18 and 26, in a Safari tab and as a Home Screen app: the runner loads under the explicit-origin policy. Also record whether a `'self'` variant loads.
- The same devices: classic `blob:` script and `import()` of a `blob:` module run in the frame. Inline script, `new Function`, inline style, remote image and `fetch` are blocked. `adoptedStyleSheets` applies.
- iOS 26 and Android Chrome: Trusted Types makes `innerHTML` strings throw in the frame.
- MessageChannel transfer and a 300 KB bundle string over `postMessage`.
- The keyboard and the composer inside the frame: what the frame's own `visualViewport` reports, and whether the forwarded numbers keep the composer visible while typing.
- `env(safe-area-inset-*)` inside the frame on a notched iPhone in both orientations, against the loader's forwarded values.
- A link tap is intercepted, and a forced self-navigation fires a second `load` that the loader catches.
- Leaving the Home Screen app and returning: the frame survives, or rebuilds from the cached bundle without a visible flash.
- QR pairing: jsQR on an iPhone at a few frames per second reads the laptop's code in normal room light. `BarcodeDetector` is used on Android.
- The 16 px composer does not trigger zoom on focus.
