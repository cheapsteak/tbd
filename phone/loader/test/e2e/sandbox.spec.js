// The runner's sandbox, security policy and Trusted Types, seen from inside the app frame, in
// WebKit as an iPhone and in Chromium as an Android phone.
//
// One probe run per worker: the probe bundle (test/fixtures/probe-app.js) tries each thing the
// frame must or must not be able to do and reports `{ ok, detail }` per case as event
// `probe.results`, where `ok` means the expected outcome happened. Each case below is then one
// test. Where WebKit and Chromium refuse in different ways, the probe checks that the action did
// not happen rather than one engine's error.
//
// Then a runner stamped for another origin: its policy refuses its own script, so it never
// starts, and the loader shows Reload this page.

import { claimRunnerPolicy, expect, pairViaFragment, test as base, waitForAppFrame } from './fixtures.js';
import { startFakeLaptop } from './fake-laptop.js';

/** @typedef {Record<string, { ok: boolean, detail: string }>} ProbeResults */

/**
 * @typedef {object} ProbeRun
 * @property {ProbeResults} results
 * @property {string[]} requests Every request the server had when the results arrived.
 * @property {number} pages The context's pages when the results arrived.
 */

const test = base.extend({
  probe: [
    /**
     * Pairs a fresh context from the project's device with a laptop serving the probe bundle,
     * waits for the probe's results, and closes everything before the tests read them.
     * @param {{ browser: import('@playwright/test').Browser }} fixtures
     * @param {(run: ProbeRun) => Promise<void>} use
     * @param {import('@playwright/test').WorkerInfo} workerInfo
     */
    async ({ browser }, use, workerInfo) => {
      // The project's device descriptor, without `defaultBrowserType`: the project already
      // chose the browser.
      const { viewport, screen, userAgent, deviceScaleFactor, isMobile, hasTouch } = workerInfo.project.use;
      const server = await startFakeLaptop({ bundle: 'probe' });
      /** @type {ProbeRun | null} */
      let run = null;
      try {
        const context = await browser.newContext({ viewport, screen, userAgent, deviceScaleFactor, isMobile, hasTouch });
        try {
          const page = await context.newPage();
          const { laptop } = await pairViaFragment(page, server);
          await expect.poll(() => laptop.appBodies.some(isProbeResults), { timeout: 15_000 }).toBe(true);
          const body = /** @type {any} */ (laptop.appBodies.find(isProbeResults));
          run = { results: body.data, requests: [...server.requests], pages: context.pages().length };
        } finally {
          await context.close();
        }
      } finally {
        await server.close();
      }
      await use(run);
    },
    { scope: 'worker', timeout: 60_000 },
  ],
});

/** @param {any} body */
function isProbeResults(body) {
  return body?.kind === 'event' && body.event === 'probe.results';
}

/**
 * Each probe case, and what its `ok` stands for.
 * @type {Array<[string, string]>}
 */
const CASES = [
  ['blobScript', 'the bundle runs as a classic script from a blob: URL'],
  ['inlineScript', 'a script element with inline text never runs'],
  ['newFunction', 'new Function throws'],
  ['inlineStyleElement', 'a <style> element does not apply'],
  ['styleAttribute', 'a style attribute does not apply'],
  ['cssomStyle', 'a CSSOM style assignment applies'],
  ['adoptedStyleSheets', 'a constructed style sheet applies'],
  ['remoteImage', 'an image from the loader origin fails to load'],
  ['fetch', 'fetch rejects'],
  ['innerHTML', 'assigning an HTML string throws TypeError'],
  ['scriptSrcString', 'assigning a string to script.src throws TypeError'],
  ['secondPolicy', 'a second Trusted Types policy cannot be made'],
  ['worker', 'a worker from a blob: URL never runs'],
  ['localStorage', 'localStorage throws SecurityError'],
  ['indexedDB', 'indexedDB throws SecurityError'],
  ['windowOpen', 'window.open returns null'],
  ['topNavigation', 'navigating the top page throws'],
  ['parentDocument', 'reading parent.document throws'],
  ['origin', 'the frame\'s origin is opaque'],
  ['tbdHostDescriptor', 'tbdHost is not writable, not configurable, and frozen'],
];

for (const [name, meaning] of CASES) {
  test(`probe ${name}: ${meaning}`, async ({ probe }) => {
    const result = probe.results[name];
    expect(result, `the probe reported no ${name}`).toBeDefined();
    expect(result.ok, `${name}: ${result.detail}`).toBe(true);
  });
}

test('the probe ran no case it does not know', async ({ probe }) => {
  expect(Object.keys(probe.results).sort()).toEqual(CASES.map(([name]) => name).sort());
});

test('the refused image and fetch never reached the server', async ({ probe }) => {
  expect(probe.requests).not.toContain('/__test/probe-img');
  expect(probe.requests).not.toContain('/__test/probe-fetch');
});

test('the refused window.open and top navigation opened nothing', async ({ probe }) => {
  expect(probe.requests).not.toContain('/__test/landing');
  expect(probe.pages).toBe(1);
});

test.describe('a runner stamped for another origin', () => {
  // An unstamped runner is the same case: its placeholder is just another origin.
  test.use({ serverOptions: { runnerOrigin: 'https://acme-other.invalid' } });

  test('fails closed', async ({ page, server }) => {
    const laptop = server.laptops[0];
    await page.clock.install();
    await pairViaFragment(page, server);
    await waitForAppFrame(page);
    // The bundle arrived; it is the runner that cannot start it.
    expect(laptop.counts.bundleGet).toBe(1);
    const runner = page.frames().find((f) => f.url().includes('/runner.html'));
    if (runner === undefined) throw new Error('no runner frame');
    await expect.poll(() => runner.evaluate(() => document.readyState)).toBe('complete');
    // runner.js never ran: had it run, it would hold the one Trusted Types policy name its page
    // allows.
    expect(await runner.evaluate(claimRunnerPolicy)).toBe('free');

    await page.clock.fastForward(10_000);
    await expect(page.locator('[data-state="reload"] h2')).toHaveText('Reload this page');
    await expect(page.locator('iframe')).toHaveCount(0);
    expect(laptop.appBodies).toEqual([]);
  });
});
