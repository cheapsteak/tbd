import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import { createInitiator, phonePrologue } from '../../channel/noise.js';
import { PairingLinkError, base64urlDecode, base64urlEncode, parsePairingLink } from '../../channel/pairingLink.js';
import { LOADER_VERSION } from '../../constants.js';
import {
  deviceNameFromUserAgent, isRoomID, linkErrorMessage, normalizeDeviceName, readPairingLink,
  relayPresenceURL, relaySocketURL, takePairingFragment,
} from '../../links.js';
import { createFakeRelay } from '../support/fake-relay.js';
import { fakeSocketFactory } from '../support/fake-websocket.js';
import { createScriptedLaptop } from '../support/scripted-laptop.js';

// Playwright 1.65.0's devices['iPhone 15'], devices['Pixel 7'], devices['Desktop Safari'] (an
// iPad asking for desktop sites sends this Mac user agent), devices['iPad Pro 11'] and
// devices['Galaxy Tab S4'], copied from its device descriptors.
const IPHONE_15_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2 Mobile/15E148 Safari/604.1';
const PIXEL_7_UA = 'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/158.0.8127.18 Mobile Safari/537.36';
const IPAD_DESKTOP_UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2 Safari/605.1.15';
const IPAD_PRO_11_UA = 'Mozilla/5.0 (iPad; CPU OS 12_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2 Mobile/15E148 Safari/604.1';
const GALAXY_TAB_S4_UA = 'Mozilla/5.0 (Linux; Android 8.1.0; SM-T837A) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/158.0.8127.18 Safari/537.36';

const file = JSON.parse(readFileSync(new URL('../../../test-vectors/pairing-link.json', import.meta.url), 'utf8'));
const NOW = file.now * 1000, V1 = file.valid[0], ROOM = V1.link.room;
const WAIT_MS = 5_000;

