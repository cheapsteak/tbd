// The test host: the loader's app frame and header strip, with a fake laptop in place of the
// relay and the real one. It runs the committed bundle the way a phone does: the staged
// frame.js opens the staged runner.html in <iframe sandbox="allow-scripts">, and the runner
// checks the bundle's hash and starts it under its own policy and Trusted Types.
//
// Everything a test drives lives in this page, outside the frame, on `window.__host`. Nothing
// is put into the frame: the app reaches the fake laptop only through its real port, through
// `AppFrame`, and every body it sends passes the loader's own size check first. Bodies cross as
// JSON both ways, as they do between a phone and a laptop, so neither side ever holds an
// object the other made.
//
// The page's query:
// - `scenario=<name>` loads `/__app/scenarios/<name>.json` (`mock` by default); an empty name
//   starts the laptop with no data, for a test that passes its own to `loadScenario`.
// - `channel=down` leaves the channel down until a test calls `setChannel(true)`. Otherwise
//   it comes up at once.
//
// `window.__host`:
// - `requests`: every request that reached the laptop, `{ requestID, method, params }`, in
//   order, resends included. A request sent on a connection that ended before it arrived
//   never reaches the laptop, as the relay drops it. `links`: every URL the app asked to open. `faults`: every
//   `AppFrame` fault, each also logged as a console error, which fails the test.
// - `emit(event, data)`: the laptop sends an event (`emitEvent` in fake-laptop-app.js).
// - `setReply(method, reply | (params, state) => reply | null)`, `hold(name)`,
//   `release(name)`: see fake-laptop-app.js. `state`: what the laptop holds.
// - `setChannel(up)`: the channel comes up (a new connection) or goes down.
// - `setSendResult('sent' | 'tooLarge')`: what the loader answers each later send that fits a
//   frame while the channel is up. It refuses `offline`, which the loader answers only while the
//   channel is down, to every send: a test takes the channel down with `setChannel(false)`.
// - `sendEnv(partial)`: posts the env the page reads with `partial` laid over it, one level
//   deep, and keeps laying it over every later env until `sendEnv(null)`.
// - `loadScenario(nameOrObject)`: replaces the laptop's data.
// - `ready`: true once the frame is built and the first channel state is set.

import { alwaysVisible } from '/clock.js';
import { MAX_PLAINTEXT_LENGTH } from '/channel/noise.js';
import { AppFrame, readEnv } from '/frame.js';
import { decodeMessage, encodeMessage } from '/protocol.js';
import { renderStrip } from '/ui.js';
import { createFakeLaptop } from '/__app/fake-laptop-app.js';

/** What the loader's `sendApp` answers. @typedef {'sent' | 'offline' | 'tooLarge'} SendResult */
/** What a test may have it answer while the channel is up. @typedef {'sent' | 'tooLarge'} UpSendResult */

const LAPTOP_NAME = 'acme-laptop';
const SEND_RESULTS = new Set(['sent', 'tooLarge']);
const SCENARIO_NAME = /^[A-Za-z0-9_-]+$/;
/** As the laptop reads a frame's plaintext: UTF-8, nothing else. */
const utf8 = new TextDecoder('utf-8', { fatal: true });

const strip = element('strip');
const frameHost = element('frame-host');
const probe = element('safe-probe');
const query = new URLSearchParams(location.search);

/** @type {Array<{ requestID: unknown, method: unknown, params: unknown }>} */
const requests = [];
/** @type {string[]} */
const links = [];
/** @type {string[]} */
const faults = [];

let up = false;
/** @type {UpSendResult} */
let sendResult = 'sent';
/** @type {Record<string, unknown> | null} */
let envOverride = null;
let envQueued = false;
/** @type {string | null} */
let lastEnvKey = null;

/** @type {AppFrame | null} */
let frame = null;
const laptop = createFakeLaptop({
  scenario: await fetchScenario(query.get('scenario') ?? 'mock'),
  // As the loader hands the app a laptop message's body: decoded from the frame's bytes.
  emit: (body) => frame?.deliver(decodeMessage(encodeMessage({ type: 'app', body })).body),
});

// The bundle, read as the loader reads it (`BundleAssembler.finish` in phone/loader/bundle.js):
// the hash is of the bytes, and the text is their strict UTF-8, a leading U+FEFF kept.
const bundle = await fetch('/__app/app.js', { cache: 'no-store' });
if (!bundle.ok) throw new Error(`TBD app host: app.js answered ${bundle.status}`);
const bundleBytes = new Uint8Array(await bundle.arrayBuffer());
const sha256 = await sha256Hex(bundleBytes);
const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bundleBytes);
frame = new AppFrame({
  host: frameHost,
  runnerURL: `${location.origin}/runner.html`,
  text,
  sha256,
  sendApp,
  onOpenLink: (url) => links.push(url),
  onFault: (reason) => {
    faults.push(reason);
    console.error(`TBD app host: the app frame failed: ${reason}`);
  },
  visibility: alwaysVisible,
});
drawStrip();
postEnv();

