/**
 * The session menu sheet (mock 1077-1085), which the header's "Session menu" button opens.
 * Contract: `MenuSheet({ row, session, titleID })`, where `row` lists `session`, the open session.
 *
 * Its title is the row's name, with " · <tab name>" when the row has more than one session. Then
 * three rows, each opening its sheet: "Switch account" ("Now <account>. Restarts in this tab."),
 * "Fork" ("Copy this conversation into a new tab") and "Model" ("Now <model>", left out when the
 * laptop does not know the model). A row whose capability (`switchProfile`, `fork`, `model`) is
 * unavailable is disabled and shows the capability's reason in place of its line, as a remote
 * session's Switch account and Fork do, or a parked session's Fork; with no line at all when the
 * laptop gave no reason. Last comes Cancel. Nothing
 * here acts on the session: each row only opens a sheet.
 */

import type { JSX } from 'react';
import type { PhoneCapability, PhoneRow, PhoneSession } from '../protocol/types.ts';
import { useActions } from '../state/context.tsx';
import { accountName } from '../state/sheets.ts';
import type { GlyphName } from '../ui/glyphs.ts';
import { Icon } from '../ui/Icon.tsx';

export function MenuSheet({ row, session, titleID }: { row: PhoneRow; session: PhoneSession; titleID: string }): JSX.Element {
  const actions = useActions();
  const caps = session.capabilities;
  const title = row.sessions.length > 1 ? `${row.name} · ${session.tabName}` : row.name;
  return (
    <>
      <div className="sh-top">
        <p className="sh-title" id={titleID}>{title}</p>
      </div>
      <div className="group">
        <MenuRow
          icon="user" label="Switch account" capability={caps.switchProfile}
          detail={`Now ${accountName(session)}. Restarts in this tab.`} onOpen={() => actions.openSheet({ name: 'switch' })}
        />
        <MenuRow
          icon="fork" label="Fork" capability={caps.fork}
          detail="Copy this conversation into a new tab" onOpen={() => actions.openSheet({ name: 'fork' })}
        />
        <MenuRow
          icon="cpu" label="Model" capability={caps.model}
          detail={session.model === undefined ? null : `Now ${session.model}`} onOpen={() => actions.openSheet({ name: 'model' })}
        />
      </div>
      <button className="btn wide" type="button" onClick={() => actions.closeSheet()}>Cancel</button>
    </>
  );
}

/**
 * One row of the menu: `detail` under `label` while `capability` is available, else disabled with
 * its reason, or with nothing under the label when the laptop gave none (as `Why` in
 * `ProfileSheets.tsx` shows no empty line).
 */
function MenuRow({ icon, label, capability, detail, onOpen }: {
  icon: GlyphName;
  label: string;
  capability: PhoneCapability;
  detail: string | null;
  onOpen: () => void;
}): JSX.Element {
  const line = capability.available ? detail : (capability.reason ?? null);
  return (
    <button className="mi" type="button" disabled={!capability.available} onClick={onOpen}>
      <Icon name={icon} />
      <span>
        {label}
        {line !== null && line !== '' && <small>{line}</small>}
      </span>
      <Icon name="chev-r" cls="chev" />
    </button>
  );
}
