/**
 * The composer at the bottom of the dock: the open session's unsent text and Send (spec section
 * 8.3; mock `composerHTML`, mock 989-997). Contract: `Composer({ session, held })`, where
 * `session` is the open session and `held` says Send waits (the dock's tap guard). The dock
 * renders it below the prompt card. It reads the draft from `ui.drafts` and the laptop's last
 * refusal from `ui.refusal`, both by `refKey` of the session, and acts through `setDraft` and
 * `sendMessage` (`actions/prompts.ts`), which read their target from the store when the user
 * taps, never from this render.
 *
 * **The refusal**, when there is one, comes first, as `.refusal` (`role="alert"`) with the warn
 * glyph, whether or not the session can take messages. It holds whatever `ui.refusal` holds for
 * the session: a refused message, a refused switch or model change, or a fork's error that no
 * sheet or menu showed. So the words of a request made from a menu or a sheet never go unshown,
 * even on a session that takes no messages.
 *
 * **Sending unavailable.** When the list shows the session's `send` capability unavailable, the
 * rest of the composer is the `.dock-note` "Sending is not available for this session.", the
 * mock's words, whatever reason the list gives.
 *
 * **Otherwise:**
 * - `.comp`: the `textarea.field` ("Message", one row, growing with its text to at most
 *   `MAX_FIELD_PX`), then `button.send`, which reads "Send and wake" while the list shows the
 *   session `parked` and "Send" otherwise (`sendLabel`).
 *
 * **Send** is enabled while the draft is not blank (`isBlankMessage`), no message to the session
 * is on its way (`isSending`), and the dock does not hold it. The session's status plays no part:
 * the laptop decides, and the composer shows its reply. Enter in the textarea is a new line, as in
 * the mock; only the button sends. The textarea stays editable while a message is on its way.
 *
 * **Where Send sits.** The dock is the last thing on the screen and grows upward, and `.comp` is
 * its last row, with Send at its end (`align-items:flex-end`). So a prompt card that appears,
 * grows or goes above the composer, a refusal that shows, or the textarea growing, never moves
 * Send. What can put Send under a finger aimed elsewhere is Send itself appearing or changing its
 * label, and the dock holds it then.
 */

import { useLayoutEffect, useRef } from 'react';
import type { JSX } from 'react';
import type { PhoneSession } from '../protocol/types.ts';
import { refKey } from '../protocol/wire.ts';
import { useActions, useAppState } from '../state/context.tsx';
import { isBlankMessage, isSending, textAt } from '../state/prompts.ts';
import { Refusal } from './PromptCard.tsx';

/** The tallest the textarea grows, in CSS pixels (mock `autosize`). */
export const MAX_FIELD_PX = 140;

/** Send's label for `session` ("Send and wake" while the list shows it parked, "Send" otherwise), or null when it cannot take a message. */
export function sendLabel(session: PhoneSession): string | null {
  if (!session.capabilities.send.available) return null;
  return session.status.chip === 'parked' ? 'Send and wake' : 'Send';
}

export function Composer({ session, held }: { session: PhoneSession; held: boolean }): JSX.Element {
  const actions = useActions();
  const key = refKey(session.ref);
  const draft = useAppState((s) => textAt(s.ui.drafts, key) ?? '');
  const refusal = useAppState((s) => textAt(s.ui.refusal, key));
  const sending = useAppState((s) => isSending(s.prompts, session.ref));
  const label = sendLabel(session);
  const field = useRef<HTMLTextAreaElement>(null);

  // Its height follows its text: measured at its natural height, then capped (mock `autosize`).
  // Send's label takes room from it, so a new label measures it again.
  useLayoutEffect(() => {
    const el = field.current;
    if (el === null) return;
    el.style.height = 'auto';
    el.style.height = `${Math.min(el.scrollHeight + 2, MAX_FIELD_PX)}px`;
  }, [draft, label]);

  const shownRefusal = refusal === null ? null : <Refusal text={refusal} />;
  if (label === null) {
    return (
      <>
        {shownRefusal}
        <div className="dock-note">Sending is not available for this session.</div>
      </>
    );
  }
  return (
    <>
      {shownRefusal}
      <div className="comp">
        <textarea
          ref={field}
          className="field"
          rows={1}
          placeholder="Message"
          aria-label="Message"
          value={draft}
          onChange={(e) => actions.setDraft(e.currentTarget.value)}
        />
        <button
          className="send"
          type="button"
          disabled={isBlankMessage(draft) || sending || held}
          onClick={() => void actions.sendMessage()}
        >
          {label}
        </button>
      </div>
    </>
  );
}
