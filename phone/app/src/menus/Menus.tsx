/**
 * The session header's dropdowns (spec section 8.3; mock 1028-1070), shown while `ui.menu` names
 * one: the account menu (`.lapdrop.profdrop`, "Account for this session") and the model menu
 * (`.lapdrop.modeldrop`, "Model for this session"). Contract: `Menus({ session })`, the open
 * session. Each shows only while the session's capability for it (`switchProfile`, `model`) is
 * available, as the header's buttons that open them do. When the capability turns unavailable
 * while the menu is open, the menu closes (`closeMenu`), before the next paint: it is gone, not
 * hidden, so the dock under it is no longer covered, and it does not come back by itself when the
 * capability returns.
 *
 * Both are `role="menu"`, each row a `menuitemradio` with `aria-checked` on the current one. A
 * tap outside the menu closes it and does nothing else (mock 1464-1469), except a tap on the
 * other menu's button in the header, which opens that menu; a tap on the open menu's own button
 * closes it. Escape closes it too.
 *
 * **The account menu** loads the profiles afresh as it opens (`loadProfiles`): a spinner while
 * they load, the error's message if the load fails (reopening the menu tries again), then one row
 * per profile with its kind (`profileDetail`) and a tick on the current one (`currentProfileID`).
 * Picking the current profile closes the menu. Picking another asks about it in the menu: the
 * ask the "Restart under X?" sheet shows too (`RestartAsk` in `sheets/ProfileSheets.tsx`, as
 * `.pd-ask`), "Restart this session under X?", what a restart stops, that a fork keeps the
 * session, then Restart (`switchProfile`), "Fork into a new tab" (`fork` under X) and Cancel,
 * which goes back to the list.
 *
 * **The model menu** lists `MODEL_NAMES`, with the tick on an exact match with `session.model`
 * only. Picking one calls `setModel`; picking the current one closes the menu. Under them, the
 * "Other model name" field and Set, enabled once the field holds more than white space. Set sends
 * the name trimmed of the white space around it (`setModel` trims). Enter in the field does
 * nothing, as in the mock. The session's status plays no part: the laptop takes a model change
 * while a session works and answers for itself.
 *
 * **Acting buttons** (Restart, "Fork into a new tab", the model rows and Set) are disabled while a
 * switch, fork or model change for the session is on its way (`isActing`), and for `TAP_GUARD_MS`
 * after the view that puts them under the finger shows (`useChangeHold`): the ask that replaces
 * the profile row just tapped, or changes under it (its note, a reason or a failure appearing),
 * or the model menu as it opens. In the ask, Restart and "Fork into a new tab" are also disabled
 * while their request cannot go out, with the reason under each (`switchBlock`,
 * `unavailableReason`): a parked session cannot fork, and a session already under the profile
 * asked about has nothing to restart. The ask holds and gates them itself (`RestartAsk`).
 *
 * **Outcomes.** A menu closes only when its action succeeds (`actions/sheets.ts`). A switch or a
 * fork refused or failed from the ask shows in the ask (`.refusal`, above its buttons) while that
 * ask shows, the very `ui.menu` of the tap (`failed` in the sheet slice); a refused switch shows
 * in the composer too, as a refused model change does, and a fork's error goes to the composer
 * only once the ask is gone.
 */

import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import type { JSX, RefObject } from 'react';
import type { PhoneProfile, PhoneSession } from '../protocol/types.ts';
import { NotLoaded, RestartAsk, useFreshProfiles } from '../sheets/ProfileSheets.tsx';
import type { AskLook } from '../sheets/ProfileSheets.tsx';
import { useActions, useAppState } from '../state/context.tsx';
import { trimLikeLaptop } from '../state/prompts.ts';
import { currentProfileID, failureIn, isActing, MODEL_NAMES, profileByID, profileDetail } from '../state/sheets.ts';
import type { MenuState } from '../state/store.ts';
import { Icon } from '../ui/Icon.tsx';
import { useChangeHold } from '../ui/tapGuard.ts';

/** The account menu's look for the ask. */
const IN_MENU: AskLook = { in: 'menu' };

/** Whether `menu` can show over `session`: while the session's capability for it is available. */
function canShow(menu: MenuState, session: PhoneSession): boolean {
  return (menu.name === 'account' ? session.capabilities.switchProfile : session.capabilities.model).available;
}

export function Menus({ session }: { session: PhoneSession }): JSX.Element | null {
  const actions = useActions();
  const menu = useAppState((s) => s.ui.menu);
  const shows = menu !== null && canShow(menu, session);
  // A menu that can no longer show closes, so `ui.menu` never names a menu nobody sees.
  useLayoutEffect(() => {
    if (menu !== null && !shows) actions.closeMenu();
  }, [actions, menu, shows]);
  if (menu === null || !shows) return null;
  if (menu.name === 'account') return <AccountMenu session={session} ask={menu.askProfileID} />;
  return <ModelMenu session={session} />;
}

