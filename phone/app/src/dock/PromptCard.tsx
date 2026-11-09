/**
 * The card of one waiting prompt, in the dock above the composer (spec section 8.3; mock
 * `promptHTML`, mock 938-986). Contract: `PromptCard({ session, prompt, card, held })`, where
 * `card` is the prompt's card in the prompt slice (`cardFor`) and `held` says its choices wait
 * (the dock's tap guard). The dock keys it by the prompt's ID, so everything the user picked,
 * typed or hid on it belongs to that prompt alone.
 *
 * **A question** (`QuestionCard`). The head (`.c-head`) holds the hand glyph, "Claude asks", and
 * " · i of n" with `.steps` under it when the prompt asks several questions, then Hide.
 * - A single-select question's options are `.opt` buttons, each with its description as a
 *   `<small>`. A multi-select question's are `.chk` checkboxes, then "Send N selected", or "Send
 *   answer" while none is picked.
 * - Every question offers "Other answer…" (the ghost `.opt`), multi-select included, since the
 *   laptop takes an Other value on every question. It opens a textarea ("Type your answer") with
 *   Cancel and "Send answer", which is disabled while the text is blank: a blank Other is no
 *   value. On a multi-select question the Other text joins the picked labels.
 * - **Steps.** With one question, a tap that gives it a value sends the answer at once. With
 *   several, it records the value and moves to the next question, and Back returns to the one
 *   before. After the last comes the review: "Send these answers?", one button per question with
 *   its header and value (a tap returns to that question), then Back and "Send answers".
 *
 * **A permission** (`PermissionCard`, mock 946-960). The head holds the hand glyph, "Permission"
 * and Hide; then `.perm-tool` (the tool's glyph and name), `.perm-desc` (the summary) and
 * `pre.perm-target` (the target, with "…" appended when the laptop cut it). The choices:
 * - `.opt.pri` "Yes", which allows;
 * - only when the prompt offers it (`allowAlways`), "Yes, and don't ask again this session", the
 *   laptop's label (`PermissionPromptCard.swift`), with each rule string from `suggestions` as
 *   sent in a `<small>` of its own, which allows for the session. The wire carries the rules,
 *   not the mock's prose;
 * - `.opt.danger` "No", which opens the deny form: "Tell Claude what to do instead (optional)",
 *   a textarea, then Back and `.btn.danger` "Deny". The message goes trimmed, and a blank one
 *   not at all (`permissionAnswer`).
 *
 * **What is sent** is exactly `questionAnswer(prompt.questions, draft)` or
 * `permissionAnswer(decision, message)`, through `answerPrompt(prompt.id, answer)`, which
 * computes the summary and sends once per gesture: it sends nothing unless the card is `open`.
 * While the card is `sending`, and while `held`, every choice and send button is disabled, so a
 * second tap sends nothing either.
 *
 * **No answer capability.** When the list shows the session's `answer` capability unavailable,
 * the card shows its head and the question or the permission's text, no choices, and the list's
 * reason in `.dock-note`.
 *
 * **Refusal.** The laptop's words for a refused answer (`card.refusal`) show as `.refusal`
 * (`role="alert"`) with the warn glyph, above the choices.
 *
 * **The keyboard.** The dock lifts above it by `--dock-pad`, and when that leaves too little room
 * the card shrinks and scrolls (app.css). The Other and deny forms end the card, so while one's
 * textarea has focus, the card keeps its end in view whenever its size changes (`useEndInView`):
 * the field and the buttons after it stay above the keyboard.
 *
 * **Hide** collapses the card to `.card-strip`, "Question waiting" or "Permission waiting", with
 * "Show". Hiding keeps what the user picked and typed; a new prompt, which mounts a new card,
 * starts expanded.
 */

import { useEffect, useId, useRef, useState } from 'react';
import type { JSX, RefObject } from 'react';
import type { PhonePrompt, PhoneQuestion, PhoneSession, PromptAnswer } from '../protocol/types.ts';
import { useActions } from '../state/context.tsx';
import {
  chooseOption, chooseOther, emptyQuestionDraft, permissionAnswer, questionAnswer, questionValue, setOtherText, trimLikeLaptop,
} from '../state/prompts.ts';
import { toolGlyph } from '../state/status.ts';
import type { CardState, QuestionDraft } from '../state/prompts.ts';
import { Icon } from '../ui/Icon.tsx';

