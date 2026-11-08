/**
 * The app's root. It keeps `#app`'s screen name and layout variables in step with the state,
 * shows a spinner until the first `sessions.subscribe` reply (or the refusal, with "Try again"),
 * and then the route's screen, the sheet and the toast.
 *
 * `#app` is the element `main.tsx` made and mounted into. App writes to it directly: its
 * `data-screen` through `dataset`, and its variables through CSSOM, since the runner's policy
 * refuses a style attribute.
 */

import { useLayoutEffect, useMemo } from 'react';
import type { JSX } from 'react';
import { layoutVars } from './env.ts';
import { SessionScreen } from './screens/SessionScreen.tsx';
import { SessionsList } from './sessions/SessionsList.tsx';
import { SheetHost } from './sheets/SheetHost.tsx';
import { useActions, useAppState } from './state/context.tsx';
import { Toast } from './ui/Toast.tsx';

export function App({ root }: { root: HTMLElement }): JSX.Element {
  const subscribed = useAppState((s) => s.conn.subscribed);
  const error = useAppState((s) => s.conn.error);
  const screen = useAppState((s) => s.ui.route.screen);
  const env = useAppState((s) => s.env);
  const actions = useActions();
  const vars = useMemo(() => layoutVars(env), [env]);

  useLayoutEffect(() => {
    root.dataset.screen = screen;
  }, [root, screen]);

  useLayoutEffect(() => {
    for (const [name, value] of Object.entries(vars)) root.style.setProperty(name, value);
  }, [root, vars]);

  if (!subscribed) {
    if (error !== null) {
      return (
        <div className="center" data-state="app-error">
          <p>{error}</p>
          <div className="acts">
            <button className="btn pri" type="button" onClick={() => actions.retrySubscribe()}>Try again</button>
          </div>
        </div>
      );
    }
    return (
      <div className="center" data-state="loading">
        <span className="spin" />
      </div>
    );
  }

  return (
    <>
      {screen === 'session' ? <SessionScreen /> : <SessionsList />}
      <SheetHost />
      <Toast />
    </>
  );
}
