import { test } from 'node:test';
import assert from 'node:assert/strict';

import { formatCode, formatLastConnected } from '../../format.js';

const NOW = 1_800_000_000_000;

test('format', () => {
  assert.equal(formatCode('012345'), '012 345');
  assert.equal(formatLastConnected(null, NOW), 'Never');
  assert.equal(formatLastConnected(NOW - 30_000, NOW), 'Just now');
  assert.equal(formatLastConnected(NOW - 5 * 60_000, NOW), '5 min ago');
  assert.equal(formatLastConnected(NOW - 3 * 3_600_000, NOW), '3 h ago');
  assert.equal(formatLastConnected(NOW - 2 * 86_400_000, NOW), '2 days ago');
});

test('last connected boundaries', () => {
  assert.equal(formatLastConnected(NOW, NOW), 'Just now');
  assert.equal(formatLastConnected(NOW + 3_600_000, NOW), 'Just now'); // a clock that moved back
  assert.equal(formatLastConnected(NOW - 59_999, NOW), 'Just now');
  assert.equal(formatLastConnected(NOW - 60_000, NOW), '1 min ago');
  assert.equal(formatLastConnected(NOW - 3_599_999, NOW), '59 min ago');
  assert.equal(formatLastConnected(NOW - 3_600_000, NOW), '1 h ago');
  assert.equal(formatLastConnected(NOW - 86_399_999, NOW), '23 h ago');
  assert.equal(formatLastConnected(NOW - 86_400_000, NOW), '1 day ago');
  assert.equal(formatLastConnected(NOW - 400 * 86_400_000, NOW), '400 days ago');
  assert.equal(formatLastConnected(0, NOW), `${Math.floor(NOW / 86_400_000)} days ago`);
});
