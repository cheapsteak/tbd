/**
 * The Switch account, "Restart under X?" and Fork sheets (mock 1086-1107), and the ask about
 * restarting under a profile that the "Restart under X?" sheet and the account menu share.
 * Contract: `SwitchSheet({ session, titleID })`, `ConfirmSheet({ session, profileID, titleID, held,
 * failure })` and `ForkSheet({ session, titleID, held, failure })`, each for `session`, the open
 * session, and `RestartAsk({ session, profiles, profile, failure, look, onCancel })`. `held` says
 * the tap guard holds the sheet's acting buttons (`SheetHost`); `failure` is the words of an
 * action that failed while the sheet or the menu showed, or null.
 *
 * The Switch account and Fork sheets load the profiles afresh as they open (`loadProfiles`): a
 * spinner while they load, the error's message if the load fails (reopening the sheet tries
 * again), then the list. The spinner always means a load on its way: a load that ends with
 * nothing to show, as a superseded one does, starts another (`useProfiles`), in the
 * "Restart under X?" sheet too.
 *
 * - **Switch account**: Back, "Switch account", what a switch does, then one row per profile with
 *   its kind (`profileDetail`). The current profile (`currentProfileID`) reads "Current" and is
 *   disabled; picking another opens `switch-confirm` for it.
 * - **switch-confirm**: the ask (`RestartAsk`, below) as a sheet, whose Cancel goes back to the
 *   Switch account sheet. When the profiles the slice holds do not hold X, it asks nothing: its
 *   title reads "Switch account", then the spinner or the failed load's message while no list is
 *   loaded, then Cancel. Its title is there either way, since it names the dialog.
 * - **Fork**: Back, "Fork", what a fork does, then the profiles with the current one first
 *   (`forkOrder`), reading "Same account as now", the others their kind. A tap forks at once:
 *   under the session's own profile for the first (`fork(null)`, no `profileID` sent), else under
 *   the profile tapped.
 *
 *
 * **The ask** (`RestartAsk`), one component for the account menu's and the sheet's, so what it
 * says and when its buttons act are one rule: "Restart this session under X?", what a restart
 * stops (`restartNote`), that a fork keeps the session, the failure if one shows (`.refusal`),
 * then Restart (`switchProfile`), "Fork into a new tab" (`fork` under X) and Cancel (`onCancel`).
 * For a session the list shows parked, which a switch moves to X and leaves parked, the question
 * reads "Move this session to X?", the note says it stays parked, and the button reads Move
 * (`switchWords`); so does the Switch account sheet's line. `look` says where it shows, and only
 * the markup differs between the two:
 * - `{ in: 'menu' }`: `.pd-ask` in the account menu (mock 1045-1047), the question in `<b>`, the
 *   lines and the reasons in `<span>`s, and the buttons in a `<div>`;
 * - `{ in: 'sheet', titleID, held }`: `.confirm` (mock 1093-1097), the question in the `<h3>` that
 *   names the dialog, the lines and the reasons in `<p>`s, and the buttons `.wide`.
 *
 * Restart, "Fork into a new tab" and the Fork sheet's rows act on the session, so they are
 * disabled while a switch, fork or model change for it is on its way (`isActing`), and while the
 * tap guard holds them: in a sheet while `held`, and in the menu, which has no tap guard around
 * it, for `TAP_GUARD_MS` whenever the ask shows or changes (`useChangeHold`): its note, a reason,
 * or a failure appearing. They are also disabled while their request cannot go out, by the rules
 * the actions check (`switchBlock`, `unavailableReason`), with the reason under the button, or
 * under the Fork sheet's description for its rows: a fork the laptop marks unavailable cannot go
 * out, and a session already under the profile asked about has nothing to restart. Every action
 * reads its target from the store when tapped and acts only on the session this sheet or menu
 * showed (`from`, in `actions/sheets.ts`).
 */

import { useLayoutEffect, useRef } from 'react';
import type { JSX, ReactNode } from 'react';
import { Reason, Refusal } from '../dock/PromptCard.tsx';
import type { PhoneProfile, PhoneSession } from '../protocol/types.ts';
import { useActions, useAppState } from '../state/context.tsx';
import {
  currentProfileID, forkOrder, isActing, kindWords, profileByID, profileDetail, restartNote, switchBlock, switchWords, unavailableReason,
} from '../state/sheets.ts';
import type { ProfilesLoad } from '../state/sheets.ts';
import { Icon } from '../ui/Icon.tsx';
import { useChangeHold } from '../ui/tapGuard.ts';
import { SheetTop } from './SheetTop.tsx';

/**
 * The profiles, for the sheet or menu that calls it. With `fresh`, it loads them afresh before its
 * first paint, so a list an earlier opening loaded never shows; the account menu loads by it too
 * (`menus/Menus.tsx`). Either way it loads them again before the paint whenever the slice turns
 * `idle` while it shows, as a superseded load leaves it, so the spinner always means a load on
 * its way. That is once each time the slice turns idle, never more: the load leaves `idle` at
 * once (`loadProfiles`).
 */
