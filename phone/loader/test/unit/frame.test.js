import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  FRAME_SANDBOX, isRunnerReady, frameInsets, openableURL, appPortMessage,
} from '../../frame.js';

test('isRunnerReady', () => {
  const w = {};
  const ok = { source: w, data: { type: 'ready', nonce: 'n1' } };
  assert.equal(isRunnerReady(ok, { frameWindow: w, nonce: 'n1', loadCount: 0, started: false }), true);
  assert.equal(isRunnerReady(ok, { frameWindow: w, nonce: 'n1', loadCount: 1, started: false }), true);
  assert.equal(isRunnerReady(ok, { frameWindow: w, nonce: 'n1', loadCount: 2, started: false }), false);
  assert.equal(isRunnerReady(ok, { frameWindow: w, nonce: 'n1', loadCount: 1, started: true }), false);
  assert.equal(isRunnerReady({ ...ok, source: {} }, { frameWindow: w, nonce: 'n1', loadCount: 1, started: false }), false);
  assert.equal(isRunnerReady({ source: w, data: { type: 'ready', nonce: 'n2' } }, { frameWindow: w, nonce: 'n1', loadCount: 1, started: false }), false);
});

test('isRunnerReady refuses a missing frame window, a malformed message and an empty nonce', () => {
  const w = {};
  const state = { frameWindow: w, nonce: 'n1', loadCount: 0, started: false };
  // A frame that has no window yet must not match a message with no source.
  assert.equal(isRunnerReady({ source: null, data: { type: 'ready', nonce: 'n1' } }, { ...state, frameWindow: null }), false);
  for (const data of [null, undefined, 'ready', ['ready', 'n1'], { type: 'bundle', nonce: 'n1' }, { nonce: 'n1' }, { type: 'ready' }]) {
    assert.equal(isRunnerReady({ source: w, data }, state), false, JSON.stringify(data));
  }
  assert.equal(isRunnerReady({ source: w, data: { type: 'ready', nonce: '' } }, { ...state, nonce: '' }), false);
});

test('frameInsets pads only where the frame meets an inset', () => {
  const insets = { top: 47, right: 0, bottom: 34, left: 0 }, layout = { width: 390, height: 844 };
  assert.deepEqual(frameInsets(insets, { top: 91, bottom: 844, left: 0, right: 390 }, layout), { top: 0, right: 0, bottom: 34, left: 0 });
  assert.deepEqual(frameInsets(insets, { top: 0, bottom: 800, left: 0, right: 390 }, layout), { top: 47, right: 0, bottom: 0, left: 0 });
});

test('frameInsets cuts the side insets in landscape', () => {
  const insets = { top: 0, right: 47, bottom: 21, left: 47 }, layout = { width: 844, height: 390 };
  assert.deepEqual(frameInsets(insets, { top: 44, bottom: 390, left: 0, right: 844 }, layout), { top: 0, right: 47, bottom: 21, left: 47 });
  assert.deepEqual(frameInsets(insets, { top: 44, bottom: 390, left: 20, right: 800 }, layout), { top: 0, right: 3, bottom: 21, left: 27 });
});

test('openableURL', () => {
  assert.equal(openableURL('https://acme.example/x'), 'https://acme.example/x');
  assert.equal(openableURL('http://acme.example/'), 'http://acme.example/');
  for (const bad of ['javascript:alert(1)', 'data:text/html,x', 'blob:null/1', 'x', 'https://a.example/' + 'a'.repeat(2049)])
    assert.equal(openableURL(bad), null);
});

test('openableURL normalizes, and refuses credentials, relative URLs and non-strings', () => {
  assert.equal(openableURL('HTTPS://Acme.Example'), 'https://acme.example/');
  assert.equal(openableURL('https://acme.example/a b'), 'https://acme.example/a%20b');
  for (const bad of [
    'https://user@acme.example/', 'https://user:pass@acme.example/', 'https://:pass@acme.example/',
    '/relative', '//acme.example/x', 'ftp://acme.example/', 'file:///etc/hosts', 'about:blank', '',
  ]) {
    assert.equal(openableURL(bad), null, bad);
  }
  for (const bad of [null, undefined, 42, {}, ['https://acme.example/'], new URL('https://acme.example/')]) {
    assert.equal(openableURL(bad), null);
  }
});

test('openableURL allows exactly 2,048 characters, before and after normalizing', () => {
  const prefix = 'https://acme.example/';
  const max = prefix + 'a'.repeat(2048 - prefix.length);
  assert.equal(max.length, 2048);
  assert.equal(openableURL(max), max);
  assert.equal(openableURL(max + 'a'), null);
  // Short enough as typed, too long once the space is percent-encoded.
  const grows = prefix + ' ' + 'a'.repeat(2048 - prefix.length - 1);
  assert.equal(grows.length, 2048);
  assert.equal(openableURL(grows), null);
});

test('appPortMessage', () => {
  assert.deepEqual(appPortMessage({ t: 'app', body: {} }), { t: 'app', body: {} });
  assert.deepEqual(appPortMessage({ t: 'app', body: { method: 'sessions.subscribe' } }), { t: 'app', body: { method: 'sessions.subscribe' } });
  for (const body of [[], null, undefined, 'x', 1, true]) {
    assert.equal(appPortMessage({ t: 'app', body }), null, String(body));
  }
  assert.equal(appPortMessage({ t: 'app' }), null);
  assert.deepEqual(appPortMessage({ t: 'openLink', url: 'https://acme.example/' }), { t: 'openLink', url: 'https://acme.example/' });
  // The url is only checked for type here; openableURL decides what opens.
  assert.deepEqual(appPortMessage({ t: 'openLink', url: 'javascript:x' }), { t: 'openLink', url: 'javascript:x' });
  for (const url of [undefined, null, 1, {}, ['https://acme.example/']]) {
    assert.equal(appPortMessage({ t: 'openLink', url }), null);
  }
  for (const data of [{ t: 'other' }, { t: 'started' }, { t: 'fault', reason: 'hash' }, {}, null, undefined, 'app', ['app', {}]]) {
    assert.equal(appPortMessage(data), null, JSON.stringify(data));
  }
});

test('appPortMessage keeps only the known fields', () => {
  assert.deepEqual(appPortMessage({ t: 'app', body: { a: 1 }, extra: 'x' }), { t: 'app', body: { a: 1 } });
  assert.deepEqual(appPortMessage({ t: 'openLink', url: 'https://acme.example/', target: '_top' }), { t: 'openLink', url: 'https://acme.example/' });
});

test('the sandbox is exactly allow-scripts', () => assert.equal(FRAME_SANDBOX, 'allow-scripts'));