/** What the user has done on a question card: the draft, the question shown (the review once past the last), and the Other form. */
interface QuestionUI {
  draft: QuestionDraft;
  /** The question shown, by index; the questions' count for the review. */
  step: number;
  /** Whether the shown question's Other form is open. */
  otherOpen: boolean;
  /** The text in the Other form. It becomes the question's value only through "Send answer". */
  otherText: string;
}

function freshQuestionUI(): QuestionUI {
  return { draft: emptyQuestionDraft(), step: 0, otherOpen: false, otherText: '' };
}

/** What the user has done on a permission card: whether the deny form is open, and its text. */
interface PermissionUI {
  denyOpen: boolean;
  denyText: string;
}

const FRESH_PERMISSION_UI: PermissionUI = { denyOpen: false, denyText: '' };

export function PromptCard(p: { session: PhoneSession; prompt: PhonePrompt; card: CardState; held: boolean }): JSX.Element | null {
  const { session, prompt, card, held } = p;
  const actions = useActions();
  const [hidden, setHidden] = useState(false);
  const [question, setQuestion] = useState(freshQuestionUI);
  const [permission, setPermission] = useState(FRESH_PERMISSION_UI);

  if (card.phase !== 'open' && card.phase !== 'sending') return null;
  const isPermission = prompt.kind === 'permission';
  if (hidden) {
    return (
      <button className="card-strip" type="button" onClick={() => setHidden(false)}>
        <Icon name="hand" />
        {isPermission ? 'Permission waiting' : 'Question waiting'}
        <span>
          Show <Icon name="chev-u" />
        </span>
      </button>
    );
  }
  const locked = held || card.phase === 'sending';
  const capability = session.capabilities.answer;
  const send = (answer: PromptAnswer | null): void => {
    if (answer === null || locked) return;
    void actions.answerPrompt(prompt.id, answer);
  };
  const unavailable = capability.available ? null : (capability.reason ?? '');
  const hide = <HideButton onHide={() => setHidden(true)} />;
  if (isPermission) {
    return (
      <PermissionCard
        prompt={prompt}
        ui={permission}
        setUI={setPermission}
        locked={locked}
        refusal={card.refusal}
        unavailable={unavailable}
        hide={hide}
        send={send}
      />
    );
  }
  return (
    <QuestionCard
      questions={prompt.questions ?? []}
      ui={question}
      setUI={setQuestion}
      locked={locked}
      refusal={card.refusal}
      unavailable={unavailable}
      hide={hide}
      send={send}
    />
  );
}

function HideButton(p: { onHide: () => void }): JSX.Element {
  return (
    <button className="hide" type="button" onClick={p.onHide}>
      Hide <Icon name="chev-d" />
    </button>
  );
}

function Refusal(p: { text: string }): JSX.Element {
  return (
    <div className="refusal" role="alert">
      <Icon name="warn" />
      <span>{p.text}</span>
    </div>
  );
}

/**
 * While `open`, keeps the end of the card that holds `field` in view whenever the card's size
 * changes and `field` has focus, as when the keyboard comes up and the card shrinks to the room
 * left above it (see the header).
 */
function useEndInView(field: RefObject<HTMLTextAreaElement | null>, open: boolean): void {
  useEffect(() => {
    const el = field.current;
    const card = el?.closest('.card');
    if (!open || el == null || !(card instanceof HTMLElement) || typeof ResizeObserver !== 'function') return;
    const observer = new ResizeObserver(() => {
      if (el.ownerDocument.activeElement === el) card.scrollTop = card.scrollHeight;
    });
    observer.observe(card);
    return () => observer.disconnect();
  }, [field, open]);
}

/** The reason the session cannot answer, in place of the choices; nothing when the list gave none. */
function Unavailable(p: { reason: string }): JSX.Element | null {
  return p.reason === '' ? null : <div className="dock-note">{p.reason}</div>;
}

