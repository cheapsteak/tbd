// Pairing, end to end: the loader's pair, paste, name and code screens against a scripted
// laptop, in WebKit as an iPhone and in Chromium as an Android phone.
//
// The QR fixture, ../fixtures/qr-sample.png, was made once, from the repository root, with
// qrencode 4.1.1:
//
//   qrencode -l M -s 8 -m 4 -o phone/loader/test/fixtures/qr-sample.png 'https://acme.github.io/#p=eyJ2IjoxLCJyZWxheSI6Imh0dHBzOi8vYWNtZS1yZWxheS5hY21lLndvcmtlcnMuZGV2Iiwicm9vbSI6IkFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUEiLCJzZWNyZXQiOiJFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFIiwia2V5IjoiSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSSIsIm5hbWUiOiJhY21lLW1icCIsImV4cCI6NDEwMjQ0NDgwMH0'
//
// The link, QR_LINK below, is `https://acme.github.io/#p=` and the base64url of
// {"v":1,"relay":"https://acme-relay.acme.workers.dev","room":"<43×A>","secret":"<43×E>",
// "key":"<43×I>","name":"acme-mbp","exp":4102444800}. A, E and I leave the spare bits zero,
// so the link passes plan 1's strict base64url. "jsQR decodes the sample code" checks that the
// vendored jsQR reads the PNG back as exactly that link, in both engines.

import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { base64urlEncode } from '../../channel/pairingLink.js';
import { formatCode } from '../../format.js';
import { generatePair } from '../support/x25519.js';
import {
  expect, frameText, linkFields, linkFromFields, openPasteScreen, pairViaFragment, pairViaPaste, pasteLink,
  readLoaderDB, screensSeen, submitName, test,
} from './fixtures.js';

const QR_LINK = 'https://acme.github.io/#p=eyJ2IjoxLCJyZWxheSI6Imh0dHBzOi8vYWNtZS1yZWxheS5hY21lLndvcmtlcnMuZGV2Iiwicm9vbSI6IkFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUEiLCJzZWNyZXQiOiJFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFIiwia2V5IjoiSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSSIsIm5hbWUiOiJhY21lLW1icCIsImV4cCI6NDEwMjQ0NDgwMH0';

const VECTORS = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../test-vectors/pairing-link.json');

const EMPTY_DB = { laptops: [], rooms: [], bundles: [] };

/**
 * The refusal the paste screen shows under its field.
 * @param {import('@playwright/test').Page} page
 */
const pasteRefusal = (page) => page.locator('[data-state="paste"] [role="alert"]');

test('pairs from a pasted link', async ({ page, server, browserName }) => {
  const laptop = server.laptops[0];
  await page.goto(`${server.origin}/`);
  await openPasteScreen(page);
  await pasteLink(page, server.pairingLink(laptop));

  const field = page.locator('[data-state="name"] #phone-name');
  await expect(field).toHaveValue(browserName === 'webkit' ? 'iPhone' : 'Android phone');
  await submitName(page, 'acme-phone');

  await expect.poll(() => frameText(page)).toContain('acme-api');
  // The code screen is replaced as soon as `paired` arrives, so it is read from the screens
  // the page mounted: the code element's whole text, lead and digits together.
  const codes = (await screensSeen(page)).filter((screen) => screen.state === 'code').map((screen) => screen.code);
  expect(laptop.lastCode).toMatch(/^\d{6}$/);
  expect(codes).toEqual([`Check this code on your laptop: ${formatCode(laptop.lastCode)}`]);
  expect([...laptop.devices.values()].map((device) => device.deviceName)).toEqual(['acme-phone']);
  expect((await readLoaderDB(page)).laptops).toEqual([base64urlEncode(laptop.publicKey)]);
});

test('pairs from a #p= fragment on load and removes it', async ({ page, server }) => {
  const laptop = server.laptops[0];
  // A page before the link, so the history has an entry to go back to.
  await page.goto(`${server.origin}/__test/blank.html`);
  const link = server.pairingLink(laptop);
  await page.goto(link);
  await expect(page.locator('[data-state="name"]')).toBeVisible();
  expect(await page.evaluate(() => location.hash)).toBe('');
  expect(page.url()).toBe(`${server.origin}/`);

  await submitName(page);
  await expect.poll(() => frameText(page)).toContain('acme-api');
  expect(laptop.devices.size).toBe(1);

  // Walk the whole history: no entry holds the pairing link.
  const length = await page.evaluate(() => history.length);
  expect(length).toBeGreaterThanOrEqual(2);
  const visited = [await page.evaluate(() => location.href)];
  for (let i = 1; i < length; i++) {
    await page.goBack();
    visited.push(await page.evaluate(() => location.href));
  }
  for (let i = 1; i < length; i++) {
    await page.goForward();
    visited.push(await page.evaluate(() => location.href));
  }
  expect(visited).toContain(`${server.origin}/__test/blank.html`);
  expect(visited.at(-1)).toBe(`${server.origin}/`);
  for (const href of visited) expect(href).not.toContain('#p=');
});

