import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const PKG = new URL('../package.json', import.meta.url);
const LOCK = new URL('../package-lock.json', import.meta.url);
const lock = JSON.parse(readFileSync(LOCK, 'utf8'));

test('each app library is pinned to an exact version', () => {
  const dev = JSON.parse(readFileSync(PKG, 'utf8')).devDependencies;
  assert.equal(dev.react, '19.3.1'); assert.equal(dev['react-dom'], '19.3.1');
  assert.equal(dev.marked, '18.1.3'); assert.equal(dev['@tanstack/react-virtual'], '3.14.26');
  assert.equal(dev.esbuild, '0.28.2');
  for (const [name, v] of Object.entries(dev)) assert.match(v, /^\d+\.\d+\.\d+$/, name);
});

test('the lockfile has esbuild for the Linux CI runner', () => {
  assert.equal(lock.packages['node_modules/@esbuild/linux-x64'].version, '0.28.2');
});