// The env listeners of the loader page (`Boot` in phone/loader/main.js).
window.visualViewport?.addEventListener('resize', queueEnv);
window.visualViewport?.addEventListener('scroll', queueEnv);
window.addEventListener('resize', queueEnv);
window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', queueEnv);

if (query.get('channel') !== 'down') setChannel(true);

Object.defineProperty(window, '__host', {
  value: Object.freeze({
    requests,
    links,
    faults,
    get state() {
      return laptop.state;
    },
    emit: (/** @type {string} */ event, /** @type {unknown} */ data) => laptop.emitEvent(event, data),
    setReply: laptop.setReply,
    hold: laptop.hold,
    release: laptop.release,
    setChannel,
    setSendResult,
    sendEnv,
    loadScenario,
    ready: true,
  }),
});

/**
 * The loader's `sendApp`, with the fake laptop for the relay: offline while the channel is
 * down and only then, and the loader's own size check (`sendApp` in phone/loader/connection.js)
 * before anything else. A body that passes both, while the send result is `sent`, reaches the
 * laptop on a later task, as a message through the relay would: parsed from the bytes the
 * loader encoded, and only while the connection it was sent on lasts.
 * @param {object} body
 * @returns {SendResult}
 */
function sendApp(body) {
  if (!up) return 'offline';
  const bytes = encodeMessage({ type: 'app', body });
  if (bytes.length > MAX_PLAINTEXT_LENGTH) return 'tooLarge';
  if (sendResult !== 'sent') return sendResult;
  const connection = laptop.state.connection;
  setTimeout(() => {
    if (connection === null || connection !== laptop.state.connection) return;
    const sent = JSON.parse(utf8.decode(bytes)).body;
    requests.push(structuredClone({ requestID: sent.requestID, method: sent.method, params: sent.params }));
    laptop.handle(sent, connection);
  }, 0);
  return 'sent';
}

/** @param {boolean} next */
function setChannel(next) {
  if (typeof next !== 'boolean') throw new TypeError('setChannel takes a boolean');
  if (next === up || frame === null) return;
  up = next;
  if (up) {
    laptop.connect();
    frame.setChannel(true);
  } else {
    frame.setChannel(false);
    laptop.disconnect();
  }
  drawStrip();
}

/**
 * Sets what `sendApp` answers each later send that fits a frame while the channel is up. It
 * refuses `offline`: the real loader answers that only between a `down` and the next `up`
 * (`sendApp` in phone/loader/connection.js), so a phone never sees it while the channel is up.
 * @param {UpSendResult} result
 */
function setSendResult(result) {
  if (result === 'offline') {
    throw new RangeError(
      "setSendResult('offline'): the loader answers offline only while the channel is down. " +
        'Take the channel down with setChannel(false) instead: every send is offline then.',
    );
  }
  if (!SEND_RESULTS.has(result)) throw new RangeError(`no send result ${result}`);
  sendResult = result;
}

/** @param {Record<string, unknown> | null} partial */
function sendEnv(partial) {
  if (partial !== null && !isRecord(partial)) throw new TypeError('sendEnv takes an object or null');
  envOverride = partial;
  postEnv();
}

/** @param {string | object} scenario */
async function loadScenario(scenario) {
  laptop.load(typeof scenario === 'string' ? await fetchScenario(scenario) : scenario);
}

/** The strip as the loader draws it over a running frame: the laptop, and "Reconnecting…" while down. */
function drawStrip() {
  const { nodes } = renderStrip({ laptopName: LAPTOP_NAME, reconnecting: !up, expanded: false, onToggle: () => {} });
  strip.replaceChildren(...nodes);
  strip.hidden = false;
}

/** As the loader does: on the next frame, and once more on the one after, since the frame's rectangle can lag a resize. */
function queueEnv() {
  if (envQueued) return;
  envQueued = true;
  requestAnimationFrame(() => {
    envQueued = false;
    postEnv();
    requestAnimationFrame(postEnv);
  });
}

/** Posts the env, unless it is the one last posted. */
function postEnv() {
  if (frame === null) return;
  /** @type {Record<string, any>} */
  const env = readEnv(window, probe, frameHost);
  for (const [key, value] of Object.entries(envOverride ?? {})) {
    env[key] = isRecord(value) && isRecord(env[key]) ? { ...env[key], ...value } : value;
  }
  const key = JSON.stringify(env);
  if (key === lastEnvKey) return;
  lastEnvKey = key;
  frame.sendEnv(/** @type {any} */ (env));
}

/** @param {string} name */
async function fetchScenario(name) {
  if (name === '') return {};
  if (!SCENARIO_NAME.test(name)) throw new RangeError(`no scenario ${name}`);
  const response = await fetch(`/__app/scenarios/${name}.json`, { cache: 'no-store' });
  if (!response.ok) throw new Error(`scenario ${name}: ${response.status}`);
  return response.json();
}

/** @param {Uint8Array} bytes */
async function sha256Hex(bytes) {
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

/** @param {string} id */
function element(id) {
  const el = document.getElementById(id);
  if (el === null) throw new Error(`host.html has no #${id}`);
  return el;
}

/** @param {unknown} value @returns {value is Record<string, unknown>} */
function isRecord(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
