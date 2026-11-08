import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  bootRoute, connectionScreen, fatalScreen, lastConnectedText, pairingFailureScreen, presenceLine, sortLaptops,
  stripReconnecting,
} from '../../views.js';

const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;
const NOW = 1_800_000_000_000;

/** A stand-in for a LaptopRecord: the routes only count and pass records on. */
const laptop = (/** @type {string} */ id) => /** @type {any} */ ({ id });
const damaged = (/** @type {string} */ key) => ({ key, laptopName: null });

test('boot: no laptops opens the pair screen', () => {
  assert.deepEqual(bootRoute({ laptops: [], damaged: [] }), { kind: 'pair' });
});

test('boot: one laptop connects to it', () => {
  const only = laptop('a');
  const route = bootRoute({ laptops: [only], damaged: [] });
  assert.equal(route.kind, 'connect');
  assert.equal(route.kind === 'connect' && route.record, only);
});

test('boot: two or more laptops open the Laptops screen', () => {
  assert.deepEqual(bootRoute({ laptops: [laptop('a'), laptop('b')], damaged: [] }), { kind: 'laptops' });
});

test('boot: any damaged record opens the Laptops screen, even beside one good laptop or none', () => {
  assert.deepEqual(bootRoute({ laptops: [laptop('a')], damaged: [damaged('x')] }), { kind: 'laptops' });
  assert.deepEqual(bootRoute({ laptops: [], damaged: [damaged('x')] }), { kind: 'laptops' });
});

test('connection states before a frame map to full screens', () => {
  for (const state of /** @type {const} */ (['connecting', 'handshaking', 'loading', 'reconnecting'])) {
    assert.equal(connectionScreen(state), 'connecting', state);
  }
  assert.equal(connectionScreen('offline'), 'offline');
  assert.equal(connectionScreen('relayUnreachable'), 'relay');
  assert.equal(connectionScreen('replaced'), 'replaced');
  assert.equal(connectionScreen('ready'), null);
});

test('the strip reads Reconnecting… only while a frame exists and the state is not ready', () => {
  for (const state of /** @type {const} */ (['connecting', 'handshaking', 'loading', 'reconnecting', 'offline', 'relayUnreachable'])) {
    assert.equal(stripReconnecting(true, state), true, state);
    assert.equal(stripReconnecting(false, state), false, state);
  }
  assert.equal(stripReconnecting(true, 'ready'), false);
  assert.equal(stripReconnecting(false, 'ready'), false);
  assert.equal(stripReconnecting(false, null), false);
});

test('fatal reasons map to Update TBD, Reload this page and the removed screen', () => {
  assert.equal(fatalScreen('incompatibleLaptop'), 'update');
  assert.equal(fatalScreen('incompatibleLoader'), 'reload');
  assert.equal(fatalScreen('badBundle'), 'reload');
  assert.equal(fatalScreen('protocol'), 'reload');
  assert.equal(fatalScreen('revoked'), 'removed');
});

test('each pairing failure has its screen, and Cancel has none', () => {
  assert.equal(pairingFailureScreen('denied'), 'denied');
  assert.equal(pairingFailureScreen('expired'), 'expired');
  assert.equal(pairingFailureScreen('invalid'), 'pair-invalid');
  assert.equal(pairingFailureScreen('offline'), 'pair-offline');
  assert.equal(pairingFailureScreen('relayUnreachable'), 'pair-relay');
  assert.equal(pairingFailureScreen('cancelled'), null);
});

test('last connected text follows a status word in lower case, and is null when never', () => {
  assert.equal(lastConnectedText(null, NOW), null);
  assert.equal(lastConnectedText(NOW - 10_000, NOW), 'just now');
  assert.equal(lastConnectedText(NOW - 5 * MINUTE, NOW), '5 min ago');
  assert.equal(lastConnectedText(NOW - 2 * DAY, NOW), '2 days ago');
});

test('list rows read as the mock: status, a dot, and the last connection', () => {
  assert.deepEqual(presenceLine('online', NOW - 10_000, NOW, 'list'), { dot: 'on', text: 'Online · last connected just now' });
  assert.deepEqual(presenceLine('offline', NOW - 2 * DAY, NOW, 'list'), { dot: 'off', text: 'Offline · last connected 2 days ago' });
  assert.deepEqual(presenceLine('relay', NOW - 2 * DAY, NOW, 'list'),
    { dot: null, text: "Can't reach the relay · last connected 2 days ago" });
});

test('menu rows read as the mock: Online alone, Offline with the last connection', () => {
  assert.deepEqual(presenceLine('online', NOW - 2 * DAY, NOW, 'menu'), { dot: 'on', text: 'Online' });
  assert.deepEqual(presenceLine('offline', NOW - 2 * DAY, NOW, 'menu'), { dot: 'off', text: 'Offline · last connected 2 days ago' });
  assert.deepEqual(presenceLine('relay', NOW - 2 * DAY, NOW, 'menu'), { dot: null, text: "Can't reach the relay" });
});

test('a row never connected drops the last connection', () => {
  assert.deepEqual(presenceLine('online', null, NOW, 'list'), { dot: 'on', text: 'Online' });
  assert.deepEqual(presenceLine('offline', null, NOW, 'menu'), { dot: 'off', text: 'Offline' });
  assert.deepEqual(presenceLine('relay', null, NOW, 'list'), { dot: null, text: "Can't reach the relay" });
});

test('before the presence answer, a row claims no status', () => {
  assert.deepEqual(presenceLine(undefined, NOW - 5 * MINUTE, NOW, 'list'), { dot: null, text: 'Last connected 5 min ago' });
  assert.deepEqual(presenceLine(undefined, null, NOW, 'menu'), { dot: null, text: 'Never connected' });
});

test('laptops list by name, then by ID, whatever order the store returned', () => {
  const named = (/** @type {string} */ id, /** @type {string} */ laptopName) => /** @type {any} */ ({ id, laptopName });
  const stored = [named('k2', 'acme-studio'), named('k9', 'acme-laptop'), named('k1', 'acme-laptop'), named('k5', 'acme-mini')];
  const before = [...stored];
  assert.deepEqual(sortLaptops(stored).map((r) => r.id), ['k1', 'k9', 'k5', 'k2']);
  assert.deepEqual(stored, before, 'the store list itself is left alone');
});