/** @param {unknown} value */
const encode = (value) => new TextEncoder().encode(JSON.stringify(value));
/** @param {Uint8Array} bytes */
const decode = (bytes) => JSON.parse(new TextDecoder().decode(bytes));
/** @param {string} text */
const b64 = (text) => /** @type {Uint8Array} */ (base64urlDecode(text));
const sleep = (/** @type {number} */ ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * @param {() => boolean} predicate
 * @param {string} what
 */
async function until(predicate, what) {
  const deadline = Date.now() + WAIT_MS;
  while (!predicate()) {
    if (Date.now() > deadline) assert.fail(`timed out waiting for ${what}`);
    await sleep(1);
  }
}

/**
 * The relay field of a vector link, read without the parser.
 * @param {string} url
 * @returns {unknown}
 */
function vectorRelay(url) {
  const payload = base64urlDecode(url.slice(url.indexOf('#p=') + 3));
  if (payload === null) return undefined;
  try {
    return JSON.parse(new TextDecoder().decode(payload)).relay;
  } catch {
    return undefined;
  }
}

test('reads the vector link and decodes its keys', () => {
  const r = readPairingLink(V1.url, NOW);
  assert.deepEqual(r.fields, V1.link);
  assert.deepEqual(r.room, Uint8Array.from({ length: 32 }, (_, i) => i));
  assert.deepEqual(r.secret, Uint8Array.from({ length: 32 }, (_, i) => i + 32));
  assert.deepEqual(r.laptopKey, b64(V1.link.key));
  assert.equal(r.laptopKey.length, 32);
});

test('every valid vector reads', () => {
  for (const c of file.valid) assert.deepEqual(readPairingLink(c.url, NOW).fields, c.link, c.description);
});

test('every invalid vector except expiry rethrows its PairingLinkError', () => {
  for (const c of file.invalid.filter((/** @type {any} */ c) => c.error !== 'expired')) {
    assert.throws(() => readPairingLink(c.url, NOW), (error) => {
      assert.ok(error instanceof PairingLinkError, c.description);
      assert.equal(error.code, c.error, c.description);
      assert.equal(error.field, c.field, c.description);
      return true;
    });
  }
});

test('expiry grace is 120 s past exp', () => {
  /** @param {number} exp */
  const at = (exp) => file.loaderURL + '#p=' + base64urlEncode(encode({ ...V1.link, exp }));
  assert.doesNotThrow(() => readPairingLink(at(file.now - 119), NOW));
  assert.throws(() => readPairingLink(at(file.now - 120), NOW), { code: 'expired' });
  // The grace is subtracted from now, never added: a link the parser takes stays taken.
  assert.doesNotThrow(() => readPairingLink(at(file.now + 1), NOW));
});

test('a clock that is not a finite number is refused, never read as "not expired"', () => {
  const expired = file.loaderURL + '#p=' + base64urlEncode(encode({ ...V1.link, exp: file.now - 3600 }));
  assert.throws(() => readPairingLink(expired, NOW), { code: 'expired' });
  for (const now of [NaN, undefined, null, Infinity, -Infinity, String(NOW), BigInt(NOW)]) {
    for (const url of [expired, V1.url]) {
      assert.throws(() => readPairingLink(url, /** @type {any} */ (now)), TypeError, String(now));
    }
  }
});

test('each error code has its screen', () => {
  /** @param {any} code */
  const m = (code) => linkErrorMessage(new PairingLinkError(code));
  assert.equal(m('missingFragment'), 'This is not a TBD pairing link.');
  for (const code of ['badBase64', 'badJSON', 'badField'])
    assert.equal(m(code), 'This pairing link is damaged. Make a new one on the laptop.');
  assert.equal(m('unsupportedVersion'), 'Reload this page');
  assert.equal(m('expired'), 'The pairing code expired');
  assert.equal(linkErrorMessage(new TypeError('x')), 'This is not a TBD pairing link.');
  assert.equal(linkErrorMessage(null), 'This is not a TBD pairing link.');
});

test('the fragment is removed on load', () => {
  assert.deepEqual(takePairingFragment('https://acme.github.io/#p=abc'),
    { link: 'https://acme.github.io/#p=abc', cleanURL: 'https://acme.github.io/' });
  assert.deepEqual(takePairingFragment('https://acme.github.io/?x=1#q=1'), { link: null, cleanURL: 'https://acme.github.io/?x=1' });
  assert.deepEqual(takePairingFragment('https://acme.github.io/'), { link: null, cleanURL: 'https://acme.github.io/' });
  assert.deepEqual(takePairingFragment('https://acme.github.io/#'), { link: null, cleanURL: 'https://acme.github.io/' });
  assert.deepEqual(takePairingFragment(V1.url), { link: V1.url, cleanURL: file.loaderURL });
});

test('room IDs', () => {
  assert.equal(isRoomID(ROOM), true);
  assert.equal(isRoomID(base64urlEncode(new Uint8Array(32).fill(0xff))), true);
  assert.equal(isRoomID(ROOM.slice(0, 42)), false);
  assert.equal(isRoomID(ROOM + 'A'), false);
  assert.equal(isRoomID('+' + ROOM.slice(1)), false);
  assert.equal(isRoomID(ROOM.slice(0, 42) + '='), false);
  // The vector room ends in 8 (spare bits 00); 9 sets a spare bit, so it is not canonical.
  assert.equal(ROOM.at(-1), '8');
  assert.equal(isRoomID(ROOM.slice(0, 42) + '9'), false);
  assert.equal(isRoomID(` ${ROOM.slice(1)}`), false);
  for (const value of [undefined, null, 42, [ROOM], { room: ROOM }]) assert.equal(isRoomID(value), false);
});

const RELAY = 'https://acme-relay.acme.workers.dev';
// Relays that must never give a URL: cleartext off loopback, other schemes, credentials,
// paths, queries and fragments, and text that is not a URL.
const BAD_RELAYS = [
  'http://acme.example', 'http://[::1]:1', 'ftp://acme.example', 'ws://localhost:8787', 'wss://acme.example',
  'http://localhost.acme.example', 'http://127.0.0.2', 'http://localhost.', 'http://acme.example@localhost',
  'https://user@acme.example', 'https://user:pass@acme.example', 'https://:pass@acme.example',
  'http://user:pass@localhost:8787', 'https://acme.example/relay', 'https://acme.example/v1/rooms/',
  'https://acme.example?x=1', 'https://acme.example/?x=1', 'https://acme.example#frag', 'https://acme.example/#p=1',
  'acme.example', '', 'https://', 'javascript:alert(1)', 'data:text/plain,x',
];

test('relay socket URLs', () => {
  assert.equal(relaySocketURL(RELAY, ROOM), `wss://acme-relay.acme.workers.dev/v1/rooms/${ROOM}?role=phone`);
  assert.equal(relaySocketURL(`${RELAY}/`, ROOM), `wss://acme-relay.acme.workers.dev/v1/rooms/${ROOM}?role=phone`);
  assert.equal(relaySocketURL(`${RELAY}:8443`, ROOM), `wss://acme-relay.acme.workers.dev:8443/v1/rooms/${ROOM}?role=phone`);
  assert.equal(relaySocketURL('http://127.0.0.1:5173', ROOM), `ws://127.0.0.1:5173/v1/rooms/${ROOM}?role=phone`);
  assert.equal(relaySocketURL('http://localhost:8787', ROOM), `ws://localhost:8787/v1/rooms/${ROOM}?role=phone`);
  assert.equal(relaySocketURL('http://localhost', ROOM), `ws://localhost/v1/rooms/${ROOM}?role=phone`);
  assert.equal(relaySocketURL(RELAY, ROOM, 'laptop'), `wss://acme-relay.acme.workers.dev/v1/rooms/${ROOM}?role=laptop`);
  for (const bad of BAD_RELAYS) assert.throws(() => relaySocketURL(bad, ROOM), RangeError, bad);
  assert.throws(() => relaySocketURL('https://acme.example', 'short'), RangeError);
  assert.throws(() => relaySocketURL('https://acme.example', ROOM.slice(0, 42) + '9'), RangeError);
  assert.throws(() => relaySocketURL('https://acme.example', `${ROOM}/x`), RangeError);
  assert.throws(() => relaySocketURL(RELAY, ROOM, /** @type {any} */ ('phone&x=1')), RangeError);
});

test('relay presence URLs', () => {
  assert.equal(relayPresenceURL(RELAY, ROOM), `https://acme-relay.acme.workers.dev/v1/rooms/${ROOM}/presence`);
  assert.equal(relayPresenceURL(`${RELAY}/`, ROOM), `https://acme-relay.acme.workers.dev/v1/rooms/${ROOM}/presence`);
  assert.equal(relayPresenceURL(`${RELAY}:8443`, ROOM), `https://acme-relay.acme.workers.dev:8443/v1/rooms/${ROOM}/presence`);
  assert.equal(relayPresenceURL('http://127.0.0.1:5173', ROOM), `http://127.0.0.1:5173/v1/rooms/${ROOM}/presence`);
  assert.equal(relayPresenceURL('http://localhost:8787', ROOM), `http://localhost:8787/v1/rooms/${ROOM}/presence`);
  for (const bad of BAD_RELAYS) assert.throws(() => relayPresenceURL(bad, ROOM), RangeError, bad);
  assert.throws(() => relayPresenceURL('https://acme.example', 'short'), RangeError);
  assert.throws(() => relayPresenceURL('https://acme.example', ROOM.slice(0, 42) + '9'), RangeError);
});

test('every relay the pairing-link parser accepts gives URLs, and no vector relay gives an unsafe one', () => {
  const relays = [...file.valid, ...file.invalid].map((/** @type {any} */ c) => vectorRelay(c.url))
    .filter((relay) => typeof relay === 'string');
  assert.ok(relays.length > 20);
  for (const c of file.valid) {
    assert.doesNotThrow(() => relaySocketURL(c.link.relay, ROOM), c.description);
    assert.doesNotThrow(() => relayPresenceURL(c.link.relay, ROOM), c.description);
  }
  for (const relay of [...relays, ...BAD_RELAYS]) {
    for (const build of [() => relaySocketURL(relay, ROOM), () => relayPresenceURL(relay, ROOM)]) {
      let href;
      try {
        href = build();
      } catch (error) {
        assert.ok(error instanceof RangeError, relay);
        continue;
      }
      const url = new URL(href);
      if (url.protocol === 'ws:' || url.protocol === 'http:') {
        assert.ok(['localhost', '127.0.0.1'].includes(url.hostname), `cleartext to ${relay}`);
      } else {
        assert.ok(url.protocol === 'wss:' || url.protocol === 'https:', relay);
      }
      assert.equal(url.username + url.password + url.hash, '', relay);
      assert.ok(url.search === '' || url.search === '?role=phone', relay);
      assert.ok(url.pathname.startsWith(`/v1/rooms/${ROOM}`), relay);
    }
  }
  // The parser's unsafe relays are refused here too, not just made safe.
  const unsafe = file.invalid.filter((/** @type {any} */ c) => /plain http on a host that is not loopback|scheme is ftp/.test(c.description));
  assert.equal(unsafe.length, 2);
  for (const c of unsafe) {
    assert.throws(() => relaySocketURL(/** @type {string} */ (vectorRelay(c.url)), ROOM), RangeError, c.description);
    assert.throws(() => relayPresenceURL(/** @type {string} */ (vectorRelay(c.url)), ROOM), RangeError, c.description);
  }
});

test('the relay URLs reach the fake relay of a laptop', async () => {
  const relay = createFakeRelay();
  for (const origin of ['http://127.0.0.1:8787', 'https://acme-relay.acme.test']) {
    assert.equal(relay.presence(new URL(relayPresenceURL(origin, ROOM)).pathname).status, 200);
    const url = new URL(relaySocketURL(origin, ROOM));
    assert.notEqual(relay.connect(url.pathname + url.search, { binary() {}, text() {}, close() {} }), null);
  }
});

test('device names', () => {
  assert.equal(deviceNameFromUserAgent(IPHONE_15_UA, 5), 'iPhone');
  assert.equal(deviceNameFromUserAgent(IPAD_DESKTOP_UA, 5), 'iPad'); // "Macintosh" plus touch
  assert.equal(deviceNameFromUserAgent(IPAD_DESKTOP_UA, 0), 'Phone'); // a Mac
  assert.equal(deviceNameFromUserAgent(IPAD_PRO_11_UA, 5), 'iPad');
  assert.equal(deviceNameFromUserAgent(PIXEL_7_UA, 5), 'Android phone');
  assert.equal(deviceNameFromUserAgent(GALAXY_TAB_S4_UA, 5), 'Android tablet');
  assert.equal(deviceNameFromUserAgent('curl/8', 0), 'Phone');
  for (const ua of [IPHONE_15_UA, IPAD_DESKTOP_UA, PIXEL_7_UA, GALAXY_TAB_S4_UA, 'curl/8']) {
    const name = deviceNameFromUserAgent(ua, 5);
    assert.equal(normalizeDeviceName(name), name);
  }

  assert.equal(normalizeDeviceName("  Ada's iPhone "), "Ada's iPhone");
  assert.equal(normalizeDeviceName('😀'.repeat(64)).length, 128); // 64 code points
  assert.equal(normalizeDeviceName('x'.repeat(64)), 'x'.repeat(64));
  assert.equal(normalizeDeviceName('﻿ Ada　 '), 'Ada');
  assert.equal(normalizeDeviceName('a b'), 'a b');
  for (const bad of [
    '', '   ', ' \t\n ', 'x'.repeat(65), '😀'.repeat(65), 'é'.repeat(33),
    'a\u0007b', 'a​b', 'a‮b', 'a\u0085b', 'Ada\u0085', 'a‍b', 'a﻿b', 'a­b', 'a\nb', 'a\u0000b',
    '\uD800', 'a\uDC00b',
  ]) {
    assert.throws(() => normalizeDeviceName(bad), RangeError, JSON.stringify(bad));
  }
});

// Each input normalizes to a name the scripted laptop (plan 3's rule: trims Unicode
// White_Space, counts grapheme clusters, refuses Cc and Cf) must accept unchanged.
const EDGE_NAMES = [
  "Ada's iPhone",
  'x'.repeat(64),
  '😀'.repeat(64), // 64 code points, 64 clusters
  'é'.repeat(32), // 64 code points, 32 clusters
  '🇯🇵'.repeat(32), // 64 regional indicators, 32 clusters
  '❤️ phone',
  '﻿  Ada　 ', // trimmed to "Ada" on the phone
  'a b',
  '한국어 이름',
];

test('every name normalizeDeviceName accepts pairs with the scripted laptop unchanged', async () => {
  const relay = createFakeRelay();
  const laptop = await createScriptedLaptop({ relay });
  const keys = /** @type {CryptoKeyPair} */ (await crypto.subtle.generateKey({ name: 'X25519' }, false, ['deriveBits']));
  const hello = { type: 'hello', loaderVersion: LOADER_VERSION, protocols: [1] };
  for (const input of EDGE_NAMES) {
    const name = normalizeDeviceName(input);
    const offer = laptop.makeOffer({});
    assert.deepEqual(parsePairingLink(`${file.loaderURL}#p=${base64urlEncode(encode(offer))}`, { now: 0 }), offer);
    /** @type {Array<string | Uint8Array>} */
    const inbox = [];
    const ws = fakeSocketFactory(relay, { origin: laptop.relayOrigin })(relaySocketURL(offer.relay, offer.room));
    ws.binaryType = 'arraybuffer';
    ws.onmessage = (ev) => inbox.push(typeof ev.data === 'string' ? ev.data : new Uint8Array(ev.data));
    const nextFrame = async () => {
      await until(() => inbox.some((item) => typeof item !== 'string'), `a frame for ${JSON.stringify(name)}`);
      const at = inbox.findIndex((item) => typeof item !== 'string');
      return /** @type {Uint8Array} */ (inbox.splice(at, 1)[0]);
    };
    await until(() => inbox.includes('peer-joined'), 'peer-joined');

    const refused = laptop.counts.refused;
    const initiator = await createInitiator({
      pattern: 'IKpsk2', localStatic: keys, remoteStatic: b64(offer.key), psk: b64(offer.secret),
      prologue: phonePrologue(b64(offer.room)),
    });
    ws.send(await initiator.writeMessage1(encode({ deviceName: name })));
    await until(() => laptop.counts.refused > refused || inbox.some((item) => typeof item !== 'string'), 'an answer');
    assert.equal(laptop.counts.refused, refused, `the laptop refused ${JSON.stringify(name)}`);
    const { transport } = await initiator.readMessage2(await nextFrame());
    ws.send(await transport.encrypt(encode(hello)));
    const paired = decode(await transport.decrypt(await nextFrame()));
    assert.equal(paired.type, 'paired');
    assert.equal(laptop.devices.get(paired.room)?.deviceName, name);
    ws.close(1000);
  }
  assert.deepEqual(laptop.errors, []);
});
