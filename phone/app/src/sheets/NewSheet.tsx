/**
 * The New sheet (mock `newSheetHTML`, mock 1123-1150), which a repo's "+" in the sessions list
 * opens. Contract: `NewSheet({ sheet, titleID })`, where `sheet` is the `new` sheet `ui.sheet`
 * holds, with the repo whose "+" was tapped (`repoID`, `repoName`); `titleID` names the sheet's
 * title for its `aria-labelledby`. It is the one sheet that acts on a repo, not on a session.
 *
 * - **Top.** Cancel, which closes the sheet and sends nothing; "New in <repo>"; Create. Then the
 *   choice of a "Local worktree" or a "Remote session", local first.
 * - **Remote** loads the providers afresh each time it shows (`loadProviders`, prefilled for the
 *   repo): a spinner while they load, the error's message if the load fails (choosing Local and
 *   Remote again tries again), then one row per provider under "Provider". The spinner always
 *   means a load on its way: a load that ends with nothing to show, as a superseded one does,
 *   starts another. An available provider reads how many fields its form adds, or "Needs nothing
 *   else"; an unavailable one is disabled and reads the laptop's reason (`providerDetail`). Only an available provider can be picked,
 *   and a list that loads again without the picked provider, or with it unavailable, unpicks it.
 *   Picking another provider starts its form afresh.
 * - **First message** ("What should Claude do?"), hidden when the picked provider takes none
 *   (`acceptsPrompt`), which then gets `""`. It is sent as typed.
 * - **The picked provider's form**, under "<provider> needs", one row per field by its type: a
 *   text input for `string`, a text area for `text`, a switch for `bool`, a number input for `int`,
 *   a select of its values for `enum`, and a text input for any type the app does not know, as the
 *   laptop's create sheet draws one. Each shows its prefill (`fieldText`, `fieldOn`), and a
 *   required field other than a switch is marked "required". A number field whose text is not a
 *   whole number, or that the browser cannot read as a number, says "Whole numbers only." under
 *   it (`fieldProblem`).
 * - **Local** ends with "TBD picks the branch, the worktree name and everything else from its
 *   defaults."
 *
 * **Create** is enabled when local has a message that is not blank by the laptop's rule
 * (`isBlankMessage`), or remote has an available provider picked whose params are ready
 * (`remoteParamsReady`: the message unless the provider takes none, every required field, and
 * whole numbers) and whose form shows no problem (`fieldProblem`), and no create is on its way. It
 * sends `worktree.create` (`createWorktree`) or `remote.create` (`createRemote`, with
 * `remoteCreateParams`, every field as it shows) for the sheet's own repo, and nothing else: the
 * action reads the sheet again at the tap.
 *
 * **While it creates**, the sheet shows only "Creating the worktree…" or "Starting the remote
 * session…", with a spinner and "The session opens when it is ready.", so nothing in it can send
 * a second create. A New sheet that opens for the same repo meanwhile shows that too. One for
 * another repo shows its form with Create disabled, and says why. An error brings the form back
 * with the error's message, as the laptop sent it, and the values as the user left them; a
 * success closes the sheet, and the new session opens once the list shows it (`actions/sheets.ts`).
 * The words of a create that failed after its sheet closed show here when this sheet opens for
 * that repo, and a create for another repo still on its way, or its session still waiting for the
 * list, is one the user moved on from: it opens nothing and never closes this sheet
 * (`newSheetShown`).
 *
 * **The tap guard.** Create and the provider rows are held for `TAP_GUARD_MS` (`useChangeHold`)
 * from the first render of the form and after each change of what it shows that a tap aimed a
 * moment before could land on: Local or Remote chosen, in the remote form the providers loading
 * or loaded and another provider picked (its form appears, and its first message may hide), an
 * error showing, the form coming back after "Creating…", and a create elsewhere ending. The local
 * form shows none of the remote form's changes, so they hold nothing there.
 */

import { useId, useLayoutEffect, useRef, useState } from 'react';
import type { JSX } from 'react';
import { Refusal } from '../dock/PromptCard.tsx';
import type { PhoneFormField, PhoneProvider } from '../protocol/types.ts';
import { useActions, useAppState } from '../state/context.tsx';
import { isBlankMessage } from '../state/prompts.ts';
import {
  enumChoices, failureIn, fieldLabel, fieldOn, fieldProblem, fieldText, isBoolField, NO_EDITS, providerDetail, remoteCreateParams,
  remoteParamsReady, withFieldBadInput, withFieldOn, withFieldText,
} from '../state/sheets.ts';
import type { CreateMode, FieldEdits, ProvidersLoad } from '../state/sheets.ts';
import type { SheetState } from '../state/store.ts';
import { Icon } from '../ui/Icon.tsx';
import { useChangeHold } from '../ui/tapGuard.ts';

