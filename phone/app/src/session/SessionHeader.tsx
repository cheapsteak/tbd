/**
 * The session screen's header (spec section 8.3; mock `sessionHTML`): back, the row's name with
 * a "remote" badge, the session's status and how long ago it changed, its account and model,
 * the "Details" switch and the session menu. `SessionHeader({ row, session })`, where `row`
 * lists `session`.
 *
 * The account and the model are buttons only where the session's capabilities say the action is
 * available (`switchProfile`, `model`); otherwise they read as plain text. The menus they open
 * and the session menu's sheet belong to part 6d. A Codex tab shows its status only, so it has
 * no Details switch and no session menu. The age moves with the 30 s beat (`useNow`).
 */

import type { JSX } from 'react';
import type { PhoneRow, PhoneSession } from '../protocol/types.ts';
import { useActions, useAppState } from '../state/context.tsx';
import { ago, STATUS } from '../state/status.ts';
import { Dots, Icon } from '../ui/Icon.tsx';
import { useNow } from '../ui/now.ts';

const AGE_REFRESH_MS = 30_000;

export function SessionHeader({ row, session }: { row: PhoneRow; session: PhoneSession }): JSX.Element {
  const actions = useActions();
  const showDetails = useAppState((s) => s.ui.showDetails);
  const menu = useAppState((s) => s.ui.menu);
  const now = useNow(AGE_REFRESH_MS);
  const st = STATUS[session.status.chip];
  const caps = session.capabilities;
  const codex = session.agent === 'codex';

  const model = session.model ?? 'Model';
  const modelPart = caps.model.available ? (
    <button
      className="prof" type="button" aria-haspopup="menu" aria-expanded={menu?.name === 'model'}
      aria-label={`Model: ${model}. Change model`} onClick={() => actions.openMenu({ name: 'model' })}
    >
      {model}
      <Icon name="chev-d" />
    </button>
  ) : (
    <>{model}</>
  );
  const account = session.profileName ?? 'Default account';
  const accountPart = caps.switchProfile.available ? (
    <button
      className="prof" type="button" aria-haspopup="menu" aria-expanded={menu?.name === 'account'}
      aria-label={`Account: ${account}. Switch account`}
      onClick={() => actions.openMenu({ name: 'account', askProfileID: null })}
    >
      {account}
      <Icon name="chev-d" />
    </button>
  ) : (
    <>{account}</>
  );

  let meta: JSX.Element;
  if (session.ref.kind === 'remote') meta = <>{session.ref.provider} · {modelPart}</>;
  else if (codex) meta = <>Codex</>;
  else meta = <>{accountPart} · {modelPart}</>;

  return (
    <div className={`s-head st-${st.cls}`}>
      <button className="ib" type="button" aria-label="Back to sessions" onClick={() => actions.back()}>
        <Icon name="chev-l" />
      </button>
      <div className="s-title">
        <span className="t1">
          <span>{row.name}</span>
          {row.remote && (
            <span className="rb2">
              <Icon name="cloud" />
              remote
            </span>
          )}
        </span>
        <span className="t2">
          <span className="t2a">
            <span className="w">
              {st.glyph === 'dots' ? <Dots /> : st.glyph !== null && <Icon name={st.glyph} />}
              {st.word}
            </span>
            · {ago(now, session.status.changedAt)}
          </span>
          <span className="t2b">{meta}</span>
        </span>
      </div>
      {!codex && (
        <>
          <label className="tg">
            <span>Details</span>
            <input
              type="checkbox" role="switch" aria-label="Show details" checked={showDetails}
              onChange={(e) => actions.setShowDetails(e.currentTarget.checked)}
            />
            <i />
          </label>
          <button className="ib" type="button" aria-label="Session menu" onClick={() => actions.openSheet({ name: 'menu' })}>
            <Icon name="more" />
          </button>
        </>
      )}
    </div>
  );
}