/**
 * Closes the menu in `box` on a tap outside it or on Escape. The tap does nothing else: it is
 * stopped before the app sees it, in the capture phase at the document. A tap on a header button
 * that opens the other menu (`.prof` with `aria-expanded="false"`) goes through, so it opens that
 * menu.
 */
function useDismiss(box: RefObject<HTMLDivElement | null>): void {
  const actions = useActions();
  useEffect(() => {
    const el = box.current;
    if (el === null) return;
    const doc = el.ownerDocument;
    const onClick = (e: MouseEvent): void => {
      const target = e.target as Node | null;
      if (target !== null && el.contains(target)) return;
      const opener = target !== null && target.nodeType === 1 ? (target as Element).closest('.prof') : null;
      if (opener !== null && opener.getAttribute('aria-expanded') === 'false') return;
      e.preventDefault();
      e.stopPropagation();
      actions.closeMenu();
    };
    const onKey = (e: KeyboardEvent): void => {
      if (e.key !== 'Escape') return;
      e.preventDefault();
      actions.closeMenu();
    };
    doc.addEventListener('click', onClick, true);
    doc.addEventListener('keydown', onKey);
    return () => {
      doc.removeEventListener('click', onClick, true);
      doc.removeEventListener('keydown', onKey);
    };
  }, [box, actions]);
}

function AccountMenu({ session, ask }: { session: PhoneSession; ask: string | null }): JSX.Element {
  const actions = useActions();
  const box = useRef<HTMLDivElement>(null);
  useDismiss(box);
  const load = useFreshProfiles();
  const failure = useAppState((s) => failureIn(s.sheets, s.ui.menu));
  const profiles = load.phase === 'loaded' ? load.profiles : null;
  const asked = ask === null || profiles === null ? null : profileByID(profiles, ask);

  let body: JSX.Element | JSX.Element[];
  if (asked !== null && profiles !== null) {
    // Keyed by the profile, so an ask about another one is a new view, which the ask holds.
    body = (
      <RestartAsk
        key={asked.id} session={session} profiles={profiles} profile={asked} failure={failure} look={IN_MENU}
        onCancel={() => actions.openMenu({ name: 'account', askProfileID: null })}
      />
    );
  } else if (profiles !== null) {
    const current = currentProfileID(session, profiles);
    body = profiles.map((p) => (
      <ProfileRow
        key={p.id} profile={p} current={p.id === current}
        onPick={() => (p.id === current ? actions.closeMenu() : actions.openMenu({ name: 'account', askProfileID: p.id }))}
      />
    ));
  } else {
    body = <NotLoaded load={load} />;
  }

  return (
    <div ref={box} className="lapdrop profdrop" role="menu" aria-label="Account for this session">
      <div className="pd-lbl">Account for this session</div>
      {body}
    </div>
  );
}

function ProfileRow({ profile, current, onPick }: { profile: PhoneProfile; current: boolean; onPick: () => void }): JSX.Element {
  return (
    <button className="ldi" type="button" role="menuitemradio" aria-checked={current} onClick={onPick}>
      <Icon name="user" />
      <span>
        {profile.name}
        <small>{profileDetail(profile)}</small>
      </span>
      {current && <Icon name="check" cls="tick" />}
    </button>
  );
}

function ModelMenu({ session }: { session: PhoneSession }): JSX.Element {
  const actions = useActions();
  const box = useRef<HTMLDivElement>(null);
  useDismiss(box);
  const acting = useAppState((s) => isActing(s.sheets, session.ref));
  const [other, setOther] = useState('');
  const held = useChangeHold('model');
  const locked = held || acting;
  return (
    <div ref={box} className="lapdrop modeldrop" role="menu" aria-label="Model for this session">
      <div className="pd-lbl">Model for this session</div>
      {MODEL_NAMES.map((m) => {
        const current = m === session.model;
        return (
          <button
            key={m} className="ldi" type="button" role="menuitemradio" aria-checked={current} disabled={locked}
            onClick={() => (current ? actions.closeMenu() : void actions.setModel(m, session.ref))}
          >
            <Icon name="cpu" />
            <span>{m}</span>
            {current && <Icon name="check" cls="tick" />}
          </button>
        );
      })}
      <div className="ldsep" />
      <div className="md-other">
        <input
          type="text" placeholder="Other model name" aria-label="Other model name" autoComplete="off" autoCapitalize="off"
          value={other} onChange={(e) => setOther(e.currentTarget.value)}
        />
        <button
          className="btn pri" type="button" disabled={trimLikeLaptop(other) === '' || locked}
          onClick={() => void actions.setModel(other, session.ref)}
        >
          Set
        </button>
      </div>
    </div>
  );
}