/** The New sheet's `ui.sheet`. */
export type NewSheetState = Extract<SheetState, { name: 'new' }>;

/** Changes the form's edits with `fn`. */
type EditForm = (fn: (edits: FieldEdits) => FieldEdits) => void;

export function NewSheet({ sheet, titleID }: { sheet: NewSheetState; titleID: string }): JSX.Element {
  const actions = useActions();
  const creating = useAppState((s) => s.sheets.creating);
  const failure = useAppState((s) => failureIn(s.sheets, s.ui.sheet));
  const load = useAppState((s) => s.sheets.providers);
  const [mode, setMode] = useState<CreateMode>('local');
  const [message, setMessage] = useState('');
  const [pick, setPick] = useState<string | null>(null);
  const [edits, setEdits] = useState<FieldEdits>(NO_EDITS);
  const messageID = useId();
  const { repoID } = sheet;

  // Before the first paint, so the words show as the sheet does.
  useLayoutEffect(() => {
    actions.newSheetShown(sheet);
  }, [actions, sheet]);
  const mine: ProvidersLoad = load.phase !== 'idle' && load.repoID === repoID ? load : { phase: 'idle' };
  const idle = mine.phase === 'idle';
  // The repo the remote form loaded for as it showed, or null while it does not show.
  const shownFor = useRef<string | null>(null);
  // Afresh each time the remote form shows, before it paints, so an earlier list never shows. And
  // again whenever its load turns idle while it shows, as a superseded load leaves it, so the
  // spinner always means a load on its way: once each time, since the load leaves idle at once.
  useLayoutEffect(() => {
    if (mode !== 'remote') {
      shownFor.current = null;
      return;
    }
    const fresh = shownFor.current !== repoID;
    shownFor.current = repoID;
    if (fresh || idle) void actions.loadProviders(repoID);
  }, [actions, mode, repoID, idle]);

  const providers = mine.phase === 'loaded' ? mine.providers : null;
  const picked = pick === null || providers === null ? null : (providers.find((p) => p.name === pick && p.available) ?? null);
  if (pick !== null && providers !== null && picked === null) {
    // The list loaded again without the picked provider, or with it unavailable: nothing is picked.
    setPick(null);
    setEdits(NO_EDITS);
  }
  const here = creating !== null && creating.repoID === repoID;
  const elsewhere = creating !== null && !here;
  const params = mode === 'remote' && picked !== null ? remoteCreateParams(repoID, picked, message, edits) : null;
  const ready = mode === 'local'
    ? !isBlankMessage(message)
    : picked !== null && params !== null && remoteParamsReady(params, picked) && picked.fields.every((f) => fieldProblem(f, edits) === null);
  const remoteView = mode === 'remote' ? [mine.phase, picked?.name ?? null, picked?.acceptsPrompt ?? null] : [];
  const held = useChangeHold(here ? 'creating' : JSON.stringify(['form', mode, ...remoteView, failure !== null, elsewhere]));

  if (here) {
    return (
      <div className="creating">
        <span className="spin" style={{ width: 28, height: 28, borderWidth: 3 }} />
        <b id={titleID} style={{ color: 'var(--fg)' }}>
          {creating.mode === 'remote' ? 'Starting the remote session…' : 'Creating the worktree…'}
        </b>
        <span>The session opens when it is ready.</span>
      </div>
    );
  }

  const create = (): void => {
    if (mode === 'local') void actions.createWorktree(repoID, message);
    else if (params !== null) void actions.createRemote(params);
  };
  const pickProvider = (p: PhoneProvider): void => {
    if (p.name === picked?.name) return;
    setPick(p.name);
    setEdits(NO_EDITS);
  };
  return (
    <>
      <div className="sh-top">
        <button className="navbtn" type="button" onClick={() => actions.closeSheet()}>Cancel</button>
        <p className="sh-title" id={titleID}>{`New in ${sheet.repoName}`}</p>
        <button className="navbtn b" type="button" disabled={held || creating !== null || !ready} onClick={create}>Create</button>
      </div>
      {elsewhere && <p className="sh-sub">Create waits for the new session already on its way.</p>}
      {failure !== null && <Refusal text={failure} />}
      <div className="segc" role="group" aria-label="Kind">
        <button type="button" aria-pressed={mode === 'local'} onClick={() => setMode('local')}>Local worktree</button>
        <button type="button" aria-pressed={mode === 'remote'} onClick={() => setMode('remote')}>Remote session</button>
      </div>
      {mode === 'remote' && <Providers load={mine} picked={picked} held={held} onPick={pickProvider} />}
      {(picked === null || picked.acceptsPrompt || mode === 'local') && (
        <>
          <div className="lbl">First message</div>
          <div className="group">
            <div className="frow">
              <textarea
                id={messageID} rows={3} placeholder="What should Claude do?" aria-label="First message" value={message}
                onChange={(e) => setMessage(e.currentTarget.value)}
              />
            </div>
          </div>
        </>
      )}
      {mode === 'remote' && picked !== null && picked.fields.length > 0 && (
        <>
          <div className="lbl">{`${picked.name} needs`}</div>
          <div className="group">
            {picked.fields.map((f) => <Field key={f.name} field={f} edits={edits} edit={setEdits} />)}
          </div>
        </>
      )}
      {mode === 'local' && <p className="sh-sub">TBD picks the branch, the worktree name and everything else from its defaults.</p>}
    </>
  );
}

