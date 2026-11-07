// The app runner. It loads in <iframe sandbox="allow-scripts">, so its origin is opaque.
// It takes one `bundle` message from the loader, checks the bundle text against its
// SHA-256, gives the bundle `globalThis.tbdHost`, and starts it from a blob: URL.
//
// A classic script, not a module: a module script from an opaque origin would need CORS.
// Everything sits inside one function so that nothing here becomes a global the bundle
// can reach, the Trusted Types policy above all.
(() => {
  'use strict';
  // Do nothing unless this page is a frame whose origin is opaque, that is, sandboxed
  // without allow-same-origin. Any site can frame runner.html: a <meta> policy cannot
  // carry frame-ancestors, and Pages sends no X-Frame-Options. Framed without a sandbox,
  // the runner would hold the loader's origin, and a bundle posted by the framing page
  // would run with it and could read the loader's storage. Opened on its own, it has no
  // parent to take a bundle from.
  if (self.origin !== 'null' || parent === self) return;

  // 1. The nonce the loader put in this frame's URL. Without it, do nothing.
  const nonce = new URLSearchParams(location.hash.slice(1)).get('n');
  if (!nonce) return;

  // 2. The one Trusted Types policy this page's policy allows. It passes exactly one
  //    value, the blob: URL made in step 6, and refuses everything else.
  /** @type {string | null} */
  let bundleURL = null;
  const trustedTypes = /** @type {any} */ (globalThis).trustedTypes;
  const policy = trustedTypes
    ? trustedTypes.createPolicy('runner', {
      /** @param {string} u */
      createScriptURL(u) {
        if (bundleURL !== null && u === bundleURL) return u;
        throw new TypeError('runner: script URL refused');
      },
    })
    : null;

  // 3. Accept only the first message that passes every check, then stop listening.
  /** @param {MessageEvent} event */
  function onMessage(event) {
    if (event.source !== parent) return;
    const data = event.data;
    if (typeof data !== 'object' || data === null) return;
    if (data.type !== 'bundle' || data.nonce !== nonce) return;
    if (typeof data.text !== 'string') return;
    if (typeof data.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(data.sha256)) return;
    if (event.ports.length !== 1) return;
    window.removeEventListener('message', onMessage);
    start(event.ports[0], data.text, data.sha256);
  }
  window.addEventListener('message', onMessage);

  /**
   * Steps 4 to 6, for the one accepted message.
   * @param {MessagePort} port
   * @param {string} text
   * @param {string} sha256
   */
  async function start(port, text, sha256) {
    // 4. The text the script will run must be the text the loader checked. A digest
    //    that cannot be computed counts as a mismatch.
    let actual = '';
    try {
      actual = hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)));
    } catch {
      actual = '';
    }
    if (actual !== sha256) {
      port.postMessage({ t: 'fault', reason: 'hash' });
      return;
    }

    // 5. The bundle's one handle on the loader.
    Object.defineProperty(globalThis, 'tbdHost', {
      value: Object.freeze({ port, protocol: 1 }),
      writable: false,
      configurable: false,
      enumerable: false,
    });

    // 6. Run the bundle as a classic script from a blob: URL.
    const url = URL.createObjectURL(new Blob([text], { type: 'text/javascript' }));
    bundleURL = url;
    // A bundle that throws at its top level, or fails to parse, reports the error on
    // window, not on the script element, and the element's load still fires. So watch
    // window for an error from the bundle's URL until load or error. The listener only
    // reads the event, and it is gone before any later app error.
    let threw = false;
    /** @param {ErrorEvent} event */
    const onWindowError = (event) => {
      if (event.filename === url) threw = true;
    };
    window.addEventListener('error', onWindowError);
    const script = document.createElement('script');
    script.addEventListener('error', () => {
      window.removeEventListener('error', onWindowError);
      port.postMessage({ t: 'fault', reason: 'script' });
    });
    script.addEventListener('load', () => {
      window.removeEventListener('error', onWindowError);
      port.postMessage(threw ? { t: 'fault', reason: 'script' } : { t: 'started' });
      URL.revokeObjectURL(url);
    });
    // Engines without Trusted Types take the plain string.
    script.src = policy ? policy.createScriptURL(url) : url;
    document.head.append(script);
  }

  /** @param {ArrayBuffer} buffer */
  function hex(buffer) {
    return Array.from(new Uint8Array(buffer), (b) => b.toString(16).padStart(2, '0')).join('');
  }

  // 7. Tell the loader this frame is listening. The target is '*' because the runner has
  //    no reliable way to name the loader's origin; the nonce came from this frame's own
  //    URL, so the message reveals nothing new.
  parent.postMessage({ type: 'ready', nonce }, '*');
})();
