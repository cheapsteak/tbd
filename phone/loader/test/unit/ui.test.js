import { test } from 'node:test';
import assert from 'node:assert/strict';

import { MESSAGES } from '../../messages.js';
import { renderCode, renderLaptops, renderLoading, renderMenu, renderStrip } from '../../ui.js';
import { FakeDocument, FakeElement } from '../support/fake-dom.js';

// ui.js builds with the page's global `document`; each test gets a fresh fake one.
const fresh = () => {
  globalThis.document = /** @type {any} */ (new FakeDocument());
};

/**
 * Every element inside `root`, and `root` itself, in document order.
 * @param {any} root
 * @returns {FakeElement[]}
 */
const all = (root) => [root, ...root.descendants()];

/**
 * The elements inside `root` whose class list has `name`.
 * @param {any} root
 * @param {string} name
 */
const byClass = (root, name) => all(root).filter((el) => String(el.className ?? '').split(' ').includes(name));

/**
 * The elements inside `root` with this `data-state`.
 * @param {any} root
 * @param {string} state
 */
const byState = (root, state) => all(root).filter((el) => el.getAttribute('data-state') === state);

const noop = () => {};

test('the code screen reads exactly as MESSAGES.checkCode, with the code in its own element', () => {
  fresh();
  const root = renderCode({ laptopName: 'acme-laptop', phoneName: 'acme-phone', code: '123456', onCancel: noop });
  const [check] = byClass(root, 'check');
  assert.equal(check.textContent, MESSAGES.checkCode('123456'));
  assert.equal(check.textContent, 'Check this code on your laptop: 123 456');
  const [code] = byClass(root, 'code');
  assert.equal(code.textContent, '123 456');
  assert.equal(code.getAttribute('aria-label'), '1 2 3 4 5 6');
});

test('a Laptops row takes a new status line in place, leaving every other node alone', () => {
  fresh();
  const row = (/** @type {string} */ name) => ({
    name,
    line: { dot: null, text: 'Last connected 5 min ago' },
    asking: false,
    onOpen: noop,
    onForget: noop,
    onConfirm: noop,
    onCancel: noop,
  });
  const { root, rows } = renderLaptops({ rows: [row('acme-laptop'), row('acme-studio')], onPair: noop });
  assert.equal(rows.length, 2);
  const before = all(root);
  const [first, second] = /** @type {any[]} */ (all(root).filter((el) => el.tagName === 'small'));
  const buttons = all(root).filter((el) => el.tagName === 'button');

  rows[1].setLine({ dot: 'on', text: 'Online · last connected just now' });
  assert.equal(second.textContent, 'Online · last connected just now');
  assert.equal(byClass(second, 'odot').length, 1, 'the dot is drawn');
  assert.equal(first.textContent, 'Last connected 5 min ago', 'the other row is untouched');
  // The same nodes, minus nothing: only the one <small> gained a dot.
  assert.deepEqual(all(root).filter((el) => el.tagName === 'button'), buttons, 'every button is the same node');
  assert.ok(before.every((el) => all(root).includes(el)), 'no node was replaced');

  rows[1].setLine({ dot: null, text: "Can't reach the relay" });
  assert.equal(second.textContent, "Can't reach the relay");
  assert.equal(byClass(second, 'odot').length, 0, 'the dot goes when the status is not known');
});

test('a row asking to Forget shows no status line, and its handle does nothing', () => {
  fresh();
  const base = { line: { dot: null, text: 'Never connected' }, onOpen: noop, onForget: noop, onConfirm: noop, onCancel: noop };
  const { root, rows } = renderLaptops({
    rows: [{ ...base, name: 'acme-laptop', asking: true }, { ...base, name: 'acme-studio', asking: false }],
    onPair: noop,
  });
  assert.equal(root.getAttribute('data-state'), 'forget-ask');
  const text = root.textContent;
  rows[0].setLine({ dot: 'on', text: 'Online' });
  assert.equal(root.textContent, text);
});

test('a menu item takes a new status line in place', () => {
  fresh();
  const laptop = (/** @type {string} */ name, /** @type {boolean} */ current) => ({
    name, line: { dot: null, text: 'Never connected' }, current, onPick: noop,
  });
  const { nodes, items, rows } = renderMenu({
    laptops: [laptop('acme-laptop', true), laptop('acme-studio', false)], onPair: noop, onManage: noop, onDismiss: noop,
  });
  assert.equal(rows.length, 2);
  assert.equal(items.length, 4, 'two laptops, Pair a laptop and Manage laptops');
  const [drop] = byState(nodes[1], 'lapmenu');
  const itemsBefore = all(drop).filter((el) => el.tagName === 'button');
  rows[0].setLine({ dot: 'on', text: 'Online' });
  assert.equal(all(items[0]).find((el) => el.tagName === 'small')?.textContent, 'Online');
  assert.equal(all(items[1]).find((el) => el.tagName === 'small')?.textContent, 'Never connected');
  assert.deepEqual(all(drop).filter((el) => el.tagName === 'button'), itemsBefore);
});

test('the strip has a Reconnecting… node only while reconnecting', () => {
  fresh();
  const strip = (/** @type {boolean} */ reconnecting) => renderStrip({
    laptopName: 'acme-laptop', reconnecting, expanded: false, onToggle: noop,
  }).nodes;
  const shown = strip(true);
  assert.equal(shown.flatMap((node) => byState(node, 'reconnect')).length, 1);
  assert.ok(shown.some((node) => node.textContent.includes(MESSAGES.reconnecting)));
  assert.equal(strip(false).flatMap((node) => byState(node, 'reconnect')).length, 0);
});

test('the loading screen is a spinner with no text', () => {
  fresh();
  const root = renderLoading();
  assert.equal(root.getAttribute('data-state'), 'loading');
  assert.equal(byClass(root, 'spin').length, 1);
  assert.equal(root.textContent, '');
});
