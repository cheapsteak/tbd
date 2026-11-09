/**
 * The sheet over the screen that `ui.sheet` names (mock `sheetHTML`, mock 1072-1121). Contract:
 * `SheetHost()`, with no props; it reads the sheet and the open session from the store. It renders
 * `.scrim`, which closes the sheet when tapped, and `.sheet` (`role="dialog"`, `aria-modal="true"`,
 * named by the sheet's title), with `.grab`, then the sheet by name: `menu` (`MenuSheet`), `switch`,
 * `switch-confirm` and `fork` (`ProfileSheets`), `model` (`ModelSheet`), and `new` (`NewSheet`,
 * as a tall sheet). Escape closes it too.
 *
 * Every sheet but `new` acts on the open session: the session the route shows, as the list shows
 * it. With no such session nothing renders; the shell closes every sheet when an event moves the
 * route or the list stops showing the session (`applySessions`), and each action acts only on the
 * session this render showed (`from`, in `actions/sheets.ts`). `new` acts on the repo it opened
 * for, and renders over whatever screen shows.
 *
 * **Focus.** When the sheet opens, focus moves into it (to `.sheet` itself), and again each time
 * it shows another sheet, since the button that opened that one is gone, and each time the New
 * sheet turns to "Creating…" and back. While it shows, the screen under it is inert
 * (`UnderSheet`), so Tab and Shift+Tab, and a screen reader, stay in the sheet and never reach
 * the header, the transcript or the dock behind the scrim. When it closes, focus goes back to the
 * element that had it before the sheet opened, if that is still on the page.
 *
 * **The keyboard.** `.sheet` pads by the safe area, and the keyboard covers the bottom of the
 * screen, so the sheets that take typing, New and Model, end above the keyboard instead: the
 * bottom edge rises by `--dock-pad` less the bottom inset, which the keyboard covers when it is up
 * (`LIFT`). The New sheet's top stays put, so it grows shorter; the Model sheet, which is only as
 * tall as it needs, may then grow no taller than it could before less the lift, so its top stays
 * on the screen. Whenever such a sheet changes size, as while the keyboard moves, and whenever a
 * field in it takes focus, the focused field's row is scrolled into the part of the sheet that
 * shows (`useFieldInView`).
 *
 * **The tap guard.** The rows of the session menu sit where the sheets they open put their own
 * rows, and a profile picked in the Switch account sheet opens the question whose Restart sits
 * near it. So each time the sheet's view changes (`sheetView`: another sheet; the profiles loading
 * or loaded; the current profile changing, which reorders the Fork sheet; the restart note or the
 * model changing; a reason appearing; a failure showing, which moves what is below it), its acting
 * buttons are held for `TAP_GUARD_MS` (`useChangeHold`): Restart and "Fork into a new tab", the
 * Fork sheet's rows, and the Model sheet's Set. The New sheet holds its own (`NewSheet`).
 *
 * Closing the New sheet uncovers the sessions list under the finger that closed it: Cancel and
 * Create lie over its rows, and the scrim over a repo's "+". So for `TAP_GUARD_MS` after it
 * closes (`useUncoverHold`), an invisible layer over the whole screen takes every tap and does
 * nothing with it, and the second tap of a double tap on Cancel or the scrim opens no session and
 * no second New sheet. It covers the session a create opens as well. The session sheets need no
 * such layer: what they uncover is the dock, which holds its own (`dock/Dock.tsx`).
 *
 * **A failure** of an action made from a sheet shows in that sheet (`failed` in the sheet slice)
 * while it is the sheet `ui.sheet` holds; another sheet, or closing it, drops it.
 */

import { useEffect, useId, useLayoutEffect, useMemo, useRef } from 'react';
import type { CSSProperties, JSX, KeyboardEvent, RefObject } from 'react';
import type { PhoneSession } from '../protocol/types.ts';
import { useActions, useAppState } from '../state/context.tsx';
import { findSession } from '../state/route.ts';
import { currentProfileID, failureIn, restartNote, sheetShows, unavailableReason } from '../state/sheets.ts';
import type { ActingKind, ProfilesLoad } from '../state/sheets.ts';
import type { SheetState } from '../state/store.ts';
import { useChangeHold, useUncoverHold } from '../ui/tapGuard.ts';
import { MenuSheet } from './MenuSheet.tsx';
import { ModelSheet } from './ModelSheet.tsx';
import { NewSheet } from './NewSheet.tsx';
import { ConfirmSheet, ForkSheet, SwitchSheet } from './ProfileSheets.tsx';

/** How far a sheet that takes typing rises: above the keyboard while it is up, else not at all. */
const LIFT = '(var(--dock-pad, 0px) - var(--safe-bottom, 0px))';

/** The New sheet's bottom edge: above the keyboard while it is up, else at the screen's bottom, as every sheet's. */
const NEW_SHEET_STYLE: CSSProperties = { bottom: `calc${LIFT}` };

/** The Model sheet's: the same, and its most height (`.sheet`'s 90%) less the lift, so its top stays where it could be. */
const MODEL_SHEET_STYLE: CSSProperties = { bottom: `calc${LIFT}`, maxHeight: `calc(90% - ${LIFT})` };

