// One laptop's connection, end to end: the full screens for each way it can fail, the header
// strip while the channel is down, the keepalive, a dead socket after the page returns, a second
// tab taking the room, and resumes that must open one socket each. WebKit as an iPhone and
// Chromium as an Android phone.

import { HANDSHAKE_RETRIES, RESUME_COALESCE_MS } from '../../constants.js';
import {
  appRoundTrip, deviceRoom, expect, linkFields, linkFromFields, pairViaFragment, phoneSocketsTo, readLoaderDB,
  screensSeen, socketLog, stripButton, test, waitForAppFrame, waitForAppText, watchSockets,
} from './fixtures.js';

/** @typedef {import('@playwright/test').Page} Page */
/** @typedef {import('./fake-laptop.js').FakeLaptopServer} FakeLaptopServer */

const EMPTY_DB = { laptops: [], rooms: [], bundles: [] };

/**
 * Fires, back to back in one task, what a return to the page fires, with the page reading as
 * visible: `visible` is a `visibilitychange`, `pageshow` a `pageshow` from a first load, and
 * `restored` a `pageshow` from the back-forward cache.
 * @param {Page} page
 * @param {Array<'visible' | 'pageshow' | 'restored'>} events
 */
function returnToPage(page, events) {
  return page.evaluate((list) => {
    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'visible' });
    for (const event of list) {
      if (event === 'visible') document.dispatchEvent(new Event('visibilitychange'));
      else dispatchEvent(new PageTransitionEvent('pageshow', { persisted: event === 'restored' }));
    }
  }, events);
}

/**
 * The `data-state` of every screen the page has mounted.
 * @param {Page} page
 */
async function states(page) {
  return (await screensSeen(page)).map((screen) => screen.state);
}

/**
 * Pairs, waits for the app, and has the laptop drop off its room: the strip reads
 * "Reconnecting…" over the app frame.
 * @param {Page} page
 * @param {FakeLaptopServer} server
 */
async function reconnectingOverApp(page, server) {
  const { laptop } = await pairViaFragment(page, server);
  await waitForAppText(page);
  const room = deviceRoom(laptop);
  laptop.leave(room);
  await expect(page.locator('#strip [data-state="reconnect"]')).toBeVisible();
  await expect(page.locator('#frame-host iframe')).toHaveCount(1);
  return { laptop, room };
}

/**
 * A full screen replaced the app while the strip read "Reconnecting…": the strip still names
 * the laptop and says nothing more, at once, and the frame is gone.
 * @param {Page} page
 */
async function expectBareStrip(page) {
  expect(await page.locator('[data-state="reconnect"]').count()).toBe(0);
  await expect(stripButton(page).locator('b')).toHaveText('acme-mbp');
  await expect(page.locator('iframe')).toHaveCount(0);
}

// --- full screens --------------------------------------------------------------------------

test('Laptop offline, then it connects when the laptop joins', async ({ page, server }) => {
  const { laptop } = await pairViaFragment(page, server);
  await waitForAppText(page);
  const room = deviceRoom(laptop);
  laptop.leave(room);
  await page.reload();
  await expect(page.locator('[data-state="offline"] h2')).toHaveText('Laptop offline');
  await expect(page.locator('iframe')).toHaveCount(0);

  laptop.join(room);
  await waitForAppFrame(page);
  await waitForAppText(page);
  await expect(page.locator('[data-state="offline"]')).toHaveCount(0);
});

test('Can\'t reach the relay', async ({ page, server }) => {
  await pairViaFragment(page, server);
  await waitForAppText(page);
  server.refuseUpgrade = true;
  await page.reload();
  await expect(page.locator('[data-state="relay"] h2')).toHaveText('Can\'t reach the relay');
  await expect(stripButton(page).locator('b')).toHaveText('acme-mbp');
});

for (const { title, setup, state, heading, body } of [
  {
    title: 'Update TBD on this laptop, for a laptop too old for this page',
    /** @param {any} laptop */
    setup: (laptop) => laptop.setIncompatible('laptop'),
    state: 'update',
    heading: 'Update TBD on this laptop',
    body: 'This page is newer than TBD on acme-mbp. On the laptop, run tbd update, then try again.',
  },
  {
    title: 'Reload this page, for a laptop that finds this page too old',
    /** @param {any} laptop */
    setup: (laptop) => laptop.setIncompatible('loader'),
    state: 'reload',
    heading: 'Reload this page',
    body: 'TBD on acme-mbp is newer than this page. Reload to get the new page.',
  },
  {
    title: 'Reload this page, for a welcome with protocol 2',
    /** @param {any} laptop */
    setup: (laptop) => laptop.setWelcome({ protocol: 2 }),
    state: 'reload',
    heading: 'Reload this page',
    body: 'TBD on acme-mbp is newer than this page. Reload to get the new page.',
  },
]) {
  test(title, async ({ page, server }) => {
    const { laptop } = await pairViaFragment(page, server);
    await waitForAppText(page);
    setup(laptop);
    const fetched = laptop.counts.bundleGet;
    await page.reload();
    const screen = page.locator(`[data-state="${state}"]`);
    await expect(screen.locator('h2')).toHaveText(heading);
    await expect(screen.locator('p')).toHaveText(body);
    await expect(page.locator('iframe')).toHaveCount(0);
    expect(laptop.counts.bundleGet).toBe(fetched);
  });
}