/** The permission card (see the header). */
function PermissionCard(p: {
  prompt: PhonePrompt;
  ui: PermissionUI;
  setUI: (ui: PermissionUI) => void;
  locked: boolean;
  refusal: string | null;
  /** The reason the session cannot answer, or null when it can. */
  unavailable: string | null;
  hide: JSX.Element;
  send: (answer: PromptAnswer | null) => void;
}): JSX.Element {
  const { prompt, ui, setUI, locked, send } = p;
  const denyID = useId();
  const denyField = useRef<HTMLTextAreaElement>(null);
  useEndInView(denyField, ui.denyOpen);
  const tool = prompt.toolName ?? '';
  const body = (
    <>
      <div className="c-head">
        <Icon name="hand" />
        Permission
        {p.hide}
      </div>
      <div className="perm-tool">
        <Icon name={toolGlyph(tool)} />
        {tool}
      </div>
      {prompt.summary !== undefined && <div className="perm-desc">{prompt.summary}</div>}
      {prompt.target !== undefined && <pre className="perm-target">{prompt.target + (prompt.targetTruncated ? '…' : '')}</pre>}
    </>
  );
  let choices: JSX.Element;
  if (p.unavailable !== null) {
    choices = <Unavailable reason={p.unavailable} />;
  } else if (ui.denyOpen) {
    choices = (
      <>
        {p.refusal !== null && <Refusal text={p.refusal} />}
        <label className="perm-desc" htmlFor={denyID}>Tell Claude what to do instead (optional)</label>
        <textarea
          ref={denyField}
          id={denyID}
          className="ta"
          rows={2}
          autoFocus
          value={ui.denyText}
          onChange={(e) => setUI({ ...ui, denyText: e.target.value })}
        />
        <div className="c-actions">
          <button className="btn" type="button" disabled={locked} onClick={() => setUI({ ...ui, denyOpen: false })}>Back</button>
          <button className="btn danger" type="button" disabled={locked} onClick={() => send(permissionAnswer('deny', ui.denyText))}>
            Deny
          </button>
        </div>
      </>
    );
  } else {
    choices = (
      <>
        {p.refusal !== null && <Refusal text={p.refusal} />}
        <div className="opts">
          <button className="opt pri" type="button" disabled={locked} onClick={() => send(permissionAnswer('allow'))}>Yes</button>
          {prompt.allowAlways && (
            <button className="opt" type="button" disabled={locked} onClick={() => send(permissionAnswer('allow_always'))}>
              Yes, and don't ask again this session
              {(prompt.suggestions ?? []).map((rule, i) => <small key={i}>{rule}</small>)}
            </button>
          )}
          <button className="opt danger" type="button" disabled={locked} onClick={() => setUI({ ...ui, denyOpen: true })}>No</button>
        </div>
      </>
    );
  }
  return (
    <div className="card" role="region" aria-label="Permission prompt">
      {body}
      {choices}
    </div>
  );
}

