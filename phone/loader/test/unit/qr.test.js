import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chooseDecoder, startScanner } from '../../qr.js';
import { QR_INTERVAL_MS } from '../../constants.js';

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