test('revoked shows the removed message, and Forget deletes keys and bundles', async ({ page, server }) => {
  const { laptop } = await pairViaFragment(page, server);
  await waitForAppText(page);
  await expect.poll(async () => (await readLoaderDB(page)).bundles.length).toBe(1);
  await laptop.revoke(deviceRoom(laptop));

  const removed = page.locator('[data-state="removed"]');
  await expect(removed.locator('h2')).toHaveText('This phone was removed from acme-mbp');
  await expect(page.locator('iframe')).toHaveCount(0);
  await removed.getByRole('button', { name: 'Forget acme-mbp' }).click();
  // Cancel keeps everything; Forget, confirmed, deletes it.
  await removed.getByRole('button', { name: 'Cancel' }).click();
  await expect(removed.getByRole('button', { name: 'Forget', exact: true })).toHaveCount(0);
  expect((await readLoaderDB(page)).laptops).toHaveLength(1);
  await removed.getByRole('button', { name: 'Forget acme-mbp' }).click();
  await removed.getByRole('button', { name: 'Forget', exact: true }).click();

  await expect(page.locator('[data-state="scan"], [data-state="paste"]')).toBeVisible();
  expect(await readLoaderDB(page)).toEqual(EMPTY_DB);
});

test('the header strip names the laptop from the handshake', async ({ page, server }) => {
  const laptop = server.laptops[0];
  // The link's name is what the laptop was called when it made the code; the handshake's is
  // what it is called now.
  const link = linkFromFields(server.origin, { ...linkFields(server.pairingLink(laptop)), name: 'acme-old-name' });
  await pairViaFragment(page, server, { link });
  await waitForAppText(page);
  expect((await screensSeen(page)).find((screen) => screen.state === 'name')?.text).toContain('acme-old-name');
  await expect(stripButton(page).locator('b')).toHaveText('acme-mbp');
  await page.reload();
  await waitForAppText(page);
  await expect(stripButton(page).locator('b')).toHaveText('acme-mbp');
});

test('an unknown phone key reads as Laptop offline, through one round of retries and no more', async ({ page, server }) => {
  await page.clock.install();
  const { laptop } = await pairViaFragment(page, server);
  await waitForAppText(page);
  const room = deviceRoom(laptop);
  // What a phone revoked while it was away meets: plan 3 refuses an unknown key with no reply.
  laptop.devices.clear();
  const refused = laptop.counts.refused;
  await watchSockets(page);
  await page.reload();
  // Message 1 reached the laptop, so the handshake timeout is running.
  await expect.poll(() => laptop.counts.refused).toBe(refused + 1);
  await expect(page.locator('[data-state="connecting"]')).toBeVisible();
  await page.clock.fastForward(10_000);
  await expect(page.locator('[data-state="offline"] h2')).toHaveText('Laptop offline');

  // The phone retries on a fresh socket after each backoff (1 s, 2 s, 4 s, each with up to a
  // quarter of jitter), HANDSHAKE_RETRIES times. The laptop refuses each message 1 too.
  for (let i = 0; i < HANDSHAKE_RETRIES; i += 1) {
    await page.clock.fastForward(1_250 * 2 ** i);
    await expect.poll(() => laptop.counts.refused).toBe(refused + i + 2);
    await page.clock.fastForward(10_000);
  }
  // After the round the socket stays and waits: no more sockets, and no more message 1s.
  await page.clock.fastForward(5 * 60_000);
  expect(await phoneSocketsTo(page, room)).toBe(1 + HANDSHAKE_RETRIES);
  expect(laptop.counts.refused).toBe(refused + 1 + HANDSHAKE_RETRIES);
  const seen = await states(page);
  expect(seen.slice(seen.indexOf('offline'))).toEqual(['offline']);
  await expect(page.locator('[data-state="offline"] h2')).toHaveText('Laptop offline');

  // A return to the page starts one more round, at once.
  await returnToPage(page, ['visible']);
  await expect.poll(() => laptop.counts.refused).toBe(refused + 2 + HANDSHAKE_RETRIES);
  expect(await phoneSocketsTo(page, room)).toBe(2 + HANDSHAKE_RETRIES);
});

