// The channel's shared vectors inside each engine the loader runs in: WebKit as an iPhone and
// Chromium as an Android phone. Plan 1 runs them in Node; spec section 14 wants them in the
// browser too, since the phone's Web Crypto is what pairs and reconnects.
//
// The page is the test server's blank page on the loader's origin. It imports plan 1's modules
// from the staged site, as the loader does, and the runner (test/support/vectors-in-page.js)
// from `/__test/support/`, fetches the vector files from `/__test/vectors/`, and runs them.
// The number of cases is counted here, in Node, so a page that loads nothing cannot pass.

import { readFileSync } from 'node:fs';

import { expect, test } from './fixtures.js';

const NAMES = ['noise-cacophony.json', 'framing.json', 'confirmation-code.json', 'pairing-link.json'];
const CHANNEL_MODULES = ['/channel/noise.js', '/channel/confirm.js', '/channel/pairingLink.js'];

/** @type {Record<string, any>} */
const files = Object.fromEntries(NAMES.map((name) => [
  name,
  JSON.parse(readFileSync(new URL(`../../../test-vectors/${name}`, import.meta.url), 'utf8')),
]));
const link = files['pairing-link.json'];
const EXPECTED_CHECKED = 2 + files['framing.json'].messages.length + 1 + files['confirmation-code.json'].cases.length
  + link.base64url.valid.length + link.base64url.invalid.length + link.valid.length + link.invalid.length;

test('this engine has X25519, AES-GCM, HMAC and SHA-256 in Web Crypto', async ({ page, server }) => {
  await page.goto(`${server.origin}/__test/blank.html`);
  const result = await page.evaluate(async () => {
    const { subtle } = crypto;
    /** Each step's result, or the error it threw. @param {() => Promise<unknown>} step */
    const attempt = async (step) => {
      try {
        return await step();
      } catch (error) {
        return error instanceof Error ? `${error.name}: ${error.message}` : String(error);
      }
    };
    const bytes = new Uint8Array(32).fill(7);
    return {
      secureContext: isSecureContext,
      x25519: await attempt(async () => {
        const a = /** @type {CryptoKeyPair} */ (await subtle.generateKey({ name: 'X25519' }, true, ['deriveBits']));
        const b = /** @type {CryptoKeyPair} */ (await subtle.generateKey({ name: 'X25519' }, true, ['deriveBits']));
        const shared = await subtle.deriveBits({ name: 'X25519', public: b.publicKey }, a.privateKey, 256);
        const publicRaw = await subtle.exportKey('raw', a.publicKey);
        return { shared: shared.byteLength, publicKey: publicRaw.byteLength };
      }),
      aesGcm: await attempt(async () => {
        const key = await subtle.importKey('raw', bytes, 'AES-GCM', false, ['encrypt']);
        const sealed = await subtle.encrypt({ name: 'AES-GCM', iv: new Uint8Array(12) }, key, new Uint8Array(1));
        return sealed.byteLength;
      }),
      hmac: await attempt(async () => {
        const key = await subtle.importKey('raw', bytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
        return (await subtle.sign('HMAC', key, new Uint8Array(1))).byteLength;
      }),
      sha256: await attempt(async () => (await subtle.digest('SHA-256', new Uint8Array(1))).byteLength),
    };
  });
  expect(result).toEqual({
    secureContext: true,
    x25519: { shared: 32, publicKey: 32 },
    aesGcm: 17,
    hmac: 32,
    sha256: 32,
  });
});

test('channel vectors pass in this engine', async ({ page, server }) => {
  await page.goto(`${server.origin}/__test/blank.html`);
  const result = await page.evaluate(async ({ names, modules }) => {
    /** @param {string} path */
    const load = (path) => import(new URL(path, location.href).href);
    const [noise, confirm, pairingLink, runner] = await Promise.all(
      [...modules, '/__test/support/vectors-in-page.js'].map(load));
    /** @type {Record<string, unknown>} */
    const vectorFiles = {};
    for (const name of names) {
      const response = await fetch(`/__test/vectors/${name}`);
      if (!response.ok) throw new Error(`${name}: HTTP ${response.status}`);
      vectorFiles[name] = await response.json();
    }
    return runner.runChannelVectors({ noise, confirm, pairingLink, files: vectorFiles });
  }, { names: NAMES, modules: CHANNEL_MODULES });
  expect(result.failures).toEqual([]);
  expect(result.checked).toBe(EXPECTED_CHECKED);
  // The modules came from the staged site, not from a test route.
  expect(server.requests).toEqual(expect.arrayContaining(CHANNEL_MODULES));
});