test('a #p= link arriving by hashchange starts pairing and leaves no fragment', async ({ page, server }) => {
  const laptop = server.laptops[0];
  await page.goto(`${server.origin}/`);
  await expect(page.locator('[data-state="scan"], [data-state="paste"]')).toBeVisible();

  const { hash } = new URL(server.pairingLink(laptop));
  // The loader's own `hashchange` listener was added first, so it has run by the time this
  // one reads the address.
  const hashAfter = await page.evaluate((next) => new Promise((resolve) => {
    addEventListener('hashchange', () => resolve(location.hash), { once: true });
    location.hash = next;
  }), hash);
  expect(hashAfter).toBe('');
  await expect(page.locator('[data-state="name"]')).toBeVisible();
  expect(page.url()).toBe(`${server.origin}/`);

  await submitName(page);
  await expect.poll(() => frameText(page)).toContain('acme-api');
  expect(laptop.devices.size).toBe(1);
});

test('the stored room is the laptop\'s new room, not the QR code\'s room', async ({ page, server }) => {
  const { laptop, link } = await pairViaFragment(page, server);
  await expect.poll(() => frameText(page)).toContain('acme-api');
  const offerRoom = linkFields(link).room;
  const deviceRooms = [...laptop.devices.keys()];
  expect(deviceRooms).toHaveLength(1);
  const { rooms } = await readLoaderDB(page);
  expect(rooms).toEqual(deviceRooms);
  expect(rooms[0]).not.toBe(offerRoom);
});

test('deny shows Pairing was declined on the laptop. and saves nothing', async ({ page, server }) => {
  const { laptop } = await pairViaPaste(page, server, { decision: 'deny' });
  await expect(page.locator('[data-state="denied"] h2')).toHaveText('Pairing was declined on the laptop.');
  expect(laptop.counts.hello).toBe(1);
  expect(laptop.devices.size).toBe(0);
  expect(await readLoaderDB(page)).toEqual(EMPTY_DB);
});

test('laptop expiry shows the expired message and saves nothing', async ({ page, server }) => {
  const { laptop } = await pairViaPaste(page, server, { decision: 'expire' });
  await expect(page.locator('[data-state="expired"] h2')).toHaveText('This pairing code expired. Make a new one on the laptop.');
  expect(laptop.counts.hello).toBe(1);
  expect(laptop.devices.size).toBe(0);
  expect(await readLoaderDB(page)).toEqual(EMPTY_DB);
});

test('a link already past exp plus 120 s is refused before any socket opens', async ({ page, server }) => {
  await page.goto(`${server.origin}/`);
  await openPasteScreen(page);
  await pasteLink(page, server.pairingLink(server.laptops[0], { expSeconds: -121 }));
  await expect(pasteRefusal(page)).toHaveText('This pairing code expired. Make a new one on the laptop.');
  expect(server.relay.stats.phoneJoins.size).toBe(0);
  expect(server.requests.filter((url) => url.startsWith('/v1/rooms/'))).toEqual([]);
});

test('a used code shows the no-longer-valid message after 10 s', async ({ page, server }) => {
  const laptop = server.laptops[0];
  await page.clock.install();
  await page.goto(`${server.origin}/`);
  await openPasteScreen(page);
  // The laptop is in the pairing room but never answers message 1, as plan 3's laptop treats a
  // used or unknown offer. The scripted laptop does that for a message 1 it cannot read, which
  // a link naming another laptop key makes.
  const { publicRaw } = await generatePair();
  const link = linkFromFields(server.origin, { ...linkFields(server.pairingLink(laptop)), key: base64urlEncode(publicRaw) });
  await pasteLink(page, link);
  await submitName(page);
  await expect(page.locator('[data-state="pairing"]')).toBeVisible();
  // Message 1 reached the laptop, so the handshake timeout is running.
  await expect.poll(() => laptop.counts.refused).toBe(1);
  await expect(page.locator('[data-state="pairing"]')).toBeVisible();

  await page.clock.fastForward(10_000);
  await expect(page.locator('[data-state="pair-invalid"] h2'))
    .toHaveText('This pairing code is no longer valid. Make a new one on the laptop.');
  expect(laptop.lastCode).toBeNull();
  expect(laptop.devices.size).toBe(0);
  expect(await readLoaderDB(page)).toEqual(EMPTY_DB);
});

