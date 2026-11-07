import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chooseDecoder, startScanner } from '../../qr.js';
import { QR_INTERVAL_MS } from '../../constants.js';
import { FakeDocument } from '../support/fake-dom.js';

/** A BarcodeDetector stand-in whose static getSupportedFormats is given per test. */
function detectorWith(getSupportedFormats) {
  return class {
    static getSupportedFormats = getSupportedFormats;
  };
}

test('chooseDecoder picks jsQR when there is no BarcodeDetector', async () => {
  assert.equal(await chooseDecoder({}), 'jsqr');
});

test('chooseDecoder picks the native detector when it reads QR codes', async () => {
  const g = { BarcodeDetector: detectorWith(async () => ['qr_code', 'ean_13']) };
  assert.equal(await chooseDecoder(g), 'native');
});

test('chooseDecoder picks jsQR when the native detector cannot read QR codes', async () => {
  const g = { BarcodeDetector: detectorWith(async () => ['ean_13']) };
  assert.equal(await chooseDecoder(g), 'jsqr');
});

test('chooseDecoder picks jsQR when asking for formats fails', async () => {
  const rejects = { BarcodeDetector: detectorWith(async () => { throw new Error('no'); }) };
  assert.equal(await chooseDecoder(rejects), 'jsqr');
  const throws = { BarcodeDetector: detectorWith(() => { throw new Error('no'); }) };
  assert.equal(await chooseDecoder(throws), 'jsqr');
});

// --- startScanner, with a fake camera and a fake native detector -------------------------

class FakeClock {
  #now = 0;
  #nextID = 1;
  /** @type {Map<number, {due: number, fn: () => void}>} */
  #timers = new Map();

