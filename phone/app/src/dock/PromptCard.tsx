/**
 * The card of one waiting prompt, in the dock above the composer (spec section 8.3; mock
 * `promptHTML`, mock 938-986). Contract: `PromptCard({ session, prompt, card, live, held, ui,
 * setUI })`, where `card` is the prompt's card in the prompt slice (`cardFor`), `live` says the
 * session's transcript is open, so its prompt set is the laptop's live one (`promptsLive`), `held`
 * says its choices wait (the dock's tap guard), and `ui` is what the user picked, typed or hid on
 * it (`CardUI`), which the dock keeps by prompt ID and card (`serial`) and `setUI` replaces. The
 * dock keys the card by both, so none of that ever carries over to another prompt or card.
 *
 * **A question** (`QuestionCard`). The head (`.c-head`) holds the hand glyph, "Claude asks", and
 * " · i of n" with `.steps` under it when the prompt asks several questions, then Hide.
 * - A single-select question's options are `.opt` buttons, each with its description as a
 *   `<small>`. A multi-select question's are `.chk` checkboxes, then "Send N selected", or "Send
 *   answer" while none is picked. N counts the Other value too while it counts (`selectedCount`).
 * - Every question offers "Other answer…" (the ghost `.opt`), multi-select included, since the
 *   laptop takes an Other value on every question. It opens a textarea ("Type your answer") with
 *   Cancel and a button that depends on the question:
 *   - single-select: "Send answer", disabled while the text is blank, since a blank Other is no
 *     value. The text becomes the question's value, as a tapped option does (see Steps);
 *   - multi-select: "Done", which only records the text (`setOtherText`) and returns to the
 *     checkboxes, so the Other value goes out after the ticked labels, and only through "Send N
 *     selected". The laptop has no such form: its Other row is a checkbox beside a text
 *     field, and the card sends only through Submit. So, as there, a recorded Other text shows
 *     as a `.chk` checkbox of its own after the options, ticked, labelled with the text.
 *     Unticking it leaves the text out of the answer and ticking it puts it back (`chooseOther`,
 *     which toggles Other on a multi-select question, as the laptop's marker does); clearing the
 *     text and pressing Done removes the value and the checkbox, as clearing the laptop's field
 *     leaves Other with no value. Done is enabled while the text is blank for that reason.
 * - **Steps.** With one question, a tap that gives it a value sends the answer at once; for a
 *   multi-select question that tap is "Send N selected". With several, it records the value and
 *   moves to the next question, and Back returns to the one before. After the last comes the
 *   review: "Send these answers?", one button per question with its header and value (a tap
 *   returns to that question), then Back and "Send answers".
 * - **Focus.** A move to another question or to or from the review puts the focus on the
 *   question's text (`.q`, focusable by script only), not on whichever button now sits where the
 *   one tapped was, so a key press meant for the last question never answers the next.
 * - Cancel closes the Other form and leaves the draft as it was, so an Other value recorded
 *   before stays recorded.
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
 * computes the summary and sends once per gesture: it sends nothing unless the card is `open` and
 * the session's transcript is open. While the card is `sending`, while `held`, and while the card
 * is not `live` (the transcript is opening, failed or closed, so the set may be stale and an answer
 * would go nowhere), every choice and button but Hide is disabled, so a tap sends nothing either.
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
 * the field and the buttons after it stay above the keyboard. It follows the textarea itself,
 * through its ref, so a form that was open while the card showed no choices, and whose textarea
 * mounts once they come back, is kept in view all the same.
 *
 * **Answered** (mock 941). Once the laptop took this phone's answer, and until the prompt closes,
 * the card is `.card.done` with the check glyph, "Answered" and the answer's summary.
 *
 * **Answered elsewhere** (mock 942). When someone else answered first, the card says so until OK
 * (`dismissPrompt`): "Already answered on the laptop", "Someone answered this question at the
 * laptop first.", with "permission" for a permission, when the laptop answered or did not say
 * who; "Already answered on another phone", "Someone answered this question on another phone
 * first.", when another phone did. Its OK waits while `held` too.
 *
 * **Hide** collapses the card to `.card-strip`, "Question waiting" or "Permission waiting", with
 * "Show". Hiding keeps what the user picked and typed; a new prompt starts expanded.
 */

import { useCallback, useEffect, useId, useRef } from 'react';
import type { JSX, RefObject } from 'react';
import type { PhonePrompt, PhoneQuestion, PhoneSession, PromptAnswer } from '../protocol/types.ts';
import { useActions } from '../state/context.tsx';
import {
  chooseOption, chooseOther, emptyQuestionDraft, otherCounts, otherText, permissionAnswer, questionAnswer, questionValue, selectedCount,
  setOtherText, trimLikeLaptop,
} from '../state/prompts.ts';
import type { CardState, QuestionDraft } from '../state/prompts.ts';
import { toolGlyph } from '../state/status.ts';
import { Icon } from '../ui/Icon.tsx';