test('garbage pasted text shows This is not a TBD pairing link.', async ({ page, server }) => {
  await page.goto(`${server.origin}/`);
  await openPasteScreen(page);
  await pasteLink(page, 'acme says hello');
  await expect(pasteRefusal(page)).toHaveText('This is not a TBD pairing link.');
  await expect(page.locator('#paste-link')).toHaveValue('acme says hello');
  expect(server.relay.stats.phoneJoins.size).toBe(0);
});

test('a link with a damaged payload shows the damaged-link message, and a v2 link shows Reload this page', async ({ page, server }) => {
  const vectors = JSON.parse(await readFile(VECTORS, 'utf8'));
  /** @param {(c: { error: string, description: string }) => boolean} pick */
  const linkFor = (pick) => {
    const found = vectors.invalid.find(pick);
    if (found === undefined) throw new Error('pairing-link.json has no such case');
    return found.url.replace(vectors.loaderURL, `${server.origin}/`);
  };
  const damaged = linkFor((c) => c.error === 'badJSON');
  const v2 = linkFor((c) => c.error === 'unsupportedVersion' && c.description === 'v is 2');
  expect(damaged.startsWith(`${server.origin}/#p=`)).toBe(true);
  expect(v2.startsWith(`${server.origin}/#p=`)).toBe(true);

  await page.goto(`${server.origin}/`);
  await openPasteScreen(page);
  await pasteLink(page, damaged);
  await expect(pasteRefusal(page)).toHaveText('This pairing link is damaged. Make a new one on the laptop.');
  await pasteLink(page, v2);
  await expect(pasteRefusal(page)).toHaveText('Reload this page');
  expect(server.relay.stats.phoneJoins.size).toBe(0);
});

test('the camera failing shows the paste fallback', async ({ page, server, browserName }) => {
  test.skip(browserName !== 'webkit', 'WebKit only: it has no camera here');
  await page.goto(`${server.origin}/`);
  await expect(pasteRefusal(page)).toHaveText('Camera unavailable. Paste the link instead.');
  await expect(page.locator('#paste-link')).toBeFocused();
});

test('the camera starts, and leaving the pair screen stops every track', async ({ page, server, browserName }) => {
  test.skip(browserName !== 'chromium', 'Chromium only: its fake camera');
  await page.goto(`${server.origin}/`);
  const scan = page.locator('[data-state="scan"]');
  await expect(scan).toBeVisible();
  // Keep the stream: leaving the screen takes it off the video element.
  await page.waitForFunction(() => {
    const stream = /** @type {HTMLVideoElement | null} */ (document.querySelector('[data-state="scan"] video'))?.srcObject;
    if (!(stream instanceof MediaStream)) return false;
    /** @type {any} */ (window).__cameraStream = stream;
    return stream.getVideoTracks().length > 0 && stream.getTracks().every((track) => track.readyState === 'live');
  });

  await scan.getByRole('button', { name: 'Cancel' }).click();
  await expect(page.locator('[data-state="laptops"]')).toBeVisible();
  expect(await page.evaluate(() => {
    const stream = /** @type {MediaStream} */ (/** @type {any} */ (window).__cameraStream);
    return stream.getTracks().every((track) => track.readyState === 'ended');
  })).toBe(true);
  await expect(page.locator('video')).toHaveCount(0);
});

test('jsQR decodes the sample code', async ({ page, server }) => {
  await page.goto(`${server.origin}/`);
  await expect(page.locator('[data-state="scan"], [data-state="paste"]')).toBeVisible();
  const text = await page.evaluate(async () => {
    const { scanImage } = await import(new URL('/qr.js', location.href).href);
    const img = new Image();
    img.src = '/__test/qr.png';
    await img.decode();
    return scanImage(img, 'jsqr');
  });
  expect(text).toBe(QR_LINK);
  expect(linkFields(QR_LINK)).toEqual({
    v: 1,
    relay: 'https://acme-relay.acme.workers.dev',
    room: 'A'.repeat(43),
    secret: 'E'.repeat(43),
    key: 'I'.repeat(43),
    name: 'acme-mbp',
    exp: 4102444800,
  });
});