/** The layer that takes the taps for a moment after the New sheet closes: invisible, over the whole screen, under the toast. */
const SHIELD_STYLE: CSSProperties = { position: 'absolute', inset: 0, zIndex: 20 };

export function SheetHost(): JSX.Element | null {
  const actions = useActions();
  const sheet = useAppState((s) => s.ui.sheet);
  const route = useAppState((s) => s.ui.route);
  const sessions = useAppState((s) => s.sessions);
  const load = useAppState((s) => s.sheets.profiles);
  const failure = useAppState((s) => failureIn(s.sheets, s.ui.sheet));
  const creatingIn = useAppState((s) => s.sheets.creating?.repoID ?? null);
  const found = useMemo(() => (route.screen === 'session' ? findSession(sessions, route.ref) : null), [route, sessions]);
  const fresh = sheet !== null && sheet.name === 'new' ? sheet : null;
  const shown = useAppState(sheetShows) ? sheet : null;
  const box = useRef<HTMLDivElement>(null);
  const titleID = useId();
  useSheetFocus(box, shown === null ? null : sheetName(shown, creatingIn));
  const typing = fresh !== null || shown?.name === 'model';
  useFieldInView(box, typing);
  const held = useChangeHold(shown === null || fresh !== null || found === null ? null : sheetView(shown, load, failure, found.session));
  const shielded = useUncoverHold(fresh !== null);
  if (shown === null) return shielded ? <div aria-hidden="true" style={SHIELD_STYLE} /> : null;

  let body: JSX.Element | null = null;
  if (fresh !== null) {
    body = <NewSheet key={fresh.repoID} sheet={fresh} titleID={titleID} />;
  } else if (found !== null) {
    const { row, session } = found;
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
  }

  const onKeyDown = (e: KeyboardEvent<HTMLDivElement>): void => {
    if (e.key !== 'Escape') return;
    e.preventDefault();
    actions.closeSheet();
  };
  return (
    <>
      <div className="scrim" onClick={() => actions.closeSheet()} />
      <div
        ref={box} className={fresh !== null ? 'sheet tall' : 'sheet'}
        style={fresh !== null ? NEW_SHEET_STYLE : shown.name === 'model' ? MODEL_SHEET_STYLE : undefined}
        role="dialog" aria-modal="true" aria-labelledby={titleID} tabIndex={-1} onKeyDown={onKeyDown}
      >
        <div className="grab" />
        {body}
      </div>
    </>
  );
}

/**
 * Which sheet `sheet` is, for focus: its name, for `switch-confirm` the profile it asks about,
 * and for `new` its repo and whether it shows "Creating…" (a create on its way from `creatingIn`,
 * the repo of the create on its way, or null), which takes the place of Create, the button that
 * had focus, and gives it back again on an error.
 */
function sheetName(sheet: SheetState, creatingIn: string | null = null): string {
  if (sheet.name === 'switch-confirm') return `switch-confirm ${sheet.profileID}`;
  if (sheet.name === 'new') return `new ${sheet.repoID}${creatingIn === sheet.repoID ? ' creating' : ''}`;
  return sheet.name;
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

/**
 * While `on`, keeps the field that has focus in `box` in the part of `box` that shows: each time
 * a field in it takes focus, and each time `box` changes size, as the New and Model sheets do
 * while the keyboard moves (see the header). It scrolls `box` alone, by as little as it takes, to show the
 * field's row (`.frow`, its label with it), or the field when the row is taller than what shows.
 * Where the browser has no `ResizeObserver`, it does so only as a field takes focus, and the sheet
 * works all the same (the prompt card's `useEndInView` checks for it too).
 */
function useFieldInView(box: RefObject<HTMLDivElement | null>, on: boolean): void {
  useEffect(() => {
    const el = box.current;
    if (!on || el === null) return;
    const reveal = (): void => {
      const field = el.ownerDocument.activeElement;
      if (field === null || !el.contains(field) || !FIELD_TAGS.has(field.tagName)) return;
      revealIn(el, field);
    };
    const observer = typeof ResizeObserver === 'function' ? new ResizeObserver(reveal) : null;
    observer?.observe(el);
    el.addEventListener('focusin', reveal);
    return () => {
      observer?.disconnect();
      el.removeEventListener('focusin', reveal);
    };
  }, [box, on]);
}

/** The elements that take typing, and so bring the keyboard up. */
const FIELD_TAGS: ReadonlySet<string> = new Set(['INPUT', 'TEXTAREA', 'SELECT']);

/** Scrolls `box` by as little as it takes to show `field`'s row inside its padding, or `field` itself when the row does not fit. */
function revealIn(box: HTMLElement, field: Element): void {
  const style = box.ownerDocument.defaultView?.getComputedStyle(box);
  const outer = box.getBoundingClientRect();
  const top = outer.top + parseFloat(style?.paddingTop ?? '0');
  const bottom = outer.bottom - parseFloat(style?.paddingBottom ?? '0');
  const row = field.closest('.frow');
  const rowBox = row?.getBoundingClientRect();
  const target = rowBox !== undefined && rowBox.height <= bottom - top ? rowBox : field.getBoundingClientRect();
  if (target.bottom > bottom) box.scrollTop += target.bottom - bottom;
  else if (target.top < top) box.scrollTop -= top - target.top;
}