/** What the user has done on a question card: the draft, the question shown (the review once past the last), and the Other form. */
interface QuestionUI {
  draft: QuestionDraft;
  /** The question shown, by index; the questions' count for the review. */
  step: number;
  /** Whether the shown question's Other form is open. */
  otherOpen: boolean;
  /** The text in the Other form. It goes into the draft only through the form's "Send answer" or "Done". */
  otherText: string;
}

/** What the user has done on a permission card: whether the deny form is open, and its text. */
interface PermissionUI {
  denyOpen: boolean;
  denyText: string;
}

/** What the user has done on one prompt's card, whichever kind it is, and whether it is hidden to its strip. */
export interface CardUI {
  hidden: boolean;
  question: QuestionUI;
  permission: PermissionUI;
}

/** A card the user has done nothing on: expanded, at its first question, nothing picked or typed. */
export const FRESH_CARD_UI: CardUI = {
  hidden: false,
  question: { draft: emptyQuestionDraft(), step: 0, otherOpen: false, otherText: '' },
  permission: { denyOpen: false, denyText: '' },
};

/**
 * What the card of `card` shows with `ui`, as a key that changes whenever what sits under the
 * user's finger may change (the dock's tap guard): Answered, Answered elsewhere, the strip, or
 * the choices of one question or of the review, with or without the Other or the deny form, a
 * refusal, an answer on its way, and the capability to answer. So choices that come back as an
 * answer settles wait like any others, with a refusal or without one. A pick that only changes a
 * checkbox or a count keeps it.
 */
export function cardView(card: CardState, ui: CardUI, canAnswer: boolean): string {
  if (card.phase === 'answered' || card.phase === 'elsewhere') return card.phase;
  if (ui.hidden) return 'hidden';
  return JSON.stringify([canAnswer, card.phase, card.refusal !== null, ui.question.step, ui.question.otherOpen, ui.permission.denyOpen]);
}

