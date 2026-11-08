// Fixtures and helpers shared by the phone app's end-to-end specs.
//
// - `appHost`: one server.js host per worker. It stages the loader once and serves the test
//   host and the committed bundle beside it.
// - Every test fails on any console error, any uncaught page error, and any message that
//   reports a security-policy or Trusted Types violation, from the top page and from every
//   frame, the app frame included. Playwright reports the frame's console and errors on the
//   page, so nothing has to run inside the frame to see them. Before the check, a round trip to
//   the page and to each frame lets a message from the test's last step arrive. A test that
//   provokes one on purpose takes it out with `takeProblems`.
// - One message is let through, once per document, and only for a WebKit screenshot `capture`
//   takes: WebKit's refusal of a <style> element. Before each WebKit screenshot, Playwright
//   appends `<style>body {}</style>` to every document to settle animations, and both pages'
//   policies refuse it, one message per document. The message cannot be told from a refusal of
//   a <style> the app made, so the app's source policy (phone/app/src-policy.test.js) bans
//   those. `capture` fails when a document logs no refusal, since then Playwright has stopped
//   adding the <style> and the allowance should go. So take every screenshot with `capture`.
// - The helpers open the host, drive the app through `app(page)` as a user would, and call
//   `window.__host` in the top page (see host.js). They never run code in the app frame to
//   change its state; reading its document for an assert is fine.

import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { expect, test as base } from '@playwright/test';

import { startAppHost } from './server.js';

export { expect };

/** @typedef {import('@playwright/test').Page} Page */
/** @typedef {import('@playwright/test').Locator} Locator */
/** @typedef {import('./server.js').AppHost} AppHost */

const SHOTS = path.join(path.dirname(fileURLToPath(import.meta.url)), 'screenshots');
/** A console message of any level that reports a refused load or a Trusted Types violation. */
const POLICY_MESSAGE = /Content[- ]Security[- ]Policy|Trusted ?Type|TrustedHTML|TrustedScript|Refused to /i;
/** WebKit's words when a policy refuses a <style> element. */
const REFUSED_STYLE = "Refused to apply a stylesheet because its hash, its nonce, or 'unsafe-inline' does not appear in the style-src directive of the Content Security Policy.";
/**
 * The documents, by URL, whose one screenshot <style> refusal is still let through, for the
 * page whose WebKit screenshot `capture` is taking.
 * @type {WeakMap<Page, Set<string>>}
 */
const screenshotStyles = new WeakMap();

export const test = base.extend({
  appHost: [
    async ({}, use) => {
      const host = await startAppHost();
      try {
        await use(host);
      } finally {
        await host.close();
      }
    },
    { scope: 'worker' },
  ],
  pageProblems: [
    async ({ page }, use) => {
      /** @type {string[]} */
      const problems = [];
      page.on('console', (message) => {
        if (message.text() === REFUSED_STYLE && screenshotStyles.get(page)?.delete(message.location().url)) return;
        if (message.type() === 'error' || POLICY_MESSAGE.test(message.text())) {
          problems.push(`console ${message.type()} at ${message.location().url || 'an unknown place'}: ${message.text()}`);
        }
      });
      page.on('pageerror', (error) => problems.push(`page error: ${describeError(error)}`));
      await use(problems);
      if (!page.isClosed()) await roundTrip(page);
      expect(problems, 'console errors, page errors and policy violations').toEqual([]);
    },
    { auto: true },
  ],
});

/**
 * An error as a problem line that is never blank: WebKit gives an unhandled rejection an empty
 * stack, and a stack need not say the message.
 * @param {Error} error
 */
function describeError(error) {
  const stack = error.stack ?? '';
  if (stack !== '' && stack.includes(error.message)) return stack;
  return stack === '' ? String(error) : `${String(error)}\n${stack}`;
}

/**
 * A no-op round trip to each of the page's documents, so the console messages and errors they
 * made before it have arrived.
 * @param {Page} page
 */
async function roundTrip(page) {
  for (const frame of page.frames()) {
    await frame.evaluate(() => 0).catch((error) => {
      if (!frame.isDetached()) throw error;
    });
  }
}

/**
 * Waits for a problem that matches `pattern`, then takes every problem that does out of
 * `problems`, for a test that provokes one on purpose. Fails when none comes. The rest stay, so
 * the fixture still fails on them.
 * @param {string[]} problems the test's `pageProblems`
 * @param {RegExp} pattern
 * @returns {Promise<string[]>} what it took
 */
export async function takeProblems(problems, pattern) {
  const matches = new RegExp(pattern.source, pattern.flags.replace(/[gy]/g, ''));
  await expect.poll(() => problems.some((problem) => matches.test(problem)), { message: `a problem that matches ${pattern}` }).toBe(true);
  const taken = problems.filter((problem) => matches.test(problem));
  const kept = problems.filter((problem) => !matches.test(problem));
  problems.splice(0, problems.length, ...kept);
  return taken;
}

/**
 * Opens the host and waits for the app's `#app` inside the frame. A scenario is a name under
 * `scenarios/` or an object in the same form, which is loaded before the channel comes up.
 * @param {Page} page
 * @param {AppHost} appHost
 * @param {{ scenario?: string | object, channel?: 'up' | 'down' }} [options]
 */
export async function openApp(page, appHost, { scenario = 'mock', channel = 'up' } = {}) {
  if (channel !== 'up' && channel !== 'down') throw new RangeError(`openApp: no channel ${channel}`);
  const named = typeof scenario === 'string';
  const query = new URLSearchParams({ scenario: named ? scenario : '', channel: named ? channel : 'down' });
  await page.goto(`${appHost.origin}/__app/host.html?${query}`);
  await page.waitForFunction(() => /** @type {any} */ (window).__host?.ready === true);
  if (!named) {
    await hostCall(page, 'loadScenario', scenario);
    if (channel === 'up') await hostCall(page, 'setChannel', true);
  }
  await expect(app(page).locator('#app')).toBeAttached();
}

