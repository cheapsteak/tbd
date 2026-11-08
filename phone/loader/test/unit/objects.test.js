import { test } from 'node:test';
import assert from 'node:assert/strict';

import { isObject, isPlainObject, isPlainRecord } from '../../objects.js';

class Point {
  x = 1;
}

// Each value, and what isObject, isPlainObject and isPlainRecord say of it.
/** @type {Array<[string, unknown, boolean, boolean, boolean]>} */
const CASES = [
  ['null', null, false, false, false],
  ['undefined', undefined, false, false, false],
  ['a string', '{}', false, false, false],
  ['a number', 1, false, false, false],
  ['a boolean', true, false, false, false],
  ['a function', () => {}, false, false, false],
  ['an object literal', { a: 1 }, true, true, true],
  ['an empty object', {}, true, true, true],
  ['a null-prototype object', Object.create(null), true, true, true],
  ['parsed JSON with its own __proto__ key', JSON.parse('{"__proto__":{"a":1}}'), true, true, true],
  ['an array', [1], true, false, false],
  ['an empty array', [], true, false, false],
  ['a Date', new Date(0), true, true, false],
  ['a Map', new Map(), true, true, false],
  ['a Uint8Array', new Uint8Array(1), true, true, false],
  ['a class instance', new Point(), true, true, false],
  ['an object whose prototype is another object', Object.create({ a: 1 }), true, true, false],
];

test('isObject admits any object, arrays and instances included, and nothing else', () => {
  for (const [name, value, expected] of CASES) assert.equal(isObject(value), expected, name);
});

test('isPlainObject, for parsed JSON, admits any object but an array', () => {
  for (const [name, value, , expected] of CASES) assert.equal(isPlainObject(value), expected, name);
});

test('isPlainRecord admits only an object literal or a null-prototype object', () => {
  for (const [name, value, , , expected] of CASES) assert.equal(isPlainRecord(value), expected, name);
});

test('isPlainRecord holds through a structured clone, as across postMessage', () => {
  assert.equal(isPlainRecord(structuredClone({ a: [1, { b: 2 }] })), true);
  assert.equal(isPlainRecord(structuredClone(new Date(0))), false);
  assert.equal(isPlainRecord(structuredClone(new Map([['a', 1]]))), false);
  assert.equal(isPlainRecord(structuredClone([1])), false);
});
