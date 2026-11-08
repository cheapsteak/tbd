/**
 * The loader's view of the screen, as the app uses it. The loader reads the values in its own
 * page (`readEnv` in `phone/loader/frame.js`), because the sandboxed frame cannot see the
 * safe-area insets or the keyboard. It cuts the insets to the part that overlaps the frame, so
 * the app pads by them as they are and nothing pads twice.
 */

export interface Insets { top: number; right: number; bottom: number; left: number }

export interface HostEnv {
  safeArea: Insets;
  /** The visual viewport, which shrinks above the on-screen keyboard. */
  viewport: { width: number; height: number; offsetTop: number; offsetLeft: number; scale: number };
  /** The layout viewport, which the keyboard does not change. */
  layout: { width: number; height: number };
  colorScheme: 'light' | 'dark';
}

/** The CSS variables `layoutVars` sets on the app's root. */
export type LayoutVar = '--safe-top' | '--safe-right' | '--safe-bottom' | '--safe-left' | '--dock-pad';

/** A pinch zoom also shrinks the visual viewport. Past this much zoom the gap is not a keyboard. */
const ZOOM_TOLERANCE = 0.01;

/**
 * How far the on-screen keyboard covers the layout viewport from the bottom: the layout
 * viewport's height below the visual viewport's bottom edge. It is 0 while the page is zoomed,
 * because a zoomed visual viewport is smaller for a reason that has nothing to do with the
 * keyboard, and 0 when the visual viewport reaches the bottom.
 */
export function keyboardInset(env: HostEnv): number {
  if (Math.abs(env.viewport.scale - 1) > ZOOM_TOLERANCE) return 0;
  return Math.max(0, env.layout.height - env.viewport.offsetTop - env.viewport.height);
}

/**
 * The layout variables for the app's root. `--dock-pad` lifts the dock above whichever is
 * taller, the bottom inset or the keyboard, since the keyboard covers the inset when it is up.
 * Before the first env message every variable is `0px`.
 */
export function layoutVars(env: HostEnv | null): Record<LayoutVar, string> {
  if (env === null) {
    return { '--safe-top': '0px', '--safe-right': '0px', '--safe-bottom': '0px', '--safe-left': '0px', '--dock-pad': '0px' };
  }
  const { top, right, bottom, left } = env.safeArea;
  return {
    '--safe-top': px(top),
    '--safe-right': px(right),
    '--safe-bottom': px(bottom),
    '--safe-left': px(left),
    '--dock-pad': px(Math.max(bottom, keyboardInset(env))),
  };
}

/**
 * Sets the theme the app's CSS keys on: `[data-theme="light"]` or `[data-theme="dark"]`. The
 * loader posts an env once a frame while the keyboard moves, so it writes the attribute only
 * when the scheme differs from the one set.
 */
export function applyTheme(doc: Document, scheme: 'light' | 'dark'): void {
  const { dataset } = doc.documentElement;
  if (dataset.theme !== scheme) dataset.theme = scheme;
}

/**
 * A length in px, rounded to 0.01 px. Subtracting fractional viewport values can leave a
 * residue such as 1.1e-13, which JavaScript writes in exponent form; rounding keeps every
 * value a plain decimal.
 */
function px(n: number): string {
  return `${Math.round(n * 100) / 100}px`;
}
