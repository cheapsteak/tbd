/**
 * The tap guard (part 6d): what keeps the second tap of a double tap, or a tap aimed at what was
 * on screen a moment before, from landing on an acting button the user has not seen yet. A view
 * that puts such a button where the user just tapped holds it `disabled` for `TAP_GUARD_MS`, so
 * a tap on it then does nothing at all. The dock holds its prompt card and Send with it
 * (`dock/Dock.tsx`); the menus and the sheets hold Restart, "Fork into a new tab", the Fork
 * sheet's profiles, the model menu's rows and Set.
 *
 * Closing a sheet or a menu is such a change too: what was under it shows again under the finger
 * that closed it (Cancel sits over Send; a tap outside a menu lands on whatever is there), so the
 * dock holds its card and Send after one closes (`useUncoverHold`).
 */

import { useEffect, useState } from 'react';

/** How long a view that appeared, or that changed, keeps its acting buttons disabled, in milliseconds. */
export const TAP_GUARD_MS = 500;

/**
 * Whether what `view` names was first shown, or changed, less than `TAP_GUARD_MS` ago: true from
 * the first render that shows the first `view` or a new one, so no frame draws it enabled, until
 * the time is up. Each change counts, even one back to a view shown before. A null `view` shows
 * nothing, and is never held.
 */
export function useChangeHold(view: string | null): boolean {
  const [shown, setShown] = useState({ view, n: 0 });
  // A new view is a new generation. Setting state while rendering makes React render again with
  // it before anything is drawn.
  if (shown.view !== view) setShown({ view, n: shown.n + 1 });
  const n = shown.view === view ? shown.n : shown.n + 1;
  const [released, setReleased] = useState(-1);
  useEffect(() => {
    const timer = setTimeout(() => setReleased(n), TAP_GUARD_MS);
    return () => clearTimeout(timer);
  }, [n]);
  return view !== null && released !== n;
}

/**
 * Whether a sheet or a menu that covered the screen closed less than `TAP_GUARD_MS` ago: true from
 * the first render after `covered` turns false until the time is up, so the second tap of a double
 * tap on what closed it (Cancel, the scrim, a tap outside a menu) does not land on what was under
 * it. Never while `covered`, and not on the first render: nothing has closed then.
 */
export function useUncoverHold(covered: boolean): boolean {
  const [seen, setSeen] = useState({ covered, closes: 0 });
  let closes = seen.closes;
  if (seen.covered !== covered) {
    if (!covered) closes += 1;
    // As in `useChangeHold`: React renders again with it before anything is drawn.
    setSeen({ covered, closes });
  }
  const [released, setReleased] = useState(0);
  useEffect(() => {
    if (closes === 0) return;
    const timer = setTimeout(() => setReleased(closes), TAP_GUARD_MS);
    return () => clearTimeout(timer);
  }, [closes]);
  return !covered && released !== closes;
}
