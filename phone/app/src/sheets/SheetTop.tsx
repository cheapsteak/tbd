/**
 * The top row the Switch account, Fork and Model sheets share (mock `.sh-top`): Back, which goes
 * to the session menu, the sheet's title, and on the right either the sheet's own button (the
 * Model sheet's Set) or a spacer as wide as Back, so the title stays centred. Contract:
 * `SheetTop({ title, titleID, onBack, action })`; `titleID` names the title for the sheet's
 * `aria-labelledby`.
 */

import type { JSX } from 'react';

export function SheetTop({ title, titleID, onBack, action }: {
  title: string;
  titleID: string;
  onBack: () => void;
  action?: JSX.Element;
}): JSX.Element {
  return (
    <div className="sh-top">
      <button className="navbtn" type="button" onClick={onBack}>Back</button>
      <p className="sh-title" id={titleID}>{title}</p>
      {action ?? <span aria-hidden="true" style={{ width: 44 }} />}
    </div>
  );
}
