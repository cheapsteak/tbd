// The runner's half of the frame handshake, driven from test-only harness pages, in WebKit as an
// iPhone and in Chromium as an Android phone.
//
// The harness (`/__test/runner-harness.html`, served on the loader's origin and on a second
// origin, never staged) frames runner.html as each case asks, posts it bundle messages with
// fresh ports, and keeps what comes back. Each "nothing happens" case waits for a positive sign
// that the runner had its chance to act, never for a timeout:
// - A good bundle posted after a refused one, from the same window, starts: messages arrive in
//   order, so the runner turned the first one down while it was listening.
// - A fence message: once the frame has had it, every listener has handled what came before.
// - `watchRunner`, an init script in every document of the page, counts SHA-256 digests. The
//   runner hashes a bundle synchronously in the `message` event that it accepts, so a digest
//   count of 0 at a fence means it accepted nothing.
// - A fence the frame posts to its parent: a `ready` the runner posted while it loaded would
//   arrive before it.
// What a bundle did is observable too: each test bundle records its tag in `globalThis.__ran`
// and posts `{t:'ran'}` on its port.

import { createHash } from 'node:crypto';

import { claimRunnerPolicy, expect, pairViaFragment, test } from './fixtures.js';

/** @typedef {import('@playwright/test').Page} Page */
/** @typedef {import('@playwright/test').Frame} Frame */
/** @typedef {import('./fake-laptop.js').FakeLaptopServer} FakeLaptopServer */
/** @typedef {{ index: number, frame: Frame }} Runner */
/** @typedef {{ digests: number, types: string[] }} Watch */

const NONCE = 'abc';

/**
 * The lowercase hex SHA-256 of a text's UTF-8 bytes, as the loader sends it.
 * @param {string} text
 */
const sha256 = (text) => createHash('sha256').update(text, 'utf8').digest('hex');

/**
 * A bundle that records that it ran, in the frame and on its port.
 * @param {string} tag
 */
function bundleText(tag) {
  const quoted = JSON.stringify(tag);
  return `(globalThis.__ran ||= []).push(${quoted});\ntbdHost.port.postMessage({ t: 'ran', tag: ${quoted} });\n`;
}

/**
 * A valid bundle message for this runner, with `fields` merged over it.
 * @param {string} tag
 * @param {Record<string, unknown>} [fields]
 */
function bundleMessage(tag, fields = {}) {
  const text = bundleText(tag);
  return { type: 'bundle', nonce: NONCE, text, sha256: sha256(text), ...fields };
}

/** @param {string} tag */
const ranAndStarted = (tag) => [{ t: 'ran', tag }, { t: 'started' }];

/**
 * An init script for every document of the page: counts SHA-256 digests and records the
 * `type` of each window message, in `globalThis.__acmeWatch`. Its message listener comes
 * before the runner's.
 */
function watchRunner() {
  if ('__acmeWatch' in globalThis) return;
  /** @type {Watch} */
  const watch = { digests: 0, types: [] };
  Object.defineProperty(globalThis, '__acmeWatch', { value: watch });
  const proto = /** @type {any} */ (globalThis).SubtleCrypto?.prototype;
  if (proto) {
    const digest = proto.digest;
    /** @param {unknown[]} args */
    proto.digest = function (...args) {
      watch.digests += 1;
      return digest.apply(this, args);
    };
  }
  addEventListener('message', (event) => {
    const data = event.data;
    watch.types.push(data !== null && typeof data === 'object' ? String(data.type) : typeof data);
  });
}

/**
 * Opens the runner harness on `origin`, with `watchRunner` in every document.
 * @param {Page} page
 * @param {string} origin
 */
async function openHarness(page, origin) {
  await page.addInitScript(watchRunner);
  await page.goto(`${origin}/__test/runner-harness.html`);
}

/**
 * Frames `src` from the harness, and waits for the frame's load.
 * @param {Page} page
 * @param {string} src
 * @param {string | null} sandbox the `sandbox` attribute, or null for none
 * @returns {Promise<Runner>}
 */