/** The question card (see the header). */
function QuestionCard(p: {
  questions: readonly PhoneQuestion[];
  ui: QuestionUI;
  setUI: (ui: QuestionUI) => void;
  locked: boolean;
  refusal: string | null;
  /** The reason the session cannot answer, or null when it can. */
  unavailable: string | null;
  hide: JSX.Element;
  send: (answer: PromptAnswer | null) => void;
}): JSX.Element {
  const { questions, ui, setUI, locked, send } = p;
  const otherField = useRef<HTMLTextAreaElement>(null);
  useEndInView(otherField, ui.otherOpen);
  const total = questions.length;
  const step = Math.min(ui.step, total);
  const several = total > 1;
  const shownStep = Math.min(step + 1, total);
  const head = (
    <>
      <div className="c-head">
        <Icon name="hand" />
        Claude asks{several ? ` · ${shownStep} of ${total}` : ''}
        {p.hide}
      </div>
      {several && (
        <div
          className="steps"
          role="progressbar"
          aria-label="Claude asks"
          aria-valuemin={1}
          aria-valuemax={total}
          aria-valuenow={shownStep}
          aria-valuetext={`${shownStep} of ${total}`}
        >
          {questions.map((_, i) => <i key={i} className={i <= step ? 'on' : ''} />)}
        </div>
      )}
    </>
  );

  if (p.unavailable !== null || total === 0) {
    const q = questions[Math.min(step, total - 1)];
    return (
      <div className="card" role="region" aria-label="Question">
        {head}
        {q !== undefined && <div className="q">{q.text}</div>}
        {p.unavailable !== null && <Unavailable reason={p.unavailable} />}
      </div>
    );
  }

  const refusal = p.refusal === null ? null : <Refusal text={p.refusal} />;
  /** The answer once `draft` gives every question a value, and the question after `step` otherwise. */
  const advance = (draft: QuestionDraft): void => {
    if (!several) {
      setUI({ ...ui, draft });
      send(questionAnswer(questions, draft));
    } else {
      setUI({ draft, step: step + 1, otherOpen: false, otherText: '' });
    }
  };
  const back = (): void => setUI({ ...ui, step: Math.max(0, step - 1), otherOpen: false });

  if (step >= total) {
    const answer = questionAnswer(questions, ui.draft);
    return (
      <div className="card" role="region" aria-label="Questions">
        {head}
        <div className="q">Send these answers?</div>
        {refusal}
        <div className="review">
          {questions.map((q, i) => (
            <button key={i} type="button" disabled={locked} onClick={() => setUI({ ...ui, step: i, otherOpen: false })}>
              <small>{q.header ?? q.text}</small>
              {questionValue(q, ui.draft) ?? ''}
            </button>
          ))}
        </div>
        <div className="c-actions">
          <button className="btn" type="button" disabled={locked} onClick={back}>Back</button>
          <button className="btn pri" type="button" disabled={locked || answer === null} onClick={() => send(answer)}>Send answers</button>
        </div>
      </div>
    );
  }

  const q = questions[step]!;
  const openOther = (): void => setUI({ ...ui, otherOpen: true, otherText: ui.draft.other[q.text] ?? '' });
  const cancelOther = (): void => {
    const draft = q.multiSelect && ui.draft.otherChosen[q.text] === true ? chooseOther(ui.draft, q) : ui.draft;
    setUI({ ...ui, draft, otherOpen: false });
  };
  const sendOther = (): void => {
    if (trimLikeLaptop(ui.otherText) === '') return;
    advance(setOtherText(ui.draft, q, ui.otherText));
  };
  const otherButton = ui.otherOpen ? null : (
    <button className="opt ghost" type="button" disabled={locked} onClick={openOther}>Other answer…</button>
  );
  const otherForm = ui.otherOpen && (
    <>
      <textarea
        ref={otherField}
        className="ta"
        rows={2}
        placeholder="Type your answer"
        aria-label="Type your answer"
        autoFocus
        value={ui.otherText}
        onChange={(e) => setUI({ ...ui, otherText: e.target.value })}
      />
      <div className="c-actions">
        <button className="btn" type="button" disabled={locked} onClick={cancelOther}>Cancel</button>
        <button className="btn pri" type="button" disabled={locked || trimLikeLaptop(ui.otherText) === ''} onClick={sendOther}>
          Send answer
        </button>
      </div>
    </>
  );
  const backButton = several && step > 0
    ? <button className="btn" type="button" disabled={locked} onClick={back}>Back</button>
    : null;

  if (q.multiSelect) {
    const picked = ui.draft.picks[q.text] ?? [];
    const count = q.options.filter((o) => picked.includes(o.label)).length;
    const value = questionValue(q, ui.draft);
    return (
      <div className="card" role="region" aria-label="Question">
        {head}
        <div className="q">{q.text}</div>
        {refusal}
        <div className="opts">
          {q.options.map((o, i) => (
            <label key={i} className="chk">
              <input
                type="checkbox"
                checked={picked.includes(o.label)}
                disabled={locked}
                onChange={() => setUI({ ...ui, draft: chooseOption(ui.draft, q, o.label) })}
              />
              <span>
                {o.label}
                {o.description !== undefined && (
                  <>
                    <br />
                    <small style={MUTED}>{o.description}</small>
                  </>
                )}
              </span>
            </label>
          ))}
          {otherButton}
        </div>
        {otherForm || (
          <div className="c-actions">
            {backButton}
            <button className="btn pri" type="button" disabled={locked || value === null} onClick={() => advance(ui.draft)}>
              {count > 0 ? `Send ${count} selected` : 'Send answer'}
            </button>
          </div>
        )}
      </div>
    );
  }

  return (
    <div className="card" role="region" aria-label="Question">
      {head}
      <div className="q">{q.text}</div>
      {refusal}
      <div className="opts">
        {q.options.map((o, i) => (
          <button key={i} className="opt" type="button" disabled={locked} onClick={() => advance(chooseOption(ui.draft, q, o.label))}>
            {o.label}
            {o.description !== undefined && <small>{o.description}</small>}
          </button>
        ))}
        {otherButton}
      </div>
      {otherForm}
      {!ui.otherOpen && backButton !== null && <div className="c-actions">{backButton}</div>}
    </div>
  );
}

/** A checkbox description's colour, as the mock writes it inline (mock 973): app.css has no rule for `.chk small`. */
const MUTED = { color: 'var(--muted)' } as const;