// --- keys and the socket -------------------------------------------------------------------

test('the wrapped key survives a reload', async ({ context, page, server }) => {
  const { laptop } = await pairViaFragment(page, server);
  await waitForAppText(page);
  const before = { ...laptop.counts };
  await page.close();

  const next = await context.newPage();
  await next.goto(`${server.origin}/`);
  await waitForAppFrame(next);
  await waitForAppText(next);
  expect(laptop.counts.handshakes).toBe(before.handshakes + 1);
  expect(laptop.counts.ikHandshakes).toBe(before.ikHandshakes + 1);
  expect(laptop.counts.pairings).toBe(before.pairings);
  expect(await states(next)).not.toContain('key-missing');
});

test('keepalive pings every 30 s', async ({ page, server }) => {
  await page.clock.install();
  await watchSockets(page);
  const { laptop } = await pairViaFragment(page, server);
  await waitForAppText(page);
  const room = deviceRoom(laptop);
  const pings = () => server.relay.stats.pings.get(room) ?? 0;
  expect(pings()).toBe(0);

  for (const n of [1, 2]) {
    await page.clock.fastForward(30_000);
    await expect.poll(pings).toBe(n);
    // The pong is in before the next keepalive, which would otherwise call the socket dead.
    await expect.poll(async () => (await socketLog(page)).pongs).toBe(n);
  }
  expect(await phoneSocketsTo(page, room)).toBe(1);
  await expect(page.locator('[data-state="reconnect"]')).toHaveCount(0);
  await appRoundTrip(page, laptop);
});

test('returning to the page with a dead socket reconnects', async ({ page, server }) => {
  await page.clock.install();
  const { laptop } = await pairViaFragment(page, server);
  await waitForAppText(page);
  const room = deviceRoom(laptop);
  const joins = () => server.relay.stats.phoneJoins.get(room) ?? 0;
  const before = joins();

  server.relay.blackHole(room, true);
  await returnToPage(page, ['visible']);
  // The liveness probe's ping reached the relay and the black hole took it, so no pong comes.
  await expect.poll(() => server.relay.stats.swallowed.get(room) ?? 0).toBe(1);
  server.relay.blackHole(room, false);
  await page.clock.fastForward(3_000);

  await expect.poll(joins).toBe(before + 1);
  await expect.poll(() => laptop.counts.ikHandshakes).toBe(2);
  await expect(page.locator('[data-state="reconnect"]')).toHaveCount(0);
  expect(await states(page)).toContain('reconnect');
  await expect(stripButton(page).locator('b')).toHaveText('acme-mbp');
  await expect(page.locator('iframe')).toHaveCount(1);
  await appRoundTrip(page, laptop);
  expect(joins()).toBe(before + 1);
});

test('a second tab takes over; the first shows Connected in another tab and does not reconnect', async ({ context, page, server }) => {
  await page.clock.install();
  const { laptop } = await pairViaFragment(page, server);
  await waitForAppText(page);
  const room = deviceRoom(laptop);
  const joins = () => server.relay.stats.phoneJoins.get(room) ?? 0;
  const before = joins();

  const second = await context.newPage();
  await second.goto(`${server.origin}/`);
  await waitForAppText(second);
  await expect(page.locator('[data-state="replaced"] h2')).toHaveText('Connected in another tab');
  await expect(page.locator('iframe')).toHaveCount(0);
  await expect(stripButton(page).locator('b')).toHaveText('acme-mbp');
  expect(joins()).toBe(before + 1);

  // The context's one clock: every timer either page has runs.
  await page.clock.fastForward(120_000);
  // A reconnect from the first page would take the room back from the second.
  await appRoundTrip(second, laptop);
  expect(joins()).toBe(before + 1);
  await expect(page.locator('[data-state="replaced"]')).toBeVisible();
});

// --- the header strip ----------------------------------------------------------------------

test('the strip reads Reconnecting… while the channel is down, and the laptop name once ready', async ({ page, server }) => {
  const { laptop, room } = await reconnectingOverApp(page, server);
  const reconnect = page.locator('#strip [data-state="reconnect"]');
  await expect(reconnect).toHaveText('Reconnecting…');
  await expect(stripButton(page).locator('b')).toHaveText('acme-mbp');

  laptop.join(room);
  await expect(reconnect).toHaveCount(0);
  await expect(stripButton(page).locator('b')).toHaveText('acme-mbp');
  await expect(page.locator('#frame-host iframe')).toHaveCount(1);
  await appRoundTrip(page, laptop);
});

