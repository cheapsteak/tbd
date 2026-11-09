/**
 * The Model sheet (mock 1108-1116). Contract: `ModelSheet({ session, titleID, held, failure })`,
 * for `session`, the open session. `held` says the tap guard holds Set (`SheetHost`); `failure`
 * is the words of an action that failed while the sheet showed, or null.
 *
 * Back, "Model" and Set on top, then "Sends /model to the session.", the four `MODEL_NAMES`, each
 * reading "Current" where it is `session.model`, and the "Other model name" field ("for example
 * claude-opus-5-5"). A tap on a name picks it and empties the field; the tick follows the pick,
 * and shows on the current model until there is one. Typing a name hides the tick, as the typed
 * name is what Set sends. Set is enabled once there is a pick or a name that is more than white
 * space, and sends the typed name when there is one (`setModel` trims it), else the pick. It is
 * disabled while a switch, fork or model change for the session is on its way (`isActing`) and
 * while `held`. The session's status plays no part: the laptop takes a model change while a
 * session works and answers for itself.
 */

import { useId, useState } from 'react';
import type { JSX } from 'react';
import { Refusal } from '../dock/PromptCard.tsx';
import type { PhoneSession } from '../protocol/types.ts';
import { useActions, useAppState } from '../state/context.tsx';
import { trimLikeLaptop } from '../state/prompts.ts';
import { isActing, MODEL_NAMES } from '../state/sheets.ts';
import { Icon } from '../ui/Icon.tsx';
import { SheetTop } from './SheetTop.tsx';

export function ModelSheet({ session, titleID, held, failure }: {
  session: PhoneSession;
  titleID: string;
  held: boolean;
  failure: string | null;
}): JSX.Element {
  const actions = useActions();
  const acting = useAppState((s) => isActing(s.sheets, session.ref));
  const [pick, setPick] = useState<string | null>(null);
  const [other, setOther] = useState('');
  const fieldID = useId();
  const typed = trimLikeLaptop(other) !== '';
  const ticked = typed ? null : (pick ?? session.model ?? null);
  const chosen = typed ? other : pick;
  const set = (
    <button
      className="navbtn b" type="button" disabled={chosen === null || held || acting}
      onClick={() => {
        if (chosen !== null) void actions.setModel(chosen, session.ref);
      }}
    >
      Set
    </button>
  );
  return (
    <>
      <SheetTop title="Model" titleID={titleID} onBack={() => actions.openSheet({ name: 'menu' })} action={set} />
      <p className="sh-sub">Sends <code>/model</code> to the session.</p>
      {failure !== null && <Refusal text={failure} />}
      <div className="group">
        {MODEL_NAMES.map((m) => (
          <button
            key={m} className="mi" type="button" aria-pressed={ticked === m}
            onClick={() => {
              setPick(m);
              setOther('');
            }}
          >
            <Icon name="cpu" />
            <span>
              {m}
              {m === session.model && <small>Current</small>}
            </span>
            {ticked === m && <Icon name="check" cls="tick" />}
          </button>
        ))}
        <div className="frow">
          <label htmlFor={fieldID}>Other model name</label>
          <input
            id={fieldID} type="text" placeholder="for example claude-opus-5-5" autoComplete="off" autoCapitalize="off"
            value={other} onChange={(e) => setOther(e.currentTarget.value)}
          />
        </div>
      </div>
    </>
  );
}
