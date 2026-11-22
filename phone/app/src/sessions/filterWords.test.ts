// Tests filterWords.ts: the filter chip's words and accessible label, off and on, for one
// registry provider and for two or more, and the singular for a count of 1.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { filterChipWords } from './filterWords.ts';

test('off, with one provider: "Hide <name>", read as "Hide <name> sessions"', () => {
  assert.deepEqual(filterChipWords({ on: false, count: 4, providers: ['acme-box'] }),
    { text: 'Hide acme-box', label: 'Hide acme-box sessions' });
});

test('on, with one provider: "<count> hidden", read with the name and how to show them', () => {
  assert.deepEqual(filterChipWords({ on: true, count: 4, providers: ['acme-box'] }),
    { text: '4 hidden', label: '4 acme-box sessions hidden. Tap to show them.' });
  assert.deepEqual(filterChipWords({ on: true, count: 1, providers: ['acme-box'] }),
    { text: '1 hidden', label: '1 acme-box session hidden. Tap to show it.' });
  // Only the selected row is a registry row: nothing is hidden, and the chip still says so.
  assert.deepEqual(filterChipWords({ on: true, count: 0, providers: ['acme-box'] }),
    { text: '0 hidden', label: '0 acme-box sessions hidden. Tap to show them.' });
});

test('two or more providers: "remote", read as "remote sessions except cloud"', () => {
  const providers = ['acme-box', 'acme-zeta'];
  assert.deepEqual(filterChipWords({ on: false, count: 3, providers }),
    { text: 'Hide remote', label: 'Hide remote sessions except cloud' });
  assert.deepEqual(filterChipWords({ on: true, count: 3, providers }),
    { text: '3 hidden', label: '3 remote sessions except cloud hidden. Tap to show them.' });
  assert.deepEqual(filterChipWords({ on: true, count: 1, providers }),
    { text: '1 hidden', label: '1 remote session except cloud hidden. Tap to show it.' });
});
