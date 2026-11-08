// The test host's own guarantees, in WebKit as an iPhone and in Chromium as an Android phone:
// the app runs as a phone runs it (the committed bundle, in the staged runner, under the
// runner's policy alone, with an opaque origin), and the fixture's console check sees what
// goes wrong inside the frame. Nothing here depends on a screen that a later part fills.

import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { app, expect, hostCall, hostRequests, openApp, takeProblems, test } from './fixtures.js';
import { BUNDLE_PATH } from './server.js';

const RUNNER_SOURCE = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../loader/runner.html');
const PLACEHOLDER = 'https://loader-origin.invalid';

/** @param {import('@playwright/test').Page} page */
function runnerFrame(page) {
  const frame = page.frames().find((f) => f !== page.mainFrame() && new URL(f.url()).pathname === '/runner.html');
  if (frame === undefined) throw new Error('no runner frame');
  return frame;
}

/** Waits until the app has drawn something, then until its first subscribe reply took it past loading. */
async function waitForSubscribed(page) {
  await expect(app(page).locator('#app > *').first()).toBeAttached();
  await expect(app(page).locator('[data-state="loading"]')).toHaveCount(0);
  await expect(app(page).locator('[data-state="app-error"]')).toHaveCount(0);
}

test("the bundle starts under the runner's policy with no console error, and subscribes", async ({ page, appHost }) => {
  await openApp(page, appHost);
  await waitForSubscribed(page);
  await expect(app(page).locator('button[data-row]')).toHaveText(['main', 'Login redirect fix', 'Rate limit retry']);
  const [first] = await hostRequests(page);
  expect(first).toEqual({ requestID: expect.any(String), method: 'sessions.subscribe', params: {} });
});

test('the app frame is the staged runner, under its own policy alone, with an opaque origin', async ({ page, appHost, request }) => {
  await openApp(page, appHost);
  const iframe = page.locator('#frame-host iframe');
  await expect(iframe).toHaveAttribute('sandbox', 'allow-scripts');
  expect(new URL(/** @type {string} */ (await iframe.getAttribute('src'))).href.split('#')[0]).toBe(`${appHost.origin}/runner.html`);

  // The staged runner.html is the source with the origin stamped in, and nothing else changed.
  const source = await readFile(RUNNER_SOURCE, 'utf8');
  const stamped = source.replace(PLACEHOLDER, appHost.origin);
  expect(stamped).not.toBe(source);
  expect(await (await request.get(`${appHost.origin}/runner.html`)).text()).toBe(stamped);
  const policy = /<meta http-equiv="Content-Security-Policy" content="([^"]+)">/.exec(stamped)?.[1];
  expect(policy).toContain(`script-src ${appHost.origin} blob:`);

  // Inside the frame: that one policy, and an opaque origin. Read, not changed.
  const seen = await runnerFrame(page).evaluate(() => ({
    origin: self.origin,
    policies: Array.from(document.querySelectorAll('meta[http-equiv="Content-Security-Policy" i]'), (m) => m.getAttribute('content')),
  }));
  expect(seen).toEqual({ origin: 'null', policies: [policy] });

  // No response carries a policy header that would add to the meta tag.
  for (const route of ['/runner.html', '/runner.js', '/frame.js', '/__app/host.html', '/__app/host.js', '/__app/app.js']) {
    const response = await request.get(`${appHost.origin}${route}`);
    expect(response.status(), route).toBe(200);
    expect(Object.keys(response.headers()).filter((name) => name.startsWith('content-security-policy')), route).toEqual([]);
  }

  // The bundle is the committed file, byte for byte.
  const bundle = await (await request.get(`${appHost.origin}/__app/app.js`)).body();
  expect(bundle.equals(await readFile(BUNDLE_PATH))).toBe(true);
});

test('a refused load, a Trusted Types refusal and an uncaught error in the app frame reach the console check', async ({ page, appHost, pageProblems }) => {
  await openApp(page, appHost);
  await waitForSubscribed(page);
  // The one place a test reaches into the frame: to break its policy on purpose, and see the
  // fixture catch it. `takeProblems` takes out only what each step caused, so the test passes
  // only when nothing else went wrong.
  const runner = runnerFrame(page);
  await runner.evaluate((origin) => {
    const img = document.createElement('img');
    img.src = `${origin}/__app/host.html`;
    document.body.append(img);
  }, appHost.origin);
  await takeProblems(pageProblems, /img-src/);

  const thrown = await runner.evaluate(() => {
    try {
      document.body.insertAdjacentHTML('beforeend', '<b>planted</b>');
      return 'nothing';
    } catch (error) {
      return /** @type {Error} */ (error).name;
    }
  });
  expect(thrown).toBe('TypeError');
  await takeProblems(pageProblems, /TrustedHTML/);

  await runner.evaluate(() => {
    setTimeout(() => {
      throw new Error('planted uncaught error');
    }, 0);
  });
  await takeProblems(pageProblems, /^page error: .*planted uncaught error/);

  // WebKit gives an unhandled rejection an empty stack; its line still names it.
  await runner.evaluate(() => {
    setTimeout(() => {
      void Promise.reject(new Error('planted rejection'));
    }, 0);
  });
  await takeProblems(pageProblems, /^page error: .*planted rejection/);
});

test('an object scenario is loaded before the channel comes up', async ({ page, appHost }) => {
  const rowID = '00000000-0000-4000-8000-0000000000c9';
  const scenario = {
    layout: [{ id: 'repo:00000000-0000-4000-8000-0000000000a9', kind: 'repo', name: 'acme-solo', rows: [{ id: rowID, depth: 0 }] }],
    rows: [{
      id: rowID,
      kind: 'worktree',
      name: 'Solo row',
      remote: false,
      sessions: [{
        ref: { kind: 'local', terminalID: '00000000-0000-4000-8000-000000000109' },
        agent: 'claude',
        tabName: 'Claude',
        status: { chip: 'idle', agoMinutes: 5 },
        capabilities: Object.fromEntries(['transcript', 'send', 'answer', 'switchProfile', 'fork', 'model'].map((name) => [name, { available: true }])),
      }],
    }],
  };
  await openApp(page, appHost, { scenario });
  await waitForSubscribed(page);
  await expect(app(page).locator('button[data-row]')).toHaveText(['Solo row']);
  expect((await hostRequests(page)).map((r) => r.method)).toEqual(['sessions.subscribe']);
});

test('the strip shows Reconnecting… only while the channel is down', async ({ page, appHost }) => {
  await openApp(page, appHost, { channel: 'down' });
  const strip = page.locator('#strip');
  await expect(strip.locator('.lapbtn b')).toHaveText('acme-laptop');
  await expect(strip.locator('[data-state="reconnect"]')).toHaveText('Reconnecting…');
  await expect(app(page).locator('[data-state="loading"]')).toBeVisible();
  expect(await hostRequests(page)).toEqual([]);

  await hostCall(page, 'setChannel', true);
  await expect(strip.locator('[data-state="reconnect"]')).toHaveCount(0);
  await waitForSubscribed(page);
  await hostCall(page, 'setChannel', false);
  await expect(strip.locator('[data-state="reconnect"]')).toBeVisible();
});