/**
 * The remote form's providers under "Provider": the spinner while they load, the failed load's
 * message, a line when the laptop has none, or one row per provider, the picked one ticked.
 */
function Providers({ load, picked, held, onPick }: {
  load: ProvidersLoad;
  picked: PhoneProvider | null;
  held: boolean;
  onPick: (p: PhoneProvider) => void;
}): JSX.Element {
  let list: JSX.Element;
  if (load.phase === 'failed') {
    list = <Refusal text={load.message} />;
  } else if (load.phase !== 'loaded') {
    list = (
      <div className="center" data-state="providers-loading">
        <span className="spin" />
      </div>
    );
  } else if (load.providers.length === 0) {
    list = <p className="sh-sub">This laptop has no remote providers.</p>;
  } else {
    list = (
      <div className="group">
        {load.providers.map((p) => {
          const detail = providerDetail(p);
          const on = picked !== null && picked.name === p.name;
          return (
            <button key={p.name} className="mi" type="button" aria-pressed={on} disabled={!p.available || held} onClick={() => onPick(p)}>
              <Icon name="cloud" />
              <span>
                {p.name}
                {detail !== null && <small>{detail}</small>}
              </span>
              {on && <Icon name="check" cls="tick" />}
            </button>
          );
        })}
      </div>
    );
  }
  return (
    <>
      <div className="lbl">Provider</div>
      {list}
    </>
  );
}

/** One field of the picked provider's form, drawn by its type (see the header). */
function Field({ field, edits, edit }: { field: PhoneFormField; edits: FieldEdits; edit: EditForm }): JSX.Element {
  const id = useId();
  const label = fieldLabel(field);
  const { name } = field;
  if (isBoolField(field)) {
    return (
      <div className="frow sw">
        <label htmlFor={id}>{label}</label>
        <label className="tg">
          <input
            id={id} type="checkbox" role="switch" checked={fieldOn(field, edits)}
            onChange={(e) => {
              const on = e.currentTarget.checked;
              edit((before) => withFieldOn(before, name, on));
            }}
          />
          <i />
        </label>
      </div>
    );
  }
  const value = fieldText(field, edits);
  const problem = fieldProblem(field, edits);
  const onText = (text: string): void => edit((before) => withFieldText(before, name, text));
  let input: JSX.Element;
  switch (field.type) {
    case 'text':
      input = <textarea id={id} rows={2} value={value} onChange={(e) => onText(e.currentTarget.value)} />;
      break;
    case 'enum':
      input = (
        <select id={id} value={value} onChange={(e) => onText(e.currentTarget.value)}>
          {enumChoices(field).map((v) => <option key={v} value={v}>{v === '' ? '—' : v}</option>)}
        </select>
      );
      break;
    case 'int':
      // `onInput` too: text the browser cannot read as a number leaves the value `""` as it was, and
      // React fires no `onChange` for that.
      input = (
        <input
          id={id} type="number" inputMode="numeric" value={value} onChange={(e) => onText(e.currentTarget.value)}
          onInput={(e) => {
            const bad = e.currentTarget.validity.badInput;
            edit((before) => withFieldBadInput(before, name, bad));
          }}
        />
      );
      break;
    default:
      // `string`, and any type the app does not know, as the laptop's create sheet draws them.
      input = <input id={id} type="text" inputMode="text" value={value} onChange={(e) => onText(e.currentTarget.value)} />;
  }
  return (
    <div className="frow">
      <label htmlFor={id}>
        {label}
        {field.required && (
          <>
            {' '}
            <span className="req">required</span>
          </>
        )}
      </label>
      {input}
      {problem !== null && <p className="sh-sub">{problem}</p>}
    </div>
  );
}
