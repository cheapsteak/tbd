/**
 * The Switch account, "Restart under X?" and Fork sheets (mock 1086-1107). Contract:
 * `SwitchSheet({ session, titleID })`, `ConfirmSheet({ session, profileID, titleID, held, failure })`
 * and `ForkSheet({ session, titleID, held, failure })`, each for `session`, the open session.
 * `held` says the tap guard holds the sheet's acting buttons (`SheetHost`); `failure` is the
 * words of an action that failed while the sheet showed, or null.
 *
 * The Switch account and Fork sheets load the profiles afresh as they open (`loadProfiles`): a
 * spinner while they load, the error's message if the load fails (reopening the sheet tries
 * again), then the list.
 *
 * - **Switch account**: Back, "Switch account", what a switch does, then one row per profile with
 *   its kind (`profileDetail`). The current profile (`currentProfileID`) reads "Current" and is
 *   disabled; picking another opens `switch-confirm` for it.
 * - **switch-confirm** (`.confirm`): the menu's ask, "Restart this session under X?", what a
 *   restart stops (`restartNote`) and that a fork keeps the session, then Restart
 *   (`switchProfile`), "Fork into a new tab" (`fork` under X) and Cancel, which goes back to the
 *   Switch account sheet.
 * - **Fork**: Back, "Fork", what a fork does, then the profiles with the current one first
 *   (`forkOrder`), reading "Same account as now", the others their kind. A tap forks at once:
 *   under the session's own profile for the first (`fork(null)`, no `profileID` sent), else under
 *   the profile tapped.
 *
 * Restart, "Fork into a new tab" and the Fork sheet's rows act on the session, so they are
 * disabled while a switch, fork or model change for it is on its way (`isActing`) and while
 * `held`. They are also disabled while their request cannot go out, by the rules the actions
 * check (`switchBlock`, `unavailableReason`), with the reason under the button, or under the Fork
 * sheet's description for its rows: a parked session cannot fork, and a session already under the
 * profile asked about has nothing to restart. Every action reads its target from the store when
 * tapped and acts only on the session this sheet showed (`from`, in `actions/sheets.ts`).
 */

import { useLayoutEffect } from 'react';
import type { JSX } from 'react';
import { Refusal } from '../dock/PromptCard.tsx';
import type { PhoneProfile, PhoneSession } from '../protocol/types.ts';
import { useActions, useAppState } from '../state/context.tsx';
import {
  currentProfileID, forkOrder, isActing, kindWords, profileByID, profileDetail, restartNote, switchBlock, unavailableReason,
} from '../state/sheets.ts';
import type { ProfilesLoad } from '../state/sheets.ts';
import { Icon } from '../ui/Icon.tsx';
import { SheetTop } from './SheetTop.tsx';

/**
 * Loads the profiles afresh before the first paint of the sheet or menu that calls it, so a list an
 * earlier opening loaded never shows. The account menu loads by it too (`menus/Menus.tsx`).
 */
export function useFreshProfiles(): ProfilesLoad {
  const actions = useActions();
  useLayoutEffect(() => {
    void actions.loadProfiles();
  }, [actions]);
  return useAppState((s) => s.sheets.profiles);
}

/** Why the acting button above cannot act (`switchBlock`, `unavailableReason`), under it; nothing for null or for no reason given. */
function Why({ text }: { text: string | null }): JSX.Element | null {
  return text === null || text === '' ? null : <p>{text}</p>;
}

/** What stands in for the profiles until they load: the spinner, or the failed load's message. */
export function NotLoaded({ load }: { load: ProfilesLoad }): JSX.Element {
  if (load.phase === 'failed') return <Refusal text={load.message} />;
  return (
    <div className="center" data-state="profiles-loading">
      <span className="spin" />
    </div>
  );
}

export function SwitchSheet({ session, titleID }: { session: PhoneSession; titleID: string }): JSX.Element {
  const actions = useActions();
  const load = useFreshProfiles();
  let list: JSX.Element;
  if (load.phase !== 'loaded') {
    list = <NotLoaded load={load} />;
  } else {
    const current = currentProfileID(session, load.profiles);
    list = (
      <div className="group">
        {load.profiles.map((p) => (
          <SwitchRow key={p.id} profile={p} current={p.id === current} onPick={() => actions.openSheet({ name: 'switch-confirm', profileID: p.id })} />
        ))}
      </div>
    );
  }
  return (
    <>
      <SheetTop title="Switch account" titleID={titleID} onBack={() => actions.openSheet({ name: 'menu' })} />
      <p className="sh-sub">Restarts this session under another profile, in the same tab. The conversation stays.</p>
      {list}
    </>
  );
}

