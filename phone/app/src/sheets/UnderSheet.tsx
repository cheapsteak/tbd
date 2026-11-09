/**
 * The screen under the sheet. Contract: `UnderSheet({ children })`, where `children` is the
 * screen the route shows; App draws it before `SheetHost`. While a sheet shows (`sheetShows`, as
 * `SheetHost` decides), `.under` is `inert`, so neither Tab nor a screen reader reaches the
 * header, the transcript, the dock or the list the scrim covers, and focus stays in the sheet,
 * which is `aria-modal`. It takes no box of its own (`.under` is `display: contents`), so the
 * screen lays out as if it were not there.
 *
 * It is its own component, so a sheet that opens or closes renders it alone and never the screen
 * under it, whose element stays the one App made.
 */

import type { JSX } from 'react';
import { useAppState } from '../state/context.tsx';
import { sheetShows } from '../state/sheets.ts';

export function UnderSheet({ children }: { children: JSX.Element }): JSX.Element {
  const covered = useAppState(sheetShows);
  return (
    <div className="under" inert={covered}>
      {children}
    </div>
  );
}
