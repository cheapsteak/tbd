// The debug bundle: the smallest app that exercises the runner's interface (Proposed index
// change 1) end to end. A classic script, plain text, no styles.
//
// - Shows `<pre id="sessions">` and a plain link to /__test/anchor.
// - On the first `{t:'channel', state:'up'}` it sends a `sessions.subscribe` request, and the
//   reply's result fills the `pre`.
// - Every `env` message is echoed to the laptop as event `debug.env`. One that arrives while
//   the channel is down waits for it to come up: the app sends nothing to the laptop before
//   its first `channel up`.
// - It obeys two laptop events: `debug.navigate {url}` sets `location.href`, and
//   `debug.openLink {url}` asks the loader to open the URL, then sends event
//   `debug.openLinkSent`.
//
// The test server may prepend `globalThis.__debugVariant = "<name>";` to make a bundle with
// another hash; the `pre` then names the variant on its first line.
(() => {
  'use strict';
  const port = globalThis.tbdHost.port;
  const variant = typeof globalThis.__debugVariant === 'string' ? globalThis.__debugVariant : null;
  const heading = variant === null ? '' : `Variant: ${variant}\n`;

  const pre = document.createElement('pre');
  pre.id = 'sessions';
  pre.textContent = `${heading}Waiting for the laptop…`;
  const link = document.createElement('a');
  link.id = 'plain-link';
  link.href = '/__test/anchor';
  link.textContent = 'Plain link';
  document.body.append(pre, link);

  let up = false;
  let subscribed = false;
  /** @type {string | null} */
  let requestID = null;
  /** @type {object[]} */
  const waiting = [];

  /** @param {object} body */
  function toLaptop(body) {
    if (up) port.postMessage({ t: 'app', body });
    else waiting.push(body);
  }

  /**
   * @param {string} event
   * @param {object} data
   */
  function sendEvent(event, data) {
    toLaptop({ kind: 'event', event, data });
  }

  /** @param {any} body */
  function fromLaptop(body) {
    if (body === null || typeof body !== 'object') return;
    if (body.kind === 'reply' && body.requestID === requestID) {
      pre.textContent = `${heading}Sessions:\n${JSON.stringify(body.result, null, 2)}`;
      return;
    }
    if (body.kind !== 'event') return;
    const url = body.data !== null && typeof body.data === 'object' ? body.data.url : undefined;
    if (body.event === 'debug.navigate' && typeof url === 'string') {
      location.href = url;
    } else if (body.event === 'debug.openLink' && typeof url === 'string') {
      port.postMessage({ t: 'openLink', url });
      sendEvent('debug.openLinkSent', { url });
    }
  }

  port.onmessage = (event) => {
    const message = event.data;
    if (message === null || typeof message !== 'object') return;
    switch (message.t) {
      case 'channel':
        up = message.state === 'up';
        if (!up) return;
        if (!subscribed) {
          subscribed = true;
          requestID = crypto.randomUUID();
          port.postMessage({
            t: 'app',
            body: { kind: 'request', requestID, method: 'sessions.subscribe', params: {} },
          });
        }
        for (const body of waiting.splice(0)) port.postMessage({ t: 'app', body });
        return;
      case 'env':
        sendEvent('debug.env', {
          safeArea: message.safeArea,
          viewport: message.viewport,
          layout: message.layout,
          colorScheme: message.colorScheme,
        });
        return;
      case 'app':
        fromLaptop(message.body);
    }
  };
})();