/**
 * The app frame, for locators inside it.
 * @param {Page} page
 */
export function app(page) {
  return page.frameLocator('#frame-host iframe');
}

/**
 * Calls `window.__host[name](...args)` in the top page and returns what it returns. The
 * arguments and the result must be plain data; a test that needs a function, such as a
 * `setReply` that reads the params, calls `page.evaluate` itself.
 * @param {Page} page
 * @param {string} name
 * @param {...unknown} args
 */
export function hostCall(page, name, ...args) {
  return page.evaluate(([n, a]) => /** @type {any} */ (window).__host[/** @type {string} */ (n)](...a), /** @type {const} */ ([name, args]));
}

/**
 * Every request that reached the fake laptop, in order.
 * @param {Page} page
 * @returns {Promise<Array<{ requestID: string, method: string, params: any }>>}
 */
export function hostRequests(page) {
  return page.evaluate(() => /** @type {any} */ (window).__host.requests);
}

/**
 * Every URL the app asked the loader to open.
 * @param {Page} page
 * @returns {Promise<string[]>}
 */
export function hostLinks(page) {
  return page.evaluate(() => /** @type {any} */ (window).__host.links);
}

/**
 * Opens a session from the sessions list: taps the row named `rowName`, then, when `tabName`
 * is given, the session tab named that.
 * - A row is a `button.row` (the mock's sessions list) or a `button[data-row]` (6a's stub list).
 *   Its name is the text of its `.n` element when it has one, else its whole text.
 * - A tab is an element with `role="tab"`. Its name is its text.
 * - A name leaves out the text of any `.sr` or `small` inside it, such as a status word or a
 *   tab count, and has its white space collapsed. Exactly one row, and one tab, must match.
 * @param {Page} page
 * @param {string} rowName
 * @param {string} [tabName]
 */
export async function openSessionByName(page, rowName, tabName) {
  const frame = app(page);
  await tapNamed(rowButtons(page), rowName, 'row');
  if (tabName !== undefined) await tapNamed(frame.locator('[role="tab"]'), tabName, 'tab');
}

/**
 * The sessions list's rows, in either list: `button.row` (the mock's sessions list) or
 * `button[data-row]` (6a's stub list).
 * @param {Page} page
 */
export function rowButtons(page) {
  return app(page).locator('button.row, button[data-row]');
}

/**
 * The names of the rows the sessions list shows, named as `openSessionByName` names them, in
 * either list, and sorted: the order is the list's own (the stub keeps the laptop's, the real
 * list sorts newest first), so compare names as a set. It does not wait; poll it.
 * @param {Page} page
 * @returns {Promise<string[]>}
 */
export async function rowNames(page) {
  return (await rowButtons(page).evaluateAll(namesOf)).sort();
}

/**
 * Taps the one element of `candidates` whose name (see `openSessionByName`) is `name`.
 * @param {Locator} candidates
 * @param {string} name
 * @param {string} what
 */
async function tapNamed(candidates, name, what) {
  await expect(candidates.first()).toBeVisible();
  const names = await candidates.evaluateAll(namesOf);
  const matches = names.flatMap((n, i) => (n === name ? [i] : []));
  if (matches.length !== 1) {
    throw new Error(`${matches.length} ${what}s are named "${name}"; the ${what}s are ${JSON.stringify(names)}`);
  }
  await candidates.nth(matches[0]).click();
}

/**
 * Each element's name (see `openSessionByName`). Playwright runs it in the frame, so it uses
 * nothing from this module.
 * @param {Element[]} els
 * @returns {string[]}
 */
function namesOf(els) {
  return els.map((el) => {
    const root = el.querySelector('.n') ?? el;
    let text = '';
    const walker = root.ownerDocument.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node !== null; node = walker.nextNode()) {
      const extra = node.parentElement?.closest('.sr, small');
      if (extra && root.contains(extra)) continue;
      text += node.textContent ?? '';
    }
    return text.replace(/\s+/g, ' ').trim();
  });
}

/**
 * Saves the page in both colour schemes as screenshots/<scheme>/<state>.png, once the app has
 * taken the scheme (`html[data-theme]` in the frame) and `ready` shows. Animations are stopped,
 * so each spinner is drawn at its start. In WebKit, each document's refusal of the <style>
 * Playwright adds is let through once per screenshot, and one that does not come fails.
 * @param {Page} page
 * @param {string} state
 * @param {Locator} ready a locator in the app
 */
export async function capture(page, state, ready) {
  const webkit = page.context().browser()?.browserType().name() === 'webkit';
  for (const colorScheme of /** @type {const} */ (['light', 'dark'])) {
    await page.emulateMedia({ colorScheme });
    await expect(app(page).locator(`html[data-theme="${colorScheme}"]`)).toBeAttached();
    await expect(ready).toBeVisible();
    /** @type {Set<string>} */
    const pending = new Set(webkit ? page.frames().map((frame) => frame.url()) : []);
    screenshotStyles.set(page, pending);
    try {
      await page.screenshot({ path: path.join(SHOTS, colorScheme, `${state}.png`), fullPage: true, animations: 'disabled' });
      // So the refusals the screenshot caused arrive while they are let through.
      await roundTrip(page);
    } finally {
      screenshotStyles.delete(page);
    }
    expect([...pending], 'documents that refused no screenshot <style>: if Playwright no longer adds one, drop the allowance').toEqual([]);
  }
}