export function PromptCard(p: {
  session: PhoneSession;
  prompt: PhonePrompt;
  card: CardState;
  live: boolean;
  held: boolean;
  ui: CardUI;
  setUI: (ui: CardUI) => void;
}): JSX.Element {
  const { session, prompt, card, live, held, ui, setUI } = p;
  const actions = useActions();

  const isPermission = prompt.kind === 'permission';
  if (card.phase === 'answered') {
    return (
      <div className="card done" role="status">
        <span className="ok">
          <Icon name="check" />
        </span>
        <div>
          <b>Answered</b>
          <small>{card.summary ?? ''}</small>
        </div>
      </div>
    );
  }
  if (card.phase === 'elsewhere') {
    const what = isPermission ? 'permission' : 'question';
    const byPhone = card.elsewhereBy === 'phone';
    return (
      <div className="card done" role="status">
        <span className="ok">
          <Icon name={byPhone ? 'check' : 'laptop'} />
        </span>
        <div>
          <b>{byPhone ? 'Already answered on another phone' : 'Already answered on the laptop'}</b>
          <small>{byPhone ? `Someone answered this ${what} on another phone first.` : `Someone answered this ${what} at the laptop first.`}</small>
        </div>
        <button className="btn" type="button" disabled={held} onClick={() => { if (!held) actions.dismissPrompt(prompt.id); }}>OK</button>
      </div>
    );
  }
  if (ui.hidden) {
    return (
      <button className="card-strip" type="button" onClick={() => setUI({ ...ui, hidden: false })}>
        <Icon name="hand" />
        {isPermission ? 'Permission waiting' : 'Question waiting'}
        <span>
          Show <Icon name="chev-u" />
        </span>
      </button>
    );
  }
  const locked = held || !live || card.phase === 'sending';
  const capability = session.capabilities.answer;
  const send = (answer: PromptAnswer | null): void => {
    if (answer === null || locked) return;
    void actions.answerPrompt(prompt.id, answer);
  };
  const unavailable = capability.available ? null : (capability.reason ?? '');
  const hide = <HideButton onHide={() => setUI({ ...ui, hidden: true })} />;
  if (isPermission) {
    return (
      <PermissionCard
        prompt={prompt}
        ui={ui.permission}
        setUI={(permission) => setUI({ ...ui, permission })}
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
      ui={ui.question}
      setUI={(question) => setUI({ ...ui, question })}
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

/** The laptop's words for something it refused, as `.refusal` (`role="alert"`) with the warn glyph; the composer shows its refusal the same way. */
export function Refusal(p: { text: string }): JSX.Element {
  return (
    <div className="refusal" role="alert">
      <Icon name="warn" />
      <span>{p.text}</span>
    </div>
  );
}

/**
 * Why something cannot act, the laptop's reason or a rule's, as a `tag` element with `className`,
 * or nothing for null or for an empty reason, since the laptop need not give one. Every such
 * reason shows through it: the card's in place of its choices (`.dock-note`), the session menu's
 * under a row, and the sheets' and the account menu's under what they cannot do.
 */
export function Reason(p: { text: string | null; tag: 'div' | 'p' | 'span' | 'small'; className?: string }): JSX.Element | null {
  if (p.text === null || p.text === '') return null;
  const Tag = p.tag;
  return <Tag className={p.className}>{p.text}</Tag>;
}

/**
 * The ref for a form's textarea that keeps the end of the card holding it in view whenever the
 * card's size changes and the textarea has focus, as when the keyboard comes up and the card
 * shrinks to the room left above it (see the header). It watches from the moment the textarea
 * mounts until it unmounts, whenever that is, so it never misses a textarea that mounts later
 * than its form opened. It does nothing where the browser has no `ResizeObserver`.
 */
function useEndInView(): (el: HTMLTextAreaElement | null) => (() => void) | undefined {
  return useCallback((el: HTMLTextAreaElement | null) => {
    const card = el?.closest('.card');
    if (el == null || !(card instanceof HTMLElement) || typeof ResizeObserver !== 'function') return undefined;
    const observer = new ResizeObserver(() => {
      if (el.ownerDocument.activeElement === el) card.scrollTop = card.scrollHeight;
    });
    observer.observe(card);
    return () => observer.disconnect();
  }, []);
}

/**
 * Puts the focus on `el` whenever `step` changes after the first render, so the focus leaves the
 * button that was tapped or pressed (see the header).
 */
function useFocusOnStep(el: RefObject<HTMLElement | null>, step: number): void {
  const last = useRef(step);
  useEffect(() => {
    if (last.current === step) return;
    last.current = step;
    el.current?.focus({ preventScroll: true });
  }, [el, step]);
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
  const denyField = useEndInView();
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
  const refusal = p.refusal === null ? null : <Refusal text={p.refusal} />;
  let choices: JSX.Element;
  if (p.unavailable !== null) {
    choices = <Reason text={p.unavailable} tag="div" className="dock-note" />;
  } else if (ui.denyOpen) {
    choices = (
      <>
        {refusal}
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
        {refusal}
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
  const otherField = useEndInView();
  const total = questions.length;
  const step = Math.min(ui.step, total);
  const questionText = useRef<HTMLDivElement>(null);
  useFocusOnStep(questionText, step);
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
        {q !== undefined && <div ref={questionText} className="q" tabIndex={-1}>{q.text}</div>}
        <Reason text={p.unavailable} tag="div" className="dock-note" />
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
        <div ref={questionText} className="q" tabIndex={-1}>Send these answers?</div>
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
  const cancelOther = (): void => setUI({ ...ui, otherOpen: false });
  /** Single-select: the typed text is the question's value, sent or recorded as a tapped option is. */
  const sendOther = (): void => {
    if (trimLikeLaptop(ui.otherText) === '') return;
    advance(setOtherText(ui.draft, q, ui.otherText));
  };
  /** Multi-select: the typed text is recorded beside the ticked labels, and the checkboxes show again; nothing is sent. */
  const keepOther = (): void => setUI({ ...ui, draft: setOtherText(ui.draft, q, ui.otherText), otherOpen: false });
  const otherButton = ui.otherOpen ? null : (
    <button className="opt ghost" type="button" disabled={locked} onClick={openOther}>Other answer…</button>
  );
  /** The Other form, ending in `action`, while it is open; null otherwise. */
  const otherForm = (action: JSX.Element): JSX.Element | null => !ui.otherOpen ? null : (
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
        {action}
      </div>
    </>
  );
  const backButton = several && step > 0
    ? <button className="btn" type="button" disabled={locked} onClick={back}>Back</button>
    : null;

  if (q.multiSelect) {
    const picked = ui.draft.picks[q.text] ?? [];
    const other = otherText(ui.draft, q);
    const count = selectedCount(q, ui.draft);
    const value = questionValue(q, ui.draft);
    const form = otherForm(<button className="btn pri" type="button" disabled={locked} onClick={keepOther}>Done</button>);
    return (
      <div className="card" role="region" aria-label="Question">
        {head}
        <div ref={questionText} className="q" tabIndex={-1}>{q.text}</div>
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
          {other !== '' && (
            <label className="chk">
              <input
                type="checkbox"
                checked={otherCounts(ui.draft, q)}
                disabled={locked}
                onChange={() => setUI({ ...ui, draft: chooseOther(ui.draft, q) })}
              />
              <span>{other}</span>
            </label>
          )}
          {otherButton}
        </div>
        {form ?? (
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
      <div ref={questionText} className="q" tabIndex={-1}>{q.text}</div>
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
      {otherForm(
        <button className="btn pri" type="button" disabled={locked || trimLikeLaptop(ui.otherText) === ''} onClick={sendOther}>
          Send answer
        </button>,
      )}
      {!ui.otherOpen && backButton !== null && <div className="c-actions">{backButton}</div>}
    </div>
  );
}

/** A checkbox description's colour, as the mock writes it inline (mock 973): app.css has no rule for `.chk small`. */
const MUTED = { color: 'var(--muted)' } as const;
