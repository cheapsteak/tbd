import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  KEEPALIVE_MS, RECONNECT_MIN_MS, RECONNECT_MAX_MS, CACHED_BUNDLES_PER_LAPTOP,
  MAX_CHUNK_BYTES, LOADER_PROTOCOLS, LOADER_VERSION, DEVICE_NAME_MAX,
} from '../../constants.js';
import { MAX_PLAINTEXT_LENGTH } from '../../channel/noise.js';
import { MESSAGES } from '../../messages.js';

test('constants match spec section 13 and the index', () => {
  assert.equal(KEEPALIVE_MS, 30_000);
  assert.equal(RECONNECT_MIN_MS, 1_000);
  assert.equal(RECONNECT_MAX_MS, 60_000);
  assert.equal(CACHED_BUNDLES_PER_LAPTOP, 2);
  assert.equal(MAX_CHUNK_BYTES, 45_000);
  assert.deepEqual(LOADER_PROTOCOLS, [1]);
  assert.match(LOADER_VERSION, /^\d+\.\d+\.\d+$/);
  assert.equal(DEVICE_NAME_MAX, 64);
  assert.equal(MAX_PLAINTEXT_LENGTH, 65_519); // the index's frame budget
});

test('error copy matches spec 8.1', () => {
  assert.equal(MESSAGES.offline, 'Laptop offline');
  assert.equal(MESSAGES.updateTBD, 'Update TBD on this laptop');
  assert.equal(MESSAGES.reload, 'Reload this page');
  assert.equal(MESSAGES.removed('acme-mbp'), 'This phone was removed from acme-mbp');
  assert.equal(MESSAGES.relay, "Can't reach the relay");
  assert.equal(MESSAGES.checkCode('123456'), 'Check this code on your laptop: 123 456');
});