async function frameFromHarness(page, src, sandbox) {
  const index = await page.evaluate(([s, b]) => /** @type {any} */ (window).harness.frame(s, b), [src, sandbox]);
  const frame = await (await page.locator(`#runner-${index}`).elementHandle())?.contentFrame();
  if (frame === null || frame === undefined) throw new Error('no frame');
  expect(frame.url()).toContain(new URL(src).pathname);
  return { index, frame };
}

/**
 * Frames the server's runner.html, with this suite's nonce, from the harness.
 * @param {Page} page
 * @param {FakeLaptopServer} server
 * @param {string | null} sandbox
 */
function frameRunner(page, server, sandbox) {
  return frameFromHarness(page, `${server.origin}/runner.html#n=${NONCE}`, sandbox);
}

/**
 * @param {Page} page
 * @param {number} index
 * @returns {Promise<{ window: Array<{ origin: string, data: any }>, posts: unknown[][][] }>}
 */
function harnessLog(page, index) {
  return page.evaluate((i) => /** @type {any} */ (window).harness.log(i), index);
}

/**
 * The `type` of each window message the frame posted to the harness.
 * @param {Page} page
 * @param {number} index
 */
async function windowTypes(page, index) {
  return (await harnessLog(page, index)).window.map((message) => message.data?.type);
}

/**
 * What came back on each port of one post.
 * @param {Page} page
 * @param {number} index
 * @param {number} post
 */
async function portLog(page, index, post) {
  return (await harnessLog(page, index)).posts[post];
}

/**
 * Posts `data` to the frame with `ports` fresh ports.
 * @param {Page} page
 * @param {number} index
 * @param {unknown} data
 * @param {number} ports
 * @returns {Promise<number>} the post's number
 */
function post(page, index, data, ports) {
  return page.evaluate(([i, d, p]) => /** @type {any} */ (window).harness.post(i, d, p), [index, data, ports]);
}

/**
 * @param {Page | Frame} target
 * @returns {Promise<Watch>}
 */
function watchOf(target) {
  return target.evaluate(() => /** @type {any} */ (globalThis).__acmeWatch);
}

/**
 * The tags of the test bundles that ran in `target`.
 * @param {Page | Frame} target
 * @returns {Promise<string[]>}
 */
function ran(target) {
  return target.evaluate(() => /** @type {any} */ (globalThis).__ran ?? []);
}

/**
 * Waits for the runner's `ready`, from an opaque origin with this suite's nonce, and nothing else.
 * @param {Page} page
 * @param {Runner} runner
 */
async function waitReady(page, runner) {
  await expect.poll(() => windowTypes(page, runner.index)).toContain('ready');
  expect((await harnessLog(page, runner.index)).window).toEqual([{ origin: 'null', data: { type: 'ready', nonce: NONCE } }]);
}

/**
 * Posts a fence from the harness to the frame and waits until the frame has had it: every
 * listener has then handled each message posted before it.
 * @param {Page} page
 * @param {Runner} runner
 */
async function fenceToFrame(page, runner) {
  const fences = async () => (await watchOf(runner.frame)).types.filter((type) => type === 'fence').length;
  const before = await fences();
  await post(page, runner.index, { type: 'fence' }, 0);
  await expect.poll(fences).toBe(before + 1);
}

/**
 * Has the frame post a fence to its parent and waits for it: a `ready` the runner posted while
 * it loaded would have arrived first.
 * @param {Page} page
 * @param {Runner} runner
 */
async function fenceFromFrame(page, runner) {
  await runner.frame.evaluate(() => parent.postMessage({ type: 'fence' }, '*'));
  await expect.poll(() => windowTypes(page, runner.index)).toContain('fence');
}

/**
 * Checks that a page or frame holding runner.html ran nothing: a bundle posted by the page to
 * itself, with the right nonce and a port, starts nothing, and runner.js never made its policy.
 * The caller has already shown that no `ready` came.
 * @param {Page | Frame} target
 */
