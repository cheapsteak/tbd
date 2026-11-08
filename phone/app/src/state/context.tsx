/**
 * How components reach the store and the actions: `main.tsx` provides both through
 * `AppContext`, a component reads state with `useAppState` and acts with `useActions`.
 */

import { createContext, useContext, useSyncExternalStore } from 'react';
import type { Actions } from '../actions/index.ts';
import type { AppState, Store } from './store.ts';

export const AppContext = createContext<{ store: Store; actions: Actions } | null>(null);

function useApp(): { store: Store; actions: Actions } {
  const app = useContext(AppContext);
  if (app === null) throw new Error('TBD phone app: AppContext has no value');
  return app;
}

/**
 * The part of the state `select` picks, read again on every store change. The component
 * renders again only when the picked value changes, by `Object.is`.
 *
 * `select` must return a value from the state, such as `s.ui.route` or `s.sessions`, never a
 * new object or array built from it: React calls it on every check, and a value that is new
 * each time never matches, so the component renders forever. Build derived values in the
 * component, from the picked parts, with `useMemo`.
 */
export function useAppState<T>(select: (s: AppState) => T): T {
  const { store } = useApp();
  return useSyncExternalStore(store.subscribe, () => select(store.get()));
}

export function useActions(): Actions {
  return useApp().actions;
}