  now() { return this.#now; }

  setTimeout(fn, ms) {
    const id = this.#nextID++;
    this.#timers.set(id, { due: this.#now + Math.max(0, ms), fn });
    return id;
  }

  clearTimeout(id) { this.#timers.delete(id); }

  get pending() { return this.#timers.size; }

  async advance(ms) {
    const target = this.#now + ms;
    for (;;) {
      let nextID = null;
      let next = null;
      for (const [id, timer] of this.#timers) {
        if (timer.due <= target && (next === null || timer.due < next.due)) {
          nextID = id;
          next = timer;
        }
      }
      if (next === null) break;
      this.#timers.delete(nextID);
      this.#now = next.due;
      next.fn();
      await flush();
    }
    this.#now = target;
  }
}

async function flush() {
  for (let i = 0; i < 10; i++) await new Promise((resolve) => setImmediate(resolve));
}

/** What the fake native detector reports, one entry per detect() call; then nothing. */
let detections = [];
let detectCalls = 0;
globalThis.BarcodeDetector = class {
  static async getSupportedFormats() { return ['qr_code']; }
  async detect() {
    detectCalls += 1;
    return detections.shift() ?? [];
  }
};

function fakeStream() {
  const tracks = [{ stopped: 0 }, { stopped: 0 }].map((t) => ({ ...t, stop() { this.stopped += 1; } }));
  return { tracks, getTracks: () => tracks };
}

function fakeVideo() {
  return {
    readyState: 4, playsInline: false, muted: false, srcObject: null,
    play: () => Promise.resolve(),
  };
}

/** Installs a navigator whose mediaDevices.getUserMedia is `getUserMedia`, or none. */
function setCamera(getUserMedia) {
  const mediaDevices = getUserMedia ? { getUserMedia } : undefined;
  Object.defineProperty(globalThis, 'navigator', { value: { mediaDevices }, configurable: true, writable: true });
}

function record() {
  const texts = [];
  const errors = [];
  return { texts, errors, onText: (t) => texts.push(t), onError: (e) => errors.push(e) };
}

test('startScanner asks for the rear camera and stops after the first pairing text', async () => {
  const stream = fakeStream();
  const asked = [];
  setCamera(async (constraints) => { asked.push(constraints); return stream; });
  const clock = new FakeClock();
  const video = fakeVideo();
  const r = record();
  detections = [[], [{ rawValue: 'https://acme.example/not-pairing' }], [{ rawValue: 'https://acme.example/#p=abc' }]];
  detectCalls = 0;

  startScanner({ video, onText: r.onText, onError: r.onError, clock });
  await flush();
  assert.deepEqual(asked, [{ video: { facingMode: 'environment' }, audio: false }]);
  assert.equal(video.playsInline, true);
  assert.equal(video.muted, true);
  assert.equal(video.srcObject, stream);

  await clock.advance(QR_INTERVAL_MS * 2);
  assert.deepEqual(r.texts, []);
  await clock.advance(QR_INTERVAL_MS);
  assert.deepEqual(r.texts, ['https://acme.example/#p=abc']);
  assert.deepEqual(r.errors, []);
  assert.deepEqual(stream.tracks.map((t) => t.stopped), [1, 1]);
  assert.equal(video.srcObject, null);
  assert.equal(clock.pending, 0);

  await clock.advance(QR_INTERVAL_MS * 10);
  assert.equal(detectCalls, 3);
  assert.equal(r.texts.length, 1);
});

test('stop() stops every track and the timer, and nothing is called afterwards', async () => {
  const stream = fakeStream();
  setCamera(async () => stream);
  const clock = new FakeClock();
  const video = fakeVideo();
  const r = record();
  detections = [];

  const scanner = startScanner({ video, onText: r.onText, onError: r.onError, clock });
  await flush();
  assert.equal(clock.pending, 1);
  scanner.stop();
  scanner.stop();
  assert.deepEqual(stream.tracks.map((t) => t.stopped), [1, 1]);
  assert.equal(clock.pending, 0);
  assert.equal(video.srcObject, null);

  detections = [[{ rawValue: 'https://acme.example/#p=abc' }]];
  await clock.advance(QR_INTERVAL_MS * 4);
  assert.deepEqual(r.texts, []);
  assert.deepEqual(r.errors, []);
});

test('stop() during the camera prompt stops the camera once it arrives', async () => {
  const stream = fakeStream();
  /** @type {(s: unknown) => void} */
  let grant = () => {};
  setCamera(() => new Promise((resolve) => { grant = resolve; }));
  const clock = new FakeClock();
  const video = fakeVideo();
  const r = record();

  const scanner = startScanner({ video, onText: r.onText, onError: r.onError, clock });
  await flush();
  scanner.stop();
  grant(stream);
  await flush();
  assert.deepEqual(stream.tracks.map((t) => t.stopped), [1, 1]);
  assert.equal(video.srcObject, null);
  assert.equal(clock.pending, 0);
  assert.deepEqual(r.texts, []);
  assert.deepEqual(r.errors, []);
});

test('no camera API, or a refused camera, calls onError once', async () => {
  setCamera(null);
  const r1 = record();
  const clock1 = new FakeClock();
  startScanner({ video: fakeVideo(), onText: r1.onText, onError: r1.onError, clock: clock1 });
  await flush();
  assert.equal(r1.errors.length, 1);
  assert.equal(clock1.pending, 0);

  const refused = new Error('NotAllowedError');
  setCamera(async () => { throw refused; });
  const r2 = record();
  const clock2 = new FakeClock();
  startScanner({ video: fakeVideo(), onText: r2.onText, onError: r2.onError, clock: clock2 });
  await flush();
  assert.deepEqual(r2.errors, [refused]);
  assert.deepEqual(r2.texts, []);
  assert.equal(clock2.pending, 0);
});

test('startScanner calls back only after it returns, so onError can stop the scanner', async () => {
  setCamera(null);
  const clock = new FakeClock();
  const errors = [];
  const thrown = [];
  /** @type {{stop(): void}} */
  let scanner;
  scanner = startScanner({
    video: fakeVideo(),
    onText: () => {},
    onError: (error) => {
      errors.push(error);
      try {
        scanner.stop();
      } catch (e) {
        thrown.push(e);
      }
    },
    clock,
  });
  await flush();
  assert.equal(errors.length, 1);
  assert.deepEqual(thrown, []);
  assert.equal(clock.pending, 0);
});

test('stop() right after startScanner returns never asks for the camera', async () => {
  let asked = 0;
  setCamera(async () => { asked += 1; return fakeStream(); });
  const clock = new FakeClock();
  const r = record();
  const scanner = startScanner({ video: fakeVideo(), onText: r.onText, onError: r.onError, clock });
  scanner.stop();
  await flush();
  assert.equal(asked, 0);
  assert.deepEqual(r.errors, []);
  assert.equal(clock.pending, 0);
});

// --- loadJsQR, with a fake document and fake Trusted Types --------------------------------

const JSQR_URL = new URL('../../vendor/jsqr/dist/jsQR.js', import.meta.url).href;
let copies = 0;

/** A fresh copy of qr.js, so its memoized load and its policy start empty. */
function freshQR() {
  copies += 1;
  return import(`../../qr.js?copy=${copies}`);
}

/**
 * Installs a `trustedTypes` whose policies wrap each URL their rule passes, and returns the
 * policies made, as `{name, rules}`.
 */
function installTrustedTypes(t) {
  const policies = [];
  globalThis.trustedTypes = {
    createPolicy(name, rules) {
      policies.push({ name, rules });
      return { createScriptURL: (url) => ({ trustedScriptURL: rules.createScriptURL(url) }) };
    },
  };
  t.after(() => { delete globalThis.trustedTypes; });
  return policies;
}

/** Defines `globalThis.jsQR`, as the vendored script does, until the test ends. */
function defineJsQR(t) {
  const jsQR = function jsQR() { return null; };
  globalThis.jsQR = jsQR;
  t.after(() => { delete globalThis.jsQR; });
  return jsQR;
}

test('the loader-jsqr policy passes only the jsQR URL, and two loads insert one script', async (t) => {
  const policies = installTrustedTypes(t);
  const { loadJsQR } = await freshQR();
  const doc = new FakeDocument();

  const first = loadJsQR(doc);
  assert.equal(loadJsQR(doc), first);
  assert.equal(policies.length, 1);
  const [{ name, rules }] = policies;
  assert.equal(name, 'loader-jsqr');
  assert.equal(rules.createScriptURL(JSQR_URL), JSQR_URL);
  for (const bad of [JSQR_URL + '?x', JSQR_URL + '#x', 'blob:https://acme.example/6b1f0c1e-0000-4000-8000-000000000000', 'https://acme.example/jsQR.js', '']) {
    assert.throws(() => rules.createScriptURL(bad), TypeError, bad);
  }

  assert.equal(doc.head.children.length, 1);
  const [script] = doc.head.children;
  assert.equal(script.tagName, 'script');
  assert.deepEqual(script.src, { trustedScriptURL: JSQR_URL });

  const jsQR = defineJsQR(t);
  script.load();
  assert.equal(await first, jsQR);
  assert.equal(loadJsQR(doc), first);
  assert.equal(doc.head.children.length, 1);
  assert.equal(policies.length, 1);
});

test('a failed jsQR load is forgotten, so a later scan tries again', async (t) => {
  const policies = installTrustedTypes(t);
  const { loadJsQR } = await freshQR();
  const doc = new FakeDocument();

  const fetchFailed = loadJsQR(doc);
  doc.head.children[0].fail();
  await assert.rejects(fetchFailed, /jsQR failed to load/);
  assert.deepEqual(doc.head.children, []);

  const undefinedGlobal = loadJsQR(doc);
  assert.notEqual(undefinedGlobal, fetchFailed);
  assert.equal(doc.head.children.length, 1);
  doc.head.children[0].load();
  await assert.rejects(undefinedGlobal, /jsQR did not define itself/);

  const retry = loadJsQR(doc);
  assert.notEqual(retry, undefinedGlobal);
  const jsQR = defineJsQR(t);
  doc.head.children.at(-1).load();
  assert.equal(await retry, jsQR);
  assert.equal(loadJsQR(doc), retry);
  assert.equal(policies.length, 1);
});
