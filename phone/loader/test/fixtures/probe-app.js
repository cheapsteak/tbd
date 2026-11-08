// The probe bundle: checks, from inside the app frame, what the runner's sandbox and policy
// allow (plan 5 Task 18). A classic script, plain text.
//
// After the first `{t:'channel', state:'up'}` it runs every case, waits up to 2 s for the image,
// `fetch`, IndexedDB and worker outcomes, writes the results as text into `<pre id="results">`,
// and sends them to the laptop as event `probe.results`. Each result is `{ ok, detail }`, where
// `ok` means the expected outcome happened.
//
// Several cases deliberately use a sink the loader bans (`innerHTML`, `new Function`, a script
// element's text and `src`, a `style` attribute, a worker URL). Each sits inside `try`, with a
// comment, and is expected to be refused.
//
// For checks on a device it also shows a 16 px text field, the last env values, and three
// controls: open https://example.com through the loader, navigate this frame, and a plain link.
(() => {
  'use strict';
  // Read at the top level: `document.currentScript` is null inside callbacks.
  const ownScript = document.currentScript;
  const port = globalThis.tbdHost.port;
  const WAIT_MS = 2_000;

  /** @typedef {{ ok: boolean, detail: string }} Result */

  const results = /** @type {Record<string, Result>} */ ({});
  const resultsPre = document.createElement('pre');
  resultsPre.id = 'results';
  resultsPre.textContent = 'Waiting for the laptop…';
  const envPre = document.createElement('pre');
  envPre.id = 'env';
  envPre.textContent = 'No env yet';
  const field = document.createElement('textarea');
  field.id = 'typing';
  field.rows = 3;
  // Through the CSSOM, which the runner's policy allows (the `cssomStyle` case).
  field.style.fontSize = '16px';
  const openButton = button('Open https://example.com through the loader', () => {
    port.postMessage({ t: 'openLink', url: 'https://example.com/' });
  });
  const navigateButton = button('Navigate this frame', () => {
    location.href = '/__test/nav?x=1';
  });
  const plainLink = document.createElement('a');
  plainLink.id = 'plain-link';
  plainLink.href = '/__test/anchor';
  plainLink.textContent = 'Plain link';
  document.body.append(resultsPre, envPre, field, openButton, navigateButton, plainLink);

  let started = false;
  port.onmessage = (event) => {
    const message = event.data;
    if (message === null || typeof message !== 'object') return;
    if (message.t === 'env') {
      envPre.textContent = JSON.stringify({
        safeArea: message.safeArea, viewport: message.viewport, layout: message.layout, colorScheme: message.colorScheme,
      }, null, 2);
    } else if (message.t === 'channel' && message.state === 'up' && !started) {
      started = true;
      runAll();
    }
  };

  /**
   * @param {string} label
   * @param {() => void} onClick
   */
  function button(label, onClick) {
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = label;
    b.addEventListener('click', onClick);
    return b;
  }

  /**
   * @param {string} name
   * @param {boolean} ok
   * @param {string} detail
   */
  function record(name, ok, detail) {
    results[name] = { ok, detail };
  }

  /** @param {unknown} error */
  function describe(error) {
    if (error instanceof Error || error instanceof DOMException) return `${error.name}: ${error.message}`;
    return String(error);
  }

  /**
   * Runs `fn` and records whether it threw, and what.
   * @param {() => unknown} fn
   * @returns {{ threw: boolean, error: unknown, value: unknown }}
   */
  function attempt(fn) {
    try {
      return { threw: false, error: null, value: fn() };
    } catch (error) {
      return { threw: true, error, value: undefined };
    }
  }

  /**
   * A probe element for a style case, in the document so its computed style is real.
   * @param {string} id
   */
  function probeElement(id) {
    const el = document.createElement('div');
    el.id = id;
    el.textContent = id;
    document.body.append(el);
    return el;
  }

  /** @param {Element} el */
  function colorOf(el) {
    return getComputedStyle(el).color;
  }

  /**
   * Resolves with `outcome(…)` when it is called, or with `onTimeout()` after WAIT_MS.
   * @template T
   * @param {(settle: (value: T) => void) => void} start
   * @param {() => T} onTimeout
   * @returns {Promise<T>}
   */
  function within(start, onTimeout) {
    return new Promise((resolve) => {
      let done = false;
      const timer = setTimeout(() => {
        if (done) return;
        done = true;
        resolve(onTimeout());
      }, WAIT_MS);
      start((value) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        resolve(value);
      });
    });
  }

  async function runAll() {
    const src = ownScript instanceof HTMLScriptElement ? ownScript.src : '';
    record('blobScript', src.startsWith('blob:'), src === '' ? 'no current script' : src.slice(0, 5));

    {
      // Deliberate: a script element's text is a sink the runner's policy must refuse.
      const script = document.createElement('script');
      const set = attempt(() => {
        script.textContent = 'globalThis.__probeInline = 1;';
        document.head.append(script);
      });
      const ran = /** @type {any} */ (globalThis).__probeInline === 1;
      record('inlineScript', !ran, set.threw ? `threw ${describe(set.error)}` : ran ? 'the inline script ran' : 'did not run');
    }

    {
      // Deliberate: `new Function` is a sink the runner's policy must refuse.
      const made = attempt(() => new Function('return 1'));
      record('newFunction', made.threw, made.threw ? describe(made.error) : 'made a function');
    }

    {
      const el = probeElement('probe-inline-style');
      const style = document.createElement('style');
      style.textContent = '#probe-inline-style { color: rgb(1, 2, 3); }';
      document.head.append(style);
      const color = colorOf(el);
      record('inlineStyleElement', color !== 'rgb(1, 2, 3)', color);
    }

    {
      const el = probeElement('probe-style-attribute');
      // Deliberate: a `style` attribute is banned in the loader and refused by the policy.
      const set = attempt(() => el.setAttribute('style', 'color: rgb(4, 5, 6)'));
      const color = colorOf(el);
      record('styleAttribute', color !== 'rgb(4, 5, 6)', set.threw ? `threw ${describe(set.error)}` : color);
    }

    {
      const el = probeElement('probe-cssom');
      el.style.color = 'rgb(7, 8, 9)';
      const color = colorOf(el);
      record('cssomStyle', color === 'rgb(7, 8, 9)', color);
    }

    {
      const el = probeElement('probe-adopted');
      const made = attempt(() => {
        const sheet = new CSSStyleSheet();
        sheet.replaceSync('#probe-adopted { color: rgb(10, 11, 12); }');
        document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
      });
      const color = colorOf(el);
      record('adoptedStyleSheets', !made.threw && color === 'rgb(10, 11, 12)', made.threw ? `threw ${describe(made.error)}` : color);
    }

    const image = within((settle) => {
      const img = new Image();
      img.addEventListener('load', () => settle({ ok: false, detail: 'loaded' }));
      img.addEventListener('error', () => settle({ ok: true, detail: 'error' }));
      img.src = '/__test/probe-img';
    }, () => ({ ok: false, detail: 'no outcome within 2 s' }));

    const fetched = within((settle) => {
      fetch('/__test/probe-fetch').then(
        (response) => settle({ ok: false, detail: `status ${response.status}` }),
        (error) => settle({ ok: true, detail: describe(error) }),
      );
    }, () => ({ ok: false, detail: 'no outcome within 2 s' }));

    {
      const el = probeElement('probe-inner-html');
      // Deliberate: `innerHTML` with a string is a sink Trusted Types must refuse.
      const set = attempt(() => {
        el.innerHTML = '<b>probe</b>';
      });
      record('innerHTML', set.threw && set.error instanceof TypeError, set.threw ? describe(set.error) : 'assigned');
    }

    {
      const script = document.createElement('script');
      const url = URL.createObjectURL(new Blob(['globalThis.__probeSrc = 1;'], { type: 'text/javascript' }));
      // Deliberate: a plain string for a script URL is a sink Trusted Types must refuse.
      const set = attempt(() => {
        script.src = url;
      });
      URL.revokeObjectURL(url);
      record('scriptSrcString', set.threw && set.error instanceof TypeError, set.threw ? describe(set.error) : 'assigned');
    }

    const worker = within((settle) => {
      const url = URL.createObjectURL(new Blob(['postMessage("ran");'], { type: 'text/javascript' }));
      // Deliberate: a plain string for a worker URL is a sink Trusted Types must refuse, and the
      // runner's `worker-src 'none'` refuses any worker where Trusted Types is missing.
      const made = attempt(() => new Worker(url));
      if (made.threw) {
        URL.revokeObjectURL(url);
        settle({ ok: true, detail: `threw ${describe(made.error)}` });
        return;
      }
      const started = /** @type {Worker} */ (made.value);
      started.addEventListener('message', () => settle({ ok: false, detail: 'the worker ran' }));
      started.addEventListener('error', () => settle({ ok: true, detail: 'error event' }));
    }, () => ({ ok: false, detail: 'no outcome within 2 s' }));

    {
      const trustedTypes = /** @type {any} */ (globalThis).trustedTypes;
      if (!trustedTypes) {
        record('secondPolicy', false, 'no trustedTypes in this engine');
      } else {
        const made = attempt(() => trustedTypes.createPolicy('other', {}));
        record('secondPolicy', made.threw, made.threw ? describe(made.error) : 'made a second policy');
      }
    }

    {
      const read = attempt(() => window.localStorage);
      const name = read.threw && read.error instanceof DOMException ? read.error.name : '';
      record('localStorage', name === 'SecurityError', read.threw ? describe(read.error) : 'readable');
    }

    const database = within((settle) => {
      // An opaque origin has no storage: opening throws SecurityError. An engine that queues
      // the refusal instead reports it on the request; that is recorded as a detail.
      const opened = attempt(() => indexedDB.open('probe'));
      if (opened.threw) {
        const name = opened.error instanceof DOMException ? opened.error.name : '';
        settle({ ok: name === 'SecurityError', detail: describe(opened.error) });
        return;
      }
      const request = /** @type {IDBOpenDBRequest} */ (opened.value);
      request.addEventListener('success', () => settle({ ok: false, detail: 'opened' }));
      request.addEventListener('error', () => settle({ ok: false, detail: `did not throw; request error ${request.error?.name}` }));
    }, () => ({ ok: false, detail: 'did not throw; no outcome within 2 s' }));

    {
      const opened = attempt(() => window.open('/__test/landing'));
      record('windowOpen', !opened.threw && opened.value === null, opened.threw ? `threw ${describe(opened.error)}` : String(opened.value));
    }

    {
      const read = attempt(() => /** @type {any} */ (parent).document);
      record('parentDocument', read.threw, read.threw ? describe(read.error) : 'readable');
    }

    record('origin', self.origin === 'null', self.origin);

    {
      const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'tbdHost');
      const ok = descriptor !== undefined && descriptor.writable === false && descriptor.configurable === false
        && Object.isFrozen(descriptor.value);
      record('tbdHostDescriptor', ok, descriptor === undefined
        ? 'no property'
        : `writable ${descriptor.writable}, configurable ${descriptor.configurable}, frozen ${Object.isFrozen(descriptor.value)}`);
    }

    {
      // Last of the synchronous cases: were it allowed, the top page would navigate away.
      const set = attempt(() => {
        /** @type {any} */ (top).location.href = '/__test/landing';
      });
      record('topNavigation', set.threw, set.threw ? describe(set.error) : 'navigated');
    }

    const [imageResult, fetchResult, databaseResult, workerResult] = await Promise.all([image, fetched, database, worker]);
    results.remoteImage = imageResult;
    results.fetch = fetchResult;
    results.indexedDB = databaseResult;
    results.worker = workerResult;

    resultsPre.textContent = JSON.stringify(results, null, 2);
    port.postMessage({ t: 'app', body: { kind: 'event', event: 'probe.results', data: results } });
  }
})();
