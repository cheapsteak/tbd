// Tests env.ts: the keyboard inset, the layout variables and the theme, from the env message
// the loader's readEnv builds (`phone/loader/frame.js`).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { applyTheme, keyboardInset, layoutVars } from './env.ts';
import type { HostEnv } from './env.ts';

interface EnvOptions {
  top?: number; right?: number; bottom?: number; left?: number;
  layoutH?: number; vvH?: number; vvTop?: number; scale?: number;
}

/** An env for a 390 px wide phone, with the given insets and viewport values. */
function env({ top = 0, right = 0, bottom = 0, left = 0, layoutH = 844, vvH = layoutH, vvTop = 0, scale = 1 }: EnvOptions): HostEnv {
  return {
    safeArea: { top, right, bottom, left },
    viewport: { width: 390, height: vvH, offsetTop: vvTop, offsetLeft: 0, scale },
    layout: { width: 390, height: layoutH },
    colorScheme: 'light',
  };
}

test('the keyboard inset is the layout height below the visual viewport', () => {
  assert.equal(keyboardInset(env({ layoutH: 844, vvH: 508, vvTop: 0 })), 336);
  assert.equal(keyboardInset(env({ layoutH: 844, vvH: 844, vvTop: 0 })), 0);
});

test('a visual viewport scrolled down within the layout leaves only the gap below it', () =>
  assert.equal(keyboardInset(env({ layoutH: 844, vvH: 508, vvTop: 100 })), 236));

test('a visual viewport past the layout bottom is no keyboard', () =>
  assert.equal(keyboardInset(env({ layoutH: 844, vvH: 844, vvTop: 20 })), 0));

test('a pinch zoom is not a keyboard', () =>
  assert.equal(keyboardInset(env({ layoutH: 844, vvH: 422, vvTop: 200, scale: 2 })), 0));

test('a zoom within 0.01 of 1 still counts the keyboard, and one past it does not', () => {
  assert.equal(keyboardInset(env({ layoutH: 844, vvH: 508, scale: 1.005 })), 336);
  assert.equal(keyboardInset(env({ layoutH: 844, vvH: 508, scale: 0.995 })), 336);
  assert.equal(keyboardInset(env({ layoutH: 844, vvH: 508, scale: 1.02 })), 0);
  assert.equal(keyboardInset(env({ layoutH: 844, vvH: 508, scale: 0.98 })), 0);
});

test('the dock pads by the larger of the bottom inset and the keyboard', () => {
  assert.equal(layoutVars(env({ bottom: 34, layoutH: 844, vvH: 844 }))['--dock-pad'], '34px');
  assert.equal(layoutVars(env({ bottom: 34, layoutH: 844, vvH: 508 }))['--dock-pad'], '336px');
  assert.deepEqual(Object.values(layoutVars(null)), ['0px', '0px', '0px', '0px', '0px']);
});

test('each inset becomes its own variable, in px', () => {
  assert.deepEqual(layoutVars(env({ top: 47, right: 3, bottom: 34, left: 0.5 })), {
    '--safe-top': '47px',
    '--safe-right': '3px',
    '--safe-bottom': '34px',
    '--safe-left': '0.5px',
    '--dock-pad': '34px',
  });
  assert.deepEqual(Object.keys(layoutVars(null)), ['--safe-top', '--safe-right', '--safe-bottom', '--safe-left', '--dock-pad']);
});

test('a float residue is written as a plain decimal, never in exponent form', () => {
  const vars = layoutVars(env({ top: 1e-7, layoutH: 844.1, vvH: 844.1 - 1e-9, vvTop: 0 }));
  for (const value of Object.values(vars)) assert.match(value, /^-?\d+(\.\d+)?px$/, value);
  assert.equal(vars['--safe-top'], '0px');
});

test('applyTheme sets data-theme on the root element', () => {
  const doc = { documentElement: { dataset: {} as Record<string, string> } };
  applyTheme(doc as unknown as Document, 'dark');
  assert.equal(doc.documentElement.dataset.theme, 'dark');
  applyTheme(doc as unknown as Document, 'light');
  assert.equal(doc.documentElement.dataset.theme, 'light');
});

test('applyTheme writes data-theme only when the scheme changes', () => {
  // A dataset that counts its writes, as the keyboard's env messages would make them.
  const writes: string[] = [];
  let theme: string | undefined;
  const dataset = {
    get theme() { return theme; },
    set theme(value) { writes.push(value!); theme = value; },
  };
  const doc = { documentElement: { dataset } } as unknown as Document;
  applyTheme(doc, 'dark');
  applyTheme(doc, 'dark');
  applyTheme(doc, 'dark');
  assert.deepEqual(writes, ['dark']);
  applyTheme(doc, 'light');
  applyTheme(doc, 'light');
  assert.deepEqual(writes, ['dark', 'light']);
});