function SwitchRow({ profile, current, onPick }: { profile: PhoneProfile; current: boolean; onPick: () => void }): JSX.Element {
  return (
    <button className="mi" type="button" disabled={current} onClick={onPick}>
      <Icon name="user" />
      <span>
        {profile.name}
        <small>{profileDetail(profile)}</small>
      </span>
      {current ? <span className="cur">Current</span> : <Icon name="chev-r" cls="chev" />}
    </button>
  );
}

export function ConfirmSheet({ session, profileID, titleID, held, failure }: {
  session: PhoneSession;
  profileID: string;
  titleID: string;
  held: boolean;
  failure: string | null;
}): JSX.Element {
  const actions = useActions();
  const load = useAppState((s) => s.sheets.profiles);
  const acting = useAppState((s) => isActing(s.sheets, session.ref));
  const profile = load.phase === 'loaded' ? profileByID(load.profiles, profileID) : null;
  const restartWhy = profile === null || load.phase !== 'loaded' ? null : switchBlock(session, load.profiles, profile);
  const forkWhy = unavailableReason(session, 'fork');
  const locked = held || acting;
  const cancel = (): void => actions.openSheet({ name: 'switch' });
  if (profile === null) {
    // The list the profile was picked from is gone, or no longer holds it: there is nothing to ask
    // about. The spinner shows only while a list is on its way.
    return (
      <div className="confirm">
        {load.phase !== 'loaded' && <NotLoaded load={load} />}
        <button className="btn wide" type="button" onClick={cancel}>Cancel</button>
      </div>
    );
  }
  return (
    <div className="confirm">
      <h3 id={titleID}>Restart this session under {profile.name}?</h3>
      <p>{restartNote(session)}</p>
      <p>To keep this session as it is, fork instead. A copy opens in a new tab under {profile.name}.</p>
      {failure !== null && <Refusal text={failure} />}
      <button
        className="btn pri wide" type="button" disabled={locked || restartWhy !== null}
        onClick={() => void actions.switchProfile(profile.id, session.ref)}
      >
        Restart
      </button>
      <Why text={restartWhy} />
      <button
        className="btn wide" type="button" disabled={locked || forkWhy !== null}
        onClick={() => void actions.fork(profile.id, session.ref)}
      >
        <Icon name="fork" />
        Fork into a new tab
      </button>
      <Why text={forkWhy} />
      <button className="btn wide" type="button" onClick={cancel}>Cancel</button>
    </div>
  );
}

export function ForkSheet({ session, titleID, held, failure }: {
  session: PhoneSession;
  titleID: string;
  held: boolean;
  failure: string | null;
}): JSX.Element {
  const actions = useActions();
  const load = useFreshProfiles();
  const acting = useAppState((s) => isActing(s.sheets, session.ref));
  const forkWhy = unavailableReason(session, 'fork');
  let list: JSX.Element;
  if (load.phase !== 'loaded') {
    list = <NotLoaded load={load} />;
  } else {
    const current = currentProfileID(session, load.profiles);
    list = (
      <div className="group">
        {forkOrder(load.profiles, current).map((p) => {
          const same = p.id === current;
          return (
            <button
              key={p.id} className="mi" type="button" disabled={held || acting || forkWhy !== null}
              onClick={() => void actions.fork(same ? null : p.id, session.ref)}
            >
              <Icon name="fork" />
              <span>
                {p.name}
                <small>{same ? 'Same account as now' : kindWords(p.kind)}</small>
              </span>
              <Icon name="chev-r" cls="chev" />
            </button>
          );
        })}
      </div>
    );
  }
  return (
    <>
      <SheetTop title="Fork" titleID={titleID} onBack={() => actions.openSheet({ name: 'menu' })} />
      <p className="sh-sub">Copies this conversation into a new tab, under the account you pick. The phone switches to the new tab.</p>
      {forkWhy !== null && forkWhy !== '' && <p className="sh-sub">{forkWhy}</p>}
      {failure !== null && <Refusal text={failure} />}
      {list}
    </>
  );
}
