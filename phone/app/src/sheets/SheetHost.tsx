/**
 * The sheet over the screen that `ui.sheet` names (mock `sheetHTML`, mock 1072-1121). Contract:
 * `SheetHost()`, with no props; it reads the sheet and the open session from the store. It renders
 * `.scrim`, which closes the sheet when tapped, and `.sheet` (`role="dialog"`, `aria-modal="true"`,
 * named by the sheet's title), with `.grab`, then the sheet by name: `menu` (`MenuSheet`), `switch`,
 * `switch-confirm` and `fork` (`ProfileSheets`), and `model` (`ModelSheet`). Escape closes it too.
 * `new` belongs to the New sheet, which part 6d's last task adds; until then it renders nothing.
 *
 * Every sheet but `new` acts on the open session: the session the route shows, as the list shows
 * it. With no such session nothing renders; the shell closes every sheet when an event moves the
 * route or the list stops showing the session (`applySessions`), and each action acts only on the
 * session this render showed (`from`, in `actions/sheets.ts`).
 *
 * **Focus.** When the sheet opens, focus moves into it (to `.sheet` itself), and again each time
 * it shows another sheet, since the button that opened that one is gone. When it closes, focus
 * goes back to the element that had it before the sheet opened, if that is still on the page.
 *
 * **The tap guard.** The rows of the session menu sit where the sheets they open put their own
 * rows, and a profile picked in the Switch account sheet opens the question whose Restart sits
 * near it. So each time the sheet's view changes (`sheetView`: another sheet; the profiles loading
 * or loaded; the current profile changing, which reorders the Fork sheet; the restart note or the
 * model changing; a reason appearing; a failure showing, which moves what is below it), its acting
 * buttons are held for `TAP_GUARD_MS` (`useChangeHold`): Restart and "Fork into a new tab", the
 * Fork sheet's rows, and the Model sheet's Set.
 *
 * **A failure** of an action made from a sheet shows in that sheet (`failed` in the sheet slice)
 * while it is the sheet `ui.sheet` holds; another sheet, or closing it, drops it.
 */

import { useId, useLayoutEffect, useMemo, useRef } from 'react';
import type { JSX, KeyboardEvent, RefObject } from 'react';
import type { PhoneSession } from '../protocol/types.ts';
import { useActions, useAppState } from '../state/context.tsx';
import { findSession } from '../state/route.ts';
import { currentProfileID, failureIn, restartNote, unavailableReason } from '../state/sheets.ts';
import type { ActingKind, ProfilesLoad } from '../state/sheets.ts';
import type { SheetState } from '../state/store.ts';
import { useChangeHold } from '../ui/tapGuard.ts';
import { MenuSheet } from './MenuSheet.tsx';
import { ModelSheet } from './ModelSheet.tsx';
import { ConfirmSheet, ForkSheet, SwitchSheet } from './ProfileSheets.tsx';

export function SheetHost(): JSX.Element | null {
  const actions = useActions();
  const sheet = useAppState((s) => s.ui.sheet);
  const route = useAppState((s) => s.ui.route);
  const sessions = useAppState((s) => s.sessions);
  const load = useAppState((s) => s.sheets.profiles);
  const failure = useAppState((s) => failureIn(s.sheets, s.ui.sheet));
  const found = useMemo(() => (route.screen === 'session' ? findSession(sessions, route.ref) : null), [route, sessions]);
  const shown = sheet !== null && sheet.name !== 'new' && found !== null ? sheet : null;
  const box = useRef<HTMLDivElement>(null);
  const titleID = useId();
  useSheetFocus(box, shown === null ? null : sheetName(shown));
  const held = useChangeHold(shown === null || found === null ? null : sheetView(shown, load, failure, found.session));
  if (shown === null || found === null) return null;
  const { row, session } = found;

  let body: JSX.Element;
  switch (shown.name) {
    case 'menu':
      body = <MenuSheet row={row} session={session} titleID={titleID} />;
      break;
    case 'switch':
      body = <SwitchSheet session={session} titleID={titleID} />;
      break;
    case 'switch-confirm':
      body = <ConfirmSheet session={session} profileID={shown.profileID} titleID={titleID} held={held} failure={failure} />;
      break;
    case 'fork':
      body = <ForkSheet session={session} titleID={titleID} held={held} failure={failure} />;
      break;
    case 'model':
      body = <ModelSheet session={session} titleID={titleID} held={held} failure={failure} />;
      break;
  }

  const onKeyDown = (e: KeyboardEvent<HTMLDivElement>): void => {
    if (e.key !== 'Escape') return;
    e.preventDefault();
    actions.closeSheet();
  };
  return (
    <>
      <div className="scrim" onClick={() => actions.closeSheet()} />
      <div ref={box} className="sheet" role="dialog" aria-modal="true" aria-labelledby={titleID} tabIndex={-1} onKeyDown={onKeyDown}>
        <div className="grab" />
        {body}
      </div>
    </>
  );
}

/** Which sheet `sheet` is, for focus: its name, and for `switch-confirm` the profile it asks about. */
function sheetName(sheet: SheetState): string {
  return sheet.name === 'switch-confirm' ? `switch-confirm ${sheet.profileID}` : sheet.name;
}

/**
 * What the sheet shows, for the tap guard: anything that puts other rows or buttons under the
 * finger. Which sheet; for the sheets that list the profiles, how far they have loaded and which
 * is the current one (the Fork sheet puts it first); the restart note, which grows or shrinks
 * above Restart as the session starts or stops working; the model (its row reads "Current");
 * which acting requests the session's capabilities allow, since a reason shows for each that it
 * does not; and whether a failure shows.
 */
function sheetView(sheet: SheetState, load: ProfilesLoad, failure: string | null, session: PhoneSession): string {
  let view = sheetName(sheet);
  if (sheet.name === 'switch' || sheet.name === 'switch-confirm' || sheet.name === 'fork') {
    view += ` ${load.phase}`;
    if (load.phase === 'loaded') view += ` current ${currentProfileID(session, load.profiles) ?? ''}`;
  }
  if (sheet.name === 'switch-confirm') view += ` ${restartNote(session)}`;
  if (sheet.name === 'model') view += ` model ${session.model ?? ''}`;
  const kinds: readonly ActingKind[] = ['switch', 'fork', 'model'];
  view += ` can ${kinds.map((k) => unavailableReason(session, k) ?? 'yes').join(' ')}`;
  if (failure !== null) view += ' failed';
  return view;
}

/**
 * Moves focus into `box` each time `name` names another sheet, and back to the element that had
 * it before the sheet opened once `name` is null, if that element is still on the page. Layout
 * effects, so focus moves before the sheet is drawn; the one that remembers the opener comes first,
 * so it reads the focus before it moves.
 */
function useSheetFocus(box: RefObject<HTMLDivElement | null>, name: string | null): void {
  const open = name !== null;
  useLayoutEffect(() => {
    if (!open) return;
    const opener = box.current?.ownerDocument.activeElement ?? null;
    return () => {
      if (opener !== null && opener.isConnected && typeof (opener as HTMLElement).focus === 'function') {
        (opener as HTMLElement).focus({ preventScroll: true });
      }
    };
  }, [box, open]);
  useLayoutEffect(() => {
    if (name !== null) box.current?.focus({ preventScroll: true });
  }, [box, name]);
}