test.describe('no stale strip on a full screen', () => {
  test('the laptop comes back too old: Update TBD on this laptop', async ({ page, server }) => {
    const { laptop, room } = await reconnectingOverApp(page, server);
    laptop.setIncompatible('laptop');
    laptop.join(room);
    await expect(page.locator('[data-state="update"] h2')).toHaveText('Update TBD on this laptop');
    await expectBareStrip(page);
  });

  test('the laptop revokes the phone while its new bundle loads: removed', async ({ page, server }) => {
    const { laptop, room } = await reconnectingOverApp(page, server);
    laptop.setBundle(server.debugBundle('next'));
    laptop.onChunk(() => 'stop');
    const asked = laptop.counts.bundleGet;
    laptop.join(room);
    // The phone is loading the new bundle under the old frame, so the strip still reads
    // "Reconnecting…".
    await expect.poll(() => laptop.counts.bundleGet).toBe(asked + 1);
    await expect(page.locator('#strip [data-state="reconnect"]')).toBeVisible();
    await laptop.revoke(room);
    await expect(page.locator('[data-state="removed"] h2')).toHaveText('This phone was removed from acme-mbp');
    await expectBareStrip(page);
  });

  test('a bad bundle while loading: Reload this page', async ({ page, server }) => {
    const { laptop, room } = await reconnectingOverApp(page, server);
    laptop.setBundle(server.debugBundle('next'));
    laptop.setWelcome({ bundle: { sha256: '0'.repeat(64) } });
    const asked = laptop.counts.bundleGet;
    laptop.join(room);
    await expect(page.locator('[data-state="reload"] h2')).toHaveText('Reload this page');
    expect(laptop.counts.bundleGet).toBe(asked + 1);
    await expectBareStrip(page);
  });

  test('a second tab takes the room: Connected in another tab', async ({ context, page, server }) => {
    await reconnectingOverApp(page, server);
    const second = await context.newPage();
    await second.goto(`${server.origin}/`);
    await expect(page.locator('[data-state="replaced"] h2')).toHaveText('Connected in another tab');
    await expectBareStrip(page);
    await expect(second.locator('[data-state="offline"]')).toBeVisible();
  });

  test('the app frame faults: Reload this page', async ({ page, server }) => {
    await reconnectingOverApp(page, server);
    const frame = page.frames().find((f) => f.url().includes('/runner.html'));
    if (frame === undefined) throw new Error('no app frame');
    // The runner never navigates, so a second load is a fault.
    await frame.evaluate(() => {
      location.href = '/__test/nav';
    }).catch(() => {
      // The frame may be gone before the evaluation answers.
    });
    await expect(page.locator('[data-state="reload"] h2')).toHaveText('Reload this page');
    await expectBareStrip(page);
  });
});

// --- resumes -------------------------------------------------------------------------------

/**
 * Pairs, then reloads with every upgrade held, so the page's first socket stays connecting.
 * @param {Page} page
 * @param {FakeLaptopServer} server
 */
async function connectingAfterReload(page, server) {
  await page.clock.install();
  await watchSockets(page);
  const { laptop } = await pairViaFragment(page, server);
  await waitForAppText(page);
  const room = deviceRoom(laptop);
  const release = server.holdUpgrades();
  await page.reload();
  await expect(page.locator('[data-state="connecting"]')).toBeVisible();
  await expect.poll(() => phoneSocketsTo(page, room)).toBe(1);
  return { laptop, room, release };
}

test('a return to the page opens one socket, whatever fires; a first load\'s pageshow opens none', async ({ page, server }) => {
  const { room, release } = await connectingAfterReload(page, server);
  await returnToPage(page, ['pageshow']);
  // Past the coalescing window, so a socket that pageshow opened would not absorb the next.
  await page.clock.fastForward(RESUME_COALESCE_MS);
  await returnToPage(page, ['visible', 'restored']);
  await expect.poll(() => phoneSocketsTo(page, room)).toBe(2);

  release();
  await waitForAppFrame(page);
  await waitForAppText(page);
  // Each resume runs on the connection's chain at once, long before it is ready.
  expect(await phoneSocketsTo(page, room)).toBe(2);
});

test('a later resume is not delayed', async ({ page, server }) => {
  const { room, release } = await connectingAfterReload(page, server);
  await returnToPage(page, ['visible']);
  await expect.poll(() => phoneSocketsTo(page, room)).toBe(2);
  await page.clock.fastForward(RESUME_COALESCE_MS);
  // A second return to the page replaces the socket at once, not after the signal timeout.
  await returnToPage(page, ['visible']);
  await expect.poll(() => phoneSocketsTo(page, room)).toBe(3);

  release();
  await waitForAppFrame(page);
  await waitForAppText(page);
  expect(await phoneSocketsTo(page, room)).toBe(3);
});
