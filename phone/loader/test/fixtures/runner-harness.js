// The runner harness: a test-only page script, served with `/__test/runner-harness.html` on the
// loader's origin and on a second origin and never staged. It frames runner.html the way
// sandbox-runner.spec.js asks and keeps everything that comes back. A classic script.
//
// - `harness.frame(src, sandbox)` frames `src` (with the `sandbox` attribute when `sandbox` is a
//   string) as `#runner-<index>`, and resolves with the index once the frame's load event fires.
// - Every window message from a framed runner is kept, with its origin, in that frame's
//   `window` log.
// - `harness.post(index, data, ports)` posts `data` to the frame with `ports` fresh
//   MessageChannel ports, keeps what comes back on each, and returns the post's number.
// - `harness.relay(index, data, ports)` has a second, same-origin frame post the same, so the
//   runner sees a message whose source is not its parent.
// - `harness.log(index)` reads both logs: `{ window, posts }`, where `posts[n][k]` holds what
//   came back on port `k` of post `n`.
(() => {
  'use strict';

  /**
   * @typedef {object} Entry
   * @property {HTMLIFrameElement} iframe
   * @property {Array<{ origin: string, data: unknown }>} window
   * @property {unknown[][][]} posts
   */

  /** @type {Entry[]} */
  const frames = [];

  addEventListener('message', (event) => {
    for (const entry of frames) {
      if (event.source !== null && event.source === entry.iframe.contentWindow) {
        entry.window.push({ origin: event.origin, data: event.data });
      }
    }
  });

  /**
   * Makes `count` channels for one post to `entry`, logging what comes back on each.
   * @param {Entry} entry
   * @param {number} count
   * @returns {{ post: number, transfer: MessagePort[] }}
   */
  function channels(entry, count) {
    /** @type {unknown[][]} */
    const logs = [];
    /** @type {MessagePort[]} */
    const transfer = [];
    for (let k = 0; k < count; k += 1) {
      const channel = new MessageChannel();
      /** @type {unknown[]} */
      const log = [];
      channel.port1.onmessage = (event) => {
        log.push(event.data);
      };
      logs.push(log);
      transfer.push(channel.port2);
    }
    const post = entry.posts.push(logs) - 1;
    return { post, transfer };
  }

  /** @param {number} index */
  function entryAt(index) {
    const entry = frames[index];
    if (entry === undefined) throw new RangeError(`no frame ${index}`);
    return entry;
  }

  /** @type {Promise<Window> | null} */
  let relayWindow = null;

  /**
   * A same-origin frame whose own script forwards each message it gets, with its ports, to
   * the window in `parent.__harnessRelayTarget`. Its script must be its own, not one the
   * harness calls into, so that the runner sees the relay frame as the message's source.
   * Deliberate: an HTML string with an inline script, on this test-only page with no policy.
   * @returns {Promise<Window>}
   */
  function relayFrame() {
    relayWindow ??= new Promise((resolve) => {
      const iframe = document.createElement('iframe');
      iframe.id = 'relay';
      iframe.srcdoc = '<!doctype html><script>addEventListener("message", (event) => {'
        + ' parent.__harnessRelayTarget.postMessage(event.data, "*", [...event.ports]); });<\/script>';
      iframe.addEventListener('load', () => resolve(/** @type {Window} */ (iframe.contentWindow)), { once: true });
      document.body.append(iframe);
    });
    return relayWindow;
  }

  /** @type {any} */ (globalThis).harness = {
    /**
     * @param {string} src
     * @param {string | null} sandbox
     * @returns {Promise<number>}
     */
    frame(src, sandbox) {
      return new Promise((resolve) => {
        const iframe = document.createElement('iframe');
        if (typeof sandbox === 'string') iframe.setAttribute('sandbox', sandbox);
        const index = frames.push({ iframe, window: [], posts: [] }) - 1;
        iframe.id = `runner-${index}`;
        iframe.addEventListener('load', () => resolve(index), { once: true });
        iframe.src = src;
        document.body.append(iframe);
      });
    },

    /**
     * @param {number} index
     * @param {unknown} data
     * @param {number} ports
     * @returns {number} the post's number
     */
    post(index, data, ports) {
      const entry = entryAt(index);
      const { post, transfer } = channels(entry, ports);
      const target = entry.iframe.contentWindow;
      if (target === null) throw new Error(`frame ${index} has no window`);
      target.postMessage(data, '*', transfer);
      return post;
    },

    /**
     * @param {number} index
     * @param {unknown} data
     * @param {number} ports
     * @returns {Promise<number>} the post's number
     */
    async relay(index, data, ports) {
      const entry = entryAt(index);
      const relay = await relayFrame();
      /** @type {any} */ (globalThis).__harnessRelayTarget = entry.iframe.contentWindow;
      const { post, transfer } = channels(entry, ports);
      relay.postMessage(data, '*', transfer);
      return post;
    },

    /** @param {number} index */
    log(index) {
      const entry = entryAt(index);
      return { window: entry.window, posts: entry.posts };
    },
  };
})();
