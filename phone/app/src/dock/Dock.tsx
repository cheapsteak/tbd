/**
 * The dock at the bottom of the session screen (mock `sessionHTML`, `.dock`): the card of the
 * prompt waiting in the open session, if any, then the composer. Contract: `Dock({ session })`.
 * The session screen keys it by the session, so a switch to another session mounts it afresh.
 *
 * **Which card.** One at a time, the one `cardFor` picks from the prompt slice: an `elsewhere`
 * card first, since it waits for OK, then one on its way or answered, then the first open prompt
 * in the order the laptop sent. The card is keyed by its prompt's ID.
 *
 * **What the user did on a card** (`CardUI`: the picks, the question shown, the Other text, the
 * deny text, and whether the card is hidden) is kept here by prompt ID rather than in the card.
 * So a card that another prompt's card displaced for a while, as when another of the session's
 * prompts was answered elsewhere and its card waits for OK, comes back as the user left it, and a
 * new prompt starts afresh: expanded, with nothing picked or typed. Only the prompts that still
 * have a card in the slice keep theirs.
 *
 * **No tap lands on what the user has not seen.** A card that appears, or that changes under the
 * finger, can take the second tap of a double tap, or a tap meant for what was there a moment
 * before, such as a transcript row when the dock grows over it. So for `TAP_GUARD_MS` the card's
 * choices and buttons are disabled (`held`), with a real `disabled`, so a tap on them does
 * nothing at all:
 * - when the dock shows a card it did not show the moment before: from none, or in place of
 *   another prompt's card, as when one of several prompts is answered and the next takes its
 *   place about one round trip later. The one exception is a card that appears from none within
 *   `OPENING_MS` of the dock mounting: it was there as the session opened, before the user could
 *   aim a tap at anything else;
 * - when the card's view changes (`cardView`): it expands from its strip, moves to another
 *   question or to or from the review, opens or closes the Other or the deny form, shows a
 *   refusal, gains or loses its choices as the session's answer capability changes, or turns
 *   into Answered or Answered elsewhere;
 * - when a sheet or a menu closes (`useUncoverHold`): the card shows again under the finger that
 *   closed it, as when the second tap of a double tap on the scrim, or outside a menu, lands on a
 *   choice.
 * A change during a hold starts it again.
 *
 * The composer's Send is held the same way (`useChangeHold` in `ui/tapGuard.ts`, which holds the
 * menus' and the sheets' acting buttons too), from the first render that shows it until
 * `TAP_GUARD_MS` later: when the dock mounts, since a draft kept from before can leave Send
 * enabled the moment the session opens, under the second tap of a double tap on its row; when the
 * composer replaces the note that sending is unavailable; and when its label changes between
 * "Send" and "Send and wake", which moves its edge over the textarea; and when a sheet or a menu
 * closes, since the session menu's Cancel sits right over Send. Nothing on the card holds Send:
 * the card sits above the composer, and the dock grows upward from the screen's bottom, so the
 * card never moves it.
 */

import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import type { JSX } from 'react';
import type { PhoneSession } from '../protocol/types.ts';
import { useAppState } from '../state/context.tsx';
import { cardFor, cardKey } from '../state/prompts.ts';
import { TAP_GUARD_MS, useChangeHold, useUncoverHold } from '../ui/tapGuard.ts';
import { Composer, sendLabel } from './Composer.tsx';
import { cardView, FRESH_CARD_UI, PromptCard } from './PromptCard.tsx';
import type { CardUI } from './PromptCard.tsx';

/** How long after the dock mounts a card that appears is taken as there when the session opened, in milliseconds. */
export const OPENING_MS = 1000;

export function Dock({ session }: { session: PhoneSession }): JSX.Element {
  const prompts = useAppState((s) => s.prompts);
  const ref = session.ref;
  const shown = useMemo(() => cardFor(prompts, ref), [prompts, ref]);
  const [drafts, setDrafts] = useState<ReadonlyMap<string, CardUI>>(() => new Map());
  const id = shown === null ? null : shown.prompt.id;
  const ui = id === null ? FRESH_CARD_UI : (drafts.get(id) ?? FRESH_CARD_UI);
  const view = shown === null ? null : cardView(shown.card, ui, session.capabilities.answer.available);
  const covered = useAppState((s) => s.ui.sheet !== null || s.ui.menu !== null);
  const uncoverHeld = useUncoverHold(covered);
  const held = useTapGuard(id, view) || (id !== null && uncoverHeld);
  const sendHeld = useChangeHold(sendLabel(session)) || uncoverHeld;
  const setUI = (next: CardUI): void => {
    if (id === null) return;
    setDrafts((before) => {
      const after = new Map<string, CardUI>();
      for (const [promptID, kept] of before) if (Object.hasOwn(prompts.cards, cardKey(ref, promptID))) after.set(promptID, kept);
      after.set(id, next);
      return after;
    });
  };
  return (
    <div className="dock">
      {shown !== null && (
        <PromptCard key={shown.prompt.id} session={session} prompt={shown.prompt} card={shown.card} held={held} ui={ui} setUI={setUI} />
      )}
      <Composer session={session} held={sendHeld} />
    </div>
  );
}

/** The card the dock shows: its prompt's ID and its `cardView`, each null while it shows none. */
interface Shown {
  id: string | null;
  view: string | null;
}

/**
 * Whether the card of prompt `id`, in `view`, keeps its choices disabled now: from the first
 * render that shows it after a change that holds (`holds`) until `TAP_GUARD_MS` later. The first
 * render is covered by comparing with the card shown last before the effect records it, so no
 * frame ever draws the choices enabled; the timer covers the rest.
 */
function useTapGuard(id: string | null, view: string | null): boolean {
  const [opening, setOpening] = useState(true);
  /** The card the dock showed last. */
  const last = useRef<Shown>({ id: null, view: null });
  const [held, setHeld] = useState<Shown | null>(null);
  const timers = useRef(new Set<ReturnType<typeof setTimeout>>());

  useLayoutEffect(() => {
    const before = last.current;
    if (before.id === id && before.view === view) return;
    const now: Shown = { id, view };
    last.current = now;
    if (!holds(before, now, opening)) return;
    setHeld(now);
    const timer = setTimeout(() => {
      timers.current.delete(timer);
      setHeld((h) => (h === now ? null : h));
    }, TAP_GUARD_MS);
    timers.current.add(timer);
  }, [id, view, opening]);

  useEffect(() => {
    const timer = setTimeout(() => setOpening(false), OPENING_MS);
    const pending = timers.current;
    return () => {
      clearTimeout(timer);
      for (const t of pending) clearTimeout(t);
      pending.clear();
    };
  }, []);

  if (id === null) return false;
  if (held !== null && held.id === id && held.view === view) return true;
  const before = last.current;
  return (before.id !== id || before.view !== view) && holds(before, { id, view }, opening);
}

/**
 * Whether the dock's change from showing `before` to showing `after` holds the new card's
 * choices: the same prompt's card in another view, another prompt's card, or a card after none
 * unless the dock is still `opening`.
 */
function holds(before: Shown, after: Shown, opening: boolean): boolean {
  if (after.id === null) return false;
  if (before.id === after.id) return before.view !== after.view;
  return before.id !== null || !opening;
}