export function useProfiles(fresh: boolean): ProfilesLoad {
  const actions = useActions();
  const load = useAppState((s) => s.sheets.profiles);
  const idle = load.phase === 'idle';
  const mounted = useRef(false);
  useLayoutEffect(() => {
    const first = !mounted.current;
    mounted.current = true;
    if ((first && fresh) || idle) void actions.loadProfiles();
  }, [actions, fresh, idle]);
  return load;
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
  const load = useProfiles(true);
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
      <p className="sh-sub">{switchWords(session).sub}</p>
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
  const load = useProfiles(false);
  const profiles = load.phase === 'loaded' ? load.profiles : null;
  const profile = profiles === null ? null : profileByID(profiles, profileID);
  const cancel = (): void => actions.openSheet({ name: 'switch' });
  if (profiles === null || profile === null) {
    // The list the profile was picked from is gone, or no longer holds it: there is nothing to ask
    // about. The spinner shows only while a list is on its way. The title still names the dialog
    // (`aria-labelledby`): this is the step of Switch account that Cancel goes back from.
    return (
      <div className="confirm">
        <h3 id={titleID}>Switch account</h3>
        {load.phase !== 'loaded' && <NotLoaded load={load} />}
        <button className="btn wide" type="button" onClick={cancel}>Cancel</button>
      </div>
    );
  }
  return (
    <RestartAsk
      session={session} profiles={profiles} profile={profile} failure={failure} look={{ in: 'sheet', titleID, held }} onCancel={cancel}
    />
  );
}

/**
 * Where the ask shows: in the account menu, or as the switch-confirm sheet, named by `titleID`
 * and held while `held` (see the header).
 */
export type AskLook = { in: 'menu' } | { in: 'sheet'; titleID: string; held: boolean };

/**
 * The ask about restarting `session` under `profile`, picked from `profiles` (see the header),
 * with `failure` above its buttons when not null. Cancel calls `onCancel`.
 */
export function RestartAsk({ session, profiles, profile, failure, look, onCancel }: {
  session: PhoneSession;
  profiles: readonly PhoneProfile[];
  profile: PhoneProfile;
  failure: string | null;
  look: AskLook;
  onCancel: () => void;
}): JSX.Element {
  const actions = useActions();
  const acting = useAppState((s) => isActing(s.sheets, session.ref));
  const inMenu = look.in === 'menu';
  const note = restartNote(session);
  const restartWhy = switchBlock(session, profiles, profile);
  const forkWhy = unavailableReason(session, 'fork');
  // The menu's own tap guard: the ask replaces the profile row just tapped, and its buttons move
  // when the note above them, a reason beside them or a failure changes. A sheet's comes in `held`.
  const view = `${profile.id} ${note} ${restartWhy ?? ''} ${forkWhy ?? ''} ${failure === null ? '' : 'failed'}`;
  const ownHeld = useChangeHold(inMenu ? view : null);
  const locked = acting || ownHeld || (look.in === 'sheet' && look.held);
  const wide = inMenu ? '' : ' wide';
  // Why an acting button cannot act (`switchBlock`, `unavailableReason`), under it.
  const why = inMenu ? 'span' : 'p';
  const words = switchWords(session);
  const question = words.question(profile.name);
  const forkNote = `To keep this session as it is, fork instead. A copy opens in a new tab under ${profile.name}.`;
  const refusal = failure === null ? null : <Refusal text={failure} />;
  const buttons: ReactNode = (
    <>
      <button
        className={`btn pri${wide}`} type="button" disabled={locked || restartWhy !== null}
        onClick={() => void actions.switchProfile(profile.id, session.ref)}
      >
        {words.button}
      </button>
      <Reason text={restartWhy} tag={why} />
      <button
        className={`btn${wide}`} type="button" disabled={locked || forkWhy !== null}
        onClick={() => void actions.fork(profile.id, session.ref)}
      >
        <Icon name="fork" />
        Fork into a new tab
      </button>
      <Reason text={forkWhy} tag={why} />
      <button className={`btn${wide}`} type="button" onClick={onCancel}>Cancel</button>
    </>
  );
  if (look.in === 'menu') {
    return (
      <div className="pd-ask">
        <b>{question}</b>
        <span>{note}</span>
        <span>{forkNote}</span>
        {refusal}
        <div>{buttons}</div>
      </div>
    );
  }
  return (
    <div className="confirm">
      <h3 id={look.titleID}>{question}</h3>
      <p>{note}</p>
      <p>{forkNote}</p>
      {refusal}
      {buttons}
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
  const load = useProfiles(true);
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
      <Reason text={forkWhy} tag="p" className="sh-sub" />
      {failure !== null && <Refusal text={failure} />}
      {list}
    </>
  );
}