async function expectSelfPostedBundleIgnored(target) {
  const before = (await watchOf(target)).types.length;
  await target.evaluate((message) => {
    const channel = new MessageChannel();
    channel.port1.onmessage = (event) => {
      (/** @type {any} */ (globalThis).__acmePort ||= []).push(event.data);
    };
    postMessage(message, '*', [channel.port2]);
    postMessage({ type: 'fence' }, '*');
  }, bundleMessage('self'));
  await expect.poll(async () => (await watchOf(target)).types.slice(before)).toEqual(['bundle', 'fence']);
  expect((await watchOf(target)).digests).toBe(0);
  expect(await ran(target)).toEqual([]);
  expect(await target.evaluate(() => 'tbdHost' in globalThis)).toBe(false);
  expect(await target.evaluate(() => /** @type {any} */ (globalThis).__acmePort ?? [])).toEqual([]);
  expect(await target.evaluate(claimRunnerPolicy)).toBe('free');
}

// --- framed where its origin is not opaque ------------------------------------------------

/** @type {Array<[string, 'loader' | 'other', string | null]>} */
const NOT_OPAQUE = [
  ['another origin', 'other', null],
  ['another origin', 'other', 'allow-scripts allow-same-origin'],
  ['the loader\'s origin', 'loader', 'allow-scripts allow-same-origin'],
];

for (const [who, harnessAt, sandbox] of NOT_OPAQUE) {
  const how = sandbox === null ? 'with no sandbox' : `with sandbox="${sandbox}"`;
  test(`a runner framed by ${who} ${how} never posts ready and runs no bundle`, async ({ page, server }) => {
    await openHarness(page, harnessAt === 'other' ? server.otherOrigin : server.origin);
    const runner = await frameRunner(page, server, sandbox);
    // The dangerous case: the frame holds the loader's origin, and runner.js was fetched and
    // ran before the frame's load.
    expect(await runner.frame.evaluate(() => self.origin)).toBe(server.origin);
    expect(server.requests).toContain('/runner.js');

    await fenceFromFrame(page, runner);
    expect(await windowTypes(page, runner.index)).toEqual(['fence']);

    // The bundle a framing page would send: the right nonce, one port, a good hash.
    const sent = await post(page, runner.index, bundleMessage('framed'), 1);
    await fenceToFrame(page, runner);
    expect((await watchOf(runner.frame)).digests).toBe(0);
    expect(await ran(runner.frame)).toEqual([]);
    expect(await runner.frame.evaluate(() => 'tbdHost' in globalThis)).toBe(false);
    expect(await portLog(page, runner.index, sent)).toEqual([[]]);
    // runner.js stopped at its first check, before it made its Trusted Types policy.
    expect(await runner.frame.evaluate(claimRunnerPolicy)).toBe('free');
  });
}

test('runner.html opened as a top-level page runs nothing', async ({ page, server }) => {
  await page.addInitScript(watchRunner);
  await page.goto(`${server.origin}/runner.html#n=${NONCE}`);
  expect(server.requests).toContain('/runner.js');
  // Its parent is itself: a `ready` posted while it loaded would arrive before this fence.
  await page.evaluate(() => postMessage({ type: 'fence' }, '*'));
  await expect.poll(async () => (await watchOf(page)).types).toContain('fence');
  expect((await watchOf(page)).types).toEqual(['fence']);
  await expectSelfPostedBundleIgnored(page);
});

test('runner.html opened top-level with an opaque origin, as a sandboxed frame\'s popup, runs nothing', async ({ context, page, server }) => {
  await context.addInitScript(watchRunner);
  await page.goto(`${server.origin}/__test/runner-harness.html`);
  const opener = await frameFromHarness(page, `${server.origin}/__test/blank.html`, 'allow-scripts allow-popups');
  const opened = context.waitForEvent('page');
  await opener.frame.evaluate((url) => {
    window.open(url);
  }, `${server.origin}/runner.html#n=${NONCE}`);
  const popup = await opened;
  await popup.waitForLoadState('load');
  // The popup inherits the sandbox: an opaque origin with no parent but itself, so the
  // runner's other check is what stops it.
  expect(await popup.evaluate(() => [self.origin, window.parent === window])).toEqual(['null', true]);
  expect(server.requests).toContain('/runner.js');
  await popup.evaluate(() => postMessage({ type: 'fence' }, '*'));
  await expect.poll(async () => (await watchOf(popup)).types).toContain('fence');
  expect((await watchOf(popup)).types).toEqual(['fence']);
  await expectSelfPostedBundleIgnored(popup);
});

