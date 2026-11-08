/**
 * The toast: one short line over the screen that takes itself down after 2,600 ms (mock
 * `toast()`). A newer toast has a new `id`, which starts the time over, so each toast shows for
 * the full time even when it replaces one still showing.
 */

import { useEffect } from 'react';
import type { JSX } from 'react';
import { useActions, useAppState } from '../state/context.tsx';

export const TOAST_MS = 2_600;

export function Toast(): JSX.Element | null {
  const toast = useAppState((s) => s.ui.toast);
  const actions = useActions();
  const id = toast === null ? null : toast.id;

  useEffect(() => {
    if (id === null) return;
    // `clearToast` takes down only the toast with this `id`, so a late call leaves a newer one.
    const timer = setTimeout(() => actions.clearToast(id), TOAST_MS);
    return () => clearTimeout(timer);
  }, [actions, id]);

  if (toast === null) return null;
  return <div className="toast" role="status">{toast.text}</div>;
}
