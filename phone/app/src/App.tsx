/**
 * The app's root. It keeps `#app`'s screen name and layout variables in step with the state,
 * shows a spinner until the first `sessions.subscribe` reply (or the refusal, with "Try again"),
 * and then the route's screen, the sheet and the toast. The screen is drawn under the sheet
 * (`UnderSheet`), which makes it inert while a sheet shows.
 *
 * `#app` is the element `main.tsx` made and mounted into. App writes to it directly: its
 * `data-screen` through `dataset`, and its variables through CSSOM, since the runner's policy
 * refuses a style attribute.
 *
 * The variables follow the loader's env, which comes once a frame while the keyboard moves. So
 * `LayoutVars`, a leaf that renders nothing, reads it, and App does not: an env message renders
 * that leaf alone, never the screen, and writes only the variables it changed, which while the
 * keyboard moves is `--dock-pad` alone (`app/render.test.js`).
 */

import { useLayoutEffect, useRef } from 'react';
import type { JSX } from 'react';
import { layoutVars } from './env.ts';
import { SessionScreen } from './screens/SessionScreen.tsx';
import { SessionsList } from './sessions/SessionsList.tsx';
import { SheetHost } from './sheets/SheetHost.tsx';
import { UnderSheet } from './sheets/UnderSheet.tsx';
import { useActions, useAppState } from './state/context.tsx';
import { Toast } from './ui/Toast.tsx';

export function App({ root }: { root: HTMLElement }): JSX.Element {
  const subscribed = useAppState((s) => s.conn.subscribed);
  const error = useAppState((s) => s.conn.error);
  const screen = useAppState((s) => s.ui.route.screen);
  const actions = useActions();

  useLayoutEffect(() => {
    root.dataset.screen = screen;
  }, [root, screen]);

  let content: JSX.Element;
  if (!subscribed && error !== null) {
    content = (
      <div className="center" data-state="app-error">
        <p>{error}</p>
        <div className="acts">
          <button className="btn pri" type="button" onClick={() => actions.retrySubscribe()}>Try again</button>
        </div>
      </div>
    );
  } else if (!subscribed) {
    content = (
      <div className="center" data-state="loading">
        <span className="spin" />
      </div>
    );
  } else {
    content = (
      <>
        <UnderSheet>{screen === 'session' ? <SessionScreen /> : <SessionsList />}</UnderSheet>
        <SheetHost />
        <Toast />
      </>
    );
  }

  return (
    <>
      <LayoutVars root={root} />
      {content}
    </>
  );
}

/**
 * Sets `root`'s layout variables from the loader's env. It renders nothing. Each env message is
 * a new object, so it keeps the values it wrote last and writes only a variable whose value
 * differs. `root` is the one element `main.tsx` makes, so the values it wrote are always its.
 */
function LayoutVars({ root }: { root: HTMLElement }): null {
  const env = useAppState((s) => s.env);
  const written = useRef<Map<string, string> | null>(null);

  useLayoutEffect(() => {
    const last = (written.current ??= new Map());
    for (const [name, value] of Object.entries(layoutVars(env))) {
      if (last.get(name) === value) continue;
      root.style.setProperty(name, value);
      last.set(name, value);
    }
  }, [root, env]);

  return null;
}