// --- framed as the loader frames it -------------------------------------------------------

test.describe('framed with sandbox="allow-scripts" by the loader\'s origin', () => {
  test('a good bundle posts started', async ({ page, server }) => {
    await openHarness(page, server.origin);
    const runner = await frameRunner(page, server, 'allow-scripts');
    await waitReady(page, runner);
    const sent = await post(page, runner.index, bundleMessage('good'), 1);
    await expect.poll(() => portLog(page, runner.index, sent)).toEqual([ranAndStarted('good')]);
    expect(await ran(runner.frame)).toEqual(['good']);
    expect((await watchOf(runner.frame)).digests).toBe(1);
    expect(await runner.frame.evaluate(() => self.origin)).toBe('null');
  });

  const refusedBase = bundleMessage('refused');
  const { nonce: _nonce, ...noNonce } = refusedBase;
  /** @type {Array<[string, Record<string, unknown>, number]>} */
  const REFUSED = [
    ['a wrong nonce', { ...refusedBase, nonce: 'abd' }, 1],
    ['no nonce', noNonce, 1],
    ['two ports', refusedBase, 2],
    ['no port', refusedBase, 0],
    ['a type other than bundle', { ...refusedBase, type: 'bundles' }, 1],
    ['a text that is not a string', { ...refusedBase, text: [refusedBase.text] }, 1],
    ['a sha256 in upper case', { ...refusedBase, sha256: refusedBase.sha256.toUpperCase() }, 1],
    ['a sha256 of 63 hex digits', { ...refusedBase, sha256: refusedBase.sha256.slice(1) }, 1],
    ['a sha256 of 65 hex digits', { ...refusedBase, sha256: `${refusedBase.sha256}0` }, 1],
    ['a sha256 that is not a string', { ...refusedBase, sha256: [refusedBase.sha256] }, 1],
  ];

  for (const [what, message, ports] of REFUSED) {
    test(`a bundle message with ${what} does not start`, async ({ page, server }) => {
      await openHarness(page, server.origin);
      const runner = await frameRunner(page, server, 'allow-scripts');
      await waitReady(page, runner);
      const refused = await post(page, runner.index, message, ports);
      // A good bundle after it, from the same window, starts: the runner turned the first one
      // down and kept listening.
      const accepted = await post(page, runner.index, bundleMessage('control'), 1);
      await expect.poll(() => portLog(page, runner.index, accepted)).toEqual([ranAndStarted('control')]);
      expect(await portLog(page, runner.index, refused)).toEqual(Array.from({ length: ports }, () => []));
      expect(await ran(runner.frame)).toEqual(['control']);
      expect((await watchOf(runner.frame)).digests).toBe(1);
    });
  }

  test('a bundle from a window other than the parent does not start', async ({ page, server }) => {
    await openHarness(page, server.origin);
    const runner = await frameRunner(page, server, 'allow-scripts');
    await waitReady(page, runner);
    // A sibling frame of the same origin as the parent posts it.
    const relayed = await page.evaluate(([i, d]) => /** @type {any} */ (window).harness.relay(i, d, 1),
      [runner.index, bundleMessage('sibling')]);
    await expect.poll(async () => (await watchOf(runner.frame)).types).toEqual(['bundle']);
    expect((await watchOf(runner.frame)).digests).toBe(0);
    const accepted = await post(page, runner.index, bundleMessage('control'), 1);
    await expect.poll(() => portLog(page, runner.index, accepted)).toEqual([ranAndStarted('control')]);
    expect(await portLog(page, runner.index, relayed)).toEqual([[]]);
    expect(await ran(runner.frame)).toEqual(['control']);
  });

  test('a hash mismatch posts fault hash, runs nothing, and takes no later bundle', async ({ page, server }) => {
    await openHarness(page, server.origin);
    const runner = await frameRunner(page, server, 'allow-scripts');
    await waitReady(page, runner);
    const sent = await post(page, runner.index, bundleMessage('mismatched', { sha256: sha256('acme') }), 1);
    await expect.poll(() => portLog(page, runner.index, sent)).toEqual([[{ t: 'fault', reason: 'hash' }]]);
    expect(await ran(runner.frame)).toEqual([]);
    expect(await runner.frame.evaluate(() => 'tbdHost' in globalThis)).toBe(false);

    const later = await post(page, runner.index, bundleMessage('later'), 1);
    await fenceToFrame(page, runner);
    expect((await watchOf(runner.frame)).digests).toBe(1);
    expect(await portLog(page, runner.index, later)).toEqual([[]]);
    expect(await ran(runner.frame)).toEqual([]);
  });

  test('a second valid bundle message is ignored: only one bundle runs', async ({ page, server }) => {
    await openHarness(page, server.origin);
    const runner = await frameRunner(page, server, 'allow-scripts');
    await waitReady(page, runner);
    // Both in one task, so the second arrives while the first is still being hashed.
    const [first, second] = await page.evaluate(([i, a, b]) => {
      const harness = /** @type {any} */ (window).harness;
      return [harness.post(i, a, 1), harness.post(i, b, 1)];
    }, [runner.index, bundleMessage('first'), bundleMessage('second')]);
    await expect.poll(() => portLog(page, runner.index, first)).toEqual([ranAndStarted('first')]);
    await fenceToFrame(page, runner);
    expect((await watchOf(runner.frame)).digests).toBe(1);
    expect(await portLog(page, runner.index, second)).toEqual([[]]);
    expect(await ran(runner.frame)).toEqual(['first']);
  });

  /** @type {Array<[string, string, unknown[]]>} */
  const FAULTY = [
    ['throws at its top level', 'tbdHost.port.postMessage({ t: \'ran\' });\nthrow new Error(\'acme\');\n',
      [{ t: 'ran' }, { t: 'fault', reason: 'script' }]],
    ['fails to parse', 'tbdHost.port.postMessage({ t: \'ran\' });\nthis is not javascript (\n',
      [{ t: 'fault', reason: 'script' }]],
  ];

  for (const [what, text, expected] of FAULTY) {
    test(`a bundle that ${what} posts fault script`, async ({ page, server }) => {
      await openHarness(page, server.origin);
      const runner = await frameRunner(page, server, 'allow-scripts');
      await waitReady(page, runner);
      const sent = await post(page, runner.index, { type: 'bundle', nonce: NONCE, text, sha256: sha256(text) }, 1);
      await expect.poll(() => portLog(page, runner.index, sent)).toEqual([expected]);
    });
  }
});

// --- the same faults in the loader ---------------------------------------------------------

for (const [what, text] of [
  ['throws at its top level', 'throw new Error(\'acme\');\n'],
  ['fails to parse', 'this is not javascript (\n'],
]) {
  test(`a bundle that ${what} shows Reload this page in the loader, with no frame left`, async ({ page, server }) => {
    const laptop = server.laptops[0];
    laptop.setBundle(text);
    // The page's clock stands still, so the runner's start timeout cannot be what fires.
    await page.clock.install();
    await page.clock.pauseAt(Date.now() + 1_000);
    await pairViaFragment(page, server, { waitForFrame: false });
    await expect(page.locator('[data-state="reload"] h2')).toHaveText('Reload this page');
    await expect(page.locator('iframe')).toHaveCount(0);
    // The bundle arrived whole and the runner loaded: the runner's report ended it.
    expect(laptop.counts.bundleGet).toBe(1);
    expect(server.requests).toContain('/runner.js');
    expect(laptop.appBodies).toEqual([]);
  });
}
